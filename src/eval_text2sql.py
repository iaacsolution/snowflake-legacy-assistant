"""Evaluation de Cortex Analyst sur eval/golden_questions.json.

Pour chaque question du golden dataset :
    1. envoi de la question en francais a Cortex Analyst (REST, semantic_view SV_BENCHMARK)
    2. extraction du SQL genere
    3. execution de ce SQL contre Snowflake
    4. comparaison du resultat a expected_value

L'evaluation est repetee N fois (3 par defaut). Cortex Analyst est un modele
generatif : deux runs sur la meme question peuvent produire deux SQL differents.
Rapporter le meilleur run serait malhonnete, on rapporte donc la MEDIANE et
l'ECART entre runs, plus la stabilite par question.

Authentification : connexion SQL via ~/.snowflake/connections.toml (`legacy_ai`,
paire de cles). L'API REST, elle, exige un JWT signe : il est fabrique a partir
de la meme cle privee (~/.snowflake/rsa_key.p8, hors du repo). Le jeton de
session du connecteur ne convient pas — voir jeton_jwt(). Aucun secret n'est
lu ailleurs ni ecrit nulle part.

API verifiee le 18/08/2026 :
https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst/rest-api

    POST /api/v2/cortex/analyst/message
    body : {"messages":[{"role":"user","content":[{"type":"text","text":...}]}],
            "semantic_view":"LEGACY_AI_DB.CORE.SV_BENCHMARK", "stream":false}
    reponse : message.content[] ou l'element {"type":"sql","statement":...}
              porte la requete generee.

COUT : un appel Analyst par question et par run. 10 questions x 3 runs = 30
appels, plus 30 executions SQL sur un XSMALL. Signale avant lancement.

Exemples
--------
    python src/eval_text2sql.py --dry-run          # n'appelle rien, montre le plan
    python src/eval_text2sql.py --runs 1 --only q6 # une question, un run
    python src/eval_text2sql.py                    # 3 runs, les 10 questions
"""

from __future__ import annotations

import argparse
import json
import logging
import statistics
import sys
import time
from pathlib import Path

LOG = logging.getLogger("eval")

ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "eval" / "golden_questions.json"

SEMANTIC_VIEW = "LEGACY_AI_DB.CORE.SV_BENCHMARK"
CLE_PRIVEE = Path.home() / ".snowflake" / "rsa_key.p8"
ANALYST_PATH = "/api/v2/cortex/analyst/message"

# Tolerance de comparaison numerique.
#
# q6 attend 66.666667 (division exacte 2/3). Un Analyst qui repond 66.67 ou
# 66.7 a raison ; une egalite stricte le compterait faux.
#
# POURQUOI 0.05 ET NON 0.01 : une tolerance de 0.01 n'admet que 66.67 (ecart
# 0.0033) et rejette 66.7, dont l'ecart vaut 0.0333. Elle ne remplirait donc
# pas l'objectif qu'elle sert. 0.05 accepte les deux arrondis usuels et
# continue de rejeter 66 (ecart 0.67) comme 67 (ecart 0.33), qui sont des
# reponses differentes et non des arrondis.
#
# Cette tolerance est ABSOLUE. Sur les grandes valeurs du jeu de donnees
# (877739, 2711957) elle equivaut a une egalite stricte, ce qui est le
# comportement voulu : une duree n'a pas a etre arrondie.
NUM_TOL = 0.05


# --- Comparateur -------------------------------------------------------------


def as_sequence(v):
    """Ramene une valeur attendue ou obtenue a une liste de scalaires.

    expected_value vaut soit un scalaire (q1, q4, q10), soit une liste de deux
    valeurs (q2, q9, q7, q8). Le resultat SQL est une liste de lignes, chaque
    ligne etant un tuple. On aplatit les deux dans le meme format pour les
    comparer sans cas particulier.
    """
    if v is None:
        return []
    if isinstance(v, (list, tuple)):
        out = []
        for item in v:
            out.extend(as_sequence(item))
        return out
    return [v]


def scalar_match(expected, actual, tol: float | None = None) -> bool:
    """Compare deux scalaires.

    tol vaut None par defaut et non NUM_TOL : une valeur par defaut est figee a
    la definition de la fonction, ce qui rendrait l'option --tol sans effet.

    Regles :
      - numerique : comparaison par VALEUR avec tolerance, jamais par type.
        4 (int) et 4.0 (float) sont egaux — la colonne metric_value est typee
        FLOAT donc tout compteur revient en float. Idem 66.666667 vs 66.67.
      - texte : insensible a la casse et aux espaces de bord.
      - un booleen n'est jamais traite comme un nombre (True != 1 ici).
    """
    if tol is None:
        tol = NUM_TOL

    if isinstance(expected, bool) or isinstance(actual, bool):
        return expected == actual

    if isinstance(expected, (int, float)):
        try:
            return abs(float(expected) - float(actual)) < tol
        except (TypeError, ValueError):
            return False

    # Une valeur attendue textuelle face a un nombre : on tente le texte.
    return str(expected).strip().casefold() == str(actual).strip().casefold()


def compare(expected_value, rows) -> tuple[bool, str]:
    """Le resultat SQL couvre-t-il la valeur attendue ?

    Regle retenue : CHAQUE valeur attendue doit correspondre a une cellule
    DISTINCTE du resultat. L'ordre des colonnes n'est pas impose.

    Pourquoi pas une egalite positionnelle stricte : Analyst ajoute
    legitimement des colonnes d'etiquette (le nom de la phase a cote de la
    duree, par exemple) et n'a aucune raison de respecter l'ordre du SQL de
    reference. Exiger la position penaliserait des reponses justes.

    Limite assumee, a garder en tete en lisant les scores : sur une valeur
    attendue petite (1, 4, 12), une correspondance fortuite avec une cellule
    sans rapport est possible. Le SQL genere est journalise pour permettre la
    verification manuelle.
    """
    expected = as_sequence(expected_value)
    if not expected:
        return False, "aucune valeur attendue"

    cells = as_sequence(rows)
    if not cells:
        return False, "resultat vide"

    restants = list(range(len(cells)))
    for exp in expected:
        trouve = None
        for idx in restants:
            if scalar_match(exp, cells[idx]):
                trouve = idx
                break
        if trouve is None:
            return False, f"valeur attendue absente du resultat : {exp!r}"
        restants.remove(trouve)

    return True, "ok"


# --- Appel Cortex Analyst ----------------------------------------------------


def jeton_jwt(conn, key_file: Path, lifetime: int = 600) -> str:
    """Fabrique un JWT signe par la cle privee, pour l'API REST.

    POURQUOI PAS LE JETON DE SESSION DU CONNECTEUR (teste, refuse) :
    l'endpoint Analyst n'accepte qu'un bearer token. Les trois variantes
    essayees ont echoue avec des messages sans ambiguite :

        Authorization: Snowflake Token="<session>"  -> 400 390146
            "Bearer token is missing in the HTTP request authorization header."
        Authorization: Bearer <session>             -> 401 390303
            "Invalid OAuth access token."           (le jeton de session
                                                     n'est pas un jeton OAuth)

    Il faut donc un JWT signe, avec X-Snowflake-Authorization-Token-Type =
    KEYPAIR_JWT. C'est coherent avec l'authentification du projet, deja en
    paire de cles depuis l'activation de la MFA sur le compte.

    Piege de chargement : AuthByKeyPair attend du DER quand on lui passe des
    bytes, or ~/.snowflake/rsa_key.p8 est au format PEM. Le charger d'abord en
    objet RSAPrivateKey evite l'erreur "Could not deserialize key data".
    """
    from cryptography.hazmat.primitives import serialization
    from snowflake.connector.auth import AuthByKeyPair

    cle = serialization.load_pem_private_key(key_file.read_bytes(), password=None)
    auth = AuthByKeyPair(private_key=cle, lifetime_in_seconds=lifetime)
    # L'identifiant de compte doit etre en majuscules pour la signature JWT.
    return auth.prepare(account=conn.account.upper(), user=conn.user.upper())


def analyst_sql(conn, jwt: str, question: str, timeout: int = 120):
    """Envoie la question a Cortex Analyst, retourne (sql, texte, warnings).

    sql vaut None si Analyst n'a produit aucun bloc de type 'sql' — cas reel
    quand il repond par une demande de precision ou des suggestions.
    """
    import requests

    host = conn.host
    url = f"https://{host}{ANALYST_PATH}"
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Authorization": f"Bearer {jwt}",
        "X-Snowflake-Authorization-Token-Type": "KEYPAIR_JWT",
    }
    body = {
        "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
        "semantic_view": SEMANTIC_VIEW,
        "stream": False,
    }

    r = requests.post(url, headers=headers, json=body, timeout=timeout)
    if r.status_code != 200:
        raise RuntimeError(f"HTTP {r.status_code} : {r.text[:400]}")

    payload = r.json()
    sql = None
    texte = []
    for bloc in payload.get("message", {}).get("content", []):
        if bloc.get("type") == "sql" and sql is None:
            sql = bloc.get("statement")
        elif bloc.get("type") == "text":
            texte.append(bloc.get("text", ""))
        elif bloc.get("type") == "suggestions":
            texte.append("SUGGESTIONS: " + " | ".join(bloc.get("suggestions", [])))

    return sql, " ".join(texte).strip(), payload.get("warnings", [])


# --- Boucle d'evaluation -----------------------------------------------------


def run_once(conn, jwt, questions, run_idx: int, pause: float):
    cur = conn.cursor()
    resultats = []

    for q in questions:
        entree = {
            "run": run_idx,
            "id": q["id"],
            "question": q["question"],
            "attendu": q["expected_value"],
            "sql_genere": None,
            "obtenu": None,
            "correct": False,
            "motif": "",
            "latence_s": None,
        }
        t0 = time.time()
        try:
            sql, texte, warnings = analyst_sql(conn, jwt, q["question"])
            entree["latence_s"] = round(time.time() - t0, 2)
            entree["sql_genere"] = sql
            if not sql:
                entree["motif"] = f"aucun SQL genere ({texte[:120]})"
                resultats.append(entree)
                continue
            if warnings:
                entree["motif"] = f"warnings: {warnings}"

            cur.execute(sql)
            rows = cur.fetchall()
            entree["obtenu"] = rows
            ok, motif = compare(q["expected_value"], rows)
            entree["correct"] = ok
            if not ok:
                entree["motif"] = motif
        except Exception as exc:
            entree["latence_s"] = round(time.time() - t0, 2)
            entree["motif"] = f"{type(exc).__name__}: {str(exc).splitlines()[0][:200]}"

        resultats.append(entree)
        statut = "OK  " if entree["correct"] else "FAUX"
        LOG.info(
            "  run %d  %-4s %s  (%.1fs) %s",
            run_idx,
            q["id"],
            statut,
            entree["latence_s"] or 0,
            entree["motif"][:80],
        )
        if pause:
            time.sleep(pause)

    return resultats


def rapport(tous_runs, questions):
    """Median, ecart entre runs, et stabilite par question."""
    n_q = len(questions)
    scores = [sum(1 for r in run if r["correct"]) for run in tous_runs]

    print()
    print("=" * 74)
    print(f"RESULTAT — {len(tous_runs)} run(s) x {n_q} questions")
    print("=" * 74)
    for i, s in enumerate(scores, 1):
        print(f"  run {i} : {s}/{n_q}  ({100.0 * s / n_q:.0f} %)")

    mediane = statistics.median(scores)
    print()
    print(f"  MEDIANE          : {mediane}/{n_q}  ({100.0 * mediane / n_q:.0f} %)")
    print(
        f"  ecart min-max    : {min(scores)} - {max(scores)}  (amplitude {max(scores) - min(scores)})"
    )
    if len(scores) > 1:
        print(f"  ecart-type       : {statistics.pstdev(scores):.2f}")

    # Stabilite par question : une question repondue juste 2 fois sur 3 est un
    # signal different d'une question toujours juste ou toujours fausse.
    print()
    print("  Par question (nombre de runs corrects / total) :")
    instables = []
    for q in questions:
        oks = [
            any(r["id"] == q["id"] and r["correct"] for r in run) for run in tous_runs
        ]
        n_ok = sum(oks)
        marque = "  <-- INSTABLE" if 0 < n_ok < len(tous_runs) else ""
        if marque:
            instables.append(q["id"])
        print(f"    {q['id']:<4} {n_ok}/{len(tous_runs)}{marque}")

    if instables:
        print()
        print(
            f"  {len(instables)} question(s) instable(s) entre runs : {', '.join(instables)}"
        )
        print("  Le SQL genere differe d'un run a l'autre — voir le journal detaille.")
    else:
        print()
        print(
            "  Aucune instabilite : chaque question donne le meme verdict a tous les runs."
        )

    return {"scores": scores, "mediane": mediane, "instables": instables}


def main(argv=None):
    # Declare en tete : NUM_TOL sert de valeur par defaut a --tol quelques
    # lignes plus bas, et Python refuse un global posterieur a une lecture.
    global NUM_TOL

    p = argparse.ArgumentParser(
        description="Evalue Cortex Analyst sur le golden dataset."
    )
    p.add_argument("--connection", default="legacy_ai")
    p.add_argument("--runs", type=int, default=3, help="Nombre de repetitions complete")
    p.add_argument("--only", nargs="*", help="N'evaluer que ces ids (ex. q6 q7)")
    p.add_argument(
        "--pause", type=float, default=0.0, help="Pause entre appels, secondes"
    )
    p.add_argument(
        "--tol",
        type=float,
        default=NUM_TOL,
        help="Tolerance absolue de comparaison numerique",
    )
    p.add_argument(
        "--key-file",
        type=Path,
        default=CLE_PRIVEE,
        help="Cle privee PEM utilisee pour signer le JWT de l API REST",
    )
    p.add_argument("--out", type=Path, default=None, help="Journal detaille JSON")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
    )

    NUM_TOL = args.tol

    questions = json.loads(GOLDEN.read_text(encoding="utf-8"))
    if args.only:
        questions = [q for q in questions if q["id"] in set(args.only)]
        if not questions:
            raise SystemExit(f"Aucune question ne correspond a {args.only}")

    n_appels = len(questions) * args.runs
    LOG.info("Golden dataset : %d question(s), %d run(s).", len(questions), args.runs)
    LOG.info(
        "Cout : %d appels Cortex Analyst + %d executions SQL sur WH_AI_DEV (XSMALL).",
        n_appels,
        n_appels,
    )
    LOG.info("Vue semantique interrogee : %s", SEMANTIC_VIEW)

    if args.dry_run:
        LOG.info("--dry-run : aucun appel, aucun credit consomme.")
        for q in questions:
            LOG.info("  %-4s %s", q["id"], q["question"])
        return 0

    import snowflake.connector

    conn = snowflake.connector.connect(connection_name=args.connection)
    tous_runs = []
    try:
        cur = conn.cursor()
        for s in (
            "USE ROLE AI_ENGINEER_ROLE",
            "USE WAREHOUSE WH_AI_DEV",
            "USE DATABASE LEGACY_AI_DB",
            "USE SCHEMA CORE",
        ):
            cur.execute(s)

        # Un JWT par session d evaluation, duree de vie large devant les
        # 30 appels. Regenere a chaque lancement du script.
        jwt = jeton_jwt(conn, args.key_file, lifetime=3600)
        LOG.info("JWT genere depuis %s.", args.key_file)

        for i in range(1, args.runs + 1):
            LOG.info("--- run %d/%d ---", i, args.runs)
            tous_runs.append(run_once(conn, jwt, questions, i, args.pause))
    finally:
        conn.close()

    synthese = rapport(tous_runs, questions)

    if args.out:
        args.out.write_text(
            json.dumps(
                {"synthese": synthese, "runs": tous_runs},
                indent=2,
                ensure_ascii=False,
                default=str,
            ),
            encoding="utf-8",
        )
        LOG.info("Journal detaille ecrit dans %s", args.out)

    return 0


if __name__ == "__main__":
    sys.exit(main())
