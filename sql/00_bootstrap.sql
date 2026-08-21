/* =============================================================================
   00_bootstrap.sql — socle du projet snowflake-legacy-assistant
   -----------------------------------------------------------------------------
   STATUT : DEJA EXECUTE MANUELLEMENT DANS SNOWSIGHT.
            Ce fichier est la trace versionnee du socle, pas un script a relancer
            en aveugle. Il est idempotent (IF NOT EXISTS / OR REPLACE cible) donc
            rejouable, mais rien ici ne doit etre execute par un agent.

   Contenu :
     BLOC A — ACCOUNTADMIN uniquement (parametre de compte, resource monitor,
              role, warehouse, database, schema, stage, grants)
     BLOC B — AI_ENGINEER_ROLE (verification que le socle est utilisable)

   Le reste du projet (sql/10_*.sql et au-dela) s'execute exclusivement sous
   AI_ENGINEER_ROLE.
   ============================================================================= */


/* #############################################################################
   #                                                                           #
   #   BLOC A  —  A EXECUTER SOUS ACCOUNTADMIN                                 #
   #              SEUL ENDROIT DU REPO OU CE ROLE EST AUTORISE                 #
   #                                                                           #
   ############################################################################# */

USE ROLE ACCOUNTADMIN;


-- -----------------------------------------------------------------------------
-- A.1  Cross-region inference
-- -----------------------------------------------------------------------------
-- Pourquoi : le compte est en region AWS EU ; tous les modeles Cortex (LLM,
--   embeddings du Search Service) n'y sont pas deployes. Ce parametre autorise
--   Snowflake a router l'inference vers une autre region AWS de l'UE.
-- Portee volontairement limitee a 'AWS_EU' et non 'ANY_REGION' : les donnees
--   ne sortent pas de l'Union europeenne.
-- Seul ACCOUNTADMIN peut poser ce parametre (ALTER ACCOUNT).
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'AWS_EU';

SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;


-- -----------------------------------------------------------------------------
-- A.2  Resource monitor — garde-fou credits (compte trial)
-- -----------------------------------------------------------------------------
-- Pourquoi : un compte trial a un budget fini et un Cortex Search Service peut
--   consommer en continu. Le monitor coupe le warehouse avant que la facture ne
--   parte, sans dependre de ma vigilance.
-- 100 credits / mois, alerte a 80 %, suspension a 95 %.
-- NOTE : NOTIFY n'envoie un mail que si une adresse de notification est
--   configuree sur le compte (Snowsight > Admin > Notifications). Sinon
--   l'alerte n'est visible que dans l'historique du monitor.
-- NE PAS SUPPRIMER NI DESACTIVER CE MONITOR.
CREATE RESOURCE MONITOR IF NOT EXISTS RM_TRIAL
  WITH CREDIT_QUOTA = 100
       FREQUENCY = MONTHLY
       START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 80 PERCENT DO NOTIFY
           ON 95 PERCENT DO SUSPEND;

-- Si le compte refuse IF NOT EXISTS sur RESOURCE MONITOR (versions anciennes),
-- remplacer par CREATE OR REPLACE — attention : cela remet le compteur a zero.


-- -----------------------------------------------------------------------------
-- A.3  Role de travail
-- -----------------------------------------------------------------------------
-- Pourquoi : tout le projet tourne sous un role dedie, jamais sous ACCOUNTADMIN.
--   C'est ce qui rend le repo defendable : les privileges reellement necessaires
--   sont explicites ci-dessous, et rien de plus.
-- Rattache a SYSADMIN pour rester dans la hierarchie standard.
CREATE ROLE IF NOT EXISTS AI_ENGINEER_ROLE
  COMMENT = 'Role de travail du projet snowflake-legacy-assistant';

GRANT ROLE AI_ENGINEER_ROLE TO ROLE SYSADMIN;
GRANT ROLE AI_ENGINEER_ROLE TO USER IDENTIFIER(CURRENT_USER());


-- -----------------------------------------------------------------------------
-- A.4  Warehouse
-- -----------------------------------------------------------------------------
-- Pourquoi : un seul warehouse XSMALL pour tout le projet. Les charges ici sont
--   des ingestions de quelques centaines de documents et des requetes Cortex ;
--   la taille du warehouse ne les accelere pas, elle ne fait que multiplier le
--   cout par 2 a chaque palier.
-- AUTO_SUSPEND = 60 s et INITIALLY_SUSPENDED : on ne paie pas l'inactivite.
-- Le resource monitor est attache juste apres.
CREATE WAREHOUSE IF NOT EXISTS WH_AI_DEV
  WAREHOUSE_SIZE = 'XSMALL'
  WAREHOUSE_TYPE = 'STANDARD'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Warehouse unique du projet legacy-assistant — ne pas redimensionner';

ALTER WAREHOUSE WH_AI_DEV SET RESOURCE_MONITOR = RM_TRIAL;


-- -----------------------------------------------------------------------------
-- A.5  Database, schema
-- -----------------------------------------------------------------------------
-- Pourquoi : un seul schema CORE. Le projet n'a pas assez d'objets pour
--   justifier une separation raw/staging/mart, et chaque schema en plus est une
--   ligne de grants en plus a maintenir.
CREATE DATABASE IF NOT EXISTS LEGACY_AI_DB
  COMMENT = 'Documentation et metriques du pipeline de modernisation Java legacy';

CREATE SCHEMA IF NOT EXISTS LEGACY_AI_DB.CORE
  COMMENT = 'Docs (Cortex Search) + metriques de benchmark (Cortex Analyst)';

-- Le schema PUBLIC cree par defaut n'est pas utilise.
DROP SCHEMA IF EXISTS LEGACY_AI_DB.PUBLIC;


-- -----------------------------------------------------------------------------
-- A.6  Stage des documents
-- -----------------------------------------------------------------------------
-- Pourquoi : les sorties de JavaDocumentationAgent sont des fichiers ; on les
--   depose tels quels dans un stage interne avant tout traitement. Le fichier
--   source reste la reference, la table n'est qu'une projection.
-- DIRECTORY = (ENABLE = TRUE) : donne une directory table (nom, taille, MD5,
--   date) interrogeable en SQL — utile pour tracer ce qui a ete ingere.
--   Stage interne => pas d'AUTO_REFRESH, il faut ALTER STAGE ... REFRESH apres
--   chaque serie de PUT (src/ingest.py le fait).
-- ENCRYPTION SNOWFLAKE_SSE : chiffrement cote serveur, requis pour les URL
--   pre-signees / la lecture par les services Cortex.
CREATE STAGE IF NOT EXISTS LEGACY_AI_DB.CORE.DOCS_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Sorties brutes de JavaDocumentationAgent (markdown)';


-- -----------------------------------------------------------------------------
-- A.7  Grants minimaux sur AI_ENGINEER_ROLE
-- -----------------------------------------------------------------------------
-- Pourquoi : le role doit pouvoir construire le projet (tables, stage, search
--   service, semantic view, agent) et appeler Cortex — rien d'autre. Aucun
--   privilege au niveau compte, aucune autre database.

-- Compute
GRANT USAGE   ON WAREHOUSE WH_AI_DEV TO ROLE AI_ENGINEER_ROLE;
GRANT OPERATE ON WAREHOUSE WH_AI_DEV TO ROLE AI_ENGINEER_ROLE;  -- resume/suspend manuel
GRANT MONITOR ON WAREHOUSE WH_AI_DEV TO ROLE AI_ENGINEER_ROLE;  -- lire sa propre conso

-- Conteneurs
GRANT USAGE ON DATABASE LEGACY_AI_DB        TO ROLE AI_ENGINEER_ROLE;
GRANT USAGE ON SCHEMA   LEGACY_AI_DB.CORE   TO ROLE AI_ENGINEER_ROLE;

-- Creation d'objets dans CORE
-- Pas de CREATE FILE FORMAT : les options de parsing sont inlinees dans le
-- COPY INTO de sql/20_chunk.sql, ce qui evite ce privilege.
GRANT CREATE TABLE,
      CREATE VIEW,
      CREATE STAGE
  ON SCHEMA LEGACY_AI_DB.CORE TO ROLE AI_ENGINEER_ROLE;

-- Objets Cortex. Ces trois privileges sont plus recents que les precedents :
-- si l'un est refuse ("unknown privilege"), le commenter et verifier la
-- disponibilite de la feature sur le compte avant d'aller plus loin.
GRANT CREATE CORTEX SEARCH SERVICE ON SCHEMA LEGACY_AI_DB.CORE TO ROLE AI_ENGINEER_ROLE;
GRANT CREATE SEMANTIC VIEW         ON SCHEMA LEGACY_AI_DB.CORE TO ROLE AI_ENGINEER_ROLE;
GRANT CREATE AGENT                 ON SCHEMA LEGACY_AI_DB.CORE TO ROLE AI_ENGINEER_ROLE;

-- Stage cree ci-dessus par ACCOUNTADMIN : le role a besoin de READ (COPY INTO,
-- directory table) et WRITE (PUT, ALTER STAGE ... REFRESH).
GRANT READ, WRITE ON STAGE LEGACY_AI_DB.CORE.DOCS_STAGE TO ROLE AI_ENGINEER_ROLE;

-- Acces aux fonctions Cortex (COMPLETE, EMBED_TEXT, SPLIT_TEXT_*, Search, Analyst).
-- Sans ce database role, tout appel SNOWFLAKE.CORTEX.* echoue.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE AI_ENGINEER_ROLE;


/* #############################################################################
   #                                                                           #
   #   FIN DU BLOC ACCOUNTADMIN                                                #
   #   Tout ce qui suit — ici et dans les autres fichiers sql/ — tourne sous   #
   #   AI_ENGINEER_ROLE.                                                       #
   #                                                                           #
   ############################################################################# */


-- -----------------------------------------------------------------------------
-- BLOC B  —  Verification du socle sous le role de travail
-- -----------------------------------------------------------------------------
USE ROLE      AI_ENGINEER_ROLE;
USE WAREHOUSE WH_AI_DEV;
USE DATABASE  LEGACY_AI_DB;
USE SCHEMA    CORE;

SELECT CURRENT_ROLE()      AS role,
       CURRENT_WAREHOUSE() AS warehouse,
       CURRENT_DATABASE()  AS database,
       CURRENT_SCHEMA()    AS schema;

-- Le stage doit etre listable (vide au premier passage).
LIST @DOCS_STAGE;

-- Sanity check Cortex : fonction locale, pas d'appel LLM, cout negligeable.
-- Si cette requete echoue, le grant SNOWFLAKE.CORTEX_USER n'est pas effectif.
SELECT SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
         'bootstrap ok', 'none', 8, 2
       ) AS cortex_smoke_test;
