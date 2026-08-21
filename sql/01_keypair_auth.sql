/* =============================================================================
   01_keypair_auth.sql — authentification par paire de cles pour l'utilisateur <TON_USER>
   -----------------------------------------------------------------------------
   A EXECUTER MANUELLEMENT DANS SNOWSIGHT. Ce script ne doit pas etre lance par
   un outil : il modifie le mode d'authentification, donc la capacite meme de se
   connecter. On le joue les yeux ouverts, dans une session deja etablie.

   POURQUOI
     Depuis l'enregistrement de la carte, le compte impose la MFA. La connexion
     par mot de passe simple echoue desormais :

         390197 (08001): Failed to connect to DB: <ton-compte>...
         Multi-factor authentication is required for this account.
         Log in to Snowsight to enroll.

     L'authentification par paire de cles est le mode prevu pour l'acces
     programmatique : elle satisfait l'exigence MFA sans declencher de push a
     chaque connexion. C'est le seul mode compatible avec un projet dont tous les
     scripts sont rejoues en boucle depuis la CLI.

   ROLE
     SECURITYADMIN, et non ACCOUNTADMIN : ALTER USER releve de la gestion des
     identites, pas de l'administration du compte. La regle projet qui confine
     ACCOUNTADMIN a sql/00_bootstrap.sql reste donc respectee.
     Si SECURITYADMIN n'est pas disponible, USERADMIN suffit egalement.

   LA CLE PRIVEE N'EST PAS DANS CE REPO
     Generee le 17/08/2026 par :

         openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM \
             -out rsa_key.p8 -nocrypt
         openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub

     Emplacement : %USERPROFILE%\.snowflake\rsa_key.p8 — hors du dossier git,
     ACL Windows restreintes au seul utilisateur courant (icacls /inheritance:r).
     Ce script ne contient AUCUNE valeur propre a un compte : la cle publique,
     l'utilisateur, l'identifiant de compte et l'empreinte sont des placeholders
     <entre chevrons>, a remplacer par les tiennes. Meme la cle publique, qui
     n'est pourtant pas un secret, en est un : elle n'aurait aucun sens chez
     quelqu'un d'autre.

     Empreinte SHA-256 de la cle publique, pour verification croisee avec la
     valeur que Snowflake renverra a l'etape 2 :

         <empreinte de TA cle>

     Elle se calcule en local, sans Snowflake :

         openssl rsa -pubin -in rsa_key.pub -outform DER \
             | openssl dgst -sha256 -binary | openssl enc -base64

     Et le corps base64 a coller a l'etape 1 s'obtient en retirant les deux
     lignes d'en-tete de rsa_key.pub puis en joignant le reste :

         python -c "print(''.join(l.strip() for l in open('rsa_key.pub') if 'KEY-----' not in l))"
   ============================================================================= */

USE ROLE SECURITYADMIN;


-- -----------------------------------------------------------------------------
-- 1. Poser la cle publique sur l'utilisateur
-- -----------------------------------------------------------------------------
-- La valeur est le corps base64 du fichier rsa_key.pub, en-tetes
-- -----BEGIN PUBLIC KEY----- / -----END PUBLIC KEY----- retires et sauts de
-- ligne supprimes. Snowflake refuse la cle si les en-tetes sont conserves.
ALTER USER <TON_USER> SET RSA_PUBLIC_KEY = '<coller la sortie de rsa_key.pub>';


-- -----------------------------------------------------------------------------
-- 2. Verifier que Snowflake a bien enregistre CETTE cle
-- -----------------------------------------------------------------------------
-- RSA_PUBLIC_KEY_FP doit valoir exactement :
--     SHA256:<ton empreinte>
-- Un ecart signifie que la valeur collee a l'etape 1 est tronquee ou alteree.
DESCRIBE USER <TON_USER>;

SELECT "property", "value"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "property" IN ('NAME', 'RSA_PUBLIC_KEY_FP', 'RSA_PUBLIC_KEY_2_FP', 'HAS_RSA_PUBLIC_KEY');


/* -----------------------------------------------------------------------------
   3. Ensuite, cote poste de travail
   -----------------------------------------------------------------------------
   ~/.snowflake/connections.toml a deja ete bascule sur la cle :

       [legacy_ai]
       account          = "<ton-compte>"
       user             = "<TON_USER>"
       private_key_file = "C:\\Users\\<toi>\\.snowflake\\rsa_key.p8"
       role             = "AI_ENGINEER_ROLE"
       ...

   Le mot de passe a ete retire du fichier : il ne sert plus a rien puisque la
   MFA le bloque, et un secret inutile qui traine reste un secret qui fuit.

   Test de bout en bout, sans rien creer ni facturer :

       python -c "import snowflake.connector as c; \
           print(c.connect(connection_name='legacy_ai').cursor() \
                  .execute('SELECT CURRENT_USER(), CURRENT_ROLE()').fetchone())"

   -----------------------------------------------------------------------------
   4. Rotation, le jour venu
   -----------------------------------------------------------------------------
   Snowflake accepte deux cles simultanement (RSA_PUBLIC_KEY et
   RSA_PUBLIC_KEY_2), precisement pour permettre une rotation sans coupure :
   poser la nouvelle sur le second emplacement, basculer connections.toml,
   verifier, puis liberer le premier.

       ALTER USER <TON_USER> SET   RSA_PUBLIC_KEY_2 = '<nouvelle cle publique>';
       ALTER USER <TON_USER> UNSET RSA_PUBLIC_KEY;

   Pour revoquer purement et simplement l'acces par cle :

       ALTER USER <TON_USER> UNSET RSA_PUBLIC_KEY;
   ----------------------------------------------------------------------------- */
