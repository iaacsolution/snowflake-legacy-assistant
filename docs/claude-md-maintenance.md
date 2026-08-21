# Maintenance de CLAUDE.md — inventaire, preuves, arbitrages

Archive de travail, produite au J5 (21/08/2026) avant packaging final.
**Ce fichier n'est jamais chargé par Claude Code au démarrage d'une session.**
Il n'est pas référencé par une syntaxe d'import (`@chemin`) depuis CLAUDE.md —
seule une mention en prose y renvoie, ce qui ne déclenche aucun chargement.

Objet : pour chaque règle de CLAUDE.md, l'échec précis qui l'a motivée. Quand
aucun échec n'est retrouvable dans `docs/`, les commits ou les sessions, la
règle est marquée **NON VÉRIFIÉE** plutôt que dotée d'une justification
reconstruite après coup.

Sources dépouillées : `docs/02-search-vs-diy.md`, les deux commits du repo
(`98932d9` J1–J3, `821b618` J4), `.gitignore`, `eval/golden_questions.json`,
la version de CLAUDE.md antérieure à cette réécriture, et la session J4.

Convention de statut :

| Statut | Sens |
|---|---|
| **PROUVÉE** | un incident daté et localisable l'a motivée |
| **DÉCISION** | choix d'ingénierie argumenté, sans incident — le raisonnement est traçable |
| **NON VÉRIFIÉE** | hypothèse « au cas où », jamais éprouvée sur ce projet |
| **RÉFUTÉE** | l'énoncé lui-même s'est révélé faux |

---

## 1. Sécurité et intégrité — conservées sans arbitrage

Conservées **verbatim** lors de l'inventaire, sur consigne explicite : elles
n'ont été ni fusionnées, ni reformulées, ni supprimées de ma propre initiative,
quel que soit leur statut de preuve. Leur réévaluation appartient à l'auteur.

**Une seule a été amendée depuis, et sur sa décision** : r10, dont le texte ne
décrivait pas le repo (détail en fin de section).

### r10 — escalade de privilège limitée aux scripts d'amorçage

- **Statut** : DÉCISION.
- **Échec observé** : aucun incident. La règle a tenu sans friction sur J1–J4.
- **Fréquence** : 0 violation.
- **Hypothèse de cause** : sur un compte trial mono-utilisateur, la tentation
  est permanente de régler un `insufficient privileges` en escaladant plutôt
  qu'en accordant le grant manquant.
- **Résultat** : deux escalades légitimes se sont produites au J4, toutes deux
  passées par Snowsight en manuel et non par un script — `GRANT CREATE AGENT`,
  et `ALTER WAREHOUSE ... SET RESOURCE_MONITOR`. La règle a produit exactement
  le comportement voulu : l'agent signale le grant manquant au lieu de
  l'accorder lui-même.
- **Test d'infirmation** : rejouer le repo depuis zéro sous `AI_ENGINEER_ROLE`
  seul et compter les blocages. S'il y en a plus de deux ou trois, la frontière
  bootstrap/travail est mal tracée.
- **Amendement du 21/08/2026, décidé par l'auteur.** L'écriture de
  `scripts/lint_sql.py` a révélé que la règle ne décrivait pas le repo : elle ne
  nommait que `00_bootstrap.sql`, alors que `01_keypair_auth.sql` escalade
  légitimement en SECURITYADMIN depuis le J1 — `ALTER USER ... SET
  RSA_PUBLIC_KEY` l'exige et il n'existe aucune alternative. Le linter appliquait
  donc une liste blanche plus large que la règle écrite, ce qui est exactement
  l'inverse de ce qu'on veut d'un garde-fou. La règle nomme désormais les deux
  exceptions et interdit tout le reste ; le linter en est la transcription
  littérale. **Preuve que le garde-fou vaut plus que la règle seule** : c'est en
  automatisant le contrôle qu'on a découvert que le texte était faux depuis
  quatre jours, sans qu'aucune relecture ne l'ait vu.

### r11 — aucun credential en dur

- **Statut** : DÉCISION.
- **Échec observé** : aucun. `sql/01_keypair_auth.sql` n'expose que des
  placeholders `<entre chevrons>`, clé publique et empreinte comprises
  (vérifié au commit `98932d9`).
- **Test** : `git log -p` sur un motif de clé privée (`BEGIN PRIVATE KEY`).

### r12 — ne jamais committer `connections.toml`, `.env`, ni données réelles

- **Statut** : PROUVÉE, par anticipation réussie.
- **Échec observé** : `eval/analyst_run_log.json` contient des données réelles
  du pipeline client — noms de classes Java, durées mesurées. Il a été ignoré
  avant le premier commit, pas après.
- **Fréquence** : 1 fichier concerné, 0 fuite.
- **Résultat** : `.gitignore` distingue explicitement le journal d'évaluation
  (ignoré, données réelles) du golden dataset (versionné, actif du projet).
  C'est la bonne granularité : la règle n'a pas conduit à sur-ignorer.
- **Test** : `git log --all --numstat | grep analyst_run_log` doit rester vide.

### r21–r24 — honnêteté des chiffres

- **Statut** : **PROUVÉE**, et par un incident dont CLAUDE.md était lui-même
  la victime.
- **Échec observé, daté du 21/08/2026** : le fichier affirmait un quota de
  100 crédits et un resource monitor « actif sur le warehouse ». Vérification
  faite : quota réel **50**, `level = None` — le monitor n'était rattaché à
  rien et n'aurait jamais rien suspendu. Le chiffre faux s'était propagé dans
  `docs/02-search-vs-diy.md` §9 (« nettement sous 1 crédit sur les 100 »).
- **Fréquence** : 1 chiffre inventé, propagé dans 2 fichiers, survivant à
  3 journées de travail (J1 à J3) sans être détecté.
- **Hypothèse de cause** : un ordre de grandeur plausible et jamais mesuré est
  indétectable par relecture. Seule une commande le réfute.
- **Approches écartées** : « relire attentivement » — c'est précisément ce qui
  a échoué trois jours de suite.
- **Résultat depuis** : au J4, les quatre réponses de l'agent ont été
  confrontées à `eval/golden_questions.json` (877 739 ms → q1, 877 267 ms →
  q3) et le garde-fou de coût vérifié par `QUERY_HISTORY` plutôt qu'affirmé.
  Le non-déterminisme observé (3 puis 4 appels d'outil pour la même question)
  a été consigné au lieu d'être lissé — c'est r24 qui s'applique.
- **Test permanent** : tout nombre de CLAUDE.md doit être ré-obtenable par une
  commande citée à côté de lui. Un nombre sans commande est un candidat à
  l'erreur.

---

## 2. Coût — conservées, avec preuves

### r13 — signaler tout coût avant exécution

- **Statut** : DÉCISION.
- **Fréquence** : appliqué à chaque étape J1–J4 ; aucun dépassement.
- **Résultat mesuré** : 1,1883 crédit consommé au total sur le compte au
  21/08/2026, soit 2,4 % du quota de 50. La règle n'a jamais eu à mordre.
- **Réserve** : une règle qui ne mord jamais peut être une bonne prévention
  comme un rituel inutile. Ici le J4 tranche en sa faveur — voir r-new-1.
- **Test** : comparer le coût annoncé au coût constaté dans
  `WAREHOUSE_METERING_HISTORY` sur trois opérations successives.

### r17 + r18 + r19 — `RM_TRIAL`, 50 crédits, périmètre du filet

**Fusionnées en une règle unique.** Elles énonçaient la même contrainte
(le plafond réel et sa portée) découpée en trois puces, dont une (r18,
« le dénominateur est 50, pas 100 ») n'était qu'une note de correction
adressée à une version antérieure du fichier — sans valeur pour une session
future qui ne verra jamais le « 100 ».

- **Statut** : PROUVÉE. Voir r21–r24 ci-dessus, même incident.
- **Détail conservé de l'audit du 21/08/2026** :

| | Ce que disait CLAUDE.md | État constaté |
|---|---|---|
| Quota | 100 crédits | **50,00** |
| Rattachement | « actif sur le warehouse » | **`level = None`** — orphelin |
| Crédits comptés | — | **0,00**, alors que le warehouse en avait consommé 0,80 |

- **Correction appliquée** : `ALTER WAREHOUSE WH_AI_DEV SET RESOURCE_MONITOR
  = RM_TRIAL` (ACCOUNTADMIN, Snowsight). Vérifié après coup : `level =
  WAREHOUSE` côté monitor, `resource_monitor = RM_TRIAL` côté warehouse.
- **Piège conservé dans CLAUDE.md** : `used_credits` reste à 0,00 — un monitor
  ne compte qu'à partir de son rattachement, il ne rattrape pas le passé.
- **Relevé `WAREHOUSE_METERING_HISTORY` au 21/08/2026** (archivé ici, retiré
  de CLAUDE.md : c'est un instantané, pas une règle) :

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

- **Deux mises en garde tirées du relevé**, promues en règle dans CLAUDE.md :
  filtrer par warehouse sous-estime la facture (0,80 vs 1,19 réel) ;
  `ACCOUNT_USAGE` a de la latence (le 20/08 valait 0,0003 le jour même,
  0,0335 au relevé du lendemain).
- **Point non résolu** : `COMPUTE_WH` reste hors filet, ainsi que le serving de
  `LEGACY_DOCS_SEARCH` qui court hors warehouse. Un `ALTER ACCOUNT SET
  RESOURCE_MONITOR = RM_TRIAL` couvrirait tout. **Non fait à ce jour** —
  décision utilisateur.
- **Test** : `SHOW RESOURCE MONITORS` doit rendre `level = WAREHOUSE` et
  `credit_quota = 50`. Si `level` repasse à `None`, le filet est de nouveau
  fictif.

### r14 — `TARGET_LAG` jamais sous `'1 day'`

- **Statut** : DÉCISION, argumentée dans `docs/02-search-vs-diy.md` §8.
- **Raisonnement d'origine** : `TARGET_LAG` est un **plafond, pas une
  fréquence**. Corpus quasi statique (30 chunks, 3 fichiers sources), donc coût
  de rafraîchissement réel proche de zéro. Descendre le lag n'achèterait rien.
- **Échec observé** : aucun. La règle n'a jamais été mise à l'épreuve.
- **Test** : mesurer le coût de refresh à `'1 hour'` sur ce corpus. S'il reste
  indiscernable de zéro, la règle est un garde-fou pour un corpus futur plus
  gros, pas pour celui-ci — et son énoncé devrait le dire.

### r16 — proposer `DROP CORTEX SEARCH SERVICE` en fin de session

- **Statut** : **NON VÉRIFIÉE**. ⚠️ Candidate à arbitrage.
- **Échec observé** : aucun. Aucune facture de serving n'a jamais été isolée.
- **Ce que la mesure dit** : `docs/02` §9 chiffre l'index à **~31 Ko**, facturé
  au Go/mois. Le poste dominant du projet n'est pas le serving mais « le réveil
  du warehouse ». Le coût que cette règle prétend éviter n'a jamais été
  distingué de zéro.
- **Coût de la règle** : elle impose un rappel à chaque fin de session, et une
  reconstruction du service (donc un ré-embedding des 30 chunks) à chaque
  reprise.
- **Hypothèse de cause** : règle importée d'un contexte de corpus volumineux,
  appliquée telle quelle à un corpus de 31 Ko.
- **Test décisif** : relever `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_
  SERVING_USAGE_HISTORY` (ou équivalent) sur 7 jours avec le service laissé
  actif. Si le total est sous 0,05 crédit, la règle coûte plus qu'elle ne
  rapporte.

### r15 — corpus plafonné à 300 documents

- **Statut** : **NON VÉRIFIÉE**. ⚠️ Candidate à arbitrage.
- **Échec observé** : aucun.
- **Fait gênant** : le corpus réel est de **30 chunks / 3 fichiers sources**,
  soit un ordre de grandeur sous le plafond. La contrainte n'a jamais été
  approchée, donc jamais éprouvée. Le nombre 300 n'est rattaché à aucune
  mesure dans le repo — c'est exactement le motif que r21 proscrit ailleurs.
- **Test** : soit rattacher 300 à un calcul (coût d'embedding par document ×
  budget acceptable), soit remplacer le plafond par la grandeur réellement
  contraignante — le crédit — et laisser r13 faire le travail.

### r31 — warehouse jamais au-dessus de XSMALL

- **Statut** : DÉCISION.
- **Échec observé** : aucun ; `WH_AI_DEV` est XSMALL depuis le bootstrap et
  n'a jamais été redimensionné.
- **Résultat** : aucune requête du projet n'a saturé un XSMALL. La création du
  search service a pris 4,7 s.
- **Test** : si une opération dépasse la minute sur XSMALL, la règle devient un
  arbitrage coût/temps et non plus une évidence.

---

## 3. Pratique de travail

### r25 — SQL numéroté, idempotent

- **Statut** : PROUVÉE.
- **Échec observé** : `docs/02` §8 — un `OR REPLACE` sur le search service
  **re-embedde les 30 chunks à chaque exécution du script**. D'où le choix de
  `IF NOT EXISTS` pour cet objet.
- **Contre-exemple assumé, J4** : `sql/50_agent.sql` utilise volontairement
  `CREATE OR REPLACE`, parce qu'un agent est un objet de configuration —
  le remplacer ne détruit aucun index et ne ré-embedde rien.
- **Affinage porté dans CLAUDE.md** : la règle ne dit plus « idempotent » tout
  court mais nomme le critère — `IF NOT EXISTS` sur ce qui ré-embedde à la
  création, `OR REPLACE` ailleurs.
- **Incident secondaire, J4** : exécuter `50_agent.sql` par
  `connection.execute_string()` échoue sur `000900 Empty SQL statement`, parce
  que le bloc de commentaire final est découpé comme un statement vide. Sans
  conséquence sur l'idempotence, mais à savoir avant de scripter l'exécution.
- **Test** : rejouer deux fois chaque script de `sql/` et comparer le coût du
  second passage au premier.

### r26 — chunking en SQL côté Snowflake, pas en pandas

- **Statut** : DÉCISION.
- **Échec observé** : aucun. `src/ingest.py` fait le chunking côté Snowflake
  depuis l'origine ; l'alternative pandas n'a jamais été essayée puis écartée,
  elle a été exclue d'emblée.
- **Hypothèse de cause** : éviter le transfert du corpus vers le client et
  garder une seule source de vérité.
- **Test** : mesurer le temps de chunking des 3 fichiers en pandas. Si l'écart
  est nul à cette échelle, la règle est une préparation au passage à l'échelle,
  pas une optimisation présente.

### r27 — vérifier la doc Snowflake avant usage

- **Statut** : PROUVÉE, mais **l'énoncé d'origine était insuffisant** — et
  c'est le point le plus intéressant de cet inventaire.
- **Échecs observés** : cinq écarts documentation/réalité, tous constatés à
  l'exécution et **aucun détectable par lecture de la doc** :

| # | Écart | Où |
|---|---|---|
| 1 | `SEARCH_PREVIEW` renvoie un VARCHAR, pas un OBJECT — `:results` échoue sur `Invalid argument types for function 'GET'`, il faut `PARSE_JSON` | `docs/02` §8, J2 |
| 2 | La clé `@scores` existe, non documentée, renvoyée sans être demandée | `docs/02` §4, J2 |
| 3 | L'outil Analyst se dédouble à l'exécution : `system_agentic_semantic_context` puis N `system_execute_sql` | `sql/50_agent.sql`, J4 |
| 4 | L'agent retente le SQL en silence après erreur, sans que rien ne remonte | idem, J4 |
| 5 | Un bloc `suggested_queries` suit le bloc `text` final | idem, J4 |

- **Fréquence** : 2 écarts au J2, 3 au J4. Aucune journée impliquant une
  surface Cortex nouvelle n'en a été exempte.
- **Hypothèse de cause** : la doc Snowflake sur les surfaces Cortex récentes
  décrit l'intention, pas le déployé. Elle est nécessaire et non suffisante.
- **Approche écartée** : se fier à la doc seule — réfutée cinq fois.
- **Reformulation appliquée** : vérifier dans la doc **puis confronter au
  comportement réel, et consigner l'écart**. C'est ce second temps qui produit
  la valeur, et il était absent de l'ancien énoncé.
- **Test** : sur la prochaine surface Cortex utilisée, prévoir d'emblée un
  appel `--raw` avant d'écrire le parseur.

### r28 — 3 lignes de « pourquoi cet objet »

- **Statut** : DÉCISION, alignée sur la finalité pédagogique et portfolio.
- **Résultat** : tenue dans `41_semantic_view.sql` et `50_agent.sql`, qui
  ouvrent tous deux sur un bloc « POURQUOI CET OBJET ».
- **Test** : impossible à infirmer techniquement. C'est une règle de
  livrable, à évaluer en entretien — son vrai banc d'essai.

---

## 4. Anti-patterns

### r30 — pas de `VECTOR(FLOAT, 768)` + `EMBED_TEXT_768` manuel en solution principale

- **Statut** : **PROUVÉE, et chiffrée** — c'est la règle la mieux étayée du
  fichier.
- **Échec observé** (`docs/02`, mesures du 17/08/2026, 30 chunks) : sur la
  question des factures, `InvoiceGeneratorBean` sort **1er/2e chez Cortex
  Search, 10e/11e en DIY vectoriel, absent en DIY lexical**.
- **Mécanismes identifiés** : flexion morphologique pour le lexical ; absence
  de fusion hybride et de reranking pour le vectoriel ; et surtout
  **l'asymétrie requête/document de l'embedding**, qui inverse le classement
  sans rien signaler.
- **Exception maintenue** : `sql/90_comparaison_diy.sql`, dont c'est l'objet.
- **Test** : rejouer les 8 questions de `sql/31_search_tests.sql` sur les trois
  moteurs. L'écart doit persister.

### r32 — pas de semantic view sans descriptions ni synonymes sur les métriques

- **Statut** : DÉCISION — et **partiellement fragilisée au J4**.
- **Motivation d'origine** : `41_semantic_view.sql` neutralise trois pièges
  (somme des durées d'étapes ≠ durée écoulée, `success_rate_pct = 0 %` issu
  d'une division 0/0, homonymie phase/étape `analyze`) au moyen de
  descriptions croisées sur les METRICS.
- **Ce que le J4 a montré** : l'agent ne consomme pas les METRICS comme des
  colonnes. Il aplatit la vue en une CTE ne contenant que les FACTS et
  DIMENSIONS, puis **re-dérive lui-même l'expression de la métrique**.
  Constaté : 6 échecs `SQL compilation error: invalid identifier
  'DUREE_TOTALE_MS'` avant qu'un SQL reconstruit en
  `SUM(CASE WHEN nom_mesure = 'duration_total_ms' THEN valeur END)` aboutisse.
- **Conséquence** : les garde-fous portés par les descriptions de METRICS
  agissent comme **guidage** (via les COMMENT et `AI_SQL_GENERATION`), pas
  comme **contrainte exécutable**. Ils ont tenu au J4 — la re-dérivation était
  correcte — mais rien ne le garantissait.
- **La règle reste juste ; elle est simplement insuffisante seule.**
- **Test décisif — EXÉCUTÉ le 21/08/2026. Résultat ci-dessous.**
  Protocole et analyse complète : `docs/06-retrospective.md`.

  10 questions de durée totale, formulations variées, une tendue vers le piège.

  | | |
  |---|---|
  | Valeur finale juste | **10 / 10** |
  | SQL final sommant `step_duration_ms` | **0 / 10** |
  | Questions ayant déclenché ≥ 1 `invalid identifier` | **10 / 10** |
  | SQL exécutés / erreurs | 22 / **12** |

  **Double conclusion, à ne pas confondre.** Le contournement est *confirmé et
  systématique* : les METRICS ne survivent jamais à l'aplatissement, 100 % des
  questions passent par un échec avant d'aboutir. Mais la parade *tient* :
  aucune réponse n'a présenté la somme des étapes comme une durée écoulée, et
  sur la question piège l'agent a rendu les deux grandeurs en nommant le piège.

  Le déplacement de la garde vers une vue pré-agrégée n'est donc **pas**
  déclenché : à 10/10, il coûterait plus qu'il ne rapporte sur ce corpus. La
  règle r32 reste valide, avec sa formulation corrigée — « fortement guidées,
  non garanties, à valider par golden dataset en continu ».

### r33 — ne pas parser la réponse de l'agent par index de bloc

- **Statut** : **PROUVÉE au J4**, sur payload réel.
- **Échec évité** : le bloc `text` final **n'est pas le dernier** — un bloc
  `suggested_queries` le suit. Un parseur lisant `content[-1]` aurait rendu
  les suggestions à la place de la réponse. Un parseur lisant `content[0]`
  aurait rendu un `thinking`.
- **Variabilité mesurée** : la même question a produit des traces de longueur
  différente d'un run à l'autre (3 puis 4 `system_execute_sql`). Le nombre de
  blocs n'est pas une constante.
- **Résultat** : `src/ask.py` parcourt par `type` ; `src/test_ask_parse.py`
  couvre 7 formes, dont la forme réellement observée au J4.
- **Test** : `python src/test_ask_parse.py`, hors ligne, sans crédit.

### r-new-2 (ajout) — ne pas retrier les résultats de Cortex Search sur `@scores`

- **Statut** : PROUVÉE, mesurée au J2, **absente de l'ancien CLAUDE.md**.
- **Échec observé** (`docs/02` §4, 7 questions) : aucun des trois scores
  (`reranker_score`, `cosine_similarity`, `text_match`) n'est monotone le long
  du classement retourné. Sur Q3, Q5 et Q6, **aucun des trois** ne l'est.

| | reranker | cosinus | lexical |
|---|---|---|---|
| Q1 | non | non | **oui** |
| Q2 | non | **oui** | non |
| Q3 | non | non | non |
| Q4 | **oui** | non | non |
| Q5 | non | non | non |
| Q6 | non | non | non |
| Q7 | **oui** | non | non |

- **Conséquence** : la fusion finale est interne et non reconstituable.
  Retrier sur l'un de ces scores dégrade le classement en croyant l'affiner.
  `@scores` est bon pour comprendre, mauvais comme fondation de production —
  d'autant qu'il n'est pas documenté.
- **Pourquoi promu en anti-pattern** : le résultat était enfoui dans une note
  de J2 alors qu'il porte sur un geste que tout consommateur du service est
  tenté de faire.

---

## 5. Règles ajoutées au J5

### r-new-1 — `execution_environment` sur tout outil Analyst d'un agent

- **Statut** : PROUVÉE, vérifiée par mesure au J4.
- **Risque évité** : sans ce bloc, le SQL généré par l'agent s'exécute sur le
  warehouse par défaut de l'appelant — `COMPUTE_WH`, **hors `RM_TRIAL`**. Le
  garde-fou de coût serait contourné sans qu'aucun message ne le signale.
- **Vérification effective** : après les 4 questions de recette,
  `INFORMATION_SCHEMA.QUERY_HISTORY` filtré sur `'%Generated by Cortex%'`
  rend **11 requêtes, toutes sur `WH_AI_DEV`, zéro sur `COMPUTE_WH`**.
- **Test de régression** : rejouer ce filtre après toute modification de
  `sql/50_agent.sql`.

### r-new-3 — console Windows en UTF-8

- **Statut** : PROUVÉE, incident du J4.
- **Échec observé** : `python src/ask.py --trace` a levé
  `UnicodeEncodeError: 'charmap' codec can't encode character '→'` en
  imprimant le bloc `thinking` de l'agent, qui contenait une flèche `→`.
- **Gravité réelle** : le plantage survient **après** l'appel HTTP, donc
  **après facturation**. La réponse était payée et perdue.
- **Fréquence** : 1 occurrence, sur le premier appel réel jamais fait à
  l'agent — c'est-à-dire dès que du texte non-ASCII généré par un modèle a
  traversé la sortie standard.
- **Correction** : `sys.stdout.reconfigure(encoding="utf-8",
  errors="replace")` dans `src/ask.py`. `errors="replace"` délibérément :
  mieux vaut un `?` qu'une pile d'exception sur une réponse déjà payée.
- **Généralisation portée dans CLAUDE.md** : la contrainte vaut pour tout
  script imprimant une sortie Cortex, pas seulement `ask.py`.
- **Test** : `python src/ask.py --trace "<question>"` sur une question dont la
  réflexion contient un caractère non-ASCII.

---

## 6. Retirées de CLAUDE.md

### r20 — bloc « Historique de la correction du quota (21/08/2026) »

- **Nature** : 44 lignes de récit — tableau d'écarts, relevé de consommation
  journalier, mention d'une formulation invalidée dans `docs/02` §9.
- **Motif du retrait** : c'est de l'historique, pas une règle. Le contenu
  actionnable (plafond 50, portée du monitor, latence d'`ACCOUNT_USAGE`,
  méthode de lecture) est promu en règles impératives ; le récit est archivé
  en §2 de ce fichier.
- **Rien n'est perdu** : le tableau et le relevé sont reproduits ci-dessus.

### r18 — « le dénominateur est 50 crédits, pas 100 »

- **Motif** : fusionnée dans la règle `RM_TRIAL`. La forme « pas 100 » ne
  s'adressait qu'à un lecteur ayant vu la version fautive du fichier. Une
  session future n'a pas ce contexte : « le dénominateur est 50 » suffit.

### Reformatage sans perte

- Le bloc « Statut au démarrage de Claude Code » est réduit à une phrase
  rattachée à l'inventaire des objets. La consigne opérante — ne pas rejouer
  le bootstrap — est conservée.
- L'inventaire des objets passe en tableau.
- « Structure attendue » devient « Structure », en bloc de code, et intègre
  `test_ask_parse.py` créé au J4.

---

## 7. ⚠️ En attente de validation humaine

**Aucune suppression n'a été faite sur ces trois points.** Ils restent dans
CLAUDE.md à l'identique. Ils sont listés parce qu'ils portent les marques
d'une hypothèse jamais éprouvée, et que l'arbitrage n'est pas automatisable.

| # | Règle | Ce qui cloche | Décision demandée |
|---|---|---|---|
| **V1** | r15 — corpus plafonné à 300 documents | Corpus réel : 30 chunks / 3 fichiers. Le plafond n'a jamais été approché et **le nombre 300 n'est adossé à aucune mesure** — le motif que r21 proscrit par ailleurs. | Rattacher 300 à un calcul, ou supprimer et laisser r13 (signalement du coût) faire le travail. |
| **V2** | r16 — proposer `DROP CORTEX SEARCH SERVICE` en fin de session | Index de **31 Ko**. Le coût de serving évité n'a jamais été distingué de zéro, alors que la règle impose un rituel de fin de session et un ré-embedding à chaque reprise. | Mesurer 7 jours de serving avant de trancher. |
| **V3** | r9 — « `SNOWFLAKE.CORTEX.COMPLETE` avec modèles Anthropic peut être bloqué ; ne pas en dépendre pour J1 et J2 » | **Retirée du fichier**, mais le statut réel n'est pas vérifié. La moitié « J1 et J2 » est caduque (ces jours sont livrés). L'autre moitié ne l'est pas : le J4 prouve que l'**API Agents** orchestre bien avec `claude-opus-4-8`, ce qui **ne dit rien** de la fonction SQL `CORTEX.COMPLETE()` — surface différente. `docs/02` mentionne un déblocage, mais des fonctions **d'embedding**, pas de complétion. | Trancher par un test : `SELECT SNOWFLAKE.CORTEX.COMPLETE('claude-3-5-sonnet', 'ping');`. Si l'appel passe, le retrait est définitif. S'il échoue, réintroduire la règle sous une forme sans référence à J1/J2. |

V3 est le seul retrait de cet inventaire portant sur une règle dont la
justification n'est **pas** réfutée — seulement devenue partiellement hors
sujet. Il est réversible en une ligne.
