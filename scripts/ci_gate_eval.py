"""Garde-fou CI de l'evaluation Cortex Analyst.

POURQUOI CE FICHIER PLUTOT QU'UN `if` DANS LE WORKFLOW
    eval_text2sql.py retourne TOUJOURS 0, meme quand le score s'effondre : il
    est concu comme un instrument de mesure, pas comme un test. Le transformer
    en test changerait son comportement local. Le verdict est donc pris ici, a
    partir de son journal JSON.

CE QUE CE SCRIPT VERIFIE
    1. Le score du run atteint le seuil (100 % par defaut).
    2. AUCUN warehouse autre que WH_AI_DEV n'a servi pendant la fenetre du job.
       C'est le garde-fou de cout du projet : sans le bloc execution_environment
       de sql/50_agent.sql, le SQL genere partirait sur le warehouse par defaut,
       hors du resource monitor RM_TRIAL.
    3. Le cout reel de la fenetre est reporte dans le resume du job.

    Les deux premiers font echouer le job. Le troisieme est informatif.

SUR LA FRAICHEUR DU COUT
    On interroge INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY et non
    SNOWFLAKE.ACCOUNT_USAGE : cette derniere a plusieurs heures de latence, un
    fait etabli et documente dans ce projet (README, section Cout). Un chiffre
    lu dans ACCOUNT_USAGE juste apres le job vaudrait presque toujours zero et
    donnerait une fausse assurance. Meme INFORMATION_SCHEMA peut sous-evaluer la
    minute en cours : le resume le dit explicitement plutot que de le taire.

    python scripts/ci_gate_eval.py --journal eval_ci.json --depuis "2026-08-21 10:00:00"
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

WAREHOUSE_ATTENDU = "WH_AI_DEV"


def resume(texte: str) -> None:
    """Ecrit dans le resume du job GitHub, et sur la sortie standard."""
    print(texte)
    chemin = os.environ.get("GITHUB_STEP_SUMMARY")
    if chemin:
        with open(chemin, "a", encoding="utf-8") as f:
            f.write(texte + "\n")


def lire_score(journal: Path) -> tuple[int, int, list[str]]:
    """Retourne (score, total, ids rates) du dernier run du journal."""
    data = json.loads(journal.read_text(encoding="utf-8"))
    runs = data.get("runs") or []
    if not runs:
        raise SystemExit(f"{journal} ne contient aucun run exploitable.")
    dernier = runs[-1]
    total = len(dernier)
    score = sum(1 for r in dernier if r.get("correct"))
    rates = [r.get("id", "?") for r in dernier if not r.get("correct")]
    return score, total, rates


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--journal", type=Path, required=True)
    p.add_argument("--depuis", required=True, help="debut de fenetre, UTC")
    p.add_argument("--connection", default="legacy_ai")
    p.add_argument(
        "--seuil",
        type=float,
        default=100.0,
        help="pourcentage minimal accepte (defaut 100)",
    )
    args = p.parse_args(argv)

    echecs: list[str] = []

    # --- 1. Score -------------------------------------------------------------
    score, total, rates = lire_score(args.journal)
    pct = 100.0 * score / total if total else 0.0
    resume("## Evaluation Cortex Analyst\n")
    resume(f"- Score : **{score}/{total}** ({pct:.0f} %), seuil {args.seuil:.0f} %")
    if pct < args.seuil:
        echecs.append(
            f"score {pct:.0f} % sous le seuil de {args.seuil:.0f} % "
            f"— question(s) en echec : {', '.join(rates) or 'n/a'}"
        )

    # --- 2 et 3. Warehouses et cout ------------------------------------------
    import snowflake.connector

    conn = snowflake.connector.connect(connection_name=args.connection)
    try:
        cur = conn.cursor()

        cur.execute(
            """
            SELECT WAREHOUSE_NAME, COUNT(*)
            FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
                     END_TIME_RANGE_START => TO_TIMESTAMP_LTZ(%s),
                     RESULT_LIMIT => 10000))
            WHERE WAREHOUSE_NAME IS NOT NULL
              -- Restreint aux requetes que CE job a causees. Sans ce filtre, le
              -- garde-fou echoue a tort : le compte fait aussi tourner des pools
              -- internes Snowflake (COMPUTE_SERVICE_WH_USER_TASKS_POOL_*,
              -- SYSTEM$STREAMLIT_NOTEBOOK_WH) qui apparaissent dans
              -- QUERY_HISTORY, ne nous appartiennent pas et ne sont pas
              -- pilotables. Constate au J5 sur une fenetre elargie : 5
              -- warehouses tiers pour 840+ requetes que le projet n'a pas
              -- emises. On police ce qu'on declenche, pas ce qu'on observe.
              AND USER_NAME = CURRENT_USER()
            GROUP BY WAREHOUSE_NAME
            ORDER BY 2 DESC
            """,
            (args.depuis,),
        )
        warehouses = cur.fetchall()

        resume("\n- Warehouses ayant servi pendant le job :\n")
        if not warehouses:
            resume("  - (aucune requete relevee sur la fenetre)")
        for nom, n in warehouses:
            marque = "" if nom == WAREHOUSE_ATTENDU else "  **<-- HORS RM_TRIAL**"
            resume(f"  - `{nom}` : {n} requete(s){marque}")

        intrus = [nom for nom, _ in warehouses if nom != WAREHOUSE_ATTENDU]
        if intrus:
            echecs.append(
                f"warehouse(s) hors {WAREHOUSE_ATTENDU} : {', '.join(intrus)} "
                f"— le garde-fou de cout est contourne"
            )

        cur.execute(
            """
            SELECT WAREHOUSE_NAME, ROUND(SUM(CREDITS_USED), 4)
            FROM TABLE(INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(
                     DATE_RANGE_START => TO_TIMESTAMP_LTZ(%s)))
            GROUP BY WAREHOUSE_NAME
            ORDER BY 2 DESC
            """,
            (args.depuis,),
        )
        cout = cur.fetchall()
        total_credits = sum(float(c or 0) for _, c in cout)

        resume(f"\n- Cout de la fenetre : **{total_credits:.4f} credit**")
        for nom, c in cout:
            resume(f"  - `{nom}` : {float(c or 0):.4f}")
        resume(
            "\n> Lu dans INFORMATION_SCHEMA, pas ACCOUNT_USAGE, pour la fraicheur. "
            "Reste un **plancher** : la minute en cours peut etre sous-evaluee."
        )
    finally:
        conn.close()

    resume("")
    if echecs:
        resume("### Verdict : ECHEC\n")
        for e in echecs:
            resume(f"- {e}")
        return 1

    resume("### Verdict : OK — score au seuil, aucun warehouse hors RM_TRIAL.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
