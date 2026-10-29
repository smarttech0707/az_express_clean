# Environnement de test isolé (Firebase + Android)

Statut : **préparé, rien n'est créé ni déployé.** Aucun projet Firebase n'a été créé ou modifié. Ce dossier ne contient
aucun secret. Le projet de production (`az-express-b0469`) n'est jamais une cible : tous les scripts le refusent.

## Constat sur la configuration existante
| Élément | État | Conséquence pour le test |
|---|---|---|
| `.firebaserc` | `default` = `az-express-b0469` (production) | **Toujours passer `--project <id-test>`** ; ne pas changer `default` |
| `lib/firebase_options.dart` | valeurs lues via `--dart-define` (aucun id en dur) | `test-env/dart-defines.test.json` suffit |
| `scripts/build_mobile.py` | exige `az-express-b0469` | ne pas l'utiliser pour le test ; utiliser `build-test-apk.ps1` |
| `android/app/google-services.json` | production, ignoré par git | jamais modifié : le fichier de test est posé temporairement dans `android/app/src/debug/` |
| `applicationId` Android | `com.azexpress.app` | suffixe `.test` via `-PazTestSuffix` (installation côte à côte, production non remplacée) |
| `functions/.env` | contient le vrai `FEEXPAY_SHOP_ID` | **hérité** par tout projet : `functions/.env.<id-test>` doit le surcharger (`DISABLED`) |
| `functions/index.js` | `PROJECT_ID` du webhook FeexPay | désormais `GCLOUD_PROJECT` (repli production) : plus de webhook de test vers la production |
| `lib/partner_qr/*`, `functions/partnerQr.js` | URL de production en dur | paquet QR isolé, non modifié : **ne pas tester les QR partenaires** sur le projet de test |

## Étapes à votre charge (aucune n'est exécutée par moi)
1. Créer le projet (nom contenant `test`, ex. `az-express-test`), plan Blaze requis pour Cloud Functions :
   `firebase projects:create az-express-test --display-name "AZ Express Test"`
2. Console du projet de test : activer **Authentication** (e-mail/mot de passe), **Firestore** (même région que la production),
   **Storage**, **Cloud Messaging**. Authentication > Sign-in method > **Téléphone** : n'ajouter que des « numéros de test »
   fictifs (code fixe, aucun SMS payant) si l'écran admin exige un OTP.
3. Enregistrer l'app Android `com.azexpress.app.test` (empreinte SHA-1 debug :
   `keytool -list -v -keystore $env:USERPROFILE\.android\debug.keystore -alias androiddebugkey -storepass android -keypass android`),
   télécharger son `google-services.json` (hors du dépôt).
4. Renseigner `test-env\dart-defines.test.json` (copie de `env\dart-defines.test.example.json`) et `functions\.env.<id-test>`
   (copie de `env\functions.env.test.example`).
5. Secrets Cloud Functions du projet de test (valeurs factices, jamais celles de production) :
   ```powershell
   foreach ($s in 'FEEXPAY_TOKEN','FEEXPAY_WEBHOOK_SECRET','GEMINI_API_KEY') { "DISABLED" | firebase functions:secrets:set $s --project <id-test> --data-file - }
   "<clé de test à plafond bas, ou DISABLED>" | firebase functions:secrets:set ANTHROPIC_API_KEY --project <id-test> --data-file -
   [guid]::NewGuid().ToString("N") | firebase functions:secrets:set DELIVERY_PROOF_PEPPER --project <id-test> --data-file -
   ```
6. Vérifier l'isolation (lecture seule, code retour 1 au moindre problème) :
   `node test-env\verify-isolation.js --env functions\.env.<id-test> --defines test-env\dart-defines.test.json --google-services <chemin\google-services.json de test>`
   (le dernier argument est lu avant la copie ; après `build-test-apk.ps1` le défaut `android\app\src\debug\google-services.json` s'applique).
7. Déployer **dans le projet de test seulement** (toujours `--project`) :
   `firebase deploy --project <id-test> --only firestore:rules,firestore:indexes,storage,functions`
8. Données fictives (2 livreurs, 1 client, 1 admin, 1 vendeur, produits, zones, soldes fictifs) :
   ```powershell
   $env:AZ_TEST_PASSWORD = "<mot de passe de test, 12+ caractères>"
   node test-env\seed-test-data.js --project <id-test> --confirm-project <id-test>
   ```
   Authentification : `GOOGLE_APPLICATION_CREDENTIALS` vers une clé de service **du projet de test** (jamais celle de production).
9. Construire et installer sur les téléphones :
   ```powershell
   powershell -ExecutionPolicy Bypass -File test-env\build-test-apk.ps1 -GoogleServices C:\chemin\google-services.test.json
   powershell -ExecutionPolicy Bypass -File test-env\install-test-apk.ps1
   ```
   Équivalent manuel de l'installation : `& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" devices -l` puis
   `adb -s <serie> install -r build\app\outputs\flutter-apk\app-debug.apk` pour chacun des deux téléphones.
10. Exécuter `docs/ANDROID_TEST_PLAN.md`.

## Essai sans projet (émulateurs locaux)
```powershell
$env:AZ_TEST_PASSWORD = "motdepasse-test-12"
npx firebase emulators:exec --config test-env/firebase.emulators.json --only firestore,auth --project demo-az-test "node test-env/seed-test-data.js --project demo-az-test --emulator"
```
(vérifié : écrit les comptes et les données, aucune connexion externe).

## Garanties
- `seed-test-data.js` refuse : projet de production, nom sans `test`/`staging`/`demo`, `GOOGLE_CLOUD_PROJECT`/`GCLOUD_PROJECT`
  visant la production, absence de `--confirm-project`, mot de passe < 12 caractères. Tests : `functions/test/testEnvGuards.test.js`.
- Comptes en `@az-test.invalid` (domaine réservé : aucun e-mail réel possible) ; soldes fictifs ; mots de passe jamais écrits.
- SMS : `DELIVERY_SMS_ENABLED=false`, fournisseur `none`. Paiements : FeexPay à `DISABLED`, aucun retrait possible.
- Après chaque build de test, `android/app/src/debug/google-services.json` est supprimé (les builds debug suivants ne visent pas le test).
- Suppression du projet de test à la fin de la campagne : à votre initiative.
