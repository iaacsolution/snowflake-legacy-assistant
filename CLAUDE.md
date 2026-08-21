# CLAUDE.md — Projet snowflake-legacy-assistant

## Contexte

Assistant Cortex Agents interrogeant en langage naturel :

1. la documentation générée par le pipeline de modernisation Java legacy (non structuré -> Cortex Search) ;
2. les métriques de benchmark de ce même pipeline (structuré -> Cortex Analyst).

Projet d'apprentissage sur 5 jours, compte Snowflake trial. Objectif secondaire : un actif de portfolio défendable en entretien.

## Environnement

- Snowflake trial, région AWS EU, `CORTEX_ENABLED_CROSS_REGION = 'AWS_EU'`. External network access bloqué.
- Python 3.11+, snowflake-connector-python, snowflake-snowpark-python, snowflake.core.
- Auth par `~/.snowflake/connections.toml`, connexion nommée `legacy_ai`.
- Poste Windows. Console en cp1252 : tout script qui imprime une sortie Cortex doit forcer `sys.stdout.reconfigure(encoding="utf-8", errors="replace")`.
- Client CLI uniquement — pas de Streamlit, pas de webapp.
- API REST Cortex : JWT signé par la clé privée, en-tête `X-Snowflake-Authorization-Token-Type: KEYPAIR_JWT`. Le jeton de session du connecteur est refusé. Charger la clé en objet `RSAPrivateKey` depuis le PEM avant signature. Référence : `jeton_jwt()` dans `src/eval_text2sql.py`.

## Objets Snowflake

| | |
|---|---|
| Warehouse | `WH_AI_DEV` (XSMALL, AUTO_SUSPEND=60) |
| Database / Schema | `LEGACY_AI_DB.CORE` |
| Rôle de travail | `AI_ENGINEER_ROLE` |
| Stage | `DOCS_STAGE` |
| Tables | `LEGACY_DOCS`, `BENCHMARK_METRICS` |
| Search service | `LEGACY_DOCS_SEARCH` |
| Semantic view | `SV_BENCHMARK` |
| Agent | `LEGACY_ASSISTANT` |

Le bootstrap (rôle, warehouse, database, schema, stage, grants) est déjà exécuté. Ne pas le rejouer ; `sql/00_bootstrap.sql` n'existe que pour la trace.

## Règles impératives

### Sécurité et privilèges

- L'escalade de privilège n'est autorisée que dans **deux** scripts d'amorçage, à jouer une fois à la main dans Snowsight :
  - `sql/00_bootstrap.sql` — ACCOUNTADMIN ;
  - `sql/01_keypair_auth.sql` — SECURITYADMIN, requis par `ALTER USER ... SET RSA_PUBLIC_KEY`, sans alternative possible.

  Toute autre escalade est interdite — ACCOUNTADMIN, SECURITYADMIN, USERADMIN, ORGADMIN. Tout le reste s'exécute sous AI_ENGINEER_ROLE. Contrôlé par `scripts/lint_sql.py`.
- Aucun credential en dur dans le code ou les fichiers SQL. Toujours via connections.toml ou variables d'environnement.
- Ne jamais committer connections.toml, .env, ni aucun fichier de sortie contenant des données réelles.

### Honnêteté des chiffres

- Ne jamais inventer, arrondir ou extrapoler une métrique. Un chiffre non mesuré dans ce repo n'existe pas.
- Les métriques du pipeline Java sont celles fournies par l'utilisateur, telles quelles.
- Toute mesure produite ici doit être accompagnée du script qui l'a produite et du nombre de runs.
- Si une évaluation est bruitée d'un run à l'autre, le dire explicitement plutôt que de reporter le meilleur run.

### Coût (compte trial)

- Signaler toute requête ou tout objet coûteux **avant** exécution, avec une estimation.
- `RM_TRIAL` plafonne à **50 crédits/mois**, alerte 80 %, suspension 95 %. Il est rattaché à `WH_AI_DEV` seul : ne pas le détacher. `COMPUTE_WH` et le serving du search service restent hors filet.
- Le dénominateur de toute estimation est 50 crédits.
- Lire la consommation dans `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY`, jamais dans le seul `used_credits` du monitor, et sans filtrer sur un warehouse unique. Ne pas conclure sur la journée en cours : cette vue a de la latence.
- Tout outil Analyst d'un agent porte un bloc `execution_environment` pointant `WH_AI_DEV`. Sans lui, le SQL généré part sur le warehouse par défaut, hors `RM_TRIAL`.
- `TARGET_LAG` d'un Cortex Search Service : jamais sous `'1 day'`.
- Corpus plafonné à 300 documents. Ne pas proposer d'élargir sans demande explicite.
- Surveiller le coût de serving via les requêtes de gouvernance (J5) ; `DROP CORTEX SEARCH SERVICE` seulement si le coût mesuré cesse d'être négligeable.

### Pratique de travail

- Le SQL vit dans `sql/`, numéroté (`00_bootstrap.sql`, `10_ingest.sql`...), idempotent. Préférer `IF NOT EXISTS` à `OR REPLACE` sur tout objet qui ré-embedde à la création.
- Le traitement de texte (chunking, extraction) se fait en SQL côté Snowflake, pas en pandas côté client.
- Toute fonction Cortex ou syntaxe DDL récente est vérifiée dans la doc Snowflake avant usage — puis confrontée au comportement réel, qui s'en écarte régulièrement. Consigner chaque écart dans le fichier concerné.
- Expliquer avant d'exécuter : chaque nouvel objet Snowflake vient avec 3 lignes de « pourquoi cet objet ».

## Structure

```
sql/     DDL et requêtes numérotées
src/     ingest.py, ask.py, eval_text2sql.py, test_ask_parse.py
eval/    golden_questions.json
docs/    notes d'apprentissage, décisions d'architecture
```

## Anti-patterns à refuser

- Colonne `VECTOR(FLOAT, 768)` + `EMBED_TEXT_768` gérée manuellement comme solution principale (sauf `sql/90_comparaison_diy.sql`, pédagogique).
- Warehouse dimensionné au-dessus de XSMALL.
- Semantic view sans descriptions ni synonymes sur les métriques.
- Traiter une formule `METRICS` de vue sémantique comme une contrainte exécutable : l'agent aplatit la vue et re-dérive la formule lui-même. Elles sont **fortement guidées, non garanties, à valider par golden dataset en continu** (mesuré 10/10 le 21/08/2026, voir `docs/06-retrospective.md`).
- Parser la réponse de l'agent par index de bloc plutôt que par type.
- Retrier soi-même les résultats de Cortex Search sur `@scores` : la fusion finale est interne, retrier dégrade le classement.

---

Justifications, incidents d'origine et règles en attente d'arbitrage : `docs/claude-md-maintenance.md` (archive, non chargée en session).
