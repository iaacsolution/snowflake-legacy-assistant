/* =============================================================================
   40_metrics.sql — BENCHMARK_METRICS : ingestion des metriques du pipeline
   -----------------------------------------------------------------------------
   S'execute sous AI_ENGINEER_ROLE, apres que les deux fichiers de metriques ont
   ete deposes dans @DOCS_STAGE/metrics/<phase>/ (voir section 0).

   SOURCE REELLE — deux fichiers, MEME SCHEMA, deux phases du pipeline
   -----------------------------------------------------------------------------
   Les deux JSON portent exactement les memes cles racine et les memes cles de
   step (celui de la phase report ajoute seulement 'error'). Ce ne sont pas deux
   formats : c'est la meme enveloppe de metriques emise a deux moments.

     handoff/demo-project/metrics_demo-project.json      -> run_phase = 'analyze'
       4 fichiers / 4 succes / 100 %, 877 739 ms au total
       9 etapes : scan (projet) + ast et analyze POUR CHACUNE DES 4 CLASSES
       -> c'est le GRAIN FIN : durees par classe

     migration-output/metrics_demo-project.json          -> run_phase = 'report'
       0 fichier / 0 succes / 0 %, 2 711 957 ms au total
       3 etapes au niveau projet : dat, migration-plan (FAILED, timeout),
       migration-plan_retry2 (OK)
       -> c'est l'AGREGAT, et c'est lui qui porte l'echec

   ATTENTION AU HOMONYME : run_phase = 'analyze' designe la PHASE du pipeline,
   alors que step_name = 'analyze' designe une ETAPE a l'interieur de cette
   phase. Les deux coexistent legitimement ; ne pas les confondre en requete.

   CE QUI N'EST PAS ICI
   -----------------------------------------------------------------------------
   Aucune complexite cyclomatique, aucune metrique par methode : les JSON n'en
   contiennent pas. Les valeurs de CC (9, 13, 6, 14, 7, 11) n'existent que dans
   la prose de specs.md et migration_*.md, deja ingerees dans LEGACY_DOCS. Elles
   s'interrogent via Cortex Search, pas via Analyst. Decision explicite : ne rien
   extraire de ces markdown ici.

   MODELE — une ligne par mesure (EAV), pas une ligne par run
   -----------------------------------------------------------------------------
   Le JSON a deux niveaux imbriques (racine + tableau steps) de granularites
   differentes. Une table a colonnes fixes imposerait soit d'aplatir en perdant
   le detail par etape, soit de multiplier les colonnes nullables. Une ligne par
   mesure encaisse les deux niveaux, et encaissera un troisieme si le pipeline
   en ajoute un, sans DDL.

   Le prix a payer, assume : toute requete doit filtrer sur metric_name, et une
   somme naive melange des unites. C'est precisement le role de la vue semantique
   SV_BENCHMARK (sql/41_semantic_view.sql) que d'interdire ces melanges.

   scope vaut 'run' ou 'step'. Pas de scope 'methode' : aucune mesure n'existe a
   ce grain. Le niveau CLASSE s'obtient par GROUP BY scope_name sur les lignes
   scope = 'step' — sans fabriquer une seule ligne.
   ============================================================================= */

USE ROLE      AI_ENGINEER_ROLE;
USE WAREHOUSE WH_AI_DEV;
USE DATABASE  LEGACY_AI_DB;
USE SCHEMA    CORE;


/* -----------------------------------------------------------------------------
   0. Prerequis cote client — les deux fichiers portent le MEME NOM
   -----------------------------------------------------------------------------
   metrics_demo-project.json existe dans les deux dossiers. Les deposer a plat
   dans le stage ferait ecraser l'un par l'autre. On les separe donc par un
   sous-dossier qui porte la phase, et c'est ce chemin qui determinera run_phase.

       PUT 'file://<...>/handoff/demo-project/metrics_demo-project.json'
           @DOCS_STAGE/metrics/analyze/ AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

       PUT 'file://<...>/migration-output/metrics_demo-project.json'
           @DOCS_STAGE/metrics/report/  AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

       ALTER STAGE DOCS_STAGE REFRESH;
   ----------------------------------------------------------------------------- */


-- -----------------------------------------------------------------------------
-- 1. Staging brut — un fichier = une ligne, payload VARIANT
-- -----------------------------------------------------------------------------
-- Meme motif que LEGACY_DOCS_RAW (cf. sql/10_tables.sql) : on garde le JSON
-- integral avant de le decouper. Re-deriver BENCHMARK_METRICS apres un
-- changement de modele ne demande alors ni re-upload ni acces au disque.
CREATE TABLE IF NOT EXISTS BENCHMARK_RAW (
    source_file   VARCHAR       NOT NULL COMMENT 'Chemin dans le stage, prefixe retire (porte la phase)',
    payload       VARIANT       NOT NULL COMMENT 'JSON integral du fichier de metriques',
    loaded_at     TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Staging brut des metrics_*.json. Videe a chaque ingestion.';


-- -----------------------------------------------------------------------------
-- 2. BENCHMARK_METRICS — une ligne par mesure
-- -----------------------------------------------------------------------------
-- measure_id et run_id sont deterministes : reingerer les memes fichiers
-- reproduit les memes identifiants, ce qui rend le DELETE/INSERT idempotent et
-- evite tout doublon silencieux.
CREATE TABLE IF NOT EXISTS BENCHMARK_METRICS (
    measure_id     VARCHAR(64)   NOT NULL COMMENT 'SHA2-256 de run_id + scope + scope_name + step_name + metric_name',
    run_id         VARCHAR(64)   NOT NULL COMMENT 'SHA2-256 de project + run_phase + run_timestamp — identifie une execution',
    project        VARCHAR       NOT NULL COMMENT 'Projet analyse (ex. demo-project)',
    run_phase      VARCHAR       NOT NULL COMMENT 'Phase du pipeline : analyze (grain classe) ou report (agregat projet)',
    run_timestamp  TIMESTAMP_NTZ NOT NULL COMMENT 'Horodatage emis par le pipeline pour cette execution',

    scope          VARCHAR       NOT NULL COMMENT 'Granularite de la mesure : run (execution entiere) ou step (une etape)',
    scope_name     VARCHAR                COMMENT 'Sujet mesure : nom de CLASSE Java pour les etapes par classe, nom de projet sinon. NULL pour scope = run',
    step_name      VARCHAR                COMMENT 'Etape du pipeline : scan, ast, analyze, dat, migration-plan, migration-plan_retry2. NULL pour scope = run',
    step_status    VARCHAR                COMMENT 'OK ou FAILED. Dimension et non mesure : un statut ne s''additionne pas',
    error_message  VARCHAR                COMMENT 'Message d''erreur brut quand step_status = FAILED, sinon NULL',

    metric_name    VARCHAR       NOT NULL COMMENT 'Nom de la mesure (duration_total_ms, files_total, step_duration_ms, ...)',
    metric_value   FLOAT                  COMMENT 'Valeur numerique de la mesure',
    unit           VARCHAR                COMMENT 'Unite : ms, fichiers, pourcentage',

    source_file    VARCHAR       NOT NULL COMMENT 'Fichier de provenance dans le stage',
    ingested_at    TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),

    CONSTRAINT PK_BENCHMARK_METRICS PRIMARY KEY (measure_id)
)
COMMENT = 'Metriques du pipeline java-legacy-agent, une ligne par mesure. Source de la vue semantique SV_BENCHMARK.';


-- -----------------------------------------------------------------------------
-- 3. Chargement du stage
-- -----------------------------------------------------------------------------
TRUNCATE TABLE BENCHMARK_RAW;

-- FORCE = TRUE : la table vient d'etre videe, recharger tout le lot est voulu.
-- Sans cela, COPY ignorerait les fichiers deja charges (metadonnees conservees
-- 64 jours) et une reingestion apres correction ne ramenerait rien.
-- Le format JSON du stage rend deja un VARIANT dans $1 : appeler PARSE_JSON
-- par-dessus serait redondant (et echouerait, $1 n'etant pas du texte). Le
-- deballage se fait donc directement par navigation ':' et FLATTEN a l'etape 4.
COPY INTO BENCHMARK_RAW (source_file, payload)
FROM (
    SELECT
        REGEXP_REPLACE(METADATA$FILENAME, '^(docs_stage/)?metrics/', '', 1, 1, 'i'),
        $1
    FROM @DOCS_STAGE/metrics/
)
FILE_FORMAT = (TYPE = JSON, STRIP_OUTER_ARRAY = FALSE)
PATTERN     = '.*[.]json'
ON_ERROR    = ABORT_STATEMENT
FORCE       = TRUE;


-- -----------------------------------------------------------------------------
-- 4. Purge ciblee puis insertion
-- -----------------------------------------------------------------------------
-- Seuls les runs du lot en cours sont remplaces : un run reingere apres
-- correction peut produire moins de mesures qu'avant, et les mesures de queue
-- de l'ancienne version doivent disparaitre.
DELETE FROM BENCHMARK_METRICS
 WHERE run_id IN (
     SELECT SHA2(payload:project::VARCHAR || '|' ||
                 CASE WHEN source_file ILIKE 'analyze/%' THEN 'analyze' ELSE 'report' END || '|' ||
                 payload:timestamp::VARCHAR, 256)
       FROM BENCHMARK_RAW
 );


INSERT INTO BENCHMARK_METRICS
    (measure_id, run_id, project, run_phase, run_timestamp,
     scope, scope_name, step_name, step_status, error_message,
     metric_name, metric_value, unit, source_file)
WITH runs AS (
    SELECT
        source_file,
        payload,
        payload:project::VARCHAR                              AS project,
        -- La phase vient du SOUS-DOSSIER de stage, seul discriminant fiable :
        -- les deux fichiers portent le meme nom et le meme schema interne.
        CASE WHEN source_file ILIKE 'analyze/%' THEN 'analyze' ELSE 'report' END AS run_phase,
        payload:timestamp::TIMESTAMP_NTZ                      AS run_timestamp
    FROM BENCHMARK_RAW
),
ids AS (
    SELECT
        r.*,
        SHA2(r.project || '|' || r.run_phase || '|' || r.payload:timestamp::VARCHAR, 256) AS run_id
    FROM runs r
),

-- 4a. Les 5 mesures de niveau run.
--     OBJECT_CONSTRUCT + FLATTEN plutot que 5 SELECT unis : ajouter une mesure
--     racine au pipeline ne demandera qu'une ligne de plus ici.
run_metrics AS (
    SELECT
        i.run_id, i.project, i.run_phase, i.run_timestamp, i.source_file,
        'run'                       AS scope,
        NULL                        AS scope_name,
        NULL                        AS step_name,
        NULL                        AS step_status,
        NULL                        AS error_message,
        f.key::VARCHAR              AS metric_name,
        f.value::FLOAT              AS metric_value,
        CASE f.key::VARCHAR
            WHEN 'duration_total_ms' THEN 'ms'
            WHEN 'success_rate_pct'  THEN 'pourcentage'
            ELSE 'fichiers'
        END                         AS unit
    FROM ids i,
         LATERAL FLATTEN(input => OBJECT_CONSTRUCT(
             'duration_total_ms', i.payload:duration_total_ms,
             'files_total',       i.payload:files_total,
             'files_success',     i.payload:files_success,
             'files_failed',      i.payload:files_failed,
             'success_rate_pct',  i.payload:success_rate_pct
         )) f
    WHERE f.value IS NOT NULL
),

-- 4b. Une mesure de duree par etape. Le statut et l'erreur voyagent comme
--     dimensions de la ligne, pas comme mesures : un statut ne s'additionne pas.
step_metrics AS (
    SELECT
        i.run_id, i.project, i.run_phase, i.run_timestamp, i.source_file,
        'step'                                  AS scope,
        s.value:"class"::VARCHAR                AS scope_name,
        s.value:step::VARCHAR                   AS step_name,
        s.value:status::VARCHAR                 AS step_status,
        s.value:error::VARCHAR                  AS error_message,
        'step_duration_ms'                      AS metric_name,
        s.value:duration_ms::FLOAT              AS metric_value,
        'ms'                                    AS unit
    FROM ids i,
         LATERAL FLATTEN(input => i.payload:steps) s
),
unioned AS (
    SELECT * FROM run_metrics
    UNION ALL
    SELECT * FROM step_metrics
)
SELECT
    SHA2(run_id || '|' || scope || '|' || COALESCE(scope_name, '') || '|' ||
         COALESCE(step_name, '') || '|' || metric_name, 256) AS measure_id,
    run_id, project, run_phase, run_timestamp,
    scope, scope_name, step_name, step_status, error_message,
    metric_name, metric_value, unit, source_file
FROM unioned;


-- -----------------------------------------------------------------------------
-- 5. Controles
-- -----------------------------------------------------------------------------
-- 5a. Unicite reelle de measure_id (la PRIMARY KEY n'est pas contrainte par
--     Snowflake a l'insertion). Doit ne renvoyer aucune ligne.
SELECT measure_id, COUNT(*) AS n
FROM BENCHMARK_METRICS
GROUP BY measure_id HAVING COUNT(*) > 1;


-- 5b. Le controle qui compte : la somme des durees d'etapes N'EST PAS la duree
--     totale du run. Dans la phase analyze les 4 etapes 'analyze' tournent en
--     PARALLELE — leur somme vaut ~3x le temps reellement ecoule. Dans la phase
--     report les etapes sont sequentielles et le ratio retombe a ~1.
--     Ce rapport doit rester visible : c'est lui qui justifie la redaction des
--     descriptions de SV_BENCHMARK (cf. sql/41_semantic_view.sql).
SELECT
    run_phase,
    MAX(CASE WHEN metric_name = 'duration_total_ms' THEN metric_value END)  AS duree_totale_ms,
    SUM(CASE WHEN metric_name = 'step_duration_ms'  THEN metric_value END)  AS somme_etapes_ms,
    ROUND(SUM(CASE WHEN metric_name = 'step_duration_ms' THEN metric_value END)
        / NULLIF(MAX(CASE WHEN metric_name = 'duration_total_ms' THEN metric_value END), 0), 2) AS ratio,
    COUNT(CASE WHEN scope = 'step' THEN 1 END)                              AS nb_etapes,
    COUNT(CASE WHEN step_status = 'FAILED' THEN 1 END)                      AS nb_etapes_echouees
FROM BENCHMARK_METRICS
GROUP BY run_phase
ORDER BY run_phase;


-- 5c. Inventaire des mesures chargees.
SELECT
    run_phase,
    scope,
    metric_name,
    unit,
    COUNT(*)              AS nb_lignes,
    COUNT(DISTINCT scope_name) AS sujets_distincts
FROM BENCHMARK_METRICS
GROUP BY run_phase, scope, metric_name, unit
ORDER BY run_phase, scope, metric_name;
