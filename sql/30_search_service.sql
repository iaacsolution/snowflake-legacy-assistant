/* =============================================================================
   30_search_service.sql — Cortex Search Service sur LEGACY_DOCS
   -----------------------------------------------------------------------------
   S'execute sous AI_ENGINEER_ROLE, apres sql/20_chunk.sql (LEGACY_DOCS peuplee).

   POURQUOI CET OBJET (les 3 lignes reglementaires)
     1. Un index de recherche hybride (vectoriel + lexical + reranking) construit
        et maintenu par Snowflake sur la colonne doc_content. Il remplace le
        triptyque colonne VECTOR / EMBED_TEXT / VECTOR_COSINE_SIMILARITY qu'il
        faudrait sinon ecrire et maintenir a la main (cf. sql/90_comparaison_diy.sql).
     2. Il se rafraichit tout seul quand LEGACY_DOCS change, dans la limite du
        TARGET_LAG — pas de pipeline de re-embedding a orchestrer.
     3. C'est l'outil de recherche que l'agent LEGACY_ASSISTANT appellera en J4 ;
        les colonnes ATTRIBUTES deviennent ses filtres.

   SYNTAXE — verifiee sur la doc Snowflake le 17/08/2026
   https://docs.snowflake.com/en/sql-reference/sql/create-cortex-search

       CREATE [ OR REPLACE ] CORTEX SEARCH SERVICE [ IF NOT EXISTS ] <name>
         ON <search_column>
         [ PRIMARY KEY ( <col_name> [, ... ] ) ]
         ATTRIBUTES <col_name> [ , ... ]
         WAREHOUSE = <warehouse_name>
         TARGET_LAG = '<num> { seconds | minutes | hours | days }'
         [ EMBEDDING_MODEL = <embedding_model_name> ]
         [ REFRESH_MODE = { FULL | INCREMENTAL } ]
         [ INITIALIZE = { ON_CREATE | ON_SCHEDULE } ]
         [ FULL_INDEX_BUILD_INTERVAL_DAYS = <num> ]
         [ REQUEST_LOGGING = { TRUE | FALSE } ]
         [ AUTO_SUSPEND = <num_seconds> ]
         [ COMMENT = '<comment>' ]
       AS <query>;

   Trois points ou l'ecriture spontanee se trompe :
     - ATTRIBUTES ne prend PAS de parentheses. `ATTRIBUTES (doc_type, java_class)`
       est une erreur de syntaxe ; c'est `ATTRIBUTES doc_type, java_class`. Seule
       la clause PRIMARY KEY, elle, est parenthesee.
     - Les colonnes citees dans ON et dans ATTRIBUTES doivent etre presentes dans
       la requete AS (explicitement ou via *). D'ou le SELECT nomme ci-dessous.
     - La clause AS est obligatoire : le service n'indexe pas "une table", il
       indexe le resultat d'une requete.
   ============================================================================= */

USE ROLE      AI_ENGINEER_ROLE;
USE WAREHOUSE WH_AI_DEV;
USE DATABASE  LEGACY_AI_DB;
USE SCHEMA    CORE;


-- -----------------------------------------------------------------------------
-- Garde-fou : ne pas indexer une table vide
-- -----------------------------------------------------------------------------
-- Creer le service sur 0 ligne coute le meme prix fixe de serving et ne rend
-- aucun service. On verifie avant de payer.
SELECT
    COUNT(*)                                    AS chunks,
    COUNT(DISTINCT source_file)                 AS fichiers,
    SUM(LENGTH(doc_content))                    AS caracteres_indexes,
    COUNT(java_class)                           AS chunks_avec_classe
FROM LEGACY_DOCS;


-- -----------------------------------------------------------------------------
-- LEGACY_DOCS_SEARCH
-- -----------------------------------------------------------------------------
-- IF NOT EXISTS plutot que OR REPLACE : un CREATE OR REPLACE detruit l'index et
--   re-embedde l'integralite du corpus a chaque execution du script. Sur un
--   compte trial, l'idempotence doit etre gratuite. Pour forcer une
--   reconstruction (changement de chunking, d'attributs, de modele), passer
--   explicitement par le DROP de la derniere section.
--
-- ON doc_content : la seule colonne de texte libre. C'est elle qui est embeddee
--   et sur laquelle porte la recherche semantique.
--
-- ATTRIBUTES doc_type, java_class : les deux axes de filtrage exposes a l'agent.
--   Ils ne sont pas cherches, ils restreignent le perimetre de recherche
--   (filter @eq / @contains cote requete). Choisis parce que ce sont les seules
--   metadonnees fiables du corpus — cf. sql/10_tables.sql sur l'absence de
--   java_package et sur le taux de remplissage de java_class (23/30 chunks).
--   agent_name est volontairement HORS attributs : il est fonctionnellement
--   redondant avec doc_type (1 agent = 1 type de document dans ce corpus), et
--   chaque attribut supplementaire alourdit l'index sans ouvrir de vrai axe.
--   Il reste selectionnable dans "columns" a la requete.
--
-- TARGET_LAG = '1 day' : plafond de fraicheur, pas une frequence. Le warehouse
--   ne se reveille que si LEGACY_DOCS a change. Sur ce projet le corpus est
--   quasi statique (reingestion manuelle), donc le cout de refresh reel est
--   proche de zero. REGLE PROJET : ne jamais descendre sous '1 day'.
--
-- EMBEDDING_MODEL non specifie -> defaut snowflake-arctic-embed-m-v1.5.
--   ATTENTION : ce parametre est IMMUABLE apres creation. En changer impose un
--   DROP + CREATE, donc un re-embedding complet.
--
-- PRIMARY KEY (doc_id) non declaree : elle sert au filtre @primarykey et a la
--   deduplication cote service. Notre doc_id est deja deterministe et unique par
--   construction, et aucun cas d'usage prevu ne filtre par identifiant exact.
--   Ajoutable plus tard, mais au prix d'un DROP + CREATE.
--
-- La requete AS filtre les chunks vides par securite : 20_chunk.sql les exclut
--   deja, mais le service se reconstruit tout seul a chaque changement de la
--   table et ce garde-fou survivra a une modification du chunking.
CREATE CORTEX SEARCH SERVICE IF NOT EXISTS LEGACY_DOCS_SEARCH
    ON doc_content
    ATTRIBUTES doc_type, java_class
    WAREHOUSE  = WH_AI_DEV
    TARGET_LAG = '1 day'
    COMMENT    = 'Recherche semantique sur la documentation produite par le pipeline java-legacy-agent. Source : LEGACY_AI_DB.CORE.LEGACY_DOCS.'
AS
    SELECT
        doc_id,
        source_file,
        agent_name,
        doc_type,
        java_class,
        chunk_index,
        doc_content
    FROM LEGACY_DOCS
    WHERE doc_content IS NOT NULL
      AND TRIM(doc_content) <> '';


-- -----------------------------------------------------------------------------
-- Controles post-creation
-- -----------------------------------------------------------------------------
-- L'indexation est asynchrone. Juste apres le CREATE, le service existe mais
-- peut n'etre pas encore interrogeable : SEARCH_PREVIEW renverra alors une
-- erreur ou zero resultat. Attendre que indexing_state passe a ACTIVE.
SHOW CORTEX SEARCH SERVICES LIKE 'LEGACY_DOCS_SEARCH' IN SCHEMA LEGACY_AI_DB.CORE;

DESCRIBE CORTEX SEARCH SERVICE LEGACY_DOCS_SEARCH;

-- Etat d'indexation et volumetrie reellement indexee.
SELECT
    "name",
    "target_lag",
    "warehouse",
    "indexing_state",
    "indexing_error",
    "source_data_num_rows",
    "data_timestamp"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-2)));


-- -----------------------------------------------------------------------------
-- Fin de session de travail : liberer le serving
-- -----------------------------------------------------------------------------
-- Le cout de serving court tant que le service existe, meme sans aucune requete
-- (facture au GB/mois de donnees indexees, decompte a la seconde). Sur 31 Ko
-- d'index c'est marginal, mais l'habitude est bonne et le geste est celui d'un
-- compte trial bien tenu. Recreer coute un re-embedding du corpus (~10 k tokens).
--
--   DROP CORTEX SEARCH SERVICE IF EXISTS LEGACY_DOCS_SEARCH;
