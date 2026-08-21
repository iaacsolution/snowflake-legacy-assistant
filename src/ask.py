"""Client CLI de l'agent LEGACY_ASSISTANT.

Pose une question en francais a l'agent Cortex declare par sql/50_agent.sql, et
affiche sa reponse. L'agent decide seul d'interroger la documentation
(Cortex Search, LEGACY_DOCS_SEARCH) ou les metriques (Cortex Analyst,
SV_BENCHMARK) ; ce choix est visible avec --trace.

Authentification : identique au J3. La connexion SQL passe par
~/.snowflake/connections.toml (`legacy_ai`, paire de cles) ; l'API REST exige un
JWT signe par la meme cle privee. La fabrication du jeton n'est pas reecrite ici,
elle est importee de eval_text2sql.jeton_jwt() — implementation de reference du
projet, avec ses pieges documentes.

API VERIFIEE LE 21/08/2026
https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-run

    POST /api/v2/databases/{db}/schemas/{schema}/agents/{nom}:run
    body : {"messages":[{"role":"user","content":[{"type":"text","text":...}]}],
            "stream": false}
    reponse : {"role":"assistant","content":[ ... blocs ... ], "metadata":{...}}

POURQUOI CE FICHIER N'EST PAS eval_text2sql.py AVEC UNE AUTRE URL
    Cortex Analyst renvoie une reponse a un seul etage : un bloc `sql`, qu'on
    execute soi-meme. L'agent, lui, renvoie le journal de son propre
    raisonnement : des blocs `thinking`, un ou plusieurs couples
    `tool_use` / `tool_result`, puis un bloc `text` final. Il a DEJA execute le
    SQL — le resultat est dans le tool_result. Ce client lit, il n'execute pas.

    Observe le 21/08/2026 sur les 4 questions de recette, et qui ne figure pas
    dans la doc : le bloc `text` final n'est pas le dernier, un bloc
    `suggested_queries` le suit ; l'outil Analyst se dedouble a l'execution en
    `system_agentic_semantic_context` puis un ou plusieurs `system_execute_sql` ;
    et certains de ces derniers reviennent avec statut=error, l'agent retentant
    jusqu'a aboutir. Detail dans sql/50_agent.sql.

LE PIEGE, ET LA REGLE DU PROJET
    Le nombre de blocs et leur ordre dependent de la question posee : une
    question documentaire n'a pas la meme trace qu'une question chiffree, et une
    question mixte declenche deux outils. Indexer content[0] ou content[-1]
    marche sur l'exemple de la doc et casse a la premiere question reelle. On
    parcourt donc TOUJOURS par `type`. C'est un anti-pattern explicite de
    CLAUDE.md.

COUT
    Un appel = un modele d'orchestration qui raisonne, plus l'outil declenche
    (recherche vectorielle, ou generation SQL + execution sur WH_AI_DEV). Une
    question mixte en declenche deux. Aucun objet n'est cree, rien n'est
    re-embedde. Ordre de grandeur mesure au J3 pour un appel Analyst seul :
    quelques secondes de XSMALL.

Exemples
--------
    python src/ask.py "Combien de temps a dure la phase analyze ?"
    python src/ask.py --trace "Quelle classe a ete la plus longue a analyser ?"
    python src/ask.py --raw "Y a-t-il eu des echecs d'etape ?"   # JSON brut
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

CLE_PRIVEE = Path.home() / ".snowflake" / "rsa_key.p8"

AGENT_DB = "LEGACY_AI_DB"
AGENT_SCHEMA = "CORE"
AGENT_NOM = "LEGACY_ASSISTANT"


def chemin_agent(db: str, schema: str, nom: str) -> str:
    return f"/api/v2/databases/{db}/schemas/{schema}/agents/{nom}:run"


# --- Appel -------------------------------------------------------------------


def appeler_agent(conn, jwt: str, question: str, chemin: str, timeout: int = 180):
    """Envoie la question a l'agent, retourne (payload, latence_s).

    stream=False : on veut un seul objet JSON, pas un flux SSE. Le defaut de
    l'API est le streaming, il faut donc le desactiver explicitement — et
    demander Accept: application/json, sans quoi certains deploiements
    repondent quand meme en text/event-stream. Le cas est traite plus bas
    plutot que suppose impossible.
    """
    import requests

    url = f"https://{conn.host}{chemin}"
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Authorization": f"Bearer {jwt}",
        "X-Snowflake-Authorization-Token-Type": "KEYPAIR_JWT",
    }
    body = {
        "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
        "stream": False,
    }

    t0 = time.time()
    r = requests.post(url, headers=headers, json=body, timeout=timeout)
    latence = round(time.time() - t0, 2)

    if r.status_code != 200:
        raise RuntimeError(f"HTTP {r.status_code} : {r.text[:600]}")

    if "text/event-stream" in r.headers.get("Content-Type", ""):
        return payload_depuis_sse(r.text), latence
    return r.json(), latence


def payload_depuis_sse(texte: str) -> dict:
    """Recompose un payload a partir d'un flux SSE.

    Filet de securite : si l'API ignore stream=false, elle emet une suite
    d'evenements dont le DERNIER, nomme `response`, porte la reponse complete
    agregee. On ne reconstitue donc rien a la main a partir des deltas.
    """
    dernier = None
    for ligne in texte.splitlines():
        if ligne.startswith("data:"):
            brut = ligne[5:].strip()
            if not brut or brut == "[DONE]":
                continue
            try:
                dernier = json.loads(brut)
            except json.JSONDecodeError:
                continue
    if dernier is None:
        raise RuntimeError("flux SSE recu, aucun evenement JSON exploitable")
    return dernier


# --- Lecture de la reponse ---------------------------------------------------


def blocs(payload: dict) -> list:
    """Retourne la liste des blocs de contenu, quel que soit l'enrobage.

    Trois formes ont ete vues selon le mode d'appel et la version d'API : le
    payload porte `content` a la racine, ou sous `message`, ou sous `response`.
    On les accepte toutes plutot que de parier sur une seule.
    """
    for cle in (None, "message", "response"):
        source = payload if cle is None else payload.get(cle)
        if isinstance(source, dict) and isinstance(source.get("content"), list):
            return source["content"]
    return []


def depouiller(payload: dict) -> dict:
    """Parcourt les blocs PAR TYPE et en tire ce qui nous interesse.

    Ne suppose ni l'ordre, ni le nombre, ni la presence d'un type donne : une
    question documentaire ne produit aucun SQL, une question hors perimetre ne
    produit aucun appel d'outil. Chaque champ du resultat peut donc etre vide.
    """
    vu = {
        "reponse": [],  # texte final
        "reflexion": [],  # blocs thinking
        "outils": [],  # {nom, type, entree}
        "resultats": [],  # {nom, statut, sql, lignes, colonnes, documents}
        "citations": [],  # {titre, extrait}
        "types_vus": [],  # pour --trace : tout ce qui est passe
    }
    noms = {}  # tool_use_id -> nom d'outil

    for bloc in blocs(payload):
        if not isinstance(bloc, dict):
            continue
        t = bloc.get("type")
        vu["types_vus"].append(t)

        if t == "text":
            vu["reponse"].append(bloc.get("text", ""))
            for ann in bloc.get("annotations") or []:
                if isinstance(ann, dict) and "citation" in str(ann.get("type", "")):
                    vu["citations"].append(
                        {
                            "titre": ann.get("doc_title") or ann.get("title") or "?",
                            "extrait": (ann.get("text") or "").strip()[:200],
                        }
                    )

        elif t == "thinking":
            brut = bloc.get("thinking")
            texte = brut.get("text", "") if isinstance(brut, dict) else str(brut or "")
            if texte:
                vu["reflexion"].append(texte)

        elif t == "tool_use":
            tu = bloc.get("tool_use") or {}
            nom = tu.get("name") or tu.get("type") or "?"
            noms[tu.get("tool_use_id")] = nom
            vu["outils"].append(
                {"nom": nom, "type": tu.get("type"), "entree": tu.get("input")}
            )

        elif t == "tool_result":
            tr = bloc.get("tool_result") or {}
            entree = {
                "nom": noms.get(tr.get("tool_use_id"), "?"),
                "statut": tr.get("status"),
                "sql": None,
                "colonnes": None,
                "lignes": None,
                "documents": [],
            }
            for item in tr.get("content") or []:
                if not isinstance(item, dict) or item.get("type") != "json":
                    continue
                j = item.get("json") or {}

                # Cote Analyst : le SQL genere et le jeu de resultats deja execute.
                if j.get("sql"):
                    entree["sql"] = j["sql"]
                rs = j.get("result_set") or j.get("resultSet")
                if isinstance(rs, dict):
                    meta = rs.get("resultSetMetaData") or {}
                    entree["colonnes"] = [
                        c.get("name") for c in (meta.get("rowType") or [])
                    ]
                    entree["lignes"] = rs.get("data")

                # Cote Search : les documents rapportes.
                for cle in ("searchResults", "results", "documents"):
                    if isinstance(j.get(cle), list):
                        for d in j[cle]:
                            if isinstance(d, dict):
                                entree["documents"].append(
                                    {
                                        "titre": d.get("SOURCE_FILE")
                                        or d.get("source_file")
                                        or d.get("doc_title")
                                        or d.get("title")
                                        or d.get("DOC_ID")
                                        or "?",
                                        "extrait": str(
                                            d.get("DOC_CONTENT")
                                            or d.get("doc_content")
                                            or d.get("text")
                                            or ""
                                        ).strip()[:200],
                                    }
                                )
                        break
            vu["resultats"].append(entree)

    vu["reponse"] = "\n".join(x for x in vu["reponse"] if x).strip()
    return vu


# --- Affichage ---------------------------------------------------------------


def afficher(vu: dict, payload: dict, latence: float, trace: bool) -> None:
    if trace:
        print()
        print("--- trace " + "-" * 63)
        print(f"  blocs recus : {', '.join(vu['types_vus']) or '(aucun)'}")

        for r in vu["reflexion"]:
            print("  reflexion   :", r.strip().replace("\n", " ")[:300])

        if not vu["outils"]:
            print("  outils      : AUCUN — l'agent a repondu sans rien interroger")
        for o in vu["outils"]:
            entree = json.dumps(o["entree"], ensure_ascii=False)[:200]
            print(f"  outil       : {o['nom']}  ({o['type']})")
            print(f"                entree {entree}")

        for r in vu["resultats"]:
            print(f"  resultat    : {r['nom']}  statut={r['statut']}")
            if r["sql"]:
                for ligne in r["sql"].strip().splitlines():
                    print("                " + ligne)
            if r["colonnes"]:
                print("                colonnes", r["colonnes"])
            if r["lignes"] is not None:
                for ligne in r["lignes"][:10]:
                    print("                ", ligne)
                if len(r["lignes"]) > 10:
                    print(
                        f"                 ... {len(r['lignes']) - 10} lignes de plus"
                    )
            for d in r["documents"]:
                print(f"                doc {d['titre']} : {d['extrait'][:120]}")

        usage = (payload.get("metadata") or {}).get("usage")
        if usage:
            print("  usage       :", json.dumps(usage, ensure_ascii=False)[:300])
        print("-" * 74)

    print()
    print(vu["reponse"] or "(l'agent n'a produit aucun texte de reponse)")

    if vu["citations"]:
        print()
        print("Sources :")
        deja = set()
        for c in vu["citations"]:
            if c["titre"] in deja:
                continue
            deja.add(c["titre"])
            print(f"  - {c['titre']}")

    print()
    outils = ", ".join(o["nom"] for o in vu["outils"]) or "aucun"
    print(f"[{latence} s, outils : {outils}]")


# --- Entree ------------------------------------------------------------------


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description="Pose une question a l'agent Cortex LEGACY_ASSISTANT."
    )
    p.add_argument("question", nargs="*", help="la question, en francais")
    p.add_argument(
        "--trace",
        action="store_true",
        help="montre le routage : outils appeles, SQL genere, documents",
    )
    p.add_argument(
        "--raw",
        action="store_true",
        help="affiche le JSON brut de l'API et rien d'autre",
    )
    p.add_argument(
        "--connection",
        default="legacy_ai",
        help="nom de connexion dans connections.toml",
    )
    p.add_argument(
        "--agent",
        default=f"{AGENT_DB}.{AGENT_SCHEMA}.{AGENT_NOM}",
        help="agent a interroger, en nom qualifie",
    )
    p.add_argument("--timeout", type=int, default=180, help="timeout HTTP, secondes")
    args = p.parse_args(argv)

    # La console Windows est en cp1252 : la reflexion de l'agent et les extraits
    # de documents contiennent des caracteres qui n'y existent pas (fleches,
    # apostrophes typographiques). Sans cela, --trace plante sur un
    # UnicodeEncodeError APRES que l'appel a ete facture. errors="replace" :
    # on prefere un "?" a une pile d'exception.
    for flux in (sys.stdout, sys.stderr):
        if hasattr(flux, "reconfigure"):
            flux.reconfigure(encoding="utf-8", errors="replace")

    question = " ".join(args.question).strip()
    if not question:
        p.error(
            'aucune question. Exemple : python src/ask.py "Combien de temps a dure la phase analyze ?"'
        )

    morceaux = args.agent.split(".")
    if len(morceaux) != 3:
        p.error(f"--agent attend un nom qualifie db.schema.nom, recu : {args.agent}")
    db, schema, nom = morceaux

    if not CLE_PRIVEE.exists():
        print(f"cle privee introuvable : {CLE_PRIVEE}", file=sys.stderr)
        return 2

    import snowflake.connector
    from eval_text2sql import jeton_jwt

    conn = snowflake.connector.connect(connection_name=args.connection)
    try:
        jwt = jeton_jwt(conn, CLE_PRIVEE)
        payload, latence = appeler_agent(
            conn, jwt, question, chemin_agent(db, schema, nom), args.timeout
        )
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    finally:
        conn.close()

    if args.raw:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    vu = depouiller(payload)
    if not blocs(payload):
        print(
            "Reponse recue mais aucun bloc de contenu reconnu. "
            "Relancer avec --raw pour voir la forme exacte.",
            file=sys.stderr,
        )
        return 1

    afficher(vu, payload, latence, args.trace)
    return 0


if __name__ == "__main__":
    sys.exit(main())
