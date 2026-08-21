/* =============================================================================
   90_comparaison_diy.sql — refaire a la main ce que Cortex Search fait tout seul
   -----------------------------------------------------------------------------
   PEDAGOGIQUE. Ce fichier est l'exception prevue par CLAUDE.md a l'anti-pattern
   "colonne VECTOR geree manuellement" : il existe pour rendre visible le travail
   que le service manage absorbe, pas pour etre la solution du projet.

   Deux parties, toutes deux EXECUTEES le 17/08/2026, 2e session (le blocage trial sur
   EMBED_TEXT_768, constate en 1re session, a ete leve) :

     PARTIE A — DIY vectoriel     : embeddings a la main + VECTOR_COSINE_SIMILARITY
     PARTIE B — Baseline lexicale : TF-IDF en SQL pur, sans aucune fonction Cortex

   Resultats reportes dans docs/02-search-vs-diy.md, face a ceux du service
   manage (sql/31_search_tests.sql).

   COUT
     La partie A embedde les 30 chunks une fois (~10 k tokens), puis une fois par
     question posee. Ordre de grandeur : une fraction de credit. Le MERGE de A2
     est incremental — le rejouer sans changement du corpus ne re-embedde rien.
   ============================================================================= */

USE ROLE      AI_ENGINEER_ROLE;
USE WAREHOUSE WH_AI_DEV;
USE DATABASE  LEGACY_AI_DB;
USE SCHEMA    CORE;


/* =============================================================================
   PARTIE A — DIY VECTORIEL
   =============================================================================
   Les etapes que Cortex Search execute a notre place, ecrites explicitement.
   ============================================================================= */

-- -----------------------------------------------------------------------------
-- A1. Une table de vecteurs, et le choix irreversible de la dimension
-- -----------------------------------------------------------------------------
-- La dimension est dans le TYPE de la colonne : VECTOR(FLOAT, 768). Changer pour
-- un modele de dimension differente (EMBED_TEXT_1024) impose un ALTER TABLE et
-- un recalcul complet. Le service manage prend le meme engagement
-- (EMBEDDING_MODEL immuable apres CREATE), mais sans qu'on ait a modeliser quoi
-- que ce soit ni a se souvenir du chiffre.
CREATE TABLE IF NOT EXISTS LEGACY_DOCS_VEC (
    doc_id        VARCHAR(64) NOT NULL,
    doc_content   VARCHAR     NOT NULL,
    doc_type      VARCHAR,
    java_class    VARCHAR,
    source_file   VARCHAR,
    chunk_index   NUMBER(38,0),
    embedding     VECTOR(FLOAT, 768),
    embedded_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),

    CONSTRAINT PK_LEGACY_DOCS_VEC PRIMARY KEY (doc_id)
)
COMMENT = 'Copie vectorisee de LEGACY_DOCS — pedagogique. Non utilisee par l''agent.';


-- -----------------------------------------------------------------------------
-- A2. Le remplissage — toute la logique d'incrementalite a notre charge
-- -----------------------------------------------------------------------------
-- Ce MERGE n'embedde que les chunks nouveaux ou modifies. Sans cette precaution,
-- chaque execution repaierait l'integralite du corpus en tokens. C'est
-- exactement le raisonnement que TARGET_LAG encapsule cote service — sauf qu'ici
-- il faut l'ecrire, le tester, et penser a le rejouer.
MERGE INTO LEGACY_DOCS_VEC v
USING (SELECT doc_id, doc_content, doc_type, java_class, source_file, chunk_index
         FROM LEGACY_DOCS) d
   ON v.doc_id = d.doc_id
WHEN MATCHED AND v.doc_content <> d.doc_content THEN UPDATE SET
    v.doc_content = d.doc_content,
    v.embedding   = SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m-v1.5', d.doc_content),
    v.embedded_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (doc_id, doc_content, doc_type, java_class, source_file, chunk_index, embedding)
    VALUES (d.doc_id, d.doc_content, d.doc_type, d.java_class, d.source_file, d.chunk_index,
            SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m-v1.5', d.doc_content));


-- -----------------------------------------------------------------------------
-- A2bis. Le DELETE que le service n'exige pas
-- -----------------------------------------------------------------------------
-- Un chunk disparu de LEGACY_DOCS (re-chunking, fichier retire) laisserait son
-- vecteur orphelin dans LEGACY_DOCS_VEC, et il continuerait a remonter dans les
-- resultats. Cortex Search, lui, suit sa requete AS : rien a ecrire.
-- C'est la troisieme branche du MERGE qu'on oublie systematiquement.
DELETE FROM LEGACY_DOCS_VEC
 WHERE doc_id NOT IN (SELECT doc_id FROM LEGACY_DOCS);


-- Controle : couverture et horodatage des embeddings.
SELECT
    COUNT(*)                                        AS vecteurs,
    COUNT(embedding)                                AS non_nuls,
    (SELECT COUNT(*) FROM LEGACY_DOCS)              AS chunks_source,
    MIN(embedded_at)                                AS premier_embedding,
    MAX(embedded_at)                                AS dernier_embedding
FROM LEGACY_DOCS_VEC;


/* -----------------------------------------------------------------------------
   A2ter. LE PIEGE QUI COUTE LA BONNE REPONSE : l'embedding asymetrique
   -----------------------------------------------------------------------------
   Les modeles de la famille snowflake-arctic-embed sont ASYMETRIQUES : ils
   attendent que les DOCUMENTS soient embeddes tels quels, mais que les REQUETES
   soient prefixees par une instruction. Sans ce prefixe, on compare une question
   a des documents dans deux espaces qui ne se correspondent pas tout a fait.

   Mesure du 17/08/2026 sur la question "Comment le traitement d'un paiement
   est-il implemente ?", memes 30 vecteurs, seul le traitement de la requete change :

       SANS prefixe                          AVEC prefixe
       0.7044  OrderServiceBean      ck 5    0.3885  PaymentProcessorBean  ck 9
       0.7044  OrderServiceBean      ck 12   0.3885  PaymentProcessorBean  ck 16
       0.6952  PaymentProcessorBean  ck 9    0.3595  (dependencies.md)     ck 0
       0.6952  PaymentProcessorBean  ck 16   0.3533  PaymentProcessorBean  ck 10

   Sans prefixe, la question sur le PAIEMENT renvoie OrderServiceBean en tete.
   C'est FAUX, et rien ne le signale : 0.7044 est un score d'apparence tres
   convaincante, plus eleve meme que le 0.3885 de la version correcte.

   DEUX LECONS, dans cet ordre d'importance :
     1. Un score eleve ne veut rien dire dans l'absolu. Baisser de 0.69 a 0.39
        n'est pas une regression : les deux series vivent dans des geometries
        differentes et ne sont pas comparables entre elles. Seul l'ORDRE compte,
        et c'est l'ordre qui se corrige.
     2. L'erreur est silencieuse. Pas d'exception, pas d'avertissement, pas de
        NULL — juste un classement faux. C'est la categorie de bug la plus chere
        a decouvrir, et elle est ici a une ligne de distance.

   Le prefixe ne s'applique QU'A LA REQUETE. Le mettre aussi sur les documents
   (dans le MERGE de A2) reintroduirait la symetrie et annulerait le benefice.

   A noter enfin : meme prefixee, la serie DIY (0.3885) ne reproduit pas les
   valeurs de Cortex Search (0.4601 sur la meme question, cf. requete 1 de
   sql/31_search_tests.sql). Le service applique donc bien un traitement
   asymetrique de la requete, mais PAS exactement ce prefixe-la. Sa transformation
   exacte n'est pas observable depuis l'exterieur, et il ne faut pas pretendre
   l'avoir reproduite — seulement en avoir identifie le mecanisme.

   ET LE PREFIXE NE SUFFIT PAS. Sur la question des factures (bloc A4), le DIY
   vectoriel correctement prefixe classe toujours InvoiceGeneratorBean aux rangs
   10 et 11 sur 30, quand Cortex Search le place 1er et 2e. Le prefixe corrige
   une erreur d'usage du modele ; il ne fournit ni le volet lexical, ni le
   reranker. Voir docs/02-search-vs-diy.md pour le detail de cet ecart.
   ----------------------------------------------------------------------------- */
SET Q_PREFIX = 'Represent this sentence for searching relevant passages: ';


-- -----------------------------------------------------------------------------
-- A3. La recherche
-- -----------------------------------------------------------------------------
-- La question doit etre embeddee AVEC LE MEME MODELE que les documents, ET avec
-- le prefixe de requete. Rien dans le schema ne garantit ni l'un ni l'autre :
-- ce sont deux conventions a tenir a la main, silencieuses toutes les deux si
-- on les rompt.
--
-- Le sous-appel EMBED_TEXT_768 est re-evalue et refacture a CHAQUE requete.
-- Cortex Search embedde la question une fois, cote service.
-- On isole donc le vecteur de la question dans un CTE : sans cela, l'expression
-- apparait trois fois (SELECT, ROW_NUMBER, ORDER BY) et rien ne garantit qu'elle
-- ne soit pas evaluee — et facturee — plusieurs fois.
SET Q = 'Comment le traitement d''un paiement est-il implemente ?';

WITH qv AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m-v1.5', $Q_PREFIX || $Q) AS v
)
SELECT
    ROW_NUMBER() OVER (ORDER BY VECTOR_COSINE_SIMILARITY(d.embedding, qv.v) DESC,
                            d.source_file, d.chunk_index) AS rang,
    ROUND(VECTOR_COSINE_SIMILARITY(d.embedding, qv.v), 4)                         AS cosinus,
    d.java_class,
    d.source_file,
    d.chunk_index,
    LEFT(REPLACE(d.doc_content, CHR(10), ' '), 160)                               AS extrait
FROM LEGACY_DOCS_VEC d CROSS JOIN qv
ORDER BY cosinus DESC, source_file, chunk_index
LIMIT 5;


-- -----------------------------------------------------------------------------
-- A4. Le test morphologique, cote vectoriel
-- -----------------------------------------------------------------------------
-- Meme question que la requete 4 de sql/31_search_tests.sql et que le bloc B3
-- ci-dessous. C'est le point de comparaison central des trois approches :
--   - lexical DIY   : rate les chunks InvoiceGeneratorBean (un "s" de difference)
--   - vectoriel DIY : ?
--   - Cortex Search : les place 1er et 2e, avec text_match = 0.0
SET Q = 'Comment les factures sont-elles generees et notifiees ?';

WITH qv AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m-v1.5', $Q_PREFIX || $Q) AS v
)
SELECT
    ROW_NUMBER() OVER (ORDER BY VECTOR_COSINE_SIMILARITY(d.embedding, qv.v) DESC,
                            d.source_file, d.chunk_index) AS rang,
    ROUND(VECTOR_COSINE_SIMILARITY(d.embedding, qv.v), 4)                         AS cosinus,
    d.java_class,
    d.doc_type,
    d.chunk_index,
    LEFT(REPLACE(d.doc_content, CHR(10), ' '), 160)                               AS extrait
FROM LEGACY_DOCS_VEC d CROSS JOIN qv
ORDER BY cosinus DESC, source_file, chunk_index
LIMIT 5;


-- -----------------------------------------------------------------------------
-- A5. Le filtre par attribut
-- -----------------------------------------------------------------------------
-- Seul endroit ou le DIY est PLUS simple : un WHERE ordinaire, sur n'importe
-- quelle colonne, sans avoir a la declarer en ATTRIBUTES au moment du CREATE —
-- donc sans DROP + CREATE pour en ajouter une.
-- Mais c'est un scan complet suivi d'un tri : a 30 chunks c'est instantane, a
-- 1 M de chunks c'est le probleme que les index vectoriels existent pour resoudre.
-- A comparer a la requete 7 de sql/31_search_tests.sql, meme question, meme filtre.
SET Q = 'Comment le solde du compte est-il verifie avant de deduire un montant ?';

WITH qv AS (
    SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_768('snowflake-arctic-embed-m-v1.5', $Q_PREFIX || $Q) AS v
)
SELECT
    ROW_NUMBER() OVER (ORDER BY VECTOR_COSINE_SIMILARITY(d.embedding, qv.v) DESC,
                            d.source_file, d.chunk_index) AS rang,
    ROUND(VECTOR_COSINE_SIMILARITY(d.embedding, qv.v), 4)                         AS cosinus,
    d.java_class,
    d.source_file,
    d.chunk_index,
    LEFT(REPLACE(d.doc_content, CHR(10), ' '), 160)                               AS extrait
FROM LEGACY_DOCS_VEC d CROSS JOIN qv
WHERE d.java_class = 'PaymentProcessorBean'
ORDER BY cosinus DESC, source_file, chunk_index
LIMIT 5;


/* -----------------------------------------------------------------------------
   A6. Ce que la partie A ne reproduit toujours PAS
   -----------------------------------------------------------------------------
   Elle reproduit la recherche vectorielle, et rien d'autre :
     - pas de recherche lexicale ni de fusion des deux classements — Cortex Search
       expose text_match ET cosine_similarity, la preuve qu'il fait les deux ;
     - pas de reranking des candidats (reranker_score cote service) ;
     - pas de rafraichissement automatique sur changement de LEGACY_DOCS : il faut
       rejouer le MERGE et le DELETE a la main ;
     - pas de troncature des textes depassant la fenetre du modele d'embedding ;
     - pas de service d'interrogation — chaque question reveille le warehouse et
       re-embedde la question.
   C'est la vraie reponse a "qu'est-ce que le service fait a ma place".

   NETTOYAGE — LEGACY_DOCS_VEC est un objet pedagogique, pas un actif du projet.
   Il double le stockage du corpus et n'est utilise par aucun autre script.
   A supprimer en fin de session de travail :

       DROP TABLE IF EXISTS LEGACY_DOCS_VEC;
   ----------------------------------------------------------------------------- */


/* =============================================================================
   PARTIE B — BASELINE LEXICALE (executable, et executee)
   =============================================================================
   Troisieme point de comparaison, le plus ancien historiquement : on construit
   un TF-IDF a la main, en SQL pur, sans aucune
   fonction Cortex. C'est le "avant" historique de la recherche documentaire, et
   il a le merite de produire des chiffres reels sur ce compte, aujourd'hui.

   Ce qu'il fait :   normalisation (minuscules, accents, ponctuation), tokenisation,
                     anti-dictionnaire, TF-IDF, normalisation par longueur.
   Ce qu'il ne fait pas : aucune notion de sens, et pas meme de morphologie.
                     "facture" et "factures" sont deux chaines sans rapport pour
                     lui. C'est l'ecart que la recherche semantique est censee
                     combler, et la requete B3 le rend visible, chiffres a l'appui.
   ============================================================================= */

-- Question courante. Les trois blocs ci-dessous la relisent via $Q.
SET Q = 'Comment le traitement d''un paiement est-il implemente ?';


-- -----------------------------------------------------------------------------
-- B1. Le moteur : une seule requete, reutilisee telle quelle
-- -----------------------------------------------------------------------------
-- TRANSLATE fait le repliement des accents (Snowflake n'a pas d'unaccent) ; la
--   liste des deux cotes doit avoir la meme longueur, caractere pour caractere.
-- REGEXP_REPLACE reduit tout ce qui n'est pas alphanumerique a une espace, ce
--   qui evacue d'un coup la ponctuation, le markdown et les backticks du code.
-- SPLIT_TO_TABLE fait la tokenisation. LENGTH >= 3 elimine le bruit court.
-- L'anti-dictionnaire est ecrit en dur : sur un corpus francais de 30 chunks,
--   sans lui, "comment", "est", "les" dominent le score et noient le signal.
-- Ponderation : (1 + LN(tf)) * LN(1 + N / df), somme sur les termes de la
--   question, divisee par SQRT(longueur du document) pour ne pas favoriser les
--   chunks longs. Lisible plutot qu'optimale — BM25 ferait mieux, au prix de
--   deux parametres a regler.
--   Le "1 +" dans l'IDF n'est pas cosmetique : voir la note de B2, ou la version
--   non lissee LN(N/df) a produit QUATRE SCORES EXACTEMENT NULS (mesure).
WITH stop AS (
    SELECT column1 AS term FROM VALUES
        ('les'),('des'),('une'),('est'),('elle'),('pour'),('dans'),('par'),('sur'),
        ('avec'),('que'),('qui'),('quel'),('quels'),('quelle'),('quelles'),('comment'),
        ('sont'),('ete'),('etre'),('cette'),('ces'),('son'),('ses'),('leur'),('leurs'),
        ('aux'),('plus'),('pas'),('mais'),('ont'),('fait'),('faire'),('peut'),('doit'),
        ('the'),('and'),('for'),('with'),('this'),('that'),('from'),('via')
),
folded AS (
    SELECT
        doc_id, source_file, doc_type, java_class, chunk_index, doc_content,
        REGEXP_REPLACE(
            TRANSLATE(LOWER(doc_content),
                      'àâäãéèêëíìîïóòôöõúùûüçñ',
                      'aaaaeeeeiiiiooooouuuucn'),
            '[^a-z0-9]+', ' ') AS txt
    FROM LEGACY_DOCS
),
doc_terms AS (
    SELECT f.doc_id, t.value::VARCHAR AS term
    FROM folded f, LATERAL SPLIT_TO_TABLE(f.txt, ' ') t
    WHERE LENGTH(t.value) >= 3
),
q_terms AS (
    SELECT DISTINCT t.value::VARCHAR AS term
    FROM (SELECT REGEXP_REPLACE(
                     TRANSLATE(LOWER($Q),
                               'àâäãéèêëíìîïóòôöõúùûüçñ',
                               'aaaaeeeeiiiiooooouuuucn'),
                     '[^a-z0-9]+', ' ') AS q) qq,
         LATERAL SPLIT_TO_TABLE(qq.q, ' ') t
    WHERE LENGTH(t.value) >= 3
      AND t.value NOT IN (SELECT term FROM stop)
),
corpus AS (SELECT COUNT(*) AS n_docs FROM LEGACY_DOCS),
doc_len AS (SELECT doc_id, COUNT(*) AS n_tokens FROM doc_terms GROUP BY doc_id),
tf      AS (SELECT dt.doc_id, dt.term, COUNT(*) AS tf
              FROM doc_terms dt JOIN q_terms q ON q.term = dt.term
             GROUP BY dt.doc_id, dt.term),
df      AS (SELECT term, COUNT(DISTINCT doc_id) AS df FROM tf GROUP BY term)
SELECT
    f.source_file,
    f.chunk_index,
    f.java_class,
    COUNT(*)                                                   AS termes_apparies,
    ROUND(SUM((1 + LN(tf.tf)) * LN(1 + c.n_docs / df.df)) / SQRT(dl.n_tokens), 4) AS score,
    LEFT(REPLACE(f.doc_content, CHR(10), ' '), 200)            AS extrait
FROM tf
JOIN df      ON df.term  = tf.term
JOIN folded  f  ON f.doc_id  = tf.doc_id
JOIN doc_len dl ON dl.doc_id = tf.doc_id
CROSS JOIN corpus c
GROUP BY f.source_file, f.chunk_index, f.java_class, f.doc_content, dl.n_tokens
ORDER BY score DESC
LIMIT 5;


-- -----------------------------------------------------------------------------
-- B2. Le filtre par attribut, cote DIY
-- -----------------------------------------------------------------------------
-- Equivalent de la requete 7 de sql/31_search_tests.sql. Un WHERE suffit : c'est
-- le seul point ou le DIY est plus court ET plus souple que le service (aucune
-- colonne a declarer d'avance en ATTRIBUTES). Le prix est ailleurs — le scan.
--
-- PIEGE MESURE LE 17/08/2026, a garder dans ce fichier parce qu'il est instructif
-- -----------------------------------------------------------------------------
-- Avec l'IDF non lisse LN(N/df), cette requete a renvoye QUATRE LIGNES DE SCORE
-- 0.0 — pas une erreur, une degenerescence arithmetique :
--
--     filtre java_class = 'PaymentProcessorBean'  ->  sous-corpus de N = 4 chunks
--     df('solde')   = 4     df('compte')  = 4
--     df('montant') = 4     df('verifie') = 4      (mesure, cf. docs/02)
--     => LN(N/df) = LN(4/4) = LN(1) = 0 pour CHAQUE terme
--     => score = 0 partout, et l'ordre des resultats devient arbitraire.
--
-- Un terme present dans tous les documents n'apporte aucune information : c'est
-- le comportement voulu de l'IDF. Mais sur un sous-corpus etroit, TOUS les
-- termes utiles deviennent universels, et la ponderation s'effondre entierement.
-- Plus le filtre est selectif, plus le classement se degrade — exactement
-- l'inverse de ce qu'on attend d'un filtre.
--
-- D'ou le lissage LN(1 + N/df), applique ici et dans B1/B3 : il conserve
-- l'ordre relatif des termes tout en gardant l'IDF strictement positif.
-- C'est le genre d'arbitrage que le service manage ne laisse jamais arriver
-- jusqu'a l'utilisateur.
SET Q = 'Comment le solde du compte est-il verifie avant de deduire un montant ?';

WITH stop AS (
    SELECT column1 AS term FROM VALUES
        ('les'),('des'),('une'),('est'),('elle'),('pour'),('dans'),('par'),('sur'),
        ('avec'),('que'),('qui'),('quel'),('quels'),('quelle'),('quelles'),('comment'),
        ('sont'),('ete'),('etre'),('cette'),('ces'),('son'),('ses'),('leur'),('leurs'),
        ('aux'),('plus'),('pas'),('mais'),('ont'),('fait'),('faire'),('peut'),('doit'),
        ('avant'),('the'),('and'),('for'),('with'),('this'),('that'),('from'),('via')
),
folded AS (
    SELECT doc_id, source_file, doc_type, java_class, chunk_index, doc_content,
           REGEXP_REPLACE(TRANSLATE(LOWER(doc_content),
                                    'àâäãéèêëíìîïóòôöõúùûüçñ',
                                    'aaaaeeeeiiiiooooouuuucn'),
                          '[^a-z0-9]+', ' ') AS txt
    FROM LEGACY_DOCS
    WHERE java_class = 'PaymentProcessorBean'        -- <- le filtre
),
doc_terms AS (
    SELECT f.doc_id, t.value::VARCHAR AS term
    FROM folded f, LATERAL SPLIT_TO_TABLE(f.txt, ' ') t
    WHERE LENGTH(t.value) >= 3
),
q_terms AS (
    SELECT DISTINCT t.value::VARCHAR AS term
    FROM (SELECT REGEXP_REPLACE(TRANSLATE(LOWER($Q),
                                          'àâäãéèêëíìîïóòôöõúùûüçñ',
                                          'aaaaeeeeiiiiooooouuuucn'),
                                '[^a-z0-9]+', ' ') AS q) qq,
         LATERAL SPLIT_TO_TABLE(qq.q, ' ') t
    WHERE LENGTH(t.value) >= 3 AND t.value NOT IN (SELECT term FROM stop)
),
corpus  AS (SELECT COUNT(*) AS n_docs FROM folded),
doc_len AS (SELECT doc_id, COUNT(*) AS n_tokens FROM doc_terms GROUP BY doc_id),
tf      AS (SELECT dt.doc_id, dt.term, COUNT(*) AS tf
              FROM doc_terms dt JOIN q_terms q ON q.term = dt.term
             GROUP BY dt.doc_id, dt.term),
df      AS (SELECT term, COUNT(DISTINCT doc_id) AS df FROM tf GROUP BY term)
SELECT
    f.source_file, f.chunk_index, f.java_class,
    COUNT(*) AS termes_apparies,
    ROUND(SUM((1 + LN(tf.tf)) * LN(1 + c.n_docs / GREATEST(df.df,1))) / SQRT(dl.n_tokens), 4) AS score,
    LEFT(REPLACE(f.doc_content, CHR(10), ' '), 200) AS extrait
FROM tf
JOIN df      ON df.term  = tf.term
JOIN folded  f  ON f.doc_id  = tf.doc_id
JOIN doc_len dl ON dl.doc_id = tf.doc_id
CROSS JOIN corpus c
GROUP BY f.source_file, f.chunk_index, f.java_class, f.doc_content, dl.n_tokens
ORDER BY score DESC
LIMIT 5;


-- -----------------------------------------------------------------------------
-- B3. Le test qui doit echouer — et dont l'echec est le resultat
-- -----------------------------------------------------------------------------
-- Pendant DIY de la requete 4 de sql/31_search_tests.sql.
--
-- L'hypothese de depart etait un ecart francais/anglais : le corpus dirait
-- "invoices" la ou la question dit "factures". VERIFICATION FAITE, C'EST FAUX —
-- les deux chunks qui documentent InvoiceGeneratorBean contiennent "facture"
-- 3 fois ET "invoice(s)" 4 fois. Le corpus est bilingue, la question ne l'est pas
-- moins que lui.
--
-- L'echec reel est MORPHOLOGIQUE, et il est plus interessant. Sur les 30 chunks
-- (mesure du 17/08/2026, cf. docs/02-search-vs-diy.md) :
--
--     forme du corpus          df        forme de la question     df
--     facture ............... 5         factures .............. 1
--     generation ............ 11        generees .............. 1
--     notification(s) ....... 4 / 8     notifiees ............. 0
--
-- Les formes que la question emploie sont quasi absentes ; celles que le corpus
-- emploie ne sont pas cherchees. Resultat attendu : les deux chunks
-- InvoiceGeneratorBean — la bonne reponse — ne remontent PAS, et le seul chunk
-- retourne l'est parce qu'il contient par hasard les formes plurielles exactes.
--
-- Sans racinisation ni lemmatisation, un "s" suffit a manquer la reponse. Ecrire
-- un stemmer francais correct est un projet en soi ; c'est l'une des choses que
-- l'embedding rend inutiles, et elle ne se voit nulle part dans le code du
-- service manage.
SET Q = 'Comment les factures sont-elles generees et notifiees ?';

WITH stop AS (
    SELECT column1 AS term FROM VALUES
        ('les'),('des'),('une'),('est'),('elle'),('elles'),('pour'),('dans'),('par'),
        ('sur'),('avec'),('que'),('qui'),('comment'),('sont'),('ete'),('etre'),
        ('the'),('and'),('for'),('with'),('this'),('that'),('from'),('via')
),
folded AS (
    SELECT doc_id, source_file, doc_type, java_class, chunk_index, doc_content,
           REGEXP_REPLACE(TRANSLATE(LOWER(doc_content),
                                    'àâäãéèêëíìîïóòôöõúùûüçñ',
                                    'aaaaeeeeiiiiooooouuuucn'),
                          '[^a-z0-9]+', ' ') AS txt
    FROM LEGACY_DOCS
),
doc_terms AS (
    SELECT f.doc_id, t.value::VARCHAR AS term
    FROM folded f, LATERAL SPLIT_TO_TABLE(f.txt, ' ') t
    WHERE LENGTH(t.value) >= 3
),
q_terms AS (
    SELECT DISTINCT t.value::VARCHAR AS term
    FROM (SELECT REGEXP_REPLACE(TRANSLATE(LOWER($Q),
                                          'àâäãéèêëíìîïóòôöõúùûüçñ',
                                          'aaaaeeeeiiiiooooouuuucn'),
                                '[^a-z0-9]+', ' ') AS q) qq,
         LATERAL SPLIT_TO_TABLE(qq.q, ' ') t
    WHERE LENGTH(t.value) >= 3 AND t.value NOT IN (SELECT term FROM stop)
),
corpus  AS (SELECT COUNT(*) AS n_docs FROM LEGACY_DOCS),
doc_len AS (SELECT doc_id, COUNT(*) AS n_tokens FROM doc_terms GROUP BY doc_id),
tf      AS (SELECT dt.doc_id, dt.term, COUNT(*) AS tf
              FROM doc_terms dt JOIN q_terms q ON q.term = dt.term
             GROUP BY dt.doc_id, dt.term),
df      AS (SELECT term, COUNT(DISTINCT doc_id) AS df FROM tf GROUP BY term)
SELECT
    f.source_file, f.chunk_index, f.java_class,
    COUNT(*) AS termes_apparies,
    ROUND(SUM((1 + LN(tf.tf)) * LN(1 + c.n_docs / df.df)) / SQRT(dl.n_tokens), 4) AS score,
    LEFT(REPLACE(f.doc_content, CHR(10), ' '), 200) AS extrait
FROM tf
JOIN df      ON df.term  = tf.term
JOIN folded  f  ON f.doc_id  = tf.doc_id
JOIN doc_len dl ON dl.doc_id = tf.doc_id
CROSS JOIN corpus c
GROUP BY f.source_file, f.chunk_index, f.java_class, f.doc_content, dl.n_tokens
ORDER BY score DESC
LIMIT 5;


-- -----------------------------------------------------------------------------
-- B4. Le controle qui rend B3 concluant
-- -----------------------------------------------------------------------------
-- B3 seul ne prouve rien : peut-etre qu'aucun chunk ne parle de facturation.
-- Ce bloc etablit que la bonne reponse EXISTE bien dans le corpus, et que la
-- baseline lexicale est passee a cote. Aucun score, juste des occurrences.
SELECT
    source_file,
    chunk_index,
    java_class,
    REGEXP_COUNT(LOWER(doc_content), 'facture')  AS occ_facture,
    REGEXP_COUNT(LOWER(doc_content), 'invoice')  AS occ_invoice,
    LEFT(REPLACE(doc_content, CHR(10), ' '), 160) AS extrait
FROM LEGACY_DOCS
WHERE java_class = 'InvoiceGeneratorBean'
ORDER BY source_file, chunk_index;
