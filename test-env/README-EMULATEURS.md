# Tests sur émulateurs Firebase (projet local `demo-az-express`)

Aucun projet Firebase réel, aucun déploiement, aucun secret. `.firebaserc` et `firebase.json` ne sont pas modifiés
(`firebase use` n'est jamais appelé). Tous les scripts passent `--project demo-az-express` et `--config test-env/firebase.emulators.json`.

## Protections
| Risque | Protection |
|---|---|
| Fonctions → FeexPay, SMS, IA, FCM, tout service externe | `egressGuard.js` chargé avant tout code dans `emulator-entry.js` : toute connexion sortante hors boucle locale échoue (`AZ_EGRESS_BLOCKED`), couvre axios/https/fetch/http2/SDK. Prouvé : tests `emulatorEgressGuard.test.js` et appel réel d'`initiateFeexPayPayment` dans l'émulateur (bloqué, journalisé) |
| Hérédité de `functions/.env` et des secrets | Les fonctions tournent depuis une **copie** (`test-env/runtime/functions`) sans aucun `.env*` ni secret ; seuls `.env.demo-az-express` (SMS `false`, FeexPay `DISABLED`) et `.secret.local` (valeurs `DISABLED`, pepper aléatoire) existent. Évite aussi les appels à Google Secret Manager |
| Variables du shell (clés IA, FeexPay, credentials) | Retirées par `emulators-start.ps1` ; `verify-emulator-isolation.js --strict-env` échoue si elles subsistent |
| Identifiants Google par défaut (gcloud) | `CLOUDSDK_CONFIG` pointé sur un dossier vide au démarrage |
| Règles | Copies identiques de `firestore.rules`/`storage.rules` (vérifiées octet pour octet) |
| APK de test → production | `google-services.json` **factice** (projet `demo-…`) à la place de celui de production ; options Dart factices ; démarrage refusé si le projet n'est pas `demo-…` ou si l'adresse n'est pas locale ; aucune connexion de repli : émulateur injoignable = appels en échec ; FCM, Crashlytics, Analytics, App Check désactivés ; contrôle final de l'APK (aucun identifiant de production) |
| Paquet | `com.azexpress.app.test` (production non remplacée) |

## Commandes (PowerShell, depuis `D:\az_express_clean`)
```powershell
# 1. Vérifier l'isolation (lecture seule)
node test-env\stage-functions.js
node test-env\verify-emulator-isolation.js --strict-env

# 2. Vérifier les règles Firestore + Storage dans des émulateurs temporaires (366 + 120 tests)
powershell -ExecutionPolicy Bypass -File test-env\emulators-rules-check.ps1

# 3. Démarrer les émulateurs (ajouter -Persist pour garder les données)
powershell -ExecutionPolicy Bypass -File test-env\emulators-start.ps1

# 4. Données fictives (mot de passe demandé, 12 caractères minimum)
powershell -ExecutionPolicy Bypass -File test-env\emulators-seed.ps1

# 5. Arrêter
powershell -ExecutionPolicy Bypass -File test-env\emulators-stop.ps1
```
Interface : http://127.0.0.1:4000 (locale uniquement). Ports : Auth 9099, Firestore 8080, Functions 5001, Storage 9199.

## Téléphones Android (Samsung SM-A115F, Infinix X6525D)
1. PC et téléphones sur le même Wi-Fi **privé**. IP du PC : affichée par `emulators-start.ps1` (ou `Get-NetIPConfiguration`).
2. Pare-feu (administrateur, une fois) : `powershell -ExecutionPolicy Bypass -File test-env\emulators-firewall.ps1 -Action Add` (ports 5001, 8080, 9099, 9199, sous-réseau local ; `-Action Remove` pour retirer).
3. Construire : `powershell -ExecutionPolicy Bypass -File test-env\build-emulator-apk.ps1 -EmulatorHost <IP-du-PC>`
4. Installer : `powershell -ExecutionPolicy Bypass -File test-env\install-test-apk.ps1`
5. Exécuter `docs/ANDROID_TEST_PLAN.md`.

Équivalent Flutter à la main (déconseillé : n'applique pas le contrôle de l'APK) :
`flutter build apk --debug --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=EMULATOR_HOST=<IP>` avec
`--android-project-arg=azTestSuffix=.test` (une variable `ORG_GRADLE_PROJECT_*` n'est PAS transmise par Flutter) et le `google-services.json` factice (`node test-env\make-demo-google-services.js android\app\src\debug\google-services.json`, à supprimer ensuite).

## Limites connues
- Pas de notification push (FCM n'a pas d'émulateur) : les scénarios « notification reçue » ne sont pas testables ; les flux Firestore le sont.
- Cartes : la clé Google Maps de production n'est jamais incluse dans l'APK de test (cartes désactivées, clé vide). Pour activer les cartes, fournir explicitement une clé de TEST : `build-emulator-apk.ps1 -EmulatorHost <IP> -TestMapsKey <clé>` (la clé de production est refusée).
- Les fonctions planifiées (cron : expiration, remboursements 48 h, nettoyage) ne s'exécutent pas dans l'émulateur.
- Les émulateurs écoutent sur le réseau local (nécessaire aux téléphones) sans authentification d'accès : utiliser un Wi-Fi de confiance ; les règles Firestore/Storage restent appliquées.
- Le CLI Firebase connecté peut fournir des identifiants à l'émulateur Functions (« Application Default Credentials detected ») : sans effet, projet `demo-…` et sorties réseau bloquées.
- Node 24 de la machine est utilisé à la place de Node 22 (avertissement du CLI) ; à confirmer par un `npm test` déjà vert.
