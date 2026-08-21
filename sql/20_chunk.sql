/* =============================================================================
   20_chunk.sql — stage -> LEGACY_DOCS_RAW -> chunking -> LEGACY_DOCS
   -----------------------------------------------------------------------------
   S'execute sous AI_ENGINEER_ROLE, apres que les fichiers ont ete deposes dans
   @DOCS_STAGE/legacy_docs/ (src/ingest.py fait les PUT puis lance ce script).

   Tout le traitement de texte est fait ici, cote Snowflake — aucun decoupage ni
   aucune extraction de metadonnees cote Python.

   Corpus reel (pipeline java-legacy-agent) : 3 fichiers markdown AGREGES, pas
   une arborescence d'un fichier par classe.

       handoff/<projet>/specs.md          sortie agregee de JavaDocumentationAgent
       handoff/<projet>/dependencies.md   rapport DependencyMapperAgent
       migration-output/migration_*.md    rapport final (LegacyMigrationOrchestrator)

   manifest.txt et metrics_<projet>.json ne sont pas ingeres ici : le premier est
   de la metadonnee pure, le second alimentera BENCHMARK_METRICS (structure
   differente, Cortex Analyst, J3).

   Prerequis : trois variables de session. src/ingest.py les pose depuis ses
   arguments CLI ; pour un run manuel dans Snowsight, executer d'abord :

       SET CHUNK_SIZE         = 1500;
       SET CHUNK_OVERLAP      = 250;
       SET DEFAULT_AGENT_NAME = 'JavaDocumentationAgent';

   Idempotent : la table brute est videe, et seules les lignes de LEGACY_DOCS
   correspondant aux fichiers du lot en cours sont supprimees avant reinsertion.
   ============================================================================= */

USE ROLE      AI_ENGINEER_ROLE;
USE WAREHOUSE WH_AI_DEV;
USE DATABASE  LEGACY_AI_DB;
USE SCHEMA    CORE;


-- -----------------------------------------------------------------------------
-- 1. Vider le staging brut : il ne represente que le lot en cours
-- -----------------------------------------------------------------------------
TRUNCATE TABLE LEGACY_DOCS_RAW;


-- -----------------------------------------------------------------------------
-- 2. Charger les fichiers du stage, un fichier = une ligne
-- -----------------------------------------------------------------------------
-- FORCE = TRUE : sans ca, COPY ignorerait les fichiers deja charges (metadonnees
--   de chargement conservees 64 jours) et une reingestion apres modification du
--   chunking ne ramenerait rien. Comme la table vient d'etre videe, recharger
--   l'integralite du lot est le comportement voulu.
-- source_file : chemin relatif a l'ancetre commun des dossiers d'entree, prefixe
--   de stage retire. Identifiant stable du document dans tout le projet.
-- ON_ERROR = ABORT_STATEMENT : un fichier illisible doit faire echouer le lot,
--   pas passer inapercu.
--
-- File format inline plutot qu'objet nomme : evite d'exiger CREATE FILE FORMAT
--   sur le schema pour AI_ENGINEER_ROLE.
-- Les sorties de l'agent sont du markdown, pas du CSV. On detourne le parser CSV
--   pour qu'il ne parse rien : aucun separateur de champ, aucun separateur
--   d'enregistrement -> le fichier entier arrive dans $1.
-- ESCAPE_UNENCLOSED_FIELD = NONE est indispensable : sans ca, les backslashes
--   presents dans le code Java cite (regex, chaines) seraient interpretes comme
--   des echappements et le contenu serait corrompu silencieusement.
-- ENCODING = 'UTF8' : les fichiers sont valides en UTF-8 cote client avant PUT.
-- Limite : une valeur VARCHAR plafonne a 16 MB. Un fichier au-dela fera echouer
--   le COPY (comportement voulu : echec bruyant, pas troncature silencieuse).
-- file_size n'est pas calcule ici : COPY n'accepte qu'un sous-ensemble de
-- fonctions dans sa clause de transformation, et OCTET_LENGTH n'en fait pas
-- partie ("Function 'OCTET_LENGTH' not supported within a COPY"). Il est
-- renseigne par l'UPDATE de l'etape 2bis.
COPY INTO LEGACY_DOCS_RAW (source_file, raw_content)
FROM (
    SELECT
        REGEXP_REPLACE(METADATA$FILENAME, '^(docs_stage/)?legacy_docs/', '', 1, 1, 'i'),
        $1
    FROM @DOCS_STAGE/legacy_docs/
)
FILE_FORMAT = (
    TYPE = CSV
    FIELD_DELIMITER = NONE
    RECORD_DELIMITER = NONE
    FIELD_OPTIONALLY_ENCLOSED_BY = NONE
    ESCAPE_UNENCLOSED_FIELD = NONE
    SKIP_HEADER = 0
    TRIM_SPACE = FALSE
    EMPTY_FIELD_AS_NULL = FALSE
    ENCODING = 'UTF8'
    COMPRESSION = NONE
)
PATTERN     = '.*[.](md|markdown)'
ON_ERROR    = ABORT_STATEMENT
FORCE       = TRUE;


-- -----------------------------------------------------------------------------
-- 2bis. Taille des fichiers, hors COPY
-- -----------------------------------------------------------------------------
-- OCTET_LENGTH donne des octets et non des caracteres : c'est bien la taille du
-- fichier UTF-8 qu'on veut tracer, pas la longueur de la chaine.
UPDATE LEGACY_DOCS_RAW
   SET file_size = OCTET_LENGTH(raw_content)
 WHERE file_size IS NULL;


-- -----------------------------------------------------------------------------
-- 3. Purge ciblee : seuls les documents du lot en cours sont remplaces
-- -----------------------------------------------------------------------------
-- Un fichier reingere apres modification peut produire moins de chunks qu'avant.
-- Sans ce DELETE, les chunks de queue de l'ancienne version survivraient.
DELETE FROM LEGACY_DOCS
 WHERE source_file IN (SELECT source_file FROM LEGACY_DOCS_RAW);


-- -----------------------------------------------------------------------------
-- 4. Chunking + extraction des metadonnees
-- -----------------------------------------------------------------------------
-- doc_type et agent_name viennent du NOM DE FICHIER, pas du chemin. Le corpus
--   reel n'a pas d'arborescence porteuse de sens : trois fichiers agreges, dont
--   le nom identifie sans ambiguite le producteur et la nature.
--
--     specs.md          -> specs        / JavaDocumentationAgent
--     dependencies.md   -> dependencies / DependencyMapperAgent
--     migration_*.md    -> migration    / LegacyMigrationOrchestrator
--
--   Un front matter, s'il existe, reste prioritaire. Un nom non reconnu laisse
--   doc_type a NULL et agent_name a $DEFAULT_AGENT_NAME — on ne devine pas.
--
-- java_class : extrait des en-tetes markdown `### <ClassName>`.
--   Discriminant : tous les `###` ne sont pas des classes. Le corpus contient
--   aussi `### Resume fonctionnel`, `### Responsabilites`, `### Dependances
--   detectees`. Le motif exige donc un token unique sur sa ligne, en ASCII, avec
--   AU MOINS DEUX MAJUSCULES — la convention CamelCase de Java. Cela retient
--   ClientServiceBean ou PaymentProcessorBean, et rejette les titres de section
--   accentues ou en un seul mot capitalise (Conclusion, Migration).
--
--   Propagation : un chunk pris au milieu d'une section ne reporte pas l'en-tete
--   de sa classe. On propage donc la derniere classe vue, par fichier et par
--   ordre de chunk (LAST_VALUE ... IGNORE NULLS). Quand un chunk contient
--   plusieurs en-tetes, on retient le DERNIER : c'est lui qui gouverne la queue
--   du chunk et donc les chunks suivants.
--
--   LIMITES ASSUMEES :
--     - une classe dont le nom n'a qu'une majuscule (ex. `Main`) est manquee ;
--     - les chunks precedant le premier en-tete d'un fichier restent NULL ;
--     - un chunk a cheval sur deux sections est attribue a une seule classe ;
--     - dependencies.md et migration_*.md ne sont pas structures par classe :
--       leur java_class sera souvent NULL, c'est normal et non corrige.
--   Utilisable comme axe de filtrage, pas comme partitionnement exact.
--
-- Decoupage : SPLIT_TEXT_RECURSIVE_CHARACTER en mode 'markdown' -> le splitter
--   essaie d'abord les frontieres de titres et de blocs avant de couper sur les
--   sauts de ligne puis les espaces.
-- La fonction renvoie un ARRAY ; LATERAL FLATTEN le transforme en lignes, et
--   c.index donne la position reelle du chunk dans le document.
INSERT INTO LEGACY_DOCS
    (doc_id, source_file, agent_name, doc_type, java_class, chunk_index, doc_content)
WITH src AS (
    SELECT
        source_file,
        raw_content,
        LEFT(raw_content, 1000)                          AS header,
        LOWER(REGEXP_SUBSTR(source_file, '[^/]+$'))      AS base_name
    FROM LEGACY_DOCS_RAW
),
meta AS (
    SELECT
        source_file,
        raw_content,

        NULLIF(TRIM(COALESCE(
            REGEXP_SUBSTR(header, '^[ \t]*agent_name[ \t]*:[ \t]*"?([^"\n\r]+)"?', 1, 1, 'ime', 1),
            REGEXP_SUBSTR(header, '^[ \t]*agent[ \t]*:[ \t]*"?([^"\n\r]+)"?',      1, 1, 'ime', 1),
            CASE
                WHEN base_name LIKE 'specs.%'        THEN 'JavaDocumentationAgent'
                WHEN base_name LIKE 'dependencies.%' THEN 'DependencyMapperAgent'
                WHEN base_name LIKE 'migration!_%' ESCAPE '!' THEN 'LegacyMigrationOrchestrator'
            END,
            $DEFAULT_AGENT_NAME
        )), '') AS agent_name,

        NULLIF(TRIM(COALESCE(
            REGEXP_SUBSTR(header, '^[ \t]*doc_type[ \t]*:[ \t]*"?([^"\n\r]+)"?', 1, 1, 'ime', 1),
            REGEXP_SUBSTR(header, '^[ \t]*type[ \t]*:[ \t]*"?([^"\n\r]+)"?',     1, 1, 'ime', 1),
            CASE
                WHEN base_name LIKE 'specs.%'        THEN 'specs'
                WHEN base_name LIKE 'dependencies.%' THEN 'dependencies'
                WHEN base_name LIKE 'migration!_%' ESCAPE '!' THEN 'migration'
            END
        )), '') AS doc_type

    FROM src
),
chunks AS (
    SELECT
        m.source_file,
        m.agent_name,
        m.doc_type,
        c.index                                         AS chunk_index,
        c.value::VARCHAR                                AS doc_content,
        -- Dernier en-tete de classe present dans CE chunk, s'il y en a un.
        -- REGEXP_COUNT donne le nombre d'occurrences ; on demande ensuite cette
        -- occurrence-la a REGEXP_SUBSTR pour obtenir la derniere. GREATEST(...,1)
        -- garde un rang valide quand il n'y en a aucune (retourne NULL).
        NULLIF(TRIM(REGEXP_SUBSTR(
            c.value::VARCHAR,
            '^###+[ \t]+([A-Z][a-zA-Z0-9_$]*[A-Z][a-zA-Z0-9_$]*)[ \t\r]*$',
            1,
            GREATEST(REGEXP_COUNT(
                c.value::VARCHAR,
                '^###+[ \t]+([A-Z][a-zA-Z0-9_$]*[A-Z][a-zA-Z0-9_$]*)[ \t\r]*$',
                1, 'm'
            ), 1),
            'me', 1
        )), '')                                         AS class_here
    FROM meta m,
         LATERAL FLATTEN(input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
                                      m.raw_content,
                                      'markdown',
                                      $CHUNK_SIZE,
                                      $CHUNK_OVERLAP
                                  )) c
    -- Un document vide ou termine par des separateurs peut produire un chunk
    -- blanc : inutile a indexer, il ne ferait que diluer le rappel.
    WHERE TRIM(c.value::VARCHAR) <> ''
)
SELECT
    SHA2(source_file || ':' || chunk_index::VARCHAR, 256) AS doc_id,
    source_file,
    agent_name,
    doc_type,
    -- Propagation de la derniere classe vue dans le fichier, jusqu'au prochain
    -- en-tete. Les chunks anterieurs au premier en-tete restent NULL.
    LAST_VALUE(class_here) IGNORE NULLS OVER (
        PARTITION BY source_file
        ORDER BY chunk_index
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                     AS java_class,
    chunk_index,
    doc_content
FROM chunks;


-- -----------------------------------------------------------------------------
-- 5. Rapport : nombre de chunks par fichier source (lot en cours)
-- -----------------------------------------------------------------------------
-- Doit rester la DERNIERE instruction du fichier : src/ingest.py lit le jeu de
-- resultats de la derniere instruction pour produire son log.
SELECT
    d.source_file,
    ANY_VALUE(d.doc_type)                          AS doc_type,
    COUNT(*)                                       AS chunk_count,
    COUNT(d.java_class)                            AS chunks_avec_classe,
    COUNT(DISTINCT d.java_class)                   AS classes_distinctes,
    MIN(LENGTH(d.doc_content))                     AS min_chunk_chars,
    MAX(LENGTH(d.doc_content))                     AS max_chunk_chars
FROM LEGACY_DOCS d
WHERE d.source_file IN (SELECT source_file FROM LEGACY_DOCS_RAW)
GROUP BY d.source_file
ORDER BY d.source_file;
