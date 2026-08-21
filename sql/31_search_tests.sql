/* =============================================================================
   31_search_tests.sql — 8 interrogations de LEGACY_DOCS_SEARCH
   -----------------------------------------------------------------------------
   S'execute sous AI_ENGINEER_ROLE, apres sql/30_search_service.sql.
   EXECUTE LE 17/08/2026 (2e session, apres deblocage Cortex) — resultats reportes dans docs/02-search-vs-diy.md.

   SYNTAXE — verifiee sur la doc Snowflake, puis corrigee sur le comportement reel
   https://docs.snowflake.com/en/sql-reference/functions/search_preview-snowflake-cortex

       SNOWFLAKE.CORTEX.SEARCH_PREVIEW('<service_name>', '<query_parameters_object>')

   Le second argument est une CHAINE contenant du JSON, pas un OBJECT SQL. Cles :
       query    (string, requis)  texte de la recherche
       columns  (array)           colonnes a retourner
       filter   (object)          filtre sur les colonnes ATTRIBUTES uniquement
       limit    (int, defaut 10)  nombre de resultats

   Operateurs de filtre : @eq @contains @gte @lte @primarykey, et @and @or @not.
   Un filtre ne peut porter QUE sur doc_type et java_class : ce sont les seules
   colonnes declarees en ATTRIBUTES. Filtrer sur source_file ou agent_name
   echouerait, meme si ces colonnes sont retournables via "columns".

   -----------------------------------------------------------------------------
   DEUX ECARTS ENTRE LA DOC ET LE COMPORTEMENT OBSERVE (17/08/2026, AWS_EU_WEST_3)
   -----------------------------------------------------------------------------
   1. TYPE DE RETOUR. La doc annonce un OBJECT ; la fonction renvoie un VARCHAR
      contenant du JSON serialise. Acceder directement a ':results' echoue :

          Invalid argument types for function 'GET': (VARCHAR(134217728), VARCHAR(7))

      Il faut interposer PARSE_JSON. D'ou la forme utilisee partout ci-dessous :

          FLATTEN(input => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(...)):results)

   2. SCORES NON DOCUMENTES. Chaque resultat porte une cle '@scores', absente de
      la page de reference et renvoyee SANS avoir ete demandee dans "columns" :

          "@scores": { "text_match":        0.91731656,
                       "cosine_similarity": 0.4398877,
                       "reranker_score":   -1.4010834 }

      C'est la preuve directe que le service est hybride : un appariement lexical,
      une similarite vectorielle, et un reranker qui arbitre entre les deux. Ces
      trois colonnes sont ce qui rend la comparaison avec le DIY de
      sql/90_comparaison_diy.sql possible terme a terme.

      L'ORDRE DES RESULTATS NE SUIT AUCUN DES TROIS. Verifie sur les 7 premieres
      questions, en testant si chaque score est decroissant le long du classement
      retourne :

          Q1  reranker non   cosinus non   lexical OUI
          Q2  reranker non   cosinus OUI   lexical non
          Q3  reranker non   cosinus non   lexical non
          Q4  reranker OUI   cosinus non   lexical non
          Q5  reranker non   cosinus non   lexical non
          Q6  reranker non   cosinus non   lexical non
          Q7  reranker OUI   cosinus non   lexical non

      Sur Q3, Q5 et Q6, aucun des trois n'est monotone. La fusion finale est donc
      interne et NON reconstituable a partir des scores exposes. Consequence
      pratique : consommer l'ordre du tableau ':results', jamais retrier soi-meme
      sur l'un de ces scores — on degraderait le classement en croyant l'affiner.

      A traiter comme un detail d'implementation : non documente aujourd'hui,
      donc susceptible de changer sans preavis. Bon pour comprendre et comparer,
      mauvais comme fondation d'un code de production.

   r.index donne le rang, l'ordre du tableau ':results' etant le classement.
   ============================================================================= */

USE ROLE      AI_ENGINEER_ROLE;
USE WAREHOUSE WH_AI_DEV;
USE DATABASE  LEGACY_AI_DB;
USE SCHEMA    CORE;


-- -----------------------------------------------------------------------------
-- 1. Traitement d'un paiement — question centrale, sans filtre
-- -----------------------------------------------------------------------------
-- Attendu : les chunks de PaymentProcessorBean. Test du rappel de base.
SELECT
    r.index + 1                                      AS rang,
    ROUND(r.value:"@scores":reranker_score::FLOAT, 4)    AS reranker,
    ROUND(r.value:"@scores":cosine_similarity::FLOAT, 4) AS cosinus,
    ROUND(r.value:"@scores":text_match::FLOAT, 4)        AS lexical,
    r.value:doc_type::VARCHAR                        AS doc_type,
    r.value:java_class::VARCHAR                      AS java_class,
    r.value:source_file::VARCHAR                     AS source_file,
    r.value:chunk_index::NUMBER                      AS chunk_index,
    LEFT(r.value:doc_content::VARCHAR, 160)          AS extrait
FROM TABLE(FLATTEN(input => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'LEGACY_AI_DB.CORE.LEGACY_DOCS_SEARCH',
    '{
        "query": "Comment le traitement d''un paiement est-il implemente ?",
        "columns": ["doc_id", "source_file", "doc_type", "java_class", "chunk_index", "doc_content"],
        "limit": 5
     }'
)):results)) r;


-- -----------------------------------------------------------------------------
-- 2. Creation d'une commande — vocabulaire metier, pas de nom de classe
-- -----------------------------------------------------------------------------
-- Interet : la question ne contient AUCUN terme present tel quel dans le corpus
-- ("passe une commande" vs "Creation et consultation des commandes"). C'est le
-- test qui separe la recherche semantique d'un LIKE.
SELECT
    r.index + 1                                      AS rang,
    ROUND(r.value:"@scores":reranker_score::FLOAT, 4)    AS reranker,
    ROUND(r.value:"@scores":cosine_similarity::FLOAT, 4) AS cosinus,
    ROUND(r.value:"@scores":text_match::FLOAT, 4)        AS lexical,
    r.value:doc_type::VARCHAR                        AS doc_type,
    r.value:java_class::VARCHAR                      AS java_class,
    r.value:chunk_index::NUMBER                      AS chunk_index,
    LEFT(r.value:doc_content::VARCHAR, 160)          AS extrait
FROM TABLE(FLATTEN(input => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'LEGACY_AI_DB.CORE.LEGACY_DOCS_SEARCH',
    '{
        "query": "Que se passe-t-il quand un utilisateur passe une commande ?",
        "columns": ["source_file", "doc_type", "java_class", "chunk_index", "doc_content"],
        "limit": 5
     }'
)):results)) r;


-- -----------------------------------------------------------------------------
-- 3. Recherche d'un client par son code
-- -----------------------------------------------------------------------------
-- Attendu : ClientServiceBean, et sa signature findClientByCode(String).
SELECT
    r.index + 1                                      AS rang,
    ROUND(r.value:"@scores":reranker_score::FLOAT, 4)    AS reranker,
    ROUND(r.value:"@scores":cosine_similarity::FLOAT, 4) AS cosinus,
    ROUND(r.value:"@scores":text_match::FLOAT, 4)        AS lexical,
    r.value:java_class::VARCHAR                      AS java_class,
    r.value:source_file::VARCHAR                     AS source_file,
    r.value:chunk_index::NUMBER                      AS chunk_index,
    LEFT(r.value:doc_content::VARCHAR, 160)          AS extrait
FROM TABLE(FLATTEN(input => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'LEGACY_AI_DB.CORE.LEGACY_DOCS_SEARCH',
    '{
        "query": "Comment retrouve-t-on un client a partir de son code ?",
        "columns": ["source_file", "doc_type", "java_class", "chunk_index", "doc_content"],
        "limit": 5
     }'
)):results)) r;


-- -----------------------------------------------------------------------------
-- 4. Generation des factures — LE test morphologique
-- -----------------------------------------------------------------------------
-- Piege MORPHOLOGIQUE, verifie sur le corpus reel : les deux chunks qui
-- documentent InvoiceGeneratorBean ecrivent "facture" (singulier) et "invoice",
-- jamais "factures" ni "notifiees". Sur les 30 chunks : df(facture) = 5 mais
-- df(factures) = 1 ; df(generation) = 11 mais df(generees) = 1 ; df(notifiees) = 0.
-- La baseline lexicale de sql/90_comparaison_diy.sql (bloc B3) rate donc la
-- bonne reponse a cause d'un "s". Attendu ici : les chunks InvoiceGeneratorBean
-- remontent quand meme, l'embedding etant insensible a la flexion.
SELECT
    r.index + 1                                      AS rang,
    ROUND(r.value:"@scores":reranker_score::FLOAT, 4)    AS reranker,
    ROUND(r.value:"@scores":cosine_similarity::FLOAT, 4) AS cosinus,
    ROUND(r.value:"@scores":text_match::FLOAT, 4)        AS lexical,
    r.value:java_class::VARCHAR                      AS java_class,
    r.value:doc_type::VARCHAR                        AS doc_type,
    r.value:chunk_index::NUMBER                      AS chunk_index,
    LEFT(r.value:doc_content::VARCHAR, 160)          AS extrait
FROM TABLE(FLATTEN(input => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'LEGACY_AI_DB.CORE.LEGACY_DOCS_SEARCH',
    '{
        "query": "Comment les factures sont-elles generees et notifiees ?",
        "columns": ["source_file", "doc_type", "java_class", "chunk_index", "doc_content"],
        "limit": 5
     }'
)):results)) r;


-- -----------------------------------------------------------------------------
-- 5. Dette technique JDBC — filtre sur doc_type
-- -----------------------------------------------------------------------------
-- Le rapport de migration et les specs se recouvrent largement (le rapport
-- reprend les specs par classe). Sans filtre, les deux remontent en doublon.
-- @eq sur doc_type restreint aux chunks du rapport de migration.
SELECT
    r.index + 1                                      AS rang,
    ROUND(r.value:"@scores":reranker_score::FLOAT, 4)    AS reranker,
    ROUND(r.value:"@scores":cosine_similarity::FLOAT, 4) AS cosinus,
    ROUND(r.value:"@scores":text_match::FLOAT, 4)        AS lexical,
    r.value:doc_type::VARCHAR                        AS doc_type,
    r.value:java_class::VARCHAR                      AS java_class,
    r.value:chunk_index::NUMBER                      AS chunk_index,
    LEFT(r.value:doc_content::VARCHAR, 160)          AS extrait
FROM TABLE(FLATTEN(input => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'LEGACY_AI_DB.CORE.LEGACY_DOCS_SEARCH',
    '{
        "query": "Quelle est la dette technique liee a la gestion manuelle des ressources JDBC ?",
        "columns": ["source_file", "doc_type", "java_class", "chunk_index", "doc_content"],
        "filter": { "@eq": { "doc_type": "migration" } },
        "limit": 5
     }'
)):results)) r;


-- -----------------------------------------------------------------------------
-- 6. Roadmap de migration a court terme
-- -----------------------------------------------------------------------------
-- Attendu : le chunk "Court terme (1-2 sprints)". Test sur une section dont le
-- java_class est NULL — elle doit rester atteignable sans filtre.
SELECT
    r.index + 1                                      AS rang,
    ROUND(r.value:"@scores":reranker_score::FLOAT, 4)    AS reranker,
    ROUND(r.value:"@scores":cosine_similarity::FLOAT, 4) AS cosinus,
    ROUND(r.value:"@scores":text_match::FLOAT, 4)        AS lexical,
    r.value:doc_type::VARCHAR                        AS doc_type,
    r.value:java_class::VARCHAR                      AS java_class,
    r.value:chunk_index::NUMBER                      AS chunk_index,
    LEFT(r.value:doc_content::VARCHAR, 160)          AS extrait
FROM TABLE(FLATTEN(input => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'LEGACY_AI_DB.CORE.LEGACY_DOCS_SEARCH',
    '{
        "query": "Quelles sont les premieres etapes de la roadmap de migration ?",
        "columns": ["source_file", "doc_type", "java_class", "chunk_index", "doc_content"],
        "limit": 5
     }'
)):results)) r;


-- -----------------------------------------------------------------------------
-- 7. FILTRE java_class — verification du solde avant paiement
-- -----------------------------------------------------------------------------
-- Premiere des deux requetes filtrees sur l'attribut java_class.
-- Le corpus decrit la verification d'un montant/solde a plusieurs endroits
-- (OrderServiceBean valide aussi des donnees avant enregistrement). Le filtre
-- @eq garantit que la reponse vient de la classe qui detient reellement la
-- logique de paiement, et non d'un appelant.
--
-- RAPPEL DE LIMITE (cf. sql/20_chunk.sql) : java_class est propage depuis les
-- en-tetes ###, il vaut NULL sur 7 des 30 chunks. Un filtre @eq exclut donc
-- mecaniquement ces 7 chunks. C'est un axe de restriction, pas une partition.
SELECT
    r.index + 1                                      AS rang,
    ROUND(r.value:"@scores":reranker_score::FLOAT, 4)    AS reranker,
    ROUND(r.value:"@scores":cosine_similarity::FLOAT, 4) AS cosinus,
    ROUND(r.value:"@scores":text_match::FLOAT, 4)        AS lexical,
    r.value:java_class::VARCHAR                      AS java_class,
    r.value:source_file::VARCHAR                     AS source_file,
    r.value:chunk_index::NUMBER                      AS chunk_index,
    LEFT(r.value:doc_content::VARCHAR, 200)          AS extrait
FROM TABLE(FLATTEN(input => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'LEGACY_AI_DB.CORE.LEGACY_DOCS_SEARCH',
    '{
        "query": "Comment le solde du compte est-il verifie avant de deduire un montant ?",
        "columns": ["source_file", "doc_type", "java_class", "chunk_index", "doc_content"],
        "filter": { "@eq": { "java_class": "PaymentProcessorBean" } },
        "limit": 5
     }'
)):results)) r;


-- -----------------------------------------------------------------------------
-- 8. FILTRE java_class compose — risques sur les deux services principaux
-- -----------------------------------------------------------------------------
-- Seconde requete filtree. @or combine deux @eq : on interroge le perimetre
-- {OrderServiceBean, ClientServiceBean} en une passe, la ou un moteur sans
-- attributs imposerait deux requetes puis une fusion des scores cote client.
SELECT
    r.index + 1                                      AS rang,
    ROUND(r.value:"@scores":reranker_score::FLOAT, 4)    AS reranker,
    ROUND(r.value:"@scores":cosine_similarity::FLOAT, 4) AS cosinus,
    ROUND(r.value:"@scores":text_match::FLOAT, 4)        AS lexical,
    r.value:java_class::VARCHAR                      AS java_class,
    r.value:doc_type::VARCHAR                        AS doc_type,
    r.value:chunk_index::NUMBER                      AS chunk_index,
    LEFT(r.value:doc_content::VARCHAR, 200)          AS extrait
FROM TABLE(FLATTEN(input => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'LEGACY_AI_DB.CORE.LEGACY_DOCS_SEARCH',
    '{
        "query": "Quels risques et quels code smells ont ete identifies dans ce service ?",
        "columns": ["source_file", "doc_type", "java_class", "chunk_index", "doc_content"],
        "filter": { "@or": [
            { "@eq": { "java_class": "OrderServiceBean"  } },
            { "@eq": { "java_class": "ClientServiceBean" } }
        ] },
        "limit": 6
     }'
)):results)) r;


/* -----------------------------------------------------------------------------
   Note de lecture
   -----------------------------------------------------------------------------
   Ce que ces 8 requetes cherchent a etablir, dans l'ordre :
     1-3  rappel de base et robustesse au vocabulaire metier
     4    flexion des mots (factures / facture) — le vrai test semantique
     5    desambiguisation par doc_type sur un corpus qui se recouvre
     6    atteignabilite des chunks sans java_class
     7-8  filtrage par attribut, simple puis compose

   Deux precautions avant d'en tirer une conclusion :
     - le corpus fait 30 chunks. Un ecart d'une place dans un classement n'est
       pas un signal ; ne comparer que des ecarts francs.
     - specs.md et migration_*.md contiennent des passages quasi identiques.
       Voir remonter les deux versions d'un meme contenu est le comportement
       correct, pas un defaut de deduplication.
   ----------------------------------------------------------------------------- */
