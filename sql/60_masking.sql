/* =============================================================================
   60_masking.sql — MP_DOC_CONTENT, masking policy de demonstration sur LEGACY_DOCS
   -----------------------------------------------------------------------------
   POURQUOI CET OBJET (les 3 lignes de regle)
     1. LEGACY_DOCS.DOC_CONTENT contient de la documentation REELLE d'un projet
        client : noms de classes metier, logique applicative, dette technique.
        C'est la seule colonne du repo dont la fuite aurait un cout.
     2. Une masking policy applique la regle A LA COLONNE, pas a la requete :
        elle suit la donnee dans toute vue, tout JOIN et tout SELECT *, quel que
        soit l'outil client. C'est ce qui la distingue d'un filtrage applicatif.
     3. Elle rend la question "qui voit quoi" verifiable en deux SELECT
        identiques sous deux roles, plutot qu'affirmee dans une note.

   PORTEE : DEMONSTRATION. Le projet n'a qu'un seul utilisateur humain. Cet objet
   existe pour montrer le mecanisme et sa limite, pas pour proteger un secret
   qui, ici, est deja dans la table.

   SYNTAXE VERIFIEE LE 21/08/2026
     https://docs.snowflake.com/en/sql-reference/sql/create-masking-policy
     https://docs.snowflake.com/en/user-guide/security-column-ddm-use

       CREATE [ OR REPLACE ] MASKING POLICY [ IF NOT EXISTS ] <name> AS
         ( <arg> <type> [ , ... ] ) RETURNS <type> -> <expression>

     - Le type de retour doit etre IDENTIQUE au type de l'argument masque.
     - Une policy s'attache par ALTER TABLE ... MODIFY COLUMN ... SET MASKING POLICY.
     - Une colonne ne porte qu'UNE policy a la fois.
     - Edition ENTERPRISE requise. Verifie sur ce compte le 21/08/2026 :
       serviceLevelName = ENTERPRISE (trial, 24 jours restants).

   COUT
     Creation et attachement : operations de catalogue, gratuites, aucun compute.
     A l'usage, la policy est evaluee a chaque lecture de la colonne : le surcout
     est celui d'un CASE par ligne, negligeable devant le reveil du warehouse.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   PREALABLE — ce que AI_ENGINEER_ROLE ne peut PAS faire
   -----------------------------------------------------------------------------
   Constat du 21/08/2026, tentative reelle sous AI_ENGINEER_ROLE :

       003001 (42501): SQL access control error:
       Insufficient privileges to operate on schema 'CORE'. Your primary role
       AI_ENGINEER_ROLE must have CREATE MASKING POLICY granted on SCHEMA
       LEGACY_AI_DB.CORE.

   Et SHOW ROLES ne montre aucun second role utilisable : PUBLIC n'a meme pas
   USAGE sur LEGACY_AI_DB, il echouerait sur l'acces a la table avant d'atteindre
   la policy — ce qui ne demontrerait rien.

   Le bloc ci-dessous releve donc d'ACCOUNTADMIN, comme sql/00_bootstrap.sql, et
   s'execute UNE FOIS manuellement dans Snowsight. Il cree aussi le role lecteur
   qui sert de contre-exemple.

   -- ---- A JOUER DANS SNOWSIGHT, SOUS ACCOUNTADMIN -------------------------
   USE ROLE ACCOUNTADMIN;

   -- 1. Le droit de creer et d'attacher des policies
   GRANT CREATE MASKING POLICY ON SCHEMA LEGACY_AI_DB.CORE TO ROLE AI_ENGINEER_ROLE;
   GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE AI_ENGINEER_ROLE;

   -- 2. Un role lecteur, volontairement depourvu de tout droit de demasquage
   CREATE ROLE IF NOT EXISTS AI_ANALYST_ROLE
     COMMENT = 'Role lecteur de demonstration : voit LEGACY_DOCS, mais DOC_CONTENT masque.';
   GRANT USAGE ON DATABASE  LEGACY_AI_DB      TO ROLE AI_ANALYST_ROLE;
   GRANT USAGE ON SCHEMA    LEGACY_AI_DB.CORE TO ROLE AI_ANALYST_ROLE;
   GRANT USAGE ON WAREHOUSE WH_AI_DEV         TO ROLE AI_ANALYST_ROLE;
   GRANT SELECT ON TABLE    LEGACY_AI_DB.CORE.LEGACY_DOCS TO ROLE AI_ANALYST_ROLE;

   -- 3. Se l'attribuer pour pouvoir basculer dessus depuis le client.
   --    Utilisateur en dur plutot que SET + IDENTIFIER($moi) : le 21/08/2026,
   --    une premiere execution de ce bloc a accorde les deux privileges de
   --    masking mais PAS le role, sans que rien ne le signale cote client. Un
   --    nom litteral supprime ce mode de defaillance.
   GRANT ROLE AI_ANALYST_ROLE TO USER AI8;

   -- 4. Verification — DOIT renvoyer une ligne. Si elle est vide, le role n'a
   --    pas ete cree et la demonstration a deux roles est impossible.
   SHOW ROLES LIKE 'AI_ANALYST_ROLE';
   -- -------------------------------------------------------------------------

   Verification, sous AI_ENGINEER_ROLE :
       SHOW GRANTS TO ROLE AI_ENGINEER_ROLE;   -- CREATE MASKING POLICY doit apparaitre
       SELECT CURRENT_AVAILABLE_ROLES();       -- AI_ANALYST_ROLE doit y figurer
   ----------------------------------------------------------------------------- */


USE ROLE      AI_ENGINEER_ROLE;
USE WAREHOUSE WH_AI_DEV;
USE DATABASE  LEGACY_AI_DB;
USE SCHEMA    CORE;


-- -----------------------------------------------------------------------------
-- ETAT AVANT — la colonne en clair, pour les deux roles
-- -----------------------------------------------------------------------------
-- A executer AVANT l'attachement, sinon il n'y a pas de "avant" a montrer.
SELECT 'AVANT / AI_ENGINEER_ROLE' AS moment,
       DOC_ID, SOURCE_FILE, LENGTH(DOC_CONTENT) AS n_car,
       LEFT(DOC_CONTENT, 90) AS apercu
FROM LEGACY_DOCS
WHERE JAVA_CLASS = 'InvoiceGeneratorBean'
ORDER BY CHUNK_INDEX
LIMIT 3;


-- -----------------------------------------------------------------------------
-- La policy
-- -----------------------------------------------------------------------------
-- CREATE OR REPLACE : objet de configuration, aucune donnee detruite. Mais
-- ATTENTION — un OR REPLACE sur une policy DEJA attachee echoue tant qu'elle
-- l'est. Detacher d'abord (voir bloc de nettoyage en fin de fichier).
--
-- Masquage PARTIEL et non total, deliberement : renvoyer NULL ou '***' rendrait
-- la colonne inutilisable et masquerait aussi le fait qu'il y a de la donnee.
-- Ici le lecteur non habilite garde de quoi comprendre la STRUCTURE du corpus
-- (longueur, premiers mots) sans acceder au contenu metier. C'est le compromis
-- habituel du dynamic data masking : degrader, pas supprimer.
CREATE OR REPLACE MASKING POLICY MP_DOC_CONTENT AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('AI_ENGINEER_ROLE', 'ACCOUNTADMIN') THEN val
    ELSE LEFT(val, 40) || ' [*** ' || (LENGTH(val) - 40)
         || ' caracteres masques par MP_DOC_CONTENT ***]'
  END
  COMMENT = 'Demonstration J5. DOC_CONTENT porte de la documentation client reelle. En clair pour AI_ENGINEER_ROLE et ACCOUNTADMIN, tronque a 40 caracteres pour tout autre role.';


-- -----------------------------------------------------------------------------
-- Attachement
-- -----------------------------------------------------------------------------
ALTER TABLE LEGACY_DOCS
  MODIFY COLUMN DOC_CONTENT SET MASKING POLICY MP_DOC_CONTENT;


-- -----------------------------------------------------------------------------
-- ETAT APRES — la MEME requete, sous les deux roles
-- -----------------------------------------------------------------------------
-- C'est le coeur de la demonstration : le SQL ne change pas d'un caractere.
-- Seul CURRENT_ROLE() change, et la colonne se degrade toute seule.

USE ROLE AI_ENGINEER_ROLE;
SELECT 'APRES / AI_ENGINEER_ROLE' AS moment,
       DOC_ID, SOURCE_FILE, LENGTH(DOC_CONTENT) AS n_car,
       LEFT(DOC_CONTENT, 90) AS apercu
FROM LEGACY_DOCS
WHERE JAVA_CLASS = 'InvoiceGeneratorBean'
ORDER BY CHUNK_INDEX
LIMIT 3;

USE ROLE AI_ANALYST_ROLE;
USE WAREHOUSE WH_AI_DEV;
SELECT 'APRES / AI_ANALYST_ROLE' AS moment,
       DOC_ID, SOURCE_FILE, LENGTH(DOC_CONTENT) AS n_car,
       LEFT(DOC_CONTENT, 90) AS apercu
FROM LEGACY_DOCS
WHERE JAVA_CLASS = 'InvoiceGeneratorBean'
ORDER BY CHUNK_INDEX
LIMIT 3;

USE ROLE AI_ENGINEER_ROLE;


/* -----------------------------------------------------------------------------
   LA LIMITE QUI COMPTE — le masquage ne suit pas la donnee dans l'index
   -----------------------------------------------------------------------------
   Une masking policy s'applique a la LECTURE DE LA TABLE. Le service
   LEGACY_DOCS_SEARCH, lui, sert depuis un index construit AVANT l'attachement,
   et qui contient le texte en clair.

   VERIFIE LE 21/08/2026, ET LE RESULTAT CONFIRME LA CRAINTE.

     Lecture de DOC_CONTENT           AI_ENGINEER_ROLE   AI_ANALYST_ROLE
     --------------------------------------------------------------------
     SELECT, avant la policy               1411 clair        1411 clair
     SELECT, apres la policy               1411 clair       *  93 masque
     SEARCH_PREVIEW, apres la policy       1411 clair       * 1411 CLAIR

   Le meme role qui n'obtient que 93 caracteres tronques par SELECT recupere
   les 1411 caracteres en clair par le service de recherche. La frontiere de
   securite n'est donc PAS la meme des deux cotes : USAGE sur un service de
   recherche vaut acces en clair aux colonnes indexees, quelle que soit la
   policy posee sur la table.

   Deux parades, aucune automatique :
     - poser la masking policy AVANT la creation du service, ou
     - reconstruire l'index apres l'avoir posee.
   A defaut, ne pas accorder USAGE sur le service a un role qui ne doit pas
   voir les colonnes indexees en clair.

   Requete de controle, a rejouer sous les deux roles :

       SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
                'LEGACY_AI_DB.CORE.LEGACY_DOCS_SEARCH',
                '{"query": "generation des factures", "columns": ["DOC_CONTENT"], "limit": 1}'
              ))['results'][0]['DOC_CONTENT']::STRING AS extrait_via_index;

   Le grant qui rend ce test possible (l'owner du service peut l'accorder,
   aucun ACCOUNTADMIN requis) :

       GRANT USAGE ON CORTEX SEARCH SERVICE LEGACY_AI_DB.CORE.LEGACY_DOCS_SEARCH
         TO ROLE AI_ANALYST_ROLE;

   Il est REVOQUE en fin de demonstration : le laisser en place maintiendrait
   un contournement reel de la policy sur ce compte.
   ----------------------------------------------------------------------------- */


-- -----------------------------------------------------------------------------
-- Controles
-- -----------------------------------------------------------------------------
SHOW MASKING POLICIES IN SCHEMA LEGACY_AI_DB.CORE;

-- Ou la policy est-elle reellement attachee ? Source de verite cote catalogue.
SELECT POLICY_NAME, REF_ENTITY_NAME, REF_COLUMN_NAME, POLICY_STATUS
FROM TABLE(LEGACY_AI_DB.INFORMATION_SCHEMA.POLICY_REFERENCES(
       POLICY_NAME => 'LEGACY_AI_DB.CORE.MP_DOC_CONTENT'));


/* -----------------------------------------------------------------------------
   Nettoyage
   -----------------------------------------------------------------------------
   Detacher AVANT de supprimer : un DROP sur une policy attachee echoue.

       USE ROLE AI_ENGINEER_ROLE;
       ALTER TABLE LEGACY_DOCS MODIFY COLUMN DOC_CONTENT UNSET MASKING POLICY;
       DROP MASKING POLICY IF EXISTS MP_DOC_CONTENT;

   Le role de demonstration, lui, releve d'ACCOUNTADMIN :

       USE ROLE ACCOUNTADMIN;
       DROP ROLE IF EXISTS AI_ANALYST_ROLE;
   ----------------------------------------------------------------------------- */
