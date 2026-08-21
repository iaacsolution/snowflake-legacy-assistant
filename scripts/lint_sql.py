"""Linter des garde-fous SQL du projet — hors ligne, aucun credit.

POURQUOI CE FICHIER PLUTOT QUE sqlfluff
    sqlfluff verifie un style (indentation, casse des mots-cles). Ce qui peut
    reellement nuire ici n'est pas le style : c'est qu'une escalade de privilege
    ou un secret en dur se glisse dans un script, ou qu'un objet coute plus que
    prevu. Les regles ci-dessous sont exactement celles de CLAUDE.md, donc
    verifiables et defendables ; un linter de style aurait produit du bruit sur
    des fichiers volontairement tres commentes.

LE PIEGE QUE CE LINTER DOIT EVITER
    Un simple `grep ACCOUNTADMIN sql/` est faux deux fois sur ce repo :
      - sql/50_agent.sql et sql/60_masking.sql citent ACCOUNTADMIN dans un bloc
        de commentaire, pour documenter un prealable a jouer dans Snowsight ;
      - sql/60_masking.sql contient la chaine 'ACCOUNTADMIN' dans un CASE, comme
        valeur de donnee, ce qui est parfaitement legitime.
    On retire donc les commentaires AVANT d'analyser, et on cible l'instruction
    `USE ROLE ACCOUNTADMIN`, pas le mot.

    python scripts/lint_sql.py [chemin_sql]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

RACINE = Path(__file__).resolve().parents[1]

# Scripts d'amorcage, seuls autorises a escalader. Ils s'executent une fois, a
# la main dans Snowsight, et ne contiennent que des placeholders.
#
# NOTE — CLAUDE.md ne nomme que 00_bootstrap.sql. Le repo en compte deux depuis
# le J1 : 01_keypair_auth.sql pose la cle publique par ALTER USER ... SET
# RSA_PUBLIC_KEY, ce qui exige SECURITYADMIN et ne peut pas s'ecrire autrement.
# La liste ci-dessous reflete donc le repo reel ; l'ecart de formulation avec
# CLAUDE.md est signale a l'auteur, la regle de securite ne se modifie pas seule.
BOOTSTRAP = ("00_bootstrap.sql", "01_keypair_auth.sql")

ROLES_PRIVILEGIES = ("ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN", "ORGADMIN")

# Motifs de secret en dur. AUTHENTICATOR et RSA_PUBLIC_KEY sont exclus : une
# cle PUBLIQUE dans un script est sans danger, c'est le cas de 01_keypair_auth.
SECRETS = [
    (re.compile(r"PASSWORD\s*=\s*['\"][^'\"]+['\"]", re.I), "mot de passe en dur"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "cle privee en dur"),
    (re.compile(r"\bAWS_SECRET_ACCESS_KEY\b", re.I), "secret AWS en dur"),
    (
        re.compile(r"\b(TOKEN|SECRET)\s*=\s*['\"][^'\"<][^'\"]*['\"]", re.I),
        "jeton en dur",
    ),
]

RE_USE_ROLE = re.compile(r"\bUSE\s+ROLE\s+(\w+)", re.I)
RE_WH_SIZE = re.compile(r"WAREHOUSE_SIZE\s*=\s*'?([A-Za-z\-]+)'?", re.I)
RE_TARGET_LAG = re.compile(r"TARGET_LAG\s*=\s*'(\d+)\s*(second|minute|hour|day)", re.I)


def sans_commentaires(sql: str) -> str:
    """Retire les blocs /* */ puis les commentaires -- de fin de ligne.

    Les lignes sont conservees (remplacees par du vide) pour que les numeros de
    ligne rapportes restent ceux du fichier d'origine.
    """

    def blancs(m: re.Match) -> str:
        return re.sub(r"[^\n]", " ", m.group(0))

    sql = re.sub(r"/\*.*?\*/", blancs, sql, flags=re.S)
    return re.sub(r"--[^\n]*", blancs, sql)


def controler(chemin: Path) -> list[str]:
    brut = chemin.read_text(encoding="utf-8", errors="replace")
    code = sans_commentaires(brut)
    nom = chemin.name
    ecarts: list[str] = []

    for i, ligne in enumerate(code.splitlines(), 1):
        # 1. Escalade de privilege hors bootstrap.
        for m in RE_USE_ROLE.finditer(ligne):
            role = m.group(1).upper()
            if role in ROLES_PRIVILEGIES and nom not in BOOTSTRAP:
                ecarts.append(
                    f"{chemin}:{i}: USE ROLE {role} hors amorcage "
                    f"({', '.join(BOOTSTRAP)}) — le travail courant s'execute "
                    f"sous AI_ENGINEER_ROLE"
                )

        # 2. Secret en dur.
        for motif, libelle in SECRETS:
            if motif.search(ligne):
                ecarts.append(f"{chemin}:{i}: {libelle}")

        # 3. Warehouse au-dessus de XSMALL.
        m = RE_WH_SIZE.search(ligne)
        if m and m.group(1).upper().replace("-", "") not in ("XSMALL",):
            ecarts.append(
                f"{chemin}:{i}: WAREHOUSE_SIZE = {m.group(1)} — "
                f"le projet plafonne a XSMALL"
            )

        # 4. TARGET_LAG sous '1 day'.
        m = RE_TARGET_LAG.search(ligne)
        if m:
            n, unite = int(m.group(1)), m.group(2).lower()
            if unite != "day" or n < 1:
                ecarts.append(
                    f"{chemin}:{i}: TARGET_LAG = '{n} {unite}' — "
                    f"jamais sous '1 day' sur ce projet"
                )

    return ecarts


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    racine = Path(args[0]) if args else RACINE / "sql"

    fichiers = sorted(racine.glob("*.sql")) if racine.is_dir() else [racine]
    if not fichiers:
        print(f"aucun fichier .sql sous {racine}", file=sys.stderr)
        return 1

    tous: list[str] = []
    for f in fichiers:
        tous.extend(controler(f))

    if tous:
        print(f"{len(tous)} ecart(s) aux garde-fous du projet :\n")
        for e in tous:
            print("  " + e)
        return 1

    print(f"garde-fous SQL : {len(fichiers)} fichier(s) conformes")
    for f in fichiers:
        print(f"  ok  {f.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
