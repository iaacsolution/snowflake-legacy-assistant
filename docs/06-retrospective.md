# 06 — La limite structurelle : une vue sémantique guide, elle ne contraint pas

Note de J5, mesures du **21/08/2026**. Test conçu au §4 de
`docs/claude-md-maintenance.md`, exécuté sur `LEGACY_ASSISTANT` et
`SV_BENCHMARK`.

C'est la conclusion la plus transposable du projet, et ce n'est pas un bug.
C'est une **caractéristique de la couche Cortex Analyst telle qu'elle est
déployée aujourd'hui**, à connaître avant d'accorder sa confiance à une vue
sémantique en production.

---

## 1. L'énoncé

> Les formules déclarées dans le bloc `METRICS` d'une vue sémantique ne sont
> **pas** appliquées telles quelles par l'agent. Elles sont **re-dérivées** par
> le modèle à chaque question. Ce sont des recommandations fortes, pas des
> contraintes exécutables.

Formulé autrement, pour qui vient du monde du BI : une vue sémantique
Snowflake n'est pas une couche sémantique au sens Looker/dbt Metrics, où la
définition d'une métrique est compilée et donc inviolable. C'est un **corpus
de guidage** consommé par un LLM qui réécrit le SQL de zéro.

---

## 2. Comment on s'en aperçoit

Le J4 a produit un symptôme inattendu : sur une question simple — « Combien de
temps a duré la phase analyze ? » — l'agent a enchaîné **quatre** appels SQL
au lieu d'un, dont trois en erreur, avant de répondre juste. Rien n'en
remontait à l'utilisateur : la réponse finale était correcte et le tâtonnement
invisible sans `--trace`.

L'erreur est toujours la même :

```
SQL compilation error: invalid identifier 'DUREE_TOTALE_MS'
```

`duree_totale_ms` est pourtant bien déclarée dans `sql/41_semantic_view.sql` :

```sql
METRICS (
    metriques.duree_totale_ms AS
        SUM(CASE WHEN metric_name = 'duration_total_ms' THEN metric_value END)
    ...
)
```

### Le mécanisme

L'outil Analyst ne transmet pas la vue sémantique au moteur SQL. Il l'**aplatit
en une CTE** qui ne contient que les `FACTS` et les `DIMENSIONS`, colonnes
renommées en vocabulaire métier :

```sql
WITH __metriques AS (
  SELECT metric_name  AS nom_mesure,
         run_phase    AS phase_pipeline,
         scope        AS portee,
         metric_value AS valeur
  FROM LEGACY_AI_DB.CORE.BENCHMARK_METRICS
)
SELECT duree_totale_ms          -- ❌ n'existe pas dans la CTE
FROM __metriques
WHERE phase_pipeline = 'analyze' AND portee = 'run'
```

**Les `METRICS` ne survivent pas à l'aplatissement.** Le modèle les a lues dans
le contexte sémantique — assez pour connaître leur nom et le tenter comme une
colonne — mais elles n'existent pas dans le SQL qu'il produit. Snowflake
rejette, le modèle voit l'erreur, et **reconstruit lui-même l'expression** :

```sql
SELECT SUM(CASE WHEN nom_mesure = 'duration_total_ms' THEN valeur END)
         AS duree_totale_ms
FROM __metriques
WHERE phase_pipeline = 'analyze'
```

Ce SQL-là est juste. Mais il a été **réécrit de mémoire**, pas appliqué depuis
la définition. C'est toute la question.

---

## 3. Le test

L'enjeu n'est pas le tâtonnement — c'est ce que le modèle écrit **au deuxième
essai**. `SV_BENCHMARK` documente un piège précis (`docs/02`, `41_semantic_view.sql`) :

> Dans la phase `analyze`, quatre étapes tournent **en parallèle**. Sommer
> `step_duration_ms` donne 2 676 441 ms, soit **3,05×** le temps réellement
> écoulé (877 739 ms).

La vue neutralise ce piège par deux métriques aux noms non interchangeables,
dont les descriptions se renvoient l'une à l'autre, plus une directive
`AI_SQL_GENERATION` explicite. **Si la re-dérivation est fiable, le modèle doit
retomber sur `duration_total_ms` à chaque fois.**

**Protocole** — 10 questions de durée totale, formulations variées, dont une
(q7) tendue vers le piège (« en additionnant tout »). Pour chacune : le SQL
finalement exécuté est classé `CORRECT` (filtre `duration_total_ms` seul),
`PIEGE` (somme `step_duration_ms` seul) ou `MIXTE` ; la valeur du texte final
est comparée à l'attendu et au piège. Un seul run, sans reprise.

Attendus : `analyze` = 877 739 ms, `report` = 2 711 957 ms.
Pièges : 2 676 441 ms et 2 711 640 ms.

### Résultats

| | Compte |
|---|---|
| SQL final `CORRECT` | **9 / 10** |
| SQL final `MIXTE` | 1 / 10 (q7) |
| SQL final `PIEGE` | **0 / 10** |
| **Valeur finale juste** | **10 / 10** |
| Valeur = somme des étapes présentée comme durée | **0 / 10** |
| SQL exécutés au total | 22 |
| dont en erreur | **12 (55 %)** |
| Questions ayant nécessité ≥ 1 retry | **10 / 10** |
| Latence médiane | ~18 s |

Les 12 erreurs sont **toutes** `invalid identifier 'DUREE_TOTALE_MS'`. Aucun
autre mode de défaillance. Sur l'historique complet (J4 + cette campagne) :
18 erreurs, un seul type.

### Le cas q7, qui n'est pas un raté

Classé `MIXTE` par le classifieur automatique, mais c'est la meilleure réponse
de la série. Question posée : *« Combien de temps au total pour la phase
analyze, en additionnant tout ? »* — la formulation pousse vers le piège.

SQL produit : les **deux** colonnes, côte à côte. Réponse :

> Attention, additionner les étapes ne donne pas la durée de la phase : dans la
> phase analyze, les étapes tournent en parallèle. Leur somme (l'effort cumulé)
> vaut **2 676 441 ms**, soit environ trois fois […]

Le renvoi croisé entre les descriptions des deux métriques a fonctionné : le
modèle a détecté l'ambiguïté, refusé de trancher silencieusement, et rendu les
deux grandeurs en nommant le piège. **C'est le guidage sémantique à son
meilleur** — et c'est précisément ce qui rend le résultat global honnête plutôt
que chanceux.

---

## 4. Verdict : l'hypothèse est confirmée, la parade tient

Deux conclusions distinctes, à ne pas confondre.

**Le contournement est réel et systématique.** 10 questions sur 10 ont déclenché
au moins un `invalid identifier`. Ce n'est pas un cas limite : c'est le chemin
nominal. Les `METRICS` d'une vue sémantique ne sont jamais exécutées telles que
déclarées.

**Et pourtant le guidage a tenu, 10 fois sur 10.** Aucune réponse n'a présenté
la somme des étapes comme une durée écoulée. Les descriptions croisées, les
synonymes disjoints et `AI_SQL_GENERATION` ont suffi à faire converger la
re-dérivation vers la bonne formule.

La formulation juste est donc :

> Les formules `METRICS` sont **fortement guidées, non garanties**, et doivent
> être **validées par golden dataset en continu**.

Ce n'est pas une nuance de langage. Elle change ce qu'on a le droit d'écrire
dans une revue d'architecture :

| Ce qu'on ne peut pas écrire | Ce qu'on peut écrire |
|---|---|
| « La vue sémantique garantit que la durée totale n'est jamais calculée par somme d'étapes. » | « La vue sémantique oriente le modèle vers la bonne formule ; mesuré à 10/10 sur 10 questions au 21/08/2026, à re-mesurer à chaque évolution. » |

---

## 5. Ce que ça implique en production

1. **Une vue sémantique n'est pas un contrat.** Traiter `METRICS` comme une
   définition compilée est une erreur de modèle mental. C'est de la
   documentation exécutée par un LLM.
2. **Le golden dataset n'est pas un livrable de recette, c'est un organe
   permanent.** Il est le seul mécanisme qui transforme « fortement guidé » en
   « vérifié ». Il doit tourner après chaque changement de la vue, du modèle
   d'orchestration, ou de la version de la plateforme — dont aucun n'est sous
   votre contrôle.
3. **Le tâtonnement est un coût caché.** 22 SQL pour 10 questions, soit
   **2,2× le minimum théorique**. Facturé, invisible sans `--trace`, et il
   n'apparaît dans aucun tableau de bord de qualité puisque la réponse finale
   est juste.
4. **Un taux de succès de 100 % sur 10 questions n'est pas une garantie.**
   C'est un intervalle de confiance étroit sur un corpus de 30 chunks et
   2 exécutions. La borne inférieure honnête à 95 % pour 10/10 est d'environ
   **69 %** — il faudrait des centaines de questions pour affirmer mieux.
5. **La parade structurelle existe, si le risque n'est pas acceptable** :
   déplacer la garde hors des `METRICS`, dans une vue relationnelle
   pré-agrégée (une ligne par phase, une colonne par métrique) sur laquelle la
   vue sémantique se pose. L'aplatissement ne peut plus perdre ce que la table
   contient déjà. Coût : un objet de plus, et la souplesse du langage naturel
   réduite aux agrégats prévus. **Non fait ici** — à 10/10, le rapport
   coût/bénéfice ne le justifiait pas sur ce corpus.

---

## 6. Reproduire

Le script de campagne n'est pas versionné (il vit dans le scratchpad de
session) ; son protocole est intégralement décrit au §3 et se reconstruit à
partir de `src/ask.py`, dont il n'utilise que trois fonctions :

```python
from ask import appeler_agent, depouiller, chemin_agent
```

Classification : `duration_total_ms` présent et `step_duration_ms` absent dans
le dernier SQL exécuté → `CORRECT` ; l'inverse → `PIEGE` ; les deux → `MIXTE`.

Vérification indépendante du tâtonnement, sans rejouer la campagne :

```sql
SELECT ERROR_MESSAGE, COUNT(*)
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(RESULT_LIMIT=>500))
WHERE QUERY_TEXT LIKE '%Generated by Cortex%' AND ERROR_MESSAGE IS NOT NULL
GROUP BY ERROR_MESSAGE;
```

---

## 7. Coût de cette note, et une estimation ratée

Consommation `WH_AI_DEV` au 21/08/2026 : **0,2967 crédit** pour l'ensemble de
la journée — création de l'agent, recette J4 à 4 questions, campagne à
10 questions, requêtes de gouvernance. Soit **~0,6 % du quota de 50**.
67 requêtes générées par Cortex, **toutes sur `WH_AI_DEV`, aucune sur
`COMPUTE_WH`** : le garde-fou `execution_environment` tient toujours.

**L'estimation annoncée avant de lancer la campagne était de 0,04 à 0,06 crédit
— soit environ 5× trop bas.** Elle extrapolait un coût par appel depuis les
30 appels Analyst du 19/08, en oubliant ce que `docs/02` §9 avait déjà établi :
sur ce projet, **le poste dominant n'est pas le token, c'est le réveil du
warehouse**. Une campagne de 10 questions étalée sur plusieurs minutes paie des
réveils que 30 appels groupés ne paient pas.

Consigné ici plutôt que corrigé en silence : une estimation fausse d'un facteur
5 sur un compte à 50 crédits est un incident de méthode, même quand la dépense
absolue reste négligeable. Le relevé du jour est par ailleurs un **plancher** —
`ACCOUNT_USAGE` a de la latence et ne se stabilise que le lendemain.
