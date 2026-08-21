/* =============================================================================
   10_tables.sql — tables du corpus documentaire
   -----------------------------------------------------------------------------
   S'execute sous AI_ENGINEER_ROLE. Idempotent (CREATE ... IF NOT EXISTS).

   Deux tables :
     LEGACY_DOCS_RAW  — un fichier source = une ligne, contenu brut non decoupe
     LEGACY_DOCS      — un chunk = une ligne, source du Cortex Search Service

   Pas de file format nomme : les options de parsing sont inlinees dans le
   COPY INTO de sql/20_chunk.sql. Cela evite d'exiger CREATE FILE FORMAT sur le
   schema — un privilege de moins pour AI_ENGINEER_ROLE, un objet de moins a
   maintenir. Le prix : les options de parsing ne sont visibles qu'a l'endroit
   ou elles servent.

   Chaine complete : fichiers -> PUT -> @DOCS_STAGE -> COPY INTO LEGACY_DOCS_RAW
                     -> SPLIT_TEXT_RECURSIVE_CHARACTER -> LEGACY_DOCS
   (voir sql/20_chunk.sql, pilote par src/ingest.py)
   ============================================================================= */

USE ROLE      AI_ENGINEER_ROLE;
USE WAREHOUSE WH_AI_DEV;
USE DATABASE  LEGACY_AI_DB;
USE SCHEMA    CORE;


-- -----------------------------------------------------------------------------
-- LEGACY_DOCS_RAW — zone de staging brute
-- -----------------------------------------------------------------------------
-- Pourquoi : separer "ce que l'agent a produit" de "ce que j'en ai fait".
--   Le chunking est un choix reversible (taille, overlap, format) ; garder le
--   texte integral permet de re-chunker sans re-uploader ni relire le disque.
-- Truncatee a chaque run d'ingestion : elle ne contient que le lot en cours,
--   ce qui rend le DELETE/INSERT cible de LEGACY_DOCS trivial et idempotent.
CREATE TABLE IF NOT EXISTS LEGACY_DOCS_RAW (
    source_file   VARCHAR       NOT NULL COMMENT 'Chemin relatif du fichier sous le dossier d''entree (identifiant stable du document)',
    raw_content   VARCHAR       NOT NULL COMMENT 'Contenu integral du fichier, non modifie',
    file_size     NUMBER(38,0)           COMMENT 'Taille en octets telle que reportee par la directory table',
    loaded_at     TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'Horodatage du COPY INTO'
)
COMMENT = 'Staging brut : un fichier source = une ligne. Videe a chaque ingestion.';


-- -----------------------------------------------------------------------------
-- LEGACY_DOCS — corpus chunke, source du Cortex Search Service
-- -----------------------------------------------------------------------------
-- Pourquoi : Cortex Search indexe une colonne de texte et expose les autres
--   comme attributs filtrables. Les colonnes de metadonnees ci-dessous sont
--   exactement les axes de filtrage prevus pour l'agent : par agent producteur,
--   par type de document, par classe Java documentee.
-- Pas de colonne java_package : verifie sur le corpus reel, les sorties du
--   pipeline ne contiennent aucune declaration de package ni aucun nom qualifie
--   (0 occurrence de 'package' et de 'com.legacy' dans les 3 fichiers). La
--   colonne serait NULL a 100 % — un attribut de filtrage vide induit en erreur
--   plutot qu'il n'aide. Le nom de classe, lui, est systematiquement present en
--   en-tete markdown : c'est le seul axe structurel reellement disponible.
-- doc_id est deterministe (hash source_file + chunk_index) : re-ingerer le meme
--   fichier reproduit les memes identifiants, ce qui evite les doublons et rend
--   les citations de l'agent stables entre deux runs.
CREATE TABLE IF NOT EXISTS LEGACY_DOCS (
    doc_id        VARCHAR(64)   NOT NULL COMMENT 'SHA2-256 de source_file || '':'' || chunk_index — deterministe',
    source_file   VARCHAR       NOT NULL COMMENT 'Chemin relatif du fichier d''origine',
    agent_name    VARCHAR                COMMENT 'Agent du pipeline ayant produit le document (ex. JavaDocumentationAgent)',
    doc_type      VARCHAR                COMMENT 'Nature du document (ex. class-doc, package-summary, migration-note)',
    java_class    VARCHAR                COMMENT 'Classe Java documentee, extraite des en-tetes markdown ### <ClassName> et propagee aux chunks suivants de la meme section',
    chunk_index   NUMBER(38,0)  NOT NULL COMMENT 'Position du chunk dans le fichier source, base 0',
    doc_content   VARCHAR       NOT NULL COMMENT 'Texte du chunk — colonne indexee par LEGACY_DOCS_SEARCH',
    ingested_at   TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'Horodatage du chunking',

    CONSTRAINT PK_LEGACY_DOCS PRIMARY KEY (doc_id)
)
COMMENT = 'Corpus documentaire chunke — table source du Cortex Search Service LEGACY_DOCS_SEARCH';

-- Rappel : dans Snowflake la PRIMARY KEY n'est pas contrainte a l'insertion.
-- L'unicite de doc_id est garantie par la construction (DELETE cible puis
-- INSERT dans sql/20_chunk.sql), pas par le moteur. Requete de controle :
--
--   SELECT doc_id, COUNT(*) FROM LEGACY_DOCS GROUP BY doc_id HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- Controles
-- -----------------------------------------------------------------------------
SHOW TABLES LIKE 'LEGACY_DOCS%' IN SCHEMA LEGACY_AI_DB.CORE;
