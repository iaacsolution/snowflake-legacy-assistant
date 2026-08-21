# 02 — Cortex Search vs. recherche maison

Note de J2. Corpus : `LEGACY_AI_DB.CORE.LEGACY_DOCS`, **30 chunks**, 3 fichiers
sources, 31 634 caractères. Toutes les mesures du **17/08/2026**.

La journée s'est déroulée en deux temps : une première session où les fonctions
d'embedding étaient refusées par le compte, une seconde après déblocage. Les deux
sont documentées ici — la première parce que ses mesures lexicales restent
valides, et parce que ce qu'on découvre en étant privé d'un outil a sa valeur.

---

## 1. Ce qui existe maintenant

| Objet | État |
|---|---|
| `LEGACY_DOCS_SEARCH` | **créé**, `indexing_state = ACTIVE`, 30 lignes indexées, build en 4,7 s |
| `LEGACY_DOCS_VEC` | table pédagogique, 30 vecteurs `VECTOR(FLOAT, 768)` |
| `sql/31_search_tests.sql` | 8 requêtes, **toutes exécutées** |
| `sql/90_comparaison_diy.sql` | partie A vectorielle + partie B lexicale, **exécutées** |

Trois moteurs sont donc comparables sur le même corpus et les mêmes questions :
le service managé, un DIY vectoriel, un DIY lexical.

---

## 2. Le résultat central : la question des factures

Une seule question sépare nettement les trois approches. Le corpus documente
`InvoiceGeneratorBean` dans deux chunks ; la question emploie des formes
fléchies que ces chunks ne contiennent pas.

> « Comment les factures sont-elles générées et notifiées ? »

| Moteur | Rang de `InvoiceGeneratorBean` | Ce qui sort en tête |
|---|---|---|
| **Cortex Search** | **1er et 2e** | `InvoiceGeneratorBean` |
| DIY vectoriel (préfixé) | **10e et 11e** / 30 | `OrderServiceBean` |
| DIY lexical (TF-IDF) | **absent** — 1 seul résultat retourné | un chunk sans rapport |

Le fait décisif : côté Cortex, ces deux chunks arrivent premiers avec
**`text_match = 0.0`**. Zéro appariement lexical. Le classement vient
intégralement du volet sémantique et du reranker.

### Pourquoi le lexical échoue — c'est morphologique, pas linguistique

L'hypothèse de départ (première session) était un écart français/anglais : le
corpus dirait « invoices », la question « factures ». **Vérification faite,
c'est faux** — les chunks `InvoiceGeneratorBean` contiennent « facture » 3 fois
*et* « invoice » 9 fois. Le vrai obstacle est la flexion :

| forme du corpus | df | forme de la question | df |
|---|---|---|---|
| `facture` | **5** | `factures` | **1** |
| `generation` | **11** | `generees` | **1** |
| `notification` / `notifications` | 4 / 8 | `notifiees` | **0** |

Un « s » suffit à manquer la bonne réponse. Corriger cela demanderait une
racinisation française — un projet en soi.

### Pourquoi le vectoriel échoue aussi

Plus intéressant : même correctement configuré, l'embedding seul ne suffit pas.
`InvoiceGeneratorBean` remonte de « absent » à « 10e », ce qui est un progrès
réel mais reste inutilisable. L'écart restant (10e → 1er) est le travail du
volet lexical fusionné et du reranker, que la partie A ne reproduit pas.

---

## 3. Le piège qui coûte la bonne réponse : l'embedding asymétrique

Découverte de la seconde session, et la plus transposable de la journée.

Les modèles `snowflake-arctic-embed` sont **asymétriques** : les documents
s'embeddent tels quels, les requêtes doivent être préfixées par
`Represent this sentence for searching relevant passages: `. Sans ce préfixe, on
compare une question et des documents dans deux espaces qui ne se correspondent
pas.

Même question, mêmes 30 vecteurs, seul le traitement de la requête change :

> « Comment le traitement d'un paiement est-il implémenté ? »

| Sans préfixe | | Avec préfixe | |
|---|---:|---|---:|
| `OrderServiceBean` ck 5 | 0.7044 | `PaymentProcessorBean` ck 9 | 0.3885 |
| `OrderServiceBean` ck 12 | 0.7044 | `PaymentProcessorBean` ck 16 | 0.3885 |
| `PaymentProcessorBean` ck 9 | 0.6952 | *(dependencies.md)* ck 0 | 0.3595 |
| `PaymentProcessorBean` ck 16 | 0.6952 | `PaymentProcessorBean` ck 10 | 0.3533 |

Sans préfixe, une question sur le **paiement** renvoie `OrderServiceBean` en
tête. C'est faux.

**Les scores baissent et le résultat s'améliore — ce n'est pas une contradiction.**
0.7044 et 0.3885 ne vivent pas dans la même géométrie : dans le cas symétrique on
compare deux textes « de même nature », ce qui produit mécaniquement des cosinus
élevés et peu discriminants ; dans le cas asymétrique, question et document sont
projetés dans une relation question→passage, où les valeurs absolues sont plus
basses mais l'écart entre pertinent et non pertinent devient exploitable. Comparer
0.70 à 0.39 n'a aucun sens ; seul l'**ordre** compte, et c'est l'ordre qui se
corrige.

Deux leçons, dans cet ordre d'importance :

1. **Un score élevé ne veut rien dire dans l'absolu.** Une valeur de similarité
   n'est interprétable qu'à l'intérieur d'une série produite de façon homogène.
2. **L'erreur est silencieuse.** Pas d'exception, pas d'avertissement, pas de
   `NULL` — un classement faux avec des scores d'apparence convaincante. C'est la
   catégorie de bug la plus chère à découvrir, et elle tient ici à une ligne.

### Cortex Search applique un traitement asymétrique, mais pas celui-là

Le service classait juste dès sa première interrogation, sans qu'on ait rien à
configurer : il gère l'asymétrie en interne. En revanche, **il ne faut pas en
conclure qu'il applique exactement ce préfixe**. Sur la même question, son
`cosine_similarity` vaut 0.4601 là où le DIY préfixé donne 0.3885. Le mécanisme
est identifié ; la transformation exacte reste non observable depuis l'extérieur,
et ce repo ne prétend pas l'avoir reproduite.

---

## 4. Ce que le service expose, et qui n'est pas documenté

Chaque résultat de `SEARCH_PREVIEW` porte une clé `@scores`, absente de la page
de référence et renvoyée **sans avoir été demandée** dans `columns` :

```json
"@scores": { "text_match": 0.917, "cosine_similarity": 0.440, "reranker_score": -1.401 }
```

C'est la preuve directe du caractère hybride du service : appariement lexical,
similarité vectorielle, et un reranker qui arbitre.

**Aucun des trois ne détermine l'ordre affiché.** Vérifié sur 7 questions, en
testant si chaque score est décroissant le long du classement retourné :

| | reranker | cosinus | lexical |
|---|---|---|---|
| Q1 | non | non | **oui** |
| Q2 | non | **oui** | non |
| Q3 | non | non | non |
| Q4 | **oui** | non | non |
| Q5 | non | non | non |
| Q6 | non | non | non |
| Q7 | **oui** | non | non |

Sur Q3, Q5 et Q6, aucun des trois n'est monotone : la fusion finale est interne
et non reconstituable. **Conséquence pratique : consommer l'ordre du tableau
`results`, ne jamais retrier soi-même sur l'un de ces scores** — on dégraderait
le classement en croyant l'affiner. Et comme `@scores` n'est pas documenté, il
est bon pour comprendre et comparer, mauvais comme fondation d'un code de
production.

---

## 5. Les 8 requêtes du service

Toutes exécutées. Résumé des classements de tête :

| # | Question | Tête de classement | Verdict |
|---|---|---|---|
| 1 | traitement d'un paiement | `PaymentProcessorBean` ck 16 / 9 | juste |
| 2 | quand un utilisateur passe une commande | `OrderServiceBean` ck 5 / 12 | juste — aucun terme de la question n'est dans le corpus |
| 3 | retrouver un client par son code | `ClientServiceBean` ck 0 | juste |
| 4 | factures générées et notifiées | `InvoiceGeneratorBean` ck 10 / 3 | juste, avec `text_match = 0.0` |
| 5 | dette technique JDBC *(filtre `doc_type`)* | « Bilan de la dette technique » ck 3 | juste |
| 6 | premières étapes de la roadmap | « Roadmap — Court terme (1-2 sprints) » ck 5 | juste |
| 7 | solde vérifié avant déduction *(filtre `java_class`)* | `processPayment` ck 17 / 10 | juste |
| 8 | risques et code smells *(filtre `@or`)* | « Risques identifiés » ck 4 / 11 | juste |

Deux observations de fonctionnement :

- **Q7 ne renvoie que 4 résultats** pour un `limit` de 5. C'est correct : seuls
  4 chunks portent `java_class = 'PaymentProcessorBean'`. Le filtre restreint
  réellement, il ne complète pas avec du hors-périmètre.
- Les doublons `specs.md` / `migration_*.md` remontent systématiquement par
  paires, avec des scores identiques. Attendu : le rapport de migration reprend
  littéralement des sections des specs. Ce n'est pas un défaut de déduplication.

Précaution de lecture : 30 chunks. Un écart d'une place n'est pas un signal ;
seuls les écarts francs comptent — et celui de la question 4 en est un.

---

## 6. Le piège arithmétique du DIY lexical

Trouvaille de la première session, conservée parce qu'elle est instructive.

Première version du bloc B2 (recherche filtrée sur `PaymentProcessorBean`), avec
l'IDF classique `ln(N/df)` : **quatre lignes de score exactement 0.0**, dans un
ordre arbitraire. Pas un bug — de l'arithmétique.

Le filtre réduit le corpus à N = 4 chunks. Or les quatre termes utiles de la
question y sont **tous universels** : `solde`, `compte`, `montant`, `verifie`
ont chacun `df = 4`. Donc `ln(4/4) = 0` pour chaque terme, et le score s'annule
partout.

**Plus le filtre est sélectif, plus le classement se dégrade** — l'inverse exact
de ce qu'on attend d'un filtre. Corrigé par le lissage `ln(1 + N/df)`, qui
rétablit un ordre (0.4374 vs 0.3116). C'est typiquement l'arbitrage qu'un service
managé absorbe sans jamais le faire remonter à l'utilisateur.

---

## 7. Lignes de code

Comptage automatique, lignes non vides et non commentaires.

| | Installation | Une requête |
|---|---:|---:|
| **Cortex Search** | **18** | **18** |
| DIY vectoriel | **27** | **15** |
| DIY lexical | — | **56** |

Le rapport 18 / 27 à l'installation est le chiffre le moins intéressant de cette
note, et il est trompeur à deux titres.

**D'abord, il a doublé en une journée.** La première session avait esquissé la
partie A en commentaire : 32 lignes, jamais exécutées. En la rendant réellement
exécutable, elle est passée à **81 lignes** au total — parce qu'il a fallu
ajouter ce qu'on oublie tant qu'on n'exécute pas : le `DELETE` des vecteurs
orphelins, le contrôle de couverture, le préfixe de requête, l'isolation du
vecteur de question dans un CTE pour ne pas le facturer trois fois. Une esquisse
non exécutée sous-estime le coût réel d'un facteur 2,5.

**Ensuite, les colonnes ne font pas la même chose.** Ce que les 27 lignes du DIY
vectoriel ne fournissent pas :

- pas de recherche lexicale ni de fusion des deux classements — c'est
  précisément ce qui manquait sur la question 4 ;
- pas de reranker ;
- pas de rafraîchissement automatique : il faut rejouer `MERGE` **et** `DELETE`
  à la main à chaque changement de `LEGACY_DOCS` ;
- pas de troncature des textes dépassant la fenêtre du modèle ;
- pas de service d'interrogation : chaque question réveille le warehouse et
  ré-embedde la question.

**Le vrai écart n'est donc pas 18 contre 27. Il est entre 18 lignes et une liste
de comportements à spécifier, écrire, tester et maintenir — dont un qu'on ne
découvre qu'en mesurant (le préfixe) et un qu'on ne peut pas reproduire du tout
(le reranker).**

Une seule chose reste plus simple côté DIY : le filtrage par attribut. Un `WHERE`
ordinaire, sur n'importe quelle colonne, sans avoir à la déclarer en `ATTRIBUTES`
au moment du `CREATE` — donc sans `DROP` + `CREATE` pour en ajouter une. Le prix
est le scan complet : indolore sur 30 chunks, rédhibitoire au million.

---

## 8. Décisions prises pour `LEGACY_DOCS_SEARCH`

Consignées parce qu'elles ne se lisent pas dans le DDL :

- **`ATTRIBUTES doc_type, java_class`** — sans parenthèses, contrairement à ce
  qu'on écrit spontanément ; seule `PRIMARY KEY` est parenthésée.
  `agent_name` est écarté : redondant avec `doc_type` sur ce corpus (1 agent =
  1 type de document), il reste lisible via `columns`.
- **`TARGET_LAG = '1 day'`** — plafond, pas fréquence. Corpus quasi statique,
  coût de rafraîchissement réel proche de zéro. Plancher projet, jamais en dessous.
- **`IF NOT EXISTS` plutôt que `OR REPLACE`** — un `OR REPLACE` re-embedde les
  30 chunks à chaque exécution du script.
- **`EMBEDDING_MODEL` par défaut** (`snowflake-arctic-embed-m-v1.5`), **immuable
  après création** : en changer impose `DROP` + `CREATE`.
- **`PRIMARY KEY (doc_id)` non déclarée** — aucun cas d'usage prévu ne filtre par
  identifiant exact.

### Deux écarts entre la documentation et le comportement réel

À retenir pour les prochaines étapes, parce qu'ils coûtent chacun un cycle de
débogage :

1. `SEARCH_PREVIEW` renvoie un **VARCHAR**, pas un `OBJECT` comme annoncé.
   Accéder à `:results` directement échoue sur
   `Invalid argument types for function 'GET'`. Il faut `PARSE_JSON`.
2. La clé `@scores` existe mais n'est pas documentée (section 4).

---

## 9. Coût

Aucun poste n'a été estimé à la place d'une mesure quand la mesure existait :

- création du service : **4,7 s**, 30 lignes indexées, embedding one-shot
  d'environ 10 k tokens ;
- partie A : 30 embeddings de documents (une fois — le `MERGE` est incrémental,
  les exécutions suivantes ont rapporté `0 inserted, 0 updated`), plus un
  embedding par question posée ;
- serving : facturé au Go/mois sur un index de ~31 Ko.

L'ensemble reste nettement sous 1 crédit sur les 100 du `RM_TRIAL`. Le poste
dominant n'est pas les tokens mais le réveil du warehouse.

**Nettoyage de fin de session** — les deux objets sont reconstructibles :

```sql
DROP CORTEX SEARCH SERVICE IF EXISTS LEGACY_DOCS_SEARCH;  -- serving continu
DROP TABLE IF EXISTS LEGACY_DOCS_VEC;                     -- pédagogique, double le stockage
```

---

## 10. Bilan du J2

**Objectif atteint.** Le service managé est créé et interrogé, la comparaison DIY
est faite sur les deux axes — lexical et vectoriel — et l'écart de qualité est
mesuré et expliqué plutôt que supposé.

Ce que la journée a produit de non trivial :

1. **Un écart de qualité chiffré sur une question précise** : `InvoiceGeneratorBean`
   1er/2e chez Cortex, 10e/11e en vectoriel maison, absent en lexical. Avec le
   mécanisme derrière chaque échec : flexion pour le lexical, absence de fusion
   et de reranking pour le vectoriel.
2. **Un piège d'usage transposable à tout projet d'embedding** : l'asymétrie
   requête/document, qui inverse le classement sans rien signaler.
3. **Une lecture correcte des scores de similarité** : ils ne sont comparables
   qu'à l'intérieur d'une série homogène. Baisser de 0.70 à 0.39 pouvait
   ressembler à une régression ; c'était la correction.
4. **Deux écarts documentation / réalité** sur `SEARCH_PREVIEW`, et la
   dégénérescence de l'IDF sur corpus filtré.

Ce qui reste ouvert :

- la transformation exacte appliquée par Cortex Search côté requête n'est pas
  observable — mécanisme identifié, pas reproduit ;
- `@scores` n'est pas documenté, donc instable par nature ;
- la latence d'interrogation n'a pas été mesurée proprement (un seul run par
  question, sans isolation du réveil du warehouse) ; aucun chiffre de latence
  n'est avancé ici.

**Suite — J3** : `BENCHMARK_METRICS` et Cortex Analyst. Les fonctions Cortex
étant maintenant accessibles sur ce compte, l'obstacle de la première session est
levé. L'Analyst repose sur de la génération SQL et non sur de l'embedding : c'est
une autre porte, qu'il faudra ouvrir avant de s'y engager.
