"""Ingestion des sorties du pipeline java-legacy-agent vers LEGACY_AI_DB.CORE.LEGACY_DOCS.

Chaine complete :

    dossiers locaux  --PUT-->  @DOCS_STAGE/legacy_docs/
                     --COPY INTO-->  LEGACY_DOCS_RAW   (1 fichier = 1 ligne)
                     --SPLIT_TEXT_RECURSIVE_CHARACTER-->  LEGACY_DOCS  (1 chunk = 1 ligne)

Le decoupage et l'extraction des metadonnees sont faits en SQL cote Snowflake
(sql/20_chunk.sql). Ce script ne fait que decouvrir les fichiers, verifier leur
encodage, les televerser, et piloter l'execution.

Corpus reel : 3 fichiers markdown agreges, repartis sur deux dossiers.

    handoff/<projet>/specs.md          JavaDocumentationAgent
    handoff/<projet>/dependencies.md   DependencyMapperAgent
    migration-output/migration_*.md    LegacyMigrationOrchestrator

Volontairement EXCLUS de LEGACY_DOCS :
  - manifest.txt          metadonnee pure (project/fileCount/generatedAt),
                          sans valeur pour la recherche semantique
  - metrics_<projet>.json structure tabulaire -> alimentera BENCHMARK_METRICS
                          (Cortex Analyst, J3), pas le Search Service

Plusieurs dossiers d'entree sont acceptes. `source_file` est calcule relativement
a leur ancetre commun, ce qui donne des identifiants stables et sans collision
(ex. handoff/demo-project/specs.md, migration-output/migration_...md).

Exemples
--------
    python src/ingest.py <handoff>/demo-project <repo>/migration-output --dry-run
    python src/ingest.py <handoff>/demo-project <repo>/migration-output

Authentification : uniquement via ~/.snowflake/connections.toml (connexion
`legacy_ai` par defaut). Aucun credential n'est lu depuis les arguments.
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import sys
from pathlib import Path

LOG = logging.getLogger("ingest")

# --- Constantes projet -------------------------------------------------------

STAGE = "@DOCS_STAGE"
STAGE_PREFIX = "legacy_docs"  # doit rester aligne avec le COPY INTO de sql/20_chunk.sql

# Aligne sur le PATTERN du COPY INTO. Le .txt est volontairement absent : il ne
# ramenerait que manifest.txt, explicitement hors perimetre.
DEFAULT_EXTENSIONS = (".md", ".markdown")

# Exclusions par nom de fichier, insensibles a la casse. Filet de securite qui
# double le filtre par extension : si quelqu'un ajoute .txt aux extensions,
# manifest.txt reste dehors.
EXCLUDED_NAMES = {"manifest.txt"}

CHUNK_SQL = Path(__file__).resolve().parents[1] / "sql" / "20_chunk.sql"

# Les variables de session sont injectees en litteral (Snowflake n'accepte pas de
# bind sur SET). On restreint donc severement ce qui peut y passer.
SAFE_IDENT_RE = re.compile(r"^[A-Za-z0-9_. -]{1,128}$")


# --- Decouverte des fichiers -------------------------------------------------


def common_base(roots: list[Path]) -> Path:
    """Ancetre commun des dossiers d'entree, base des chemins relatifs."""
    if len(roots) == 1:
        return roots[0]
    return Path(os.path.commonpath([str(r) for r in roots]))


def discover_files(
    roots: list[Path], extensions: tuple[str, ...], limit: int | None
) -> tuple[Path, list[tuple[Path, Path]]]:
    """Retourne (base, [(chemin_absolu, chemin_relatif), ...]) trie, ordre stable."""
    for root in roots:
        if not root.is_dir():
            raise SystemExit(f"Dossier d'entree introuvable : {root}")

    base = common_base(roots)
    wanted = {e.lower() for e in extensions}

    found: dict[Path, Path] = {}
    for root in roots:
        for p in root.rglob("*"):
            if not p.is_file():
                continue
            if p.suffix.lower() not in wanted:
                continue
            if p.name.lower() in EXCLUDED_NAMES:
                LOG.info("exclu (hors perimetre LEGACY_DOCS) : %s", p.name)
                continue
            found[p.resolve()] = p.resolve().relative_to(base)

    files = sorted(found.items(), key=lambda kv: kv[1].as_posix())

    if not files:
        raise SystemExit(
            f"Aucun fichier {'/'.join(sorted(wanted))} sous {', '.join(str(r) for r in roots)}. "
            "Verifier les dossiers ou ajuster --extensions."
        )

    if limit is not None:
        files = files[:limit]

    return base, files


def check_utf8(files: list[tuple[Path, Path]]) -> None:
    """Refuse le lot si un fichier n'est pas de l'UTF-8 valide.

    PUT transfere des octets ; c'est le COPY INTO (ENCODING = 'UTF8') qui decode.
    Sans ce controle, un fichier en cp1252 passerait le PUT puis produirait des
    caracteres corrompus en base — une corruption silencieuse, exactement ce
    qu'on ne veut pas dans un corpus documentaire.
    """
    for abs_path, rel in files:
        raw = abs_path.read_bytes()
        try:
            raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise SystemExit(
                f"{rel.as_posix()} n'est pas de l'UTF-8 valide "
                f"(octet {exc.start}) — ingestion interrompue pour ne pas "
                "corrompre le corpus."
            ) from exc
        if raw.startswith(b"\xef\xbb\xbf"):
            LOG.warning(
                "%s commence par un BOM UTF-8 ; il sera present dans le premier chunk.",
                rel.as_posix(),
            )
    LOG.info("Encodage : %d fichier(s) valides en UTF-8.", len(files))


# --- PUT ---------------------------------------------------------------------


def stage_target(rel_path: Path) -> str:
    """Repertoire de destination dans le stage, arborescence relative preservee."""
    parent = rel_path.parent.as_posix()
    if parent in (".", ""):
        return f"{STAGE}/{STAGE_PREFIX}/"
    return f"{STAGE}/{STAGE_PREFIX}/{parent}/"


def put_statement(local_path: Path, rel_path: Path) -> str:
    """Construit le PUT.

    AUTO_COMPRESS = FALSE : le COPY INTO lit le fichier tel quel et
    METADATA$FILENAME reste lisible (pas de suffixe .gz).
    OVERWRITE = TRUE : un fichier reingere remplace sa version precedente.
    """
    # Windows : le connecteur attend une URI file:// avec des slashs.
    uri = "file://" + local_path.resolve().as_posix()
    return (
        f"PUT '{uri}' {stage_target(rel_path)} "
        "AUTO_COMPRESS = FALSE OVERWRITE = TRUE SOURCE_COMPRESSION = NONE"
    )


def upload(cur, files: list[tuple[Path, Path]]) -> None:
    for i, (abs_path, rel) in enumerate(files, start=1):
        cur.execute(put_statement(abs_path, rel))
        row = cur.fetchone()
        # PUT renvoie (source, target, source_size, target_size, source_compression,
        #              target_compression, status, message)
        status = row[6] if row and len(row) > 6 else "?"
        message = row[7] if row and len(row) > 7 else ""
        if str(status).upper() not in ("UPLOADED", "SKIPPED"):
            raise SystemExit(f"PUT en echec pour {rel.as_posix()} : {status} {message}")
        LOG.info("[%d/%d] PUT %s (%s)", i, len(files), rel.as_posix(), status)


# --- Execution du SQL de chunking -------------------------------------------


def set_session_vars(cur, chunk_size: int, chunk_overlap: int, agent_name: str) -> None:
    if chunk_overlap >= chunk_size:
        raise SystemExit(
            f"--chunk-overlap ({chunk_overlap}) doit etre strictement inferieur a "
            f"--chunk-size ({chunk_size}) : SPLIT_TEXT_RECURSIVE_CHARACTER l'exige."
        )
    if not SAFE_IDENT_RE.match(agent_name):
        raise SystemExit(
            f"--agent-name invalide : {agent_name!r}. "
            "Caracteres autorises : lettres, chiffres, . _ - et espace."
        )
    cur.execute(f"SET CHUNK_SIZE = {int(chunk_size)}")
    cur.execute(f"SET CHUNK_OVERLAP = {int(chunk_overlap)}")
    cur.execute(f"SET DEFAULT_AGENT_NAME = '{agent_name}'")


def run_chunking(conn, sql_path: Path):
    """Execute sql/20_chunk.sql et retourne les lignes de sa derniere instruction.

    La derniere instruction du fichier est le rapport chunks/fichier source.
    """
    sql_text = sql_path.read_text(encoding="utf-8")
    cursors = list(conn.execute_string(sql_text, remove_comments=False))
    if not cursors:
        raise SystemExit(f"{sql_path.name} n'a produit aucune instruction executee.")
    return cursors[-1].fetchall()


def report(rows) -> None:
    if not rows:
        LOG.warning(
            "Aucun chunk produit. Verifier le PATTERN du COPY INTO et le contenu des fichiers."
        )
        return

    width = min(max(len(str(r[0])) for r in rows), 60)
    header = (
        f"{'source_file'.ljust(width)}  {'doc_type':13}  {'chunks':>6}  "
        f"{'avec_cls':>8}  {'classes':>7}  {'min_ch':>6}  {'max_ch':>6}"
    )
    LOG.info("")
    LOG.info("Chunks par fichier source")
    LOG.info(header)
    LOG.info("-" * len(header))

    total = 0
    total_cls = 0
    for (
        source_file,
        doc_type,
        chunk_count,
        with_cls,
        n_classes,
        min_chars,
        max_chars,
    ) in rows:
        total += chunk_count
        total_cls += with_cls
        label = str(source_file)
        if len(label) > width:
            label = "..." + label[-(width - 3) :]
        LOG.info(
            "%s  %-13s  %6d  %8d  %7d  %6d  %6d",
            label.ljust(width),
            doc_type or "-",
            chunk_count,
            with_cls,
            n_classes,
            min_chars,
            max_chars,
        )

    LOG.info("-" * len(header))
    LOG.info(
        "%d fichier(s) source, %d chunk(s) inseres dans LEGACY_DOCS.", len(rows), total
    )
    LOG.info(
        "java_class renseigne sur %d/%d chunks — extrait des en-tetes ### et "
        "propage ; axe de filtrage, pas un partitionnement exact.",
        total_cls,
        total,
    )


# --- CLI ---------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Ingere les sorties du pipeline java-legacy-agent dans LEGACY_DOCS.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument(
        "input_dirs",
        type=Path,
        nargs="+",
        help="Un ou plusieurs dossiers contenant les sorties du pipeline",
    )
    p.add_argument(
        "--connection",
        default="legacy_ai",
        help="Connexion nommee dans ~/.snowflake/connections.toml",
    )
    p.add_argument("--role", default="AI_ENGINEER_ROLE")
    p.add_argument("--warehouse", default="WH_AI_DEV")
    p.add_argument("--database", default="LEGACY_AI_DB")
    p.add_argument("--schema", default="CORE")
    p.add_argument(
        "--limit",
        type=int,
        default=None,
        help="N'ingerer que les N premiers fichiers (ordre alphabetique)",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Lister ce qui serait fait, sans connexion ni execution",
    )
    p.add_argument(
        "--chunk-size", type=int, default=1500, help="Caracteres max par chunk"
    )
    p.add_argument(
        "--chunk-overlap",
        type=int,
        default=250,
        help="Chevauchement entre chunks consecutifs",
    )
    p.add_argument(
        "--agent-name",
        default="JavaDocumentationAgent",
        help="Valeur de repli si ni le front matter ni le nom de fichier ne renseignent",
    )
    p.add_argument(
        "--extensions",
        default=",".join(DEFAULT_EXTENSIONS),
        help="Extensions ingerees, separees par des virgules",
    )
    p.add_argument(
        "--no-purge-stage",
        action="store_true",
        help="Ne pas vider @DOCS_STAGE/legacy_docs/ avant les PUT "
        "(par defaut le stage est purge pour refleter exactement les dossiers d'entree)",
    )
    p.add_argument("-v", "--verbose", action="store_true")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
    )

    extensions = tuple(
        e if e.startswith(".") else "." + e
        for e in (x.strip() for x in args.extensions.split(","))
        if e
    )
    roots = [d.resolve() for d in args.input_dirs]
    base, files = discover_files(roots, extensions, args.limit)
    total_bytes = sum(a.stat().st_size for a, _ in files)

    for root in roots:
        LOG.info("Dossier d'entree : %s", root)
    LOG.info("Base des chemins relatifs : %s", base)
    LOG.info(
        "%d fichier(s) selectionne(s), %d octets au total.", len(files), total_bytes
    )
    LOG.info(
        "Chunking : chunk_size=%d, overlap=%d, format='markdown'.",
        args.chunk_size,
        args.chunk_overlap,
    )

    check_utf8(files)

    if args.dry_run:
        LOG.info("")
        LOG.info("--dry-run : aucune connexion Snowflake, aucun credit consomme.")
        if not args.no_purge_stage:
            LOG.info("REMOVE %s/%s/", STAGE, STAGE_PREFIX)
        for abs_path, rel in files:
            LOG.info("%s", put_statement(abs_path, rel))
        LOG.info(
            "Puis execution de %s avec CHUNK_SIZE=%d, CHUNK_OVERLAP=%d, DEFAULT_AGENT_NAME='%s'.",
            CHUNK_SQL,
            args.chunk_size,
            args.chunk_overlap,
            args.agent_name,
        )
        LOG.info(
            "Le nombre de chunks n'est connu qu'apres execution reelle : rien n'est estime ici."
        )
        return 0

    # Cout : PUT + COPY + SPLIT_TEXT_RECURSIVE_CHARACTER sur un XSMALL, pour un
    # corpus de cette taille, c'est de l'ordre de la minute de warehouse.
    # Aucune fonction Cortex facturee au token n'est appelee ici (le splitter est
    # une fonction texte, pas un modele).
    LOG.info(
        "Cout attendu : quelques secondes a une minute de WH_AI_DEV (XSMALL). "
        "Aucun appel LLM facture au token."
    )

    try:
        import snowflake.connector
    except ImportError:
        raise SystemExit(
            "snowflake-connector-python n'est pas installe : pip install snowflake-connector-python"
        ) from None

    if not CHUNK_SQL.is_file():
        raise SystemExit(f"Script de chunking introuvable : {CHUNK_SQL}")

    conn = snowflake.connector.connect(connection_name=args.connection)
    try:
        cur = conn.cursor()
        cur.execute(f"USE ROLE {args.role}")
        cur.execute(f"USE WAREHOUSE {args.warehouse}")
        cur.execute(f"USE DATABASE {args.database}")
        cur.execute(f"USE SCHEMA {args.schema}")

        if not args.no_purge_stage:
            LOG.info(
                "Purge de %s/%s/ (le stage doit refleter les dossiers d'entree).",
                STAGE,
                STAGE_PREFIX,
            )
            cur.execute(f"REMOVE {STAGE}/{STAGE_PREFIX}/")

        upload(cur, files)

        # Stage interne : la directory table ne se met pas a jour toute seule.
        cur.execute(f"ALTER STAGE {STAGE.lstrip('@')} REFRESH")

        set_session_vars(cur, args.chunk_size, args.chunk_overlap, args.agent_name)
        LOG.info("Execution de %s ...", CHUNK_SQL.name)
        rows = run_chunking(conn, CHUNK_SQL)
        report(rows)
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
