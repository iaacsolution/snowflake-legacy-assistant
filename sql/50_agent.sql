/* =============================================================================
   50_agent.sql — LEGACY_ASSISTANT, l'agent Cortex qui reunit Search et Analyst
   -----------------------------------------------------------------------------
   POURQUOI CET OBJET (les 3 lignes de regle)
     1. Un agent est un ROUTEUR : il recoit une question en francais et decide
        seul s'il faut interroger la documentation (Cortex Search, J2) ou les
        metriques (Cortex Analyst, J3). C'est la seule piece qui manquait.
     2. Il est declare une fois cote Snowflake plutot que reconstruit a chaque
        appel : les outils, leurs descriptions et le budget vivent dans le
        catalogue, versionnes ici, et non dans le client Python.
     3. Il rend la question "documentation ou metriques ?" mesurable : c'est un
        choix d'outil observable dans la reponse, donc evaluable au J5.

   SYNTAXE VERIFIEE LE 21/08/2026
     https://docs.snowflake.com/en/sql-reference/sql/create-agent
     https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-manage

       CREATE [ OR REPLACE ] AGENT [ IF NOT EXISTS ] <name>
         [ COMMENT = '<comment>' ]
         [ PROFILE = '<profile_json>' ]
         FROM SPECIFICATION $$ <specification> $$;

     La specification est du YAML, pas du JSON, entre $$ et $$. L'indentation y
     est donc signifiante : ne pas reformater ce bloc a la legere.

   COUT
     Le CREATE lui-meme est une operation de catalogue : gratuit, aucun compute,
     aucun embedding. Ce qui coute, c'est chaque appel a l'agent : un modele
     d'orchestration qui raisonne, plus le ou les outils qu'il declenche. A la
     difference du J2 et du J3, un seul appel d'agent peut en declencher
     plusieurs autres. D'ou le budget explicite dans la specification.
   ============================================================================= */

USE ROLE AI_ENGINEER_ROLE;
USE DATABASE LEGACY_AI_DB;
USE SCHEMA CORE;
USE WAREHOUSE WH_AI_DEV;


/* -----------------------------------------------------------------------------
   PREALABLE — un grant qui n'est PAS dans le perimetre de ce script
   -----------------------------------------------------------------------------
   Constat du 21/08/2026, SHOW GRANTS TO ROLE AI_ENGINEER_ROLE : le role possede
   CREATE CORTEX SEARCH SERVICE, CREATE SEMANTIC VIEW, CREATE TABLE, CREATE VIEW
   et CREATE STAGE sur LEGACY_AI_DB.CORE — mais pas CREATE AGENT. Le bootstrap du
   J1 est anterieur a la decision d'utiliser un objet agent.

   Le grant releve d'ACCOUNTADMIN (proprietaire du schema), donc de
   sql/00_bootstrap.sql et d'une execution manuelle dans Snowsight. A jouer une
   fois, avant le premier CREATE AGENT ci-dessous :

       USE ROLE ACCOUNTADMIN;
       GRANT CREATE AGENT ON SCHEMA LEGACY_AI_DB.CORE TO ROLE AI_ENGINEER_ROLE;

   Verification, sous AI_ENGINEER_ROLE :

       SHOW GRANTS TO ROLE AI_ENGINEER_ROLE;
       -- la ligne CREATE AGENT / SCHEMA / LEGACY_AI_DB.CORE doit apparaitre

   Les autres privileges necessaires a l'execution de l'agent sont deja acquis :
   OWNERSHIP sur LEGACY_DOCS_SEARCH et sur SV_BENCHMARK, USAGE sur la database,
   le schema et WH_AI_DEV, et la database role SNOWFLAKE.CORTEX_USER.
   ----------------------------------------------------------------------------- */


-- -----------------------------------------------------------------------------
-- L'agent
-- -----------------------------------------------------------------------------
-- CREATE OR REPLACE et non IF NOT EXISTS, contrairement au service de recherche :
-- remplacer un agent ne detruit aucun index et ne re-embedde rien. C'est un objet
-- de configuration, pas un objet de donnees. On veut donc pouvoir iterer sur les
-- instructions sans avoir a le supprimer d'abord.
CREATE OR REPLACE AGENT LEGACY_ASSISTANT
  COMMENT = 'Assistant du pipeline java-legacy-agent. Route une question en francais vers la documentation (Cortex Search, LEGACY_DOCS_SEARCH) ou vers les metriques de benchmark (Cortex Analyst, SV_BENCHMARK).'
  PROFILE = '{"display_name": "Assistant Legacy"}'
  FROM SPECIFICATION
$$
models:
  orchestration: auto

orchestration:
  budget:
    seconds: 60
    tokens: 16000

instructions:
  system: |
    Tu reponds a des questions sur un pipeline de modernisation de code Java
    legacy nomme java-legacy-agent, applique a un projet de demonstration.
    Deux sources, et deux seulement, sont a ta disposition :
      - DocSearch, la documentation produite par le pipeline (specifications,
        rapports de migration, dette technique, roadmap, risques). C'est du
        texte : elle explique COMMENT le code fonctionne et CE QUI a ete decide.
      - BenchAnalyst, les metriques d'execution du pipeline (durees, nombres de
        fichiers, taux de succes, statuts d'etape). C'est du chiffre : il repond
        a COMBIEN, COMBIEN DE TEMPS, COMBIEN DE FOIS.
    Tu n'as aucune connaissance propre de ce projet. Tout ce que tu affirmes
    doit venir de l'un de ces deux outils.

  orchestration: |
    Choisis l'outil sur la nature de la reponse attendue, pas sur les mots de la
    question :
      - une question sur le fonctionnement, la conception, une classe Java, une
        decision, un risque, une etape a suivre -> DocSearch ;
      - une question dont la reponse est un nombre, une duree, un classement, un
        comptage ou une comparaison chiffree -> BenchAnalyst ;
      - une question qui demande les deux (par exemple "que fait la classe la
        plus lente a analyser ?") -> appelle BenchAnalyst pour identifier la
        classe, PUIS DocSearch pour la decrire. Dans cet ordre.
    Le mot "analyze" designe a la fois une phase du pipeline et une etape interne
    de cette phase : si la question ne permet pas de trancher, demande la
    precision plutot que de deviner.
    N'appelle pas un outil pour une question qui ne porte pas sur ce projet ; dis
    simplement que ce n'est pas dans ton perimetre.

  response: |
    Reponds en francais, brievement, sans reformuler la question.
    Regles non negociables :
      - Ne donne aucun chiffre qui ne vienne pas d'un resultat de BenchAnalyst.
        Ne l'arrondis pas, ne l'extrapole pas, ne le convertis pas dans une autre
        unite sans le dire.
      - Une duree est en millisecondes : precise l'unite.
      - Ne jamais additionner des durees d'etapes pour repondre a une question de
        duree totale : les etapes de la phase analyze tournent en parallele.
      - Quand la reponse vient de la documentation, cite le fichier source.
      - Si l'outil ne renvoie rien d'exploitable, dis-le. Une absence de resultat
        est une reponse ; une invention n'en est pas une.

  sample_questions:
    - question: "Comment les factures sont-elles generees et notifiees ?"
    - question: "Combien de temps a dure la phase analyze ?"
    - question: "Quelle classe a ete la plus longue a analyser, et que fait-elle ?"
    - question: "Y a-t-il eu des echecs d'etape, et lesquels ?"

tools:
  - tool_spec:
      type: "cortex_search"
      name: "DocSearch"
      description: |
        Recherche dans la documentation textuelle du pipeline : specifications
        fonctionnelles des classes Java (ClientServiceBean, InvoiceGeneratorBean,
        OrderServiceBean, PaymentProcessorBean), rapports de migration, bilan de
        dette technique, risques et code smells, roadmap. Utiliser pour toute
        question de fonctionnement, de conception ou de decision. Ne contient
        aucune mesure chiffree d'execution.
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "BenchAnalyst"
      description: |
        Interroge les metriques d'execution du pipeline : duree totale par phase,
        duree par etape et par classe, nombre de fichiers traites, taux de succes,
        statut et message d'erreur des etapes. Deux executions sont couvertes, la
        phase analyze et la phase report. Utiliser pour toute question dont la
        reponse est un nombre ou un classement. Ne contient aucune description du
        code.

tool_resources:
  DocSearch:
    search_service: "LEGACY_AI_DB.CORE.LEGACY_DOCS_SEARCH"
    max_results: 5
    id_column: "DOC_ID"
    title_column: "SOURCE_FILE"
  BenchAnalyst:
    semantic_view: "LEGACY_AI_DB.CORE.SV_BENCHMARK"
    execution_environment:
      type: "warehouse"
      warehouse: "WH_AI_DEV"
$$;


/* -----------------------------------------------------------------------------
   Les quatre decisions de ce fichier, et pourquoi
   -----------------------------------------------------------------------------
   1. execution_environment.warehouse = WH_AI_DEV sur BenchAnalyst.
      Sans ce bloc, le SQL genere par l'agent s'execute sur le warehouse par
      defaut de l'utilisateur appelant — ici COMPUTE_WH, qui n'est PAS rattache
      au resource monitor RM_TRIAL (constat du 21/08, voir CLAUDE.md). Le
      garde-fou de cout serait contourne sans qu'aucun message ne le signale.
      Ces quatre lignes sont la piece la plus importante du fichier.

   2. budget: 60 s / 16000 tokens.
      Un agent boucle : il peut appeler un outil, lire le resultat, en rappeler
      un autre. Sans plafond, une question mal posee peut enchainer les appels.
      Le depassement se traduit par une reponse tronquee, pas par une erreur.

   3. max_results: 5 sur DocSearch.
      Le corpus fait 30 chunks (mesure du J2). Au-dela de 5, on ne gagne pas en
      rappel, on paie des tokens de contexte. Le J2 a montre que la bonne reponse
      sort en 1re ou 2e position quand elle sort.

   4. Les descriptions d'outils se terminent chacune par ce que l'outil NE
      contient PAS. C'est ce qui empeche l'agent d'aller chercher un chiffre dans
      la documentation, ou une explication dans les metriques. La description
      d'outil est le seul levier de routage : elle est lue par le modele
      d'orchestration a chaque question.
   ----------------------------------------------------------------------------- */


/* -----------------------------------------------------------------------------
   CE QUI A ETE OBSERVE EN CONDITIONS REELLES — 21/08/2026, 4 questions
   -----------------------------------------------------------------------------
   Trois ecarts entre la specification ci-dessus et la trace effective. Aucun
   n'invalide le fichier, mais les ignorer rend la trace illisible.

   1. BenchAnalyst n'est PAS un outil unique cote execution.
      La specification declare un outil `cortex_analyst_text_to_sql` nomme
      BenchAnalyst. A l'execution, l'agent emet en realite DEUX types d'appels :
        - un appel `system_agentic_semantic_context` portant le nom BenchAnalyst,
          qui selectionne la partie utile de la vue semantique (pruning) ;
        - puis un ou plusieurs `system_execute_sql`, qui portent le SQL genere.
      Compter les outils par nom declare sous-estime donc le nombre d'appels.
      DocSearch, lui, apparait bien tel quel, en `cortex_search`.

   2. L'agent RETENTE le SQL en cas d'erreur, et cela ne remonte pas.
      Sur « Combien de temps a dure la phase analyze ? », trois `system_execute_sql`
      ont echoue (statut=error) avant qu'un quatrieme aboutisse. La reponse finale
      est juste — 877 739 ms, conforme a eval/golden_questions.json q1 — et
      l'utilisateur ne voit rien de ces echecs sans --trace. Cause : la mesure
      n'est pas resolvable directement par son nom dans la vue semantique,
      l'agent tatonne jusqu'a la reconstruire en SUM(CASE WHEN ...). C'est un
      cout cache (4 appels au lieu d'1) et une piste d'amelioration pour
      SV_BENCHMARK, pas un bug de l'agent.

   3. La reponse contient un bloc `suggested_queries` non documente.
      Il arrive apres le bloc `text` final. src/ask.py l'ignore sans planter,
      parce qu'il parcourt par type — c'est exactement le cas que l'anti-pattern
      « parser par index de bloc » aurait casse.

   Non-determinisme : deux executions de la MEME question ont produit des traces
   differentes (3 puis 4 appels system_execute_sql). Ne pas traiter le nombre
   d'appels comme une constante.

   VERIFICATION DU GARDE-FOU DE COUT (le point 1 de la section precedente)
     Apres les 4 questions, INFORMATION_SCHEMA.QUERY_HISTORY filtre sur
     '%Generated by Cortex%' donne 11 requetes, warehouse WH_AI_DEV, et zero sur
     COMPUTE_WH. Le bloc execution_environment fait donc bien ce qu'on lui
     demande : le SQL de l'agent est facture sous le resource monitor RM_TRIAL.
   ----------------------------------------------------------------------------- */


-- -----------------------------------------------------------------------------
-- Controles post-creation (gratuits, aucun compute)
-- -----------------------------------------------------------------------------
SHOW AGENTS IN SCHEMA LEGACY_AI_DB.CORE;

DESCRIBE AGENT LEGACY_ASSISTANT;


/* -----------------------------------------------------------------------------
   Interrogation
   -----------------------------------------------------------------------------
   Il n'y a pas d'equivalent SQL de SEARCH_PREVIEW pour un agent : on l'interroge
   par l'API REST.

       POST /api/v2/databases/LEGACY_AI_DB/schemas/CORE/agents/LEGACY_ASSISTANT:run

   Client du projet, qui gere le JWT et parcourt la reponse par TYPE de bloc et
   non par index :

       python src/ask.py "Combien de temps a dure la phase analyze ?"
       python src/ask.py --trace "Quelle classe a ete la plus longue a analyser ?"

   -----------------------------------------------------------------------------
   Nettoyage de fin de session
   -----------------------------------------------------------------------------
   L'agent est un objet de configuration : il ne consomme rien au repos, il n'y a
   donc aucune raison de le supprimer entre deux sessions. Le service de recherche
   sous-jacent, lui, est facture au serving (voir docs/02, section 9).

       DROP AGENT IF EXISTS LEGACY_ASSISTANT;   -- seulement pour repartir a zero
   ----------------------------------------------------------------------------- */
