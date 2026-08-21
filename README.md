# snowflake-legacy-assistant

Assistant Cortex Agents qui répond en français à des questions sur un pipeline
de modernisation de code Java legacy, en choisissant seul sa source :

- la **documentation** produite par le pipeline — texte, via Cortex Search ;
- les **métriques d'exécution** de ce même pipeline — chiffres, via Cortex Analyst.

Projet d'apprentissage mené sur 5 jours, compte Snowflake trial, client CLI
uniquement. Tous les chiffres de ce README sont mesurés dans ce repo et cités
avec le script qui les produit — aucun n'est estimé.

```
$ python src/ask.py --trace "Quelle classe a ete la plus longue a analyser, et que fait-elle ?"

  outil    : BenchAnalyst  (system_agentic_semantic_context)
  outil    : system_execute_sql
             colonnes ['CLASSE', 'DUREE_ANALYZE_MS']
             ['ClientServiceBean', '877267']
  outil    : DocSearch  (cortex_search)

La classe la plus longue à analyser est ClientServiceBean, avec une durée de
877 267 ms. ClientServiceBean est un service métier responsable de la gestion
des clients […] (source : handoff/demo-project/specs.md)

[23.76 s, outils : BenchAnalyst, system_execute_sql, DocSearch]
```

---

## Limites connues

**À lire avant le reste.** Ce sont les résultats les plus transposables du
projet, et le premier est la découverte qui compte.

### 1. Une vue sémantique guide le modèle, elle ne le contraint pas

Les formules déclarées dans le bloc `METRICS` d'une vue sémantique **ne sont pas
appliquées telles quelles**. L'outil Analyst aplatit la vue en une CTE ne
contenant que les `FACTS` et les `DIMENSIONS` ; les `METRICS` n'y survivent pas.
Le modèle tente le nom de la métrique comme une colonne, Snowflake rejette
(`invalid identifier 'DUREE_TOTALE_MS'`), et le modèle **reconstruit l'expression
de mémoire**.

Ce n'est pas un bug, c'est le fonctionnement de la couche telle qu'elle est
déployée. Une vue sémantique Snowflake n'est pas une couche sémantique au sens
Looker ou dbt Metrics, où la définition est compilée et donc inviolable : c'est
un **corpus de guidage** consommé par un LLM qui réécrit le SQL de zéro.

Mesuré le 21/08/2026 sur 10 questions de durée totale :

| | |
|---|---|
| Valeur finale juste | **10 / 10** |
| SQL final tombant dans le piège de la somme d'étapes | **0 / 10** |
| Questions ayant déclenché ≥ 1 `invalid identifier` | **10 / 10** |
| SQL exécutés / en erreur | 22 / **12 (55 %)** |

Les deux conclusions tiennent ensemble : **le contournement est systématique, et
la parade tient quand même.** Descriptions croisées, synonymes disjoints et
`AI_SQL_GENERATION` ont fait converger la re-dérivation vers la bonne formule à
chaque fois — y compris sur une question tendue vers le piège, où l'agent a
rendu les deux grandeurs en nommant l'ambiguïté.

> Formulation défendable : les formules `METRICS` sont **fortement guidées, non
> garanties, à valider par golden dataset en continu**. Un 10/10 sur 10 questions
> a une borne inférieure de confiance à 95 % d'environ **69 %** — ce n'est pas
> une garantie, c'est une mesure.

Mécanisme, protocole et implications production : **[`docs/06-retrospective.md`](docs/06-retrospective.md)**.

### 2. La documentation Snowflake décrit l'intention, pas le déployé

Cinq écarts constatés à l'exécution, **aucun détectable en lisant la doc** :

| Écart | Où |
|---|---|
| `SEARCH_PREVIEW` renvoie un VARCHAR, pas un OBJECT — il faut `PARSE_JSON` | J2 |
| La clé `@scores` existe, non documentée, renvoyée sans être demandée | J2 |
| L'outil Analyst se dédouble en `system_agentic_semantic_context` + N `system_execute_sql` | J4 |
| L'agent retente le SQL en silence après erreur, rien ne remonte | J4 |
| Un bloc `suggested_queries` suit le bloc `text` final | J4 |

D'où la règle du projet : vérifier dans la doc, **puis** confronter au
comportement réel, et consigner l'écart.

### 3. Le nombre de blocs d'une réponse d'agent n'est pas une constante

La même question a produit 3 puis 4 appels `system_execute_sql` d'un run à
l'autre. `src/ask.py` parcourt donc la réponse **par type de bloc**, jamais par
index — `content[-1]` aurait rendu les `suggested_queries` à la place de la
réponse.

### 4. Le masquage ne suit pas la donnée dans un index de recherche

**Mesuré le 21/08/2026, pas supposé.** Une masking policy s'applique à la
lecture de la table ; `LEGACY_DOCS_SEARCH` sert depuis un index construit avant
l'attachement, qui contient le texte en clair. Le même rôle obtient donc deux
réponses différentes selon le chemin d'accès :

| `AI_ANALYST_ROLE` demande `DOC_CONTENT`… | Résultat |
|---|---|
| …par `SELECT` sur `LEGACY_DOCS` | **93 caractères**, tronqués par la policy |
| …par `SEARCH_PREVIEW` sur `LEGACY_DOCS_SEARCH` | **1 411 caractères, en clair** |

**Masquer une colonne déjà indexée protège la table, pas la réponse.** Un rôle
privé du contenu par `SELECT` le récupère intégralement dès qu'il obtient
`USAGE` sur le service — et donc, a fortiori, via l'agent.

Deux parades, aucune automatique : poser la policy **avant** de créer l'index,
ou reconstruire l'index après l'avoir posée. À défaut, traiter `USAGE` sur un
service de recherche comme équivalent à un accès en clair aux colonnes indexées.
Reproduction : `sql/60_masking.sql`.

### 5. Le poste de coût dominant est le réveil du warehouse, pas le token

Établi au J2, reconfirmé au J5 — où une estimation fondée sur un coût par appel
s'est révélée **5× trop basse** parce qu'elle ignorait les réveils d'une
campagne étalée. Sur ce projet, raisonner en tokens conduit à sous-estimer.

---

## Architecture

```
                    ┌──────────────────────────────────────┐
   question FR ───► │  LEGACY_ASSISTANT      (Cortex Agent) │
                    │  routeur : documentaire ou chiffré ?  │
                    └───────────┬──────────────┬───────────┘
                                │              │
                     texte ─────┘              └───── chiffres
                                │                     │
                    ┌───────────▼─────────┐  ┌────────▼──────────────┐
                    │ DocSearch           │  │ BenchAnalyst          │
                    │ cortex_search       │  │ text-to-SQL           │
                    │ LEGACY_DOCS_SEARCH  │  │ SV_BENCHMARK          │
                    └───────────┬─────────┘  └────────┬──────────────┘
                                │                     │
                    ┌───────────▼─────────┐  ┌────────▼──────────────┐
                    │ LEGACY_DOCS         │  │ BENCHMARK_METRICS     │
                    │ 30 chunks           │  │ table EAV, 2 runs     │
                    │ DOC_CONTENT + policy│  │                       │
                    └─────────────────────┘  └───────────────────────┘
                                ▲                     ▲
                                └──── DOCS_STAGE ─────┘
                                      src/ingest.py
```

Tout s'exécute sous `AI_ENGINEER_ROLE` sur `WH_AI_DEV` (XSMALL, `AUTO_SUSPEND=60`),
dans `LEGACY_AI_DB.CORE`. `ACCOUNTADMIN` n'intervient que pour les grants, à la
main dans Snowsight.

### Les objets, et pourquoi chacun

| Objet | Rôle | Script |
|---|---|---|
| `DOCS_STAGE` | dépôt des markdown produits par le pipeline | `00_bootstrap.sql` |
| `LEGACY_DOCS` | corpus chunké, une ligne par chunk | `10_tables.sql`, `20_chunk.sql` |
| `LEGACY_DOCS_SEARCH` | index hybride lexical + vectoriel + reranker | `30_search_service.sql` |
| `BENCHMARK_METRICS` | métriques du pipeline, table EAV | `40_metrics.sql` |
| `SV_BENCHMARK` | vue sémantique : vocabulaire métier + pièges adressés | `41_semantic_view.sql` |
| `LEGACY_ASSISTANT` | l'agent, ses outils, ses instructions, son budget | `50_agent.sql` |
| `MP_DOC_CONTENT` | masking policy sur la colonne de contenu | `60_masking.sql` |
| `RM_TRIAL` | resource monitor, 50 crédits/mois | manuel, Snowsight |

> `MP_DOC_CONTENT` est **appliquée et vérifiée** (`POLICY_STATUS = ACTIVE`) : en
> clair pour `AI_ENGINEER_ROLE`, tronquée à 40 caractères pour `AI_ANALYST_ROLE`.
> Ses deux grants ACCOUNTADMIN et le rôle lecteur sont un préalable, décrit en
> tête de `sql/60_masking.sql`.

---

## Relancer

### Prérequis

- Compte Snowflake **Enterprise** (masking policies) avec Cortex activé —
  `CORTEX_ENABLED_CROSS_REGION = 'AWS_EU'` sur ce déploiement.
- Python 3.11+, `snowflake-connector-python`, `snowflake-snowpark-python`,
  `snowflake.core`, `requests`, `cryptography`, `PyJWT`.
- `~/.snowflake/connections.toml` avec une connexion `legacy_ai` en
  **authentification par paire de clés**, la clé privée en
  `~/.snowflake/rsa_key.p8`.

L'API REST Cortex n'accepte pas le jeton de session du connecteur : elle exige
un **JWT signé par la clé privée** avec l'en-tête
`X-Snowflake-Authorization-Token-Type: KEYPAIR_JWT`. Implémentation de
référence : `jeton_jwt()` dans `src/eval_text2sql.py`.

### Ordre d'exécution

Les scripts `sql/` sont numérotés et idempotents. `00_bootstrap.sql` et les
blocs `PREALABLE` des scripts 50 et 60 s'exécutent **sous ACCOUNTADMIN dans
Snowsight** ; tout le reste sous `AI_ENGINEER_ROLE`.

```bash
# 1. Bootstrap — ACCOUNTADMIN, manuel dans Snowsight
#    sql/00_bootstrap.sql   rôle, warehouse, database, schema, stage, grants
#    sql/01_keypair_auth.sql  clé publique (placeholders uniquement dans le repo)

# 2. Corpus
python src/ingest.py                  # dépôt sur stage + chunking côté Snowflake
#    sql/10_tables.sql  sql/20_chunk.sql  sql/30_search_service.sql

# 3. Métriques
#    sql/40_metrics.sql  sql/41_semantic_view.sql

# 4. Agent — le grant CREATE AGENT est un préalable ACCOUNTADMIN
#    sql/50_agent.sql
python src/ask.py "Combien de temps a dure la phase analyze ?"

# 5. Masking — grants CREATE/APPLY MASKING POLICY + rôle lecteur, préalable
#    sql/60_masking.sql
```

### Interroger

```bash
python src/ask.py "Comment les factures sont-elles generees ?"     # documentaire
python src/ask.py --trace "Combien de temps a dure analyze ?"      # + routage, SQL, docs
python src/ask.py --raw   "Y a-t-il eu des echecs d'etape ?"       # JSON brut de l'API
```

### Vérifier

```bash
python src/test_ask_parse.py     # 7 cas de dépouillement, hors ligne, sans crédit
python src/eval_text2sql.py      # golden dataset Analyst, 10 questions, via API REST
```

---

## Chiffres mesurés

Chaque ligne est reproductible par le script cité. Rien n'est extrapolé.

### Corpus et recherche — `docs/02-search-vs-diy.md`, 17/08/2026

| Mesure | Valeur | Source |
|---|---|---|
| Corpus | 30 chunks, 3 fichiers, 31 634 caractères | `20_chunk.sql` |
| Construction de l'index | 4,7 s, 30 lignes, `indexing_state = ACTIVE` | `30_search_service.sql` |
| Requêtes de recette | 8, toutes exécutées | `31_search_tests.sql` |

**Écart de qualité mesuré**, sur la question des factures — la seule qui sépare
nettement les trois moteurs :

| Moteur | Rang de `InvoiceGeneratorBean` |
|---|---|
| Cortex Search (managé) | **1er / 2e** |
| DIY vectoriel `EMBED_TEXT_768` | 10e / 11e |
| DIY lexical | **absent** |

Mécanismes identifiés : flexion morphologique pour le lexical, absence de fusion
hybride et de reranking pour le vectoriel, et surtout **l'asymétrie
requête/document de l'embedding**, qui inverse le classement sans rien signaler.
Reproduction : `sql/90_comparaison_diy.sql`.

**Les `@scores` ne déterminent pas l'ordre affiché.** Sur 7 questions, aucun des
trois scores n'est monotone le long du classement ; sur Q3, Q5 et Q6, aucun des
trois. La fusion finale est interne et non reconstituable — **ne jamais retrier
soi-même sur ces scores.**

### Métriques du pipeline — `sql/40_metrics.sql`, données fournies telles quelles

| | `analyze` | `report` |
|---|---|---|
| `duration_total_ms` | 877 739 | 2 711 957 |
| `SUM(step_duration_ms)` | 2 676 441 | 2 711 640 |
| Ratio | **3,05×** | 1,00× |
| Fichiers traités | 4 | 0 |
| Étapes | 9 | 3 |
| Étapes en échec | 0 | **1** |

Trois pièges structurels, tous **adressés** dans `41_semantic_view.sql` — au
sens de la limite n° 1 : le modèle y est fortement guidé, pas contraint.

1. **La somme des étapes n'est pas la durée écoulée.** Les 4 étapes `analyze`
   tournent en parallèle (364 282 / 631 215 / 802 751 / **877 267** ms) ; la plus
   longue vaut le temps mural. Le piège est **intermittent** — juste sur
   `report`, faux d'un facteur 3 sur `analyze`.
2. **`success_rate_pct = 0 %` sur `report` ne signale aucun échec** : `files_total`
   vaut 0, le pipeline calcule 0/0. Le seul vrai échec est au niveau *étape*
   (`migration-plan`, timeout Java, rejouée en `migration-plan_retry2`).
3. **`analyze` désigne à la fois une phase et une étape interne.**

### Évaluation

| Campagne | Résultat | Script |
|---|---|---|
| Golden dataset Analyst, 10 questions, 3 runs | **médiane 10/10** | `src/eval_text2sql.py` |
| Recette agent J4, 4 questions | 4/4 conformes | `src/ask.py --trace` |
| Robustesse du parseur, 7 formes de payload | 7/7 | `src/test_ask_parse.py` |
| Re-dérivation `METRICS`, 10 questions | 10/10 justes, 12 SQL en erreur | voir `docs/06-retrospective.md` §6 |
| Masking sur deux rôles, table puis index | 1 411 clair / **93 masqué** / **1 411 clair via l'index** | `sql/60_masking.sql` |

Recette J4, par type de question : documentaire → `DocSearch` seul, sources
citées ; chiffrée → 877 739 ms, conforme au golden q1 ; mixte → `BenchAnalyst`
puis `DocSearch` dans cet ordre, `ClientServiceBean` / 877 267 ms, conforme à q3 ;
hors périmètre → **aucun appel d'outil**, refus explicite.

### Coût — `WAREHOUSE_METERING_HISTORY`, relevé du 21/08/2026

| | Crédits |
|---|---|
| `WH_AI_DEV` | 1,2052 |
| `COMPUTE_WH` | 0,3522 |
| Autres | 0,0004 |
| **Total compte** | **1,5578** — soit **3,1 %** du quota de 50 |

Relevé en fin de J5, `ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` sans filtre de
warehouse. C'est un **plancher** : la vue a de la latence et la journée en cours
y est sous-évaluée.

`RM_TRIAL` plafonne à 50 crédits/mois (alerte 80 %, suspension 95 %), rattaché à
`WH_AI_DEV` depuis le 21/08/2026. **`COMPUTE_WH` reste hors filet**, ainsi que le
serving du search service qui court hors warehouse.

**Garde-fou vérifié, pas supposé** : les 67 requêtes générées par Cortex ont
toutes tourné sur `WH_AI_DEV`, aucune sur `COMPUTE_WH` — c'est le bloc
`execution_environment` de `sql/50_agent.sql` qui le garantit. Sans lui, le SQL
de l'agent partirait sur le warehouse par défaut, hors monitor.

> Deux mises en garde de méthode, apprises à nos dépens : **filtrer par warehouse
> sous-estime la facture** (0,80 mesuré contre 1,19 réel au 20/08), et
> **`ACCOUNT_USAGE` a de la latence** — ne pas conclure sur la journée en cours.

---

## Sécurité

- `ACCOUNTADMIN` est interdit hors `sql/00_bootstrap.sql` et des blocs
  `PREALABLE` explicitement marqués. Tout le reste tourne sous `AI_ENGINEER_ROLE`.
- Aucun credential dans le repo. `sql/01_keypair_auth.sql` n'expose que des
  placeholders `<entre chevrons>` ; la clé privée vit dans `~/.snowflake/`.
- `eval/analyst_run_log.json` est ignoré par git : il contient des données réelles
  du pipeline client. Le golden dataset, lui, est versionné — c'est l'actif.
- `LEGACY_DOCS.DOC_CONTENT` porte une masking policy de démonstration,
  `MP_DOC_CONTENT` (`sql/60_masking.sql`), vérifiée sur deux rôles : 1 411
  caractères en clair pour `AI_ENGINEER_ROLE`, 93 caractères tronqués pour
  `AI_ANALYST_ROLE`. **Elle ne couvre pas l'index de recherche** — voir la
  limite n° 4, c'est le résultat le plus important de cette section.

---

## Structure

```
sql/     00_bootstrap  01_keypair_auth  10_tables  20_chunk  30_search_service
         31_search_tests  40_metrics  41_semantic_view  50_agent  60_masking
         90_comparaison_diy
src/     ingest.py  ask.py  eval_text2sql.py  test_ask_parse.py
eval/    golden_questions.json
docs/    02-search-vs-diy.md        Cortex Search vs DIY, l'embedding asymétrique
         06-retrospective.md        la limite structurelle des vues sémantiques
         claude-md-maintenance.md   archive : chaque règle et l'incident qui l'a motivée
```
