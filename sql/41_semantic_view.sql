/* =============================================================================
   41_semantic_view.sql — SV_BENCHMARK, vue semantique sur BENCHMARK_METRICS
   -----------------------------------------------------------------------------
   S'execute sous AI_ENGINEER_ROLE, apres sql/40_metrics.sql.

   POURQUOI CET OBJET
     1. Cortex Analyst ne lit pas une table, il lit un modele : noms metier,
        synonymes, descriptions. C'est ce fichier qui traduit une table EAV
        (une ligne par mesure) en vocabulaire interrogeable en francais.
     2. BENCHMARK_METRICS melange trois unites (ms, fichiers, pourcentage) dans
        une seule colonne metric_value. Sans modele, une somme naive additionne
        des millisecondes et des pourcentages. Les METRICS ci-dessous filtrent
        systematiquement sur metric_name : cela REDUIT le risque, cela ne
        l'ELIMINE PAS. Voir la mise en garde ci-dessous.
     3. Trois pieges de ce jeu de donnees produiraient des reponses fausses mais
        plausibles. Ils sont adresses ici, et documentes deux fois : en
        commentaire SQL pour le mainteneur, dans COMMENT pour le modele.

   CE QUE CE FICHIER NE PEUT PAS GARANTIR — mesure du 21/08/2026
     Une formule METRICS n'est pas une contrainte executable. L'outil Analyst
     ne transmet pas la vue au moteur SQL : il l'APLATIT en une CTE qui ne
     contient que les FACTS et les DIMENSIONS. Les METRICS n'y survivent pas.
     Le modele tente d'abord le nom de la metrique comme une colonne, Snowflake
     rejette (invalid identifier 'DUREE_TOTALE_MS'), et le modele RECONSTRUIT
     l'expression de memoire.

     Mesure : 10 questions de duree totale, 22 SQL executes, 12 en erreur
     (55 %), et les 10 questions ont toutes echoue a leur premiere tentative.

     Les descriptions, synonymes et AI_SQL_GENERATION de ce fichier restent
     donc le bon levier — ils orientent la re-derivation, et sur cette campagne
     elle a converge vers la bonne formule 10 fois sur 10, piege inclus. Mais
     c'est un GUIDAGE FORT, PAS UNE GARANTIE : la validation revient au golden
     dataset (eval/golden_questions.json), a rejouer apres toute evolution de
     cette vue, du modele d'orchestration ou de la plateforme.

     Mecanisme detaille, protocole et resultats : docs/06-retrospective.md.

   SYNTAXE — verifiee sur la doc Snowflake le 18/08/2026
   https://docs.snowflake.com/en/sql-reference/sql/create-semantic-view

       CREATE [ OR REPLACE ] SEMANTIC VIEW [ IF NOT EXISTS ] <name>
         TABLES ( logicalTable [ , ... ] )
         [ RELATIONSHIPS ( relationshipDef [ , ... ] ) ]
         [ FACTS ( factExpression [ , ... ] ) ]
         [ DIMENSIONS ( dimensionExpression [ , ... ] ) ]
         [ METRICS ( metricExpression [ , ... ] ) ]
         [ COMMENT = '<comment>' ]
         [ AI_SQL_GENERATION '<instructions>' ]
         ...

     - RELATIONSHIPS est optionnel : une vue mono-table est valide, et c'est
       notre cas (BENCHMARK_METRICS se suffit).
     - PRIMARY KEY sur la table logique est optionnelle ; on la declare, elle
       aide le modele a comprendre le grain.
     - Il faut AU MOINS un DIMENSIONS ou un METRICS.
     - WITH SYNONYMS et COMMENT s'attachent a la table, aux facts, aux
       dimensions ET aux metrics — c'est ce qui rend le modele interrogeable
       en francais sans traduire les colonnes.
   ============================================================================= */

USE ROLE      AI_ENGINEER_ROLE;
USE WAREHOUSE WH_AI_DEV;
USE DATABASE  LEGACY_AI_DB;
USE SCHEMA    CORE;


/* =============================================================================
   PIEGE 1 — LA SOMME DES DUREES D'ETAPES N'EST PAS LA DUREE DU RUN
   =============================================================================
   Mesure du 17/08/2026 sur les donnees reellement chargees (cf. controle 5b de
   sql/40_metrics.sql) :

       run_phase   duration_total_ms   SUM(step_duration_ms)   ratio
       analyze              877 739               2 676 441    3,05x
       report             2 711 957               2 711 640    1,00x

   Dans la phase ANALYZE, les quatre etapes 'analyze' (une par classe Java)
   s'executent EN PARALLELE. Leurs durees individuelles se recouvrent :
   364 282 / 631 215 / 802 751 / 877 267 ms, et la plus longue (877 267)
   correspond quasi exactement au temps reellement ecoule (877 739). Les
   additionner revient a compter trois fois le meme temps mural.

   Dans la phase REPORT, les trois etapes sont sequentielles et la somme
   coincide avec le total a 317 ms pres.

   Le piege est donc INTERMITTENT : la meme requete est juste sur une phase et
   fausse sur l'autre. C'est la pire configuration possible, parce qu'une
   verification ponctuelle sur la phase report la validerait a tort.

   PARADE : deux metriques distinctes, aux noms non interchangeables, dont les
   descriptions se renvoient mutuellement l'une a l'autre.
     - duree_totale_ms   lit duration_total_ms — la seule source valide pour
                         "combien de temps a duré le run"
     - duree_cumulee_etapes_ms  somme les etapes — mesure d'EFFORT, pas de duree
                                ecoulee, et son nom le dit
   ============================================================================= */

/* =============================================================================
   PIEGE 2 — success_rate_pct = 0 % NE SIGNIFIE PAS UN ECHEC
   =============================================================================
   Valeurs reellement chargees :

       run_phase   files_total   files_success   files_failed   success_rate_pct
       analyze               4               4              0              100,0
       report                0               0              0                0,0

   Cote report, success_rate_pct vaut 0.0 parce que files_total vaut 0 : le
   pipeline calcule 0/0 et rend 0. Aucun fichier n'a echoue — aucun fichier
   n'etait dans le perimetre de cette phase, qui produit un rapport de migration
   et non une analyse fichier par fichier.

   Or CETTE MEME PHASE contient le seul vrai echec du jeu de donnees :
   l'etape migration-plan a echoue sur un timeout
   (java.lang.RuntimeException: java.io.InterruptedIOException: timeout)
   avant d'etre rejouee avec succes en migration-plan_retry2.

   Donc : le taux de succes FICHIERS dit 0 % sans qu'il y ait eu d'echec, et
   masque l'echec reel qui, lui, est au niveau ETAPE. Un modele qui repondrait
   "le taux de succes est de 0 %" a la question "est-ce que ça s'est bien
   passé ?" serait faux deux fois — sur le chiffre et sur le sens.

   PARADE : trois metriques separees.
     - taux_succes_fichiers_pct  valeur brute reportee, description qui refuse
                                 explicitement son interpretation quand
                                 fichiers_total = 0
     - taux_succes_etapes_pct    calcule depuis step_status, c'est LUI qui
                                 reflete la sante reelle du run
     - nb_etapes_echouees        le compte brut, la reponse la plus honnete a
                                 "y a-t-il eu un echec"
   ============================================================================= */

/* =============================================================================
   PIEGE 3 — 'analyze' DESIGNE DEUX CHOSES DIFFERENTES
   =============================================================================
   run_phase = 'analyze'  ->  la phase du pipeline qui produit handoff/
   step_name = 'analyze'  ->  une etape A L'INTERIEUR de cette phase, executee
                              une fois par classe Java

   Les deux valeurs sont legitimes et coexistent. "Combien de temps a pris
   analyze ?" est donc ambigue : la phase entiere (877 739 ms) ou la somme des
   quatre etapes homonymes (2 675 515 ms) ?

   PARADE : les deux dimensions portent des noms metier distincts et sans
   recouvrement (phase_pipeline vs etape), avec des synonymes disjoints. Aucun
   synonyme ne contient le mot nu "analyze" des deux cotes.
   ============================================================================= */


CREATE OR REPLACE SEMANTIC VIEW SV_BENCHMARK

TABLES (
    metriques AS LEGACY_AI_DB.CORE.BENCHMARK_METRICS
        PRIMARY KEY (measure_id)
        WITH SYNONYMS = ('metriques du pipeline', 'benchmark', 'mesures',
                         'performances du pipeline', 'statistiques d''execution')
        COMMENT = 'Une ligne par mesure produite par le pipeline java-legacy-agent lors de la modernisation du projet demo-project. Deux executions y figurent : la phase analyze (analyse du code, grain classe Java) et la phase report (production du dossier de migration, grain projet). Les mesures de niveau run et de niveau etape cohabitent dans la meme table : toujours filtrer par la portee attendue.'
)

FACTS (
    metriques.valeur AS metric_value
        WITH SYNONYMS = ('valeur', 'valeur mesuree', 'valeur brute')
        COMMENT = 'Valeur numerique brute d''une mesure. NE JAMAIS agreger cette colonne sans filtrer sur le nom de mesure : elle melange des millisecondes, des nombres de fichiers et des pourcentages. Utiliser les metriques nommees de cette vue, qui appliquent ce filtre.'
)

DIMENSIONS (
    metriques.projet AS project
        WITH SYNONYMS = ('projet', 'application', 'projet analyse', 'codebase')
        COMMENT = 'Nom du projet Java soumis au pipeline. Une seule valeur a ce jour : demo-project.',

    -- Piege 3 : synonymes volontairement disjoints de ceux de l'etape.
    metriques.phase_pipeline AS run_phase
        WITH SYNONYMS = ('phase', 'phase du pipeline', 'type d''execution',
                         'quelle execution', 'analyse ou rapport')
        COMMENT = 'Phase du pipeline, deux valeurs. "analyze" : l''analyse du code source, qui mesure chaque classe Java individuellement (4 fichiers traites, 100 % de succes). "report" : la production du dossier de migration, mesuree au seul niveau projet (aucun fichier dans son perimetre, et c''est elle qui contient l''unique echec d''etape). ATTENTION : ne pas confondre avec l''etape nommee "analyze", qui est une etape interne de la phase "analyze".',

    metriques.horodatage AS run_timestamp
        WITH SYNONYMS = ('date', 'date d''execution', 'quand', 'horodatage', 'moment du run')
        COMMENT = 'Horodatage de l''execution, emis par le pipeline. La phase analyze precede la phase report le meme jour.',

    metriques.portee AS scope
        WITH SYNONYMS = ('portee', 'granularite', 'niveau de detail')
        COMMENT = 'Granularite de la mesure. "run" : la mesure porte sur l''execution entiere (duree totale, compteurs de fichiers, taux de succes). "step" : la mesure porte sur une etape individuelle. Les deux niveaux ne se melangent pas dans une meme somme.',

    metriques.classe AS scope_name
        WITH SYNONYMS = ('classe', 'classe Java', 'nom de classe', 'bean',
                         'composant', 'fichier analyse', 'sujet mesure')
        COMMENT = 'Sujet de la mesure d''etape : nom de la classe Java (ClientServiceBean, InvoiceGeneratorBean, OrderServiceBean, PaymentProcessorBean) pour les etapes qui traitent une classe, ou le nom du projet pour les etapes de portee projet (scan, dat, migration-plan). NULL pour les mesures de portee run. C''est la dimension a utiliser pour comparer les classes entre elles.',

    -- Piege 3 : aucun synonyme ne reprend le mot nu "analyze".
    metriques.etape AS step_name
        WITH SYNONYMS = ('etape', 'etape du pipeline', 'traitement',
                         'quelle etape', 'phase de traitement interne')
        COMMENT = 'Etape individuelle du pipeline. Phase analyze : "scan" (inventaire du projet, une fois), "ast" (parsing syntaxique, une fois par classe), "analyze" (analyse LLM, une fois par classe, etape de loin la plus couteuse). Phase report : "dat", "migration-plan", "migration-plan_retry2". NULL pour les mesures de portee run.',

    metriques.statut_etape AS step_status
        WITH SYNONYMS = ('statut', 'resultat', 'succes ou echec', 'etat de l''etape')
        COMMENT = 'Statut d''une etape : "OK" ou "FAILED". Une seule etape a la valeur FAILED dans tout le jeu de donnees (migration-plan, phase report, timeout), et elle a ete rejouee avec succes juste apres. C''est cette dimension, et non le taux de succes fichiers, qui renseigne sur les echecs reels.',

    metriques.message_erreur AS error_message
        WITH SYNONYMS = ('erreur', 'message d''erreur', 'cause de l''echec', 'exception')
        COMMENT = 'Message d''erreur brut lorsqu''une etape a echoue, NULL sinon. Renseigne une seule fois : un timeout Java (InterruptedIOException) sur l''etape migration-plan.',

    metriques.nom_mesure AS metric_name
        WITH SYNONYMS = ('nom de la mesure', 'type de mesure', 'indicateur')
        COMMENT = 'Identifiant technique de la mesure : duration_total_ms, files_total, files_success, files_failed, success_rate_pct, step_duration_ms. Dimension de filtrage interne ; preferer les metriques nommees de cette vue.',

    metriques.unite AS unit
        WITH SYNONYMS = ('unite', 'unite de mesure')
        COMMENT = 'Unite de la valeur : "ms" (millisecondes), "fichiers", "pourcentage". Sa presence rappelle que metric_value melange des unites incompatibles.'
)

METRICS (
    -- ---------------------------------------------------------------------
    -- PIEGE 1 — la paire de metriques de duree. Voir le bloc en tete de fichier.
    -- La description de chacune renvoie explicitement a l'autre : c'est ce
    -- renvoi croise qui empeche le modele de substituer l'une a l'autre.
    -- ---------------------------------------------------------------------
    metriques.duree_totale_ms AS SUM(CASE WHEN metric_name = 'duration_total_ms' THEN metric_value END)
        WITH SYNONYMS = ('duree totale', 'temps total', 'combien de temps',
                         'duree du run', 'temps d''execution', 'duree de la phase')
        COMMENT = 'Duree reellement ecoulee d''une execution, en millisecondes, telle que mesuree par le pipeline. C''EST LA SEULE SOURCE VALIDE pour toute question de duree totale ou de temps d''execution. NE JAMAIS calculer une duree totale en additionnant les durees d''etapes : dans la phase analyze, quatre etapes tournent en parallele et leur somme vaut environ trois fois le temps reel (2 676 441 ms sommes contre 877 739 ms ecoules). Pour l''effort cumule, utiliser duree_cumulee_etapes_ms, qui est une grandeur differente.',

    metriques.duree_cumulee_etapes_ms AS SUM(CASE WHEN metric_name = 'step_duration_ms' THEN metric_value END)
        WITH SYNONYMS = ('temps cumule des etapes', 'effort total',
                         'somme des durees d''etapes', 'temps machine cumule')
        COMMENT = 'Somme des durees de toutes les etapes, en millisecondes. C''est une mesure d''EFFORT CUMULE, PAS une duree ecoulee. Dans la phase analyze, les etapes tournent en parallele : cette somme (2 676 441 ms) depasse d''un facteur 3 le temps reellement ecoule (877 739 ms). Ne jamais l''employer pour repondre a "combien de temps a dure...", qui releve de duree_totale_ms. Legitime pour comparer le cout de traitement entre classes ou entre etapes.',

    metriques.duree_etape_max_ms AS MAX(CASE WHEN metric_name = 'step_duration_ms' THEN metric_value END)
        WITH SYNONYMS = ('etape la plus longue', 'duree maximale d''une etape',
                         'pire etape', 'goulot d''etranglement')
        COMMENT = 'Duree de l''etape la plus longue, en millisecondes. Utile pour identifier le goulot d''etranglement. Dans la phase analyze ou les etapes sont parallelisees, cette valeur approche la duree totale ecoulee, ce qui est le comportement attendu.',

    metriques.duree_etape_moyenne_ms AS AVG(CASE WHEN metric_name = 'step_duration_ms' THEN metric_value END)
        WITH SYNONYMS = ('duree moyenne d''une etape', 'temps moyen par etape')
        COMMENT = 'Duree moyenne d''une etape, en millisecondes. A interpreter avec prudence : les etapes sont tres heterogenes (un scan de 6 ms voisine une analyse LLM de 877 267 ms), la moyenne y est peu representative.',

    -- ---------------------------------------------------------------------
    -- PIEGE 2 — les trois metriques de succes. Voir le bloc en tete de fichier.
    -- L'ordre de lecture voulu est : nb_etapes_echouees d'abord (le fait brut),
    -- taux_succes_etapes_pct ensuite (la sante reelle), et
    -- taux_succes_fichiers_pct en dernier, avec sa mise en garde.
    -- ---------------------------------------------------------------------
    metriques.nb_etapes_echouees AS COUNT(CASE WHEN scope = 'step' AND step_status = 'FAILED' THEN 1 END)
        WITH SYNONYMS = ('etapes en echec', 'nombre d''echecs', 'echecs',
                         'combien d''erreurs', 'y a-t-il eu un probleme')
        COMMENT = 'Nombre d''etapes dont le statut est FAILED. C''EST LA REPONSE LA PLUS DIRECTE ET LA PLUS FIABLE a toute question portant sur les echecs, les erreurs ou les problemes rencontres. Vaut 0 pour la phase analyze et 1 pour la phase report (etape migration-plan, timeout Java, rejouee avec succes ensuite). Ne pas repondre a une question sur les echecs en utilisant le taux de succes fichiers, qui n''en rend pas compte.',

    metriques.taux_succes_etapes_pct AS
        COUNT(CASE WHEN scope = 'step' AND step_status = 'OK' THEN 1 END) * 100.0
        / NULLIF(COUNT(CASE WHEN scope = 'step' THEN 1 END), 0)
        WITH SYNONYMS = ('taux de succes des etapes', 'fiabilite',
                         'pourcentage d''etapes reussies', 'sante du run')
        COMMENT = 'Pourcentage d''etapes terminees en OK, calcule a partir des statuts d''etape reels. C''est l''indicateur de sante a privilegier quand on demande si une execution s''est bien passee : 100 % pour la phase analyze, environ 67 % pour la phase report (2 etapes OK sur 3). A ne pas confondre avec taux_succes_fichiers_pct, qui mesure autre chose et vaut 0 sur la phase report pour une raison purement arithmetique.',

    metriques.taux_succes_fichiers_pct AS AVG(CASE WHEN metric_name = 'success_rate_pct' THEN metric_value END)
        WITH SYNONYMS = ('taux de succes des fichiers', 'pourcentage de fichiers traites')
        COMMENT = 'Taux de succes AU NIVEAU FICHIER tel que reporte par le pipeline. Vaut 100 pour la phase analyze (4 fichiers sur 4). Vaut 0 pour la phase report, ET CE ZERO NE SIGNIFIE PAS UN ECHEC : cette phase ne traite aucun fichier individuellement (fichiers_total = 0), le pipeline calcule 0/0 et rend 0. Ne jamais interpreter ce 0 comme un taux d''echec ni comme un incident. Pour savoir si une execution s''est bien deroulee, utiliser nb_etapes_echouees ou taux_succes_etapes_pct. Cette metrique n''a de sens que lorsque fichiers_total est strictement positif.',

    metriques.fichiers_total AS SUM(CASE WHEN metric_name = 'files_total' THEN metric_value END)
        WITH SYNONYMS = ('nombre de fichiers', 'fichiers traites', 'combien de fichiers',
                         'taille du perimetre')
        COMMENT = 'Nombre de fichiers Java dans le perimetre de l''execution. Vaut 4 pour la phase analyze et 0 pour la phase report, qui ne raisonne pas par fichier. Un total a 0 rend inexploitable le taux de succes fichiers de la meme phase.',

    metriques.fichiers_reussis AS SUM(CASE WHEN metric_name = 'files_success' THEN metric_value END)
        WITH SYNONYMS = ('fichiers reussis', 'fichiers traites avec succes')
        COMMENT = 'Nombre de fichiers traites sans erreur. 4 pour la phase analyze, 0 pour la phase report faute de fichiers dans son perimetre.',

    metriques.fichiers_en_echec AS SUM(CASE WHEN metric_name = 'files_failed' THEN metric_value END)
        WITH SYNONYMS = ('fichiers en echec', 'fichiers rates')
        COMMENT = 'Nombre de fichiers dont le traitement a echoue. Vaut 0 dans les deux phases : aucun fichier n''a jamais echoue. L''unique echec du jeu de donnees est une ETAPE, pas un fichier — voir nb_etapes_echouees.',

    metriques.nb_etapes AS COUNT(CASE WHEN scope = 'step' THEN 1 END)
        WITH SYNONYMS = ('nombre d''etapes', 'combien d''etapes')
        COMMENT = 'Nombre d''etapes executees. 9 pour la phase analyze (1 scan, 4 ast, 4 analyze), 3 pour la phase report. Compte les etapes rejouees comme des etapes distinctes : migration-plan et migration-plan_retry2 comptent pour deux.',

    metriques.nb_runs AS COUNT(DISTINCT run_id)
        WITH SYNONYMS = ('nombre d''executions', 'combien de runs')
        COMMENT = 'Nombre d''executions distinctes du pipeline. Vaut 2 sur l''ensemble du jeu de donnees : une phase analyze et une phase report.'
)

COMMENT = 'Metriques d''execution du pipeline de modernisation java-legacy-agent sur le projet demo-project. Deux executions : phase analyze (analyse du code, grain classe Java) et phase report (dossier de migration, grain projet). Attention a trois pieges documentes dans les descriptions : la somme des durees d''etapes n''est pas la duree ecoulee (parallelisme), un taux de succes fichiers a 0 % ne signale pas un echec (division par zero), et le mot analyze designe a la fois une phase et une etape.'

AI_SQL_GENERATION 'Regles imperatives pour ce modele. (1) Pour toute question de duree totale ou de temps d''execution, utiliser la metrique duree_totale_ms. Ne jamais additionner duree_cumulee_etapes_ms ni les durees d''etapes pour obtenir une duree ecoulee : les etapes de la phase analyze sont parallelisees et leur somme vaut environ trois fois le temps reel. (2) Pour toute question sur les echecs, erreurs, incidents ou sur le bon deroulement d''une execution, utiliser nb_etapes_echouees ou taux_succes_etapes_pct. Ne jamais repondre a partir de taux_succes_fichiers_pct : sa valeur de 0 sur la phase report resulte d''une division 0/0 et non d''un echec. (3) Distinguer systematiquement la dimension phase_pipeline (valeurs analyze et report) de la dimension etape (dont une valeur est aussi analyze) ; en cas d''ambiguite sur le mot analyze, preferer la phase et le signaler. (4) Toujours preciser l''unite dans la reponse, les durees etant en millisecondes.';


-- -----------------------------------------------------------------------------
-- Controles
-- -----------------------------------------------------------------------------
SHOW SEMANTIC VIEWS LIKE 'SV_BENCHMARK' IN SCHEMA LEGACY_AI_DB.CORE;

DESCRIBE SEMANTIC VIEW SV_BENCHMARK;


-- Verification par la valeur : les deux metriques de duree doivent diverger sur
-- la phase analyze et coincider sur la phase report. Si elles coincident
-- partout, la vue ne lit pas ce qu'on croit.
SELECT * FROM SEMANTIC_VIEW(
    SV_BENCHMARK
    DIMENSIONS metriques.phase_pipeline
    METRICS    metriques.duree_totale_ms,
               metriques.duree_cumulee_etapes_ms,
               metriques.nb_etapes,
               metriques.nb_etapes_echouees,
               metriques.taux_succes_etapes_pct,
               metriques.taux_succes_fichiers_pct
) ORDER BY phase_pipeline;
