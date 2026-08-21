# CLAUDE.md — Projet snowflake-legacy-assistant

## Contexte

Assistant Cortex Agents interrogeant en langage naturel :

1. la documentation générée par le pipeline de modernisation Java legacy (données non structurées -> Cortex Search) ;

2. les métriques de benchmark de ce même pipeline (données structurées -> Cortex Analyst).

Projet d'apprentissage sur 5 jours, compte Snowflake trial (crédits limités, external network access bloqué).

Objectif secondaire : produire un actif de portfolio défendable en entretien.

## Environnement

- Snowflake trial, région AWS EU, CORTEX_ENABLED_CROSS_REGION = 'AWS_EU'

- Python 3.11+, snowflake-connector-python, snowflake-snowpark-python, snowflake.core

- Auth par ~/.snowflake/connections.toml, connexion nommée legacy_ai

- Client CLI uniquement - pas de Streamlit, pas de webapp

- Poste de développement : Windows

- API REST Cortex (Analyst, et probablement Agents au J4) : exige un JWT signé par la clé privée, en-tête X-Snowflake-Authorization-Token-Type: KEYPAIR_JWT. Le jeton de session du connecteur classique est refusé (400 390146 "Bearer token is missing", puis 401 390303 "Invalid OAuth access token"). Charger la clé en objet RSAPrivateKey depuis le PEM avant signature - ne pas passer les bytes bruts, AuthByKeyPair les attend en DER. Implémentation de référence : jeton_jwt() dans src/eval_text2sql.py.

## Objets Snowflake

Warehouse : WH_AI_DEV (XSMALL, AUTO_SUSPEND=60)

Database / Schema : LEGACY_AI_DB.CORE

Rôle de travail : AI_ENGINEER_ROLE

Stage : LEGACY_AI_DB.CORE.DOCS_STAGE

Table docs : LEGACY_DOCS

Table métriques : BENCHMARK_METRICS

Search service : LEGACY_DOCS_SEARCH

Semantic view : SV_BENCHMARK

Agent : LEGACY_ASSISTANT

## Statut au démarrage de Claude Code

Le bootstrap SQL (rôle, warehouse, database, schema, stage, grants) a déjà été

exécuté manuellement dans Snowsight. NE PAS tenter de l'exécuter à nouveau

automatiquement. Écrire sql/00_bootstrap.sql pour la trace du repo, mais

passer directement à la suite (tables, ingestion) sans attendre sa validation.

SNOWFLAKE.CORTEX.COMPLETE avec des modèles Anthropic peut être bloqué sur ce

compte trial malgré carte ajoutée - connu, en cours de résolution séparément.

Ne pas en dépendre pour les étapes J1 (ingestion) et J2 (Cortex Search).

## Règles impératives

### Sécurité et privilèges

- ACCOUNTADMIN est interdit en dehors du script sql/00_bootstrap.sql. Tout le reste s'exécute sous AI_ENGINEER_ROLE.

- Aucun credential en dur dans le code ou les fichiers SQL. Toujours via connections.toml ou variables d'environnement.

- Ne jamais committer connections.toml, .env, ni aucun fichier de sortie contenant des données réelles.

### Coût (compte trial)

- Toute nouvelle requête ou objet coûteux doit être signalé avant exécution, avec une estimation.

- TARGET_LAG d'un Cortex Search Service : jamais sous '1 day' sur ce projet.

- Corpus plafonné à 300 documents. Ne pas proposer d'élargir sans demande explicite.

- Proposer un DROP CORTEX SEARCH SERVICE en fin de session de travail.

- Un resource monitor (RM_TRIAL) plafonne la consommation : **50 crédits par mois**, alerte 80 %, suspension 95 %. Depuis le 21/08/2026 il est rattaché à WH_AI_DEV (`level = WAREHOUSE`). Ne pas le désactiver ni le détacher.

- Le dénominateur de toute estimation de coût est donc **50 crédits, pas 100**.

- RM_TRIAL ne couvre que WH_AI_DEV. COMPUTE_WH reste hors filet (0,3522 crédit consommés à ce jour, soit 30 % du total du compte). Un `ALTER ACCOUNT SET RESOURCE_MONITOR = RM_TRIAL` couvrirait tout, y compris le serving de LEGACY_DOCS_SEARCH qui court hors warehouse — non fait à ce jour.

#### Historique de la correction du quota (21/08/2026)

Vérification de l'état réel du compte avant d'attaquer le J4, par `SHOW RESOURCE
MONITORS` et `SHOW WAREHOUSES LIKE 'WH_AI_DEV'`. Trois écarts avec ce que ce
fichier affirmait jusque-là :

| | Ce que disait CLAUDE.md | État constaté le 20/08 |
|---|---|---|
| Quota | 100 crédits | **50,00** |
| Rattachement | « actif sur le warehouse » | **`level = None`** — orphelin |
| Crédits comptés | — | **0,00**, alors que le warehouse en avait consommé 0,80 |

Le monitor existait avec les bons seuils, mais rattaché ni au compte ni à un
warehouse il ne mesurait rien et n'aurait jamais rien suspendu. Le filet de
sécurité invoqué dans les notes du J1 et du J2 n'existait pas. Corrigé le
21/08/2026 par `ALTER WAREHOUSE WH_AI_DEV SET RESOURCE_MONITOR = RM_TRIAL`
(ACCOUNTADMIN, exécuté manuellement dans Snowsight) ; vérifié après coup :
`level = WAREHOUSE` côté monitor, `resource_monitor = RM_TRIAL` côté warehouse.

`used_credits` reste à 0,00 : un resource monitor ne compte qu'à partir de son
rattachement, il ne rattrape pas le passé. La consommation réelle se lit dans
SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY (relevé du 21/08/2026) :

```
             WH_AI_DEV   COMPUTE_WH   autres
2026-08-15      0,2001       0,2265   0,0004    bootstrap + ingestion J1
2026-08-17      0,3825       0,1250        -    J2 : search, 8 requêtes, DIY vectoriel
2026-08-18      0,1184       0,0001        -    J3 : métriques, vue sémantique
2026-08-19      0,1012       0,0005        -    évaluation Analyst, 30 appels
2026-08-20      0,0335            -        -
2026-08-21      0,0000            -        -
TOTAL           0,8357       0,3522   0,0004    = 1,1883 crédit, 2,4 % du quota
```

Deux mises en garde tirées de ce relevé :

- **Filtrer par warehouse sous-estime la facture.** Le chiffre de 0,80 crédit
  cité jusqu'ici ne portait que sur WH_AI_DEV ; le compte en a consommé 1,19.
- **ACCOUNT_USAGE a de la latence.** Le 20/08 était mesuré à 0,0003 le jour même,
  il vaut 0,0335 au relevé du 21/08. Ne pas conclure sur la journée en cours.

Formulation invalidée dans docs/02-search-vs-diy.md §9 : « nettement sous 1 crédit
sur les 100 du RM_TRIAL » — le dénominateur est 50, et à cette date le monitor ne
protégeait rien.

### Honnêteté des chiffres

- Ne jamais inventer, arrondir ou extrapoler une métrique. Un chiffre non mesuré dans ce repo n'existe pas.

- Les métriques du pipeline Java sont celles fournies par l'utilisateur, telles quelles.

- Toute mesure produite ici doit être accompagnée du script qui l'a produite et du nombre de runs.

- Si une évaluation est bruitée d'un run à l'autre, le dire explicitement plutôt que de reporter le meilleur run.

### Pratique de travail

- Le SQL vit dans sql/, numéroté (00_bootstrap.sql, 10_ingest.sql...), idempotent.

- Le traitement de texte (chunking, extraction) se fait en SQL côté Snowflake, pas en pandas côté client.

- Toute fonction Cortex ou syntaxe DDL récente doit être vérifiée dans la doc Snowflake avant usage.

- Expliquer avant d'exécuter : chaque nouvel objet Snowflake vient avec 3 lignes de "pourquoi cet objet".

## Structure attendue

sql/            DDL et requêtes numérotées

src/            ingest.py, ask.py, eval_text2sql.py

eval/           golden_questions.json

docs/           notes d'apprentissage, décisions d'architecture

README.md

## Anti-patterns à refuser

- Colonne VECTOR(FLOAT, 768) + EMBED_TEXT_768 gérée manuellement comme solution principale (sauf sql/90_comparaison_diy.sql, pédagogique).

- Warehouse dimensionné au-dessus de XSMALL.

- Semantic view sans descriptions ni synonymes sur les métriques.

- Parser la réponse de l'agent par index de bloc plutôt que par type.

