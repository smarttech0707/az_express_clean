# Procédure — projet Firebase de préproduction AZ Express (tests Samsung)

**Statut : PROCÉDURE PRÉPARÉE, NON EXÉCUTÉE.** Rien n'est créé, aucune facturation activée, aucun déploiement. Chaque étape marquée
**[VOTRE ACCORD]** crée une ressource cloud ou engage un coût : elle n'est faite qu'avec votre autorisation explicite.
Production : `az-express-b0469` — **jamais une cible**. Outils déjà présents : `test-env/` (voir `test-env/README.md`).

Convention : `$TEST` = `az-express-preprod` (identifiant retenu). Toute commande `firebase` porte `--project $TEST`.
Le fichier `.firebaserc` (défaut = production) n'est **jamais** modifié.

## 0. Disponibilité de l'identifiant (vérifiée le 2026-10-30, lecture seule)

- `firebase projects:list` : un seul projet dans votre compte (`az-express-b0469`) — `az-express-preprod` n'existe pas chez vous.
- `gcloud projects describe az-express-preprod` : accès refusé (ce message est le même pour un identifiant libre et pour un identifiant pris par un tiers : **non concluant**).
- `https://az-express-preprod.web.app` et `.firebaseapp.com` : « Site Not Found », identique à un identifiant inexistant : **aucun conflit visible**.
- Conclusion : **aucun indice d'indisponibilité, mais seule la création le confirme** (`projects:create` échoue si l'identifiant est pris, y compris par un projet supprimé depuis moins de 30 jours).
  Repli : `az-express-preprod-1`, puis `azx-preprod`. Dans ce cas, mettre à jour le paramètre `-Project` de `test-env/deploy-preprod.ps1` (qui n'accepte que l'identifiant prévu).

## A. Création du projet [VOTRE ACCORD]

1. `firebase projects:create $TEST --display-name "AZ Express Préproduction"` (compte Google dédié recommandé, pas celui de la production).
2. Console Google Cloud du projet de test : lier un compte de facturation (**plan Blaze obligatoire** pour Cloud Functions [VOTRE ACCORD]).
   **Une alerte de budget n'est PAS une limite de dépenses** : elle envoie seulement un e-mail, les services continuent de facturer. Pour borner réellement le coût :
   (a) alerte à 5 USD (50 %, 90 %, 100 %) pour être prévenu ; (b) `maxInstances` bas sur les fonctions de test (déjà le cas) ; (c) aucun trafic public, aucune clé API non restreinte ;
   (d) en cas de dérive : désactiver la facturation du projet de test ou le supprimer (arrêt immédiat des services payants, à faire à la main) ; (e) suppression du projet en fin de campagne.
3. Console Firebase : activer **Authentication** (e-mail/mot de passe), **Firestore** (mode production, région `europe-west1`),
   **Storage** (région identique), **Cloud Messaging**.
   Authentication > Méthode de connexion > Téléphone : uniquement des « numéros de test » fictifs.
4. Ne pas activer App Check ni Analytics pour ce projet.

## B. Application Android de test

5. Enregistrer l'app Android `com.azexpress.app.test` (suffixe `.test` : s'installe à côté de la production, ne la remplace pas).
   SHA-1 debug : `keytool -list -v -keystore $env:USERPROFILE\.android\debug.keystore -alias androiddebugkey -storepass android -keypass android`.
6. Télécharger son `google-services.json` **hors du dépôt** (ex. `C:\az-test\google-services.test.json`).
7. `copy test-env\env\dart-defines.test.example.json test-env\dart-defines.test.json` puis renseigner les valeurs **du projet de test**.
8. `copy test-env\env\functions.env.test.example functions\.env.$TEST` : FeexPay / SMS = `DISABLED`.

## C. Secrets factices (jamais ceux de la production)

```powershell
foreach ($s in 'FEEXPAY_TOKEN','FEEXPAY_WEBHOOK_SECRET','GEMINI_API_KEY') { "DISABLED" | firebase functions:secrets:set $s --project $TEST --data-file - }
"DISABLED" | firebase functions:secrets:set ANTHROPIC_API_KEY --project $TEST --data-file -
[guid]::NewGuid().ToString("N") | firebase functions:secrets:set DELIVERY_PROOF_PEPPER --project $TEST --data-file -
```

## D. Contrôle d'isolation (obligatoire, code retour 0 attendu)

```powershell
node test-env\verify-isolation.js --env functions\.env.$TEST --defines test-env\dart-defines.test.json --google-services C:\az-test\google-services.test.json
```
Arrêt immédiat si le code retour est différent de 0 (un identifiant ou une clé de production a été détecté).

## E. Déploiement dans le projet de test uniquement [VOTRE ACCORD]

Source = **l'arbre isolé** (`C:\Users\User\AppData\Local\Temp\az_isolated_reliability`), pas l'arbre de travail mélangé. Dans cet arbre :
Commande protégée (refuse tout identifiant autre que `az-express-preprod`, refuse la production, lance `verify-isolation.js`, vérifie que le projet existe dans votre compte ;
**simulation par défaut**, déploiement réel seulement avec `-Execute`) :
```powershell
powershell -ExecutionPolicy Bypass -File test-env\deploy-preprod.ps1 -Source C:\Users\User\AppData\Local\Temp\az_isolated_reliability -GoogleServices C:\az-test\google-services.test.json
# après relecture de la commande affichée :
powershell -ExecutionPolicy Bypass -File test-env\deploy-preprod.ps1 -Source C:\Users\User\AppData\Local\Temp\az_isolated_reliability -GoogleServices C:\az-test\google-services.test.json -Execute
```
Avant de déployer les fonctions : vérifier le quota Cloud Run du projet de test (projet neuf = quota propre, indépendant de la production).
Les règles à tester dans le projet de test : celles de l'arbre isolé (incluent les 4 champs de litige).

## F. Comptes et données fictifs

```powershell
$env:AZ_TEST_PASSWORD = "<mot de passe de test, 12+ caractères, hors dépôt>"
$env:GOOGLE_APPLICATION_CREDENTIALS = "C:\az-test\service-account-$TEST.json"   # clé de service du projet de TEST
node test-env\seed-test-data.js --project $TEST --confirm-project $TEST
```

| Rôle | Identifiant fictif | Solde de départ |
|---|---|---|
| Client | `client.test@az-test.invalid` | 20 000 FCFA |
| Livreur A | `livreur.a@az-test.invalid` (`test-livreur-a`) | 5 000 FCFA |
| Livreur B | `livreur.b@az-test.invalid` (`test-livreur-b`) | 5 000 FCFA |
| Admin (super) | `admin.test@az-test.invalid` | — |
| Vendeur | `vendeur.test@az-test.invalid` | 0 |

Sous-administrateur (permission `commandes`, pour vérifier le refus des décisions d'argent) : à créer depuis l'écran admin du projet de test (non semé).
Aucune donnée de production n'est copiée. Les soldes réels sont relevés avant/après chaque scénario (`test-env/snapshot-balances.js`).

## G. Installation sur les Samsung

```powershell
powershell -ExecutionPolicy Bypass -File test-env\build-test-apk.ps1 -GoogleServices C:\az-test\google-services.test.json
powershell -ExecutionPolicy Bypass -File test-env\install-test-apk.ps1
```
Deux appareils (ou un appareil + un compte émulateur) : un client, un livreur. Autorisations : localisation « toujours », notifications, économie de batterie désactivée.

## H. Scénarios et preuves

Scénarios S1 à S10 : `docs/ORDER_RELIABILITY_SAMSUNG_TEST_PROTOCOL.md` (soldes de départ à relever d'après le tableau F ci-dessus).
Scénarios de litige à ajouter sur commandes de test uniquement : commande avec achat (frais 500, achat 3 000) récupérée, puis décisions A, B, C, D (une par commande) ;
vérifier chaque ligne du tableau de `docs/ORDER_DISPUTES_SPEC.md` §11 et l'absence de crédit de commission sur une commande sans trace.
Critère d'arrêt : un identifiant de production visible, un solde incohérent, une double commission, un remboursement après `picked_up` sans décision.

## I. Fin de campagne

Supprimer le projet de test (Paramètres du projet > Arrêter) ou le laisser sans trafic ; révoquer la clé de service ; supprimer `google-services.test.json`.

## Coût estimé (non mesuré)

Volume faible : Functions, Firestore et Scheduler dans les quotas gratuits ; Artifact Registry + Cloud Build : de quelques centimes à ~1-2 USD/mois.
Le planificateur `autoExpireOrders` (1 passage/minute) reste dans le gratuit. L'alerte à 5 USD ne plafonne pas la dépense (voir A.2).

## Annexe 1 — Résultats des contrôles d'isolation (2026-10-30, lecture seule, rien créé)

| Contrôle | Résultat |
|---|---|
| `verify-isolation.js` sur l'état actuel du dépôt | **Code 1 (attendu)** : `test-env/dart-defines.test.json` et `google-services.json` de test absents — rien n'est encore configuré, aucune connexion possible |
| Gabarits d'exemple (copiés hors dépôt) | **Code 1 (attendu)** : champs non renseignés (appId, clé API, sender id, bucket) |
| Test négatif : `FIREBASE_PROJECT_ID = az-express-b0469` dans les dart-defines | **Refusé** (« référence de production ») |
| Test négatif : `.env` fonctions contenant l'identifiant de production | **Refusé** |
| Test négatif : `GOOGLE_CLOUD_PROJECT=az-express-b0469` dans l'environnement du shell | **Refusé** (« pointe la production ») |
| `deploy-preprod.ps1 -Project az-express-b0469` | **Refusé** (« projet de production ») ; tout autre id que `az-express-preprod` est refusé |
| Garde-fou `assertTestProject` | Corrigé : le motif d'identifiant n'acceptait que `test`, `staging`, `demo` — **`az-express-preprod` aurait été refusé par tous les scripts** ; `preprod` ajouté (production toujours refusée), test unitaire ajouté |
| `.firebaserc` | Défaut = production, **jamais modifié** ; chaque commande porte `--project` |
| `android/app/google-services.json` (production) | Jamais modifié ni lu par les scripts de test ; le fichier de test est posé dans `android/app/src/debug/` |
| Identifiant `az-express-preprod` | Aucun conflit visible (voir §0) ; confirmé seulement à la création |

## Annexe 2 — Ressources pour un déploiement COMPLET (non retenu : voir Annexe 6 pour le déploiement ciblé)

| # | Ressource | Détail | Coût / remarque |
|---|---|---|---|
| 1 | Projet Google Cloud / Firebase `az-express-preprod` | Nouveau numéro de projet, indépendant de la production | gratuit |
| 2 | Lien à un compte de facturation + plan **Blaze** | Obligatoire pour Cloud Functions, Cloud Build, Secret Manager | **[VOTRE ACCORD]** — engage la facturation à l'usage |
| 3 | Authentication (e-mail/mot de passe) + numéros de test téléphone fictifs | 5 comptes fictifs (client, 2 livreurs, admin, vendeur) | gratuit (SMS réels : jamais) |
| 4 | Firestore (base `(default)`, mode production) | Région à aligner avec la production (à confirmer avant création : le choix est définitif) ; règles + index de l'arbre isolé | quotas gratuits quotidiens |
| 5 | Cloud Storage (bucket par défaut) + règles | Photos fictives uniquement | quotas gratuits |
| 6 | Cloud Messaging | Aucune configuration payante ; jeton des téléphones de test | gratuit |
| 7 | Application Android `com.azexpress.app.test` | Empreinte SHA-1 debug ; `google-services.json` de test hors dépôt | gratuit |
| 8 | Cloud Functions (europe-west1) | ~97 fonctions si déploiement complet (services Cloud Run) ; option : déploiement ciblé par `-Only` | usage faible → souvent dans le gratuit |
| 9 | APIs activées automatiquement au premier déploiement | Cloud Functions, Cloud Build, Artifact Registry, Cloud Run, Eventarc, Pub/Sub, Cloud Scheduler, Secret Manager, Firebase Rules | gratuites en elles-mêmes |
| 10 | Cloud Scheduler | 1 tâche par fonction planifiée (10 déployées en production) | les 3 premières par compte de facturation sont gratuites : si la production les utilise déjà, ≈ 0,10 USD/tâche/mois, soit ≈ 1 USD/mois pour 10 tâches |
| 11 | Secret Manager | 5 secrets factices : `FEEXPAY_TOKEN`, `FEEXPAY_WEBHOOK_SECRET`, `GEMINI_API_KEY`, `ANTHROPIC_API_KEY` (tous `DISABLED`), `DELIVERY_PROOF_PEPPER` (aléatoire) | 6 versions actives gratuites |
| 12 | Artifact Registry | Une image par fonction | 0,5 Go gratuit puis ≈ 0,10 USD/Go/mois ; prévoir une règle de nettoyage |
| 13 | Comptes de service par défaut + 1 clé de service JSON pour le seed | Créée par vous, stockée hors dépôt, révoquée en fin de campagne | gratuit |
| 14 | Alerte de budget (Cloud Billing) | Notification par e-mail uniquement | **ne limite PAS la dépense** |

## Annexe 3 — Coûts et limites de consommation (estimations, non mesurées)

- **Ordre de grandeur pendant la campagne** : de 0 à quelques USD par mois (principalement Artifact Registry, Cloud Scheduler, Secret Manager si les gratuités sont déjà consommées par la production). À confirmer sur la page de tarification Google Cloud avant la création.
- **Aucun plafond automatique** n'existe côté Google : seule une alerte (e-mail). Freins réels : `maxInstances` déjà bornés sur chaque fonction ; `minInstances = 0` (aucun coût à l'arrêt) ; aucun trafic public ni clé non restreinte ; FeexPay / SMS / IA désactivés (`DISABLED`) donc aucun coût tiers ; déploiement ciblé possible pour réduire images et builds.
- **Arrêt d'urgence manuel** : dissocier le compte de facturation du projet (les services payants s'arrêtent) ou supprimer le projet (récupérable 30 jours).
- **Quotas** : un projet neuf a ses propres quotas Cloud Run, indépendants de la production ; aucun quota n'est modifié.

## Annexe 4 — Étape 1 : création du projet (commande exacte, NON exécutée)

Vérifications faites le 2026-10-31 (lecture seule) :

| Paramètre | Constat |
|---|---|
| Compte Firebase / gcloud | `<compte propriétaire masqué>` (les deux outils) — le projet sera créé sous ce compte |
| Firebase CLI | 15.18.0 |
| Organisation / dossier GCP | aucun (le projet de production n'a pas de parent) → pas d'option `--organization` / `--folder` |
| Identifiant | `az-express-preprod` : aucun conflit visible, confirmé seulement par la création |
| Compte de facturation visible | `010C64-86595F-16D108` (« My Billing Account », ouvert) — **déjà lié au projet de production** ; Blaze n'est PAS activé par la commande ci-dessous |
| Autres projets sur ce compte de facturation | `az-express-b0469` et `project-b1e38eec-d265-4688-a3c` |

Commande de création (gratuite : crée le projet Google Cloud + Firebase, **sans** Firestore, **sans** facturation, **sans** fonction) :

```powershell
firebase projects:create az-express-preprod --display-name "AZ Express Preprod"
```

Contrôle immédiat après création (lecture seule) : `firebase projects:list` doit montrer `az-express-preprod`, et `gcloud billing projects describe az-express-preprod` doit indiquer `billingEnabled: false`.
Si l'identifiant est pris, la commande échoue sans rien créer ; repli proposé : `az-express-preprod-1` (à me demander avant).
Remarque : partager le compte de facturation de la production signifie que les gratuités mensuelles (ex. 3 tâches Scheduler) sont partagées et que la facture est commune ; filtrer l'alerte de budget sur le projet de préproduction.

## Annexe 5 — Régions Firestore (vérifiées sur la liste officielle du compte)

- **`europe-west1` (Belgique) est proposée pour Firestore** : disponible, aucune alternative à choisir.
- Autres régions européennes disponibles : `europe-west2`, `europe-west3`, `europe-west4`, `europe-west6`, `europe-west8`, `europe-west9`, `europe-west10`, `europe-west12`, `europe-north1`, `europe-north2`, `europe-central2`, `europe-southwest1` ; multi-régions : `eur3` (Europe), `nam5`, `nam7`. Afrique : `africa-south1` (Johannesburg).
- **Constat important : la base de PRODUCTION est en `nam5` (États-Unis, multi-région), pas en Europe.** La préproduction en `europe-west1` sera donc dans une région différente : comportement fonctionnel identique, latence différente (plutôt meilleure pour Abengourou), aucun impact sur les tests de logique. Les fonctions déclenchées par Firestore (europe-west1) sont compatibles avec une base `europe-west1`.
- Le choix de région est **définitif** à la création de la base. Commande (étape suivante, NON exécutée) :
  `firebase firestore:databases:create "(default)" --location europe-west1 --project az-express-preprod` — après votre autorisation séparée.

## Annexe 6 — Déploiement ciblé : liste minimale (21 fonctions sur 97) pour S1 à S12

| Groupe | Fonction | Rôle dans les scénarios | Déclencheur |
|---|---|---|---|
| Cœur commande | `dispatchOrderToDriver` | S1/S2 attribution et diffusion (appelée par l'app après création) | appel client |
| | `enforceOrderRateLimit` | S1/S6 limite de débit et remboursement automatique | création `orders` |
| | `acceptOrderCF` | S3 acceptation, commission prélevée une fois | appel client |
| | `cancelOrderCF` | S4/S5 annulation / demande après récupération | appel client |
| | `deliverOrderCF` | S11 livraison et paiement du livreur | appel client |
| | `syncDriverOrderLifecycle` | libère le livreur à l'état terminal | mise à jour `orders` |
| | `autoExpireOrders` | S2/S6/S10 reprise du dispatch, expiration, alertes de blocage | **planifiée (1/min)** |
| Litiges (S5, S12) | `adminOrderDisputeCF` | décisions A/B/C/D, listes | appel admin |
| | `adminConfirmDeliveryCF` | confirmation administrative de livraison | appel admin |
| Notifications (S8) | `notifyDriversOnNewOrder`, `notifyBroadcastDrivers`, `notifyDriverOnAssigned` | notification des livreurs | triggers `orders` |
| | `notifyClientOnOrderCreated`, `notifyClientOnOrderUpdate` | notification du client | triggers `orders` |
| | `notifyDriverOnOrderCancelled`, `notifyDriverOnMissionEnd`, `notifyDriverLowBalance` | annulation, fin de mission, solde bas | triggers `orders` / `livreurs` |
| Connexion / admin | `checkClientPhone` | connexion client par téléphone | appel client |
| | `logAuthEvent`, `logAdminAuditEvent` | journal de connexion (non bloquant) | appel client |
| | `createSubAdmin` | créer le sous-admin de test (S12 : refus des décisions d'argent) | appel admin |

**Dépendances exactes** : (1) ces fonctions chargent tout le code du dossier `functions/` (modules partagés `orderActions.js`, `dispatch.js`, `driverLifecycle.js`, `adminOrderDisputes.js`, `adminGuards.js`…), mais seules celles listées créent un service ; (2) **aucun secret requis** — aucune de ces fonctions ne déclare de `secrets:` (FeexPay, Anthropic, Gemini, pepper QR ne sont liés qu'à d'autres fonctions) : Secret Manager n'a pas besoin d'être utilisé ; (3) Firestore (règles + index de l'arbre isolé, nécessaires à `autoExpireOrders` : `status + createdAt`), Storage (règles ; le selfie d'acceptation est vérifié dans Storage), Authentication, Cloud Messaging ; (4) Cloud Scheduler : **1 seule tâche** (`autoExpireOrders`) ; (5) documents de configuration : `config/billing` (semé), la commission utilise ses valeurs par défaut (100/200) en l'absence de `config/commission`.
**Exclues volontairement** (non nécessaires à S1–S12) : AZ IA (toutes), FeexPay / retraits, Marketplace / Boutique / Ekbine / événements / immobilier, preuves QR/PIN et SMS, transferts de course, suppression de compte, QR partenaires, tâches de nettoyage et de réconciliation. Si vous voulez tester la libération avant récupération ou la recharge de wallet par l'admin : ajouter `releaseOrderBeforePickupCF` et `adminDriverRechargeCF` (2 fonctions).

**Limites de consommation** : `maxInstances` des 21 fonctions déjà bornés dans le code (1 à 5 ; somme théorique `Σ(cpu×max)` = 35, contre 166,5 en production) ; `minInstances` = 0 ; mémoire 256 Mo. Pour deux téléphones, la consommation réelle attendue est de 1 à 3 instances simultanées. Un projet neuf a ses propres quotas Cloud Run.
Le déploiement ciblé évite ~76 services Cloud Run, ~76 images Artifact Registry et 9 des 10 tâches Scheduler : coût résiduel attendu proche de zéro (estimation, à confirmer).

Commande de déploiement (protégée, simulation par défaut ; défaut du script = cette liste) :
`powershell -ExecutionPolicy Bypass -File test-env\deploy-preprod.ps1 -Source C:\Users\User\AppData\Local\Temp\az_isolated_reliability -GoogleServices C:\az-test\google-services.test.json`

## Annexe 7 — Empreintes du certificat de test (enregistrées dans az-express-preprod UNIQUEMENT)

| Type | Valeur | Enregistrée dans |
|---|---|---|
| SHA-1 | `E2:BC:99:02:D0:FC:8E:D6:7F:3B:90:C9:70:6C:15:01:0D:0B:2E:8E` | app `com.azexpress.app.test` (`1:306761725053:android:51262de719c16f85fd2d14`) |
| SHA-256 | `DF:21:41:DA:76:EE:77:A4:C2:4E:BC:85:A7:01:0E:95:C2:5B:5D:E0:3F:CB:BE:79:4E:8A:3C:93:6E:CF:66:00` | idem |

Certificat = clé de signature **debug** (`~/.android/debug.keystore`) : c'est elle qui signe l'APK produit par `build-test-apk.ps1` (variante debug). Le keystore de release (production) est distinct et n'est enregistré nulle part en préproduction. Aucune empreinte de production n'a été modifiée. Relecture : `firebase apps:android:sha:list 1:306761725053:android:51262de719c16f85fd2d14 --project az-express-preprod` (2 empreintes).
Limite : l'empreinte correspond à la clé debug **de ce poste** ; un APK de test construit sur un autre ordinateur serait signé par une autre clé debug — le construire ici ou enregistrer l'empreinte de l'autre poste.

## Annexe 8 — Clé Google Maps de préproduction (PRÉPARATION — clé NON créée, aucune API activée)

**Constat important (corrigé)** : la clé Maps de production est versionnée dans `lib/constants/maps_key.dart` et les imports conditionnels Dart n'honorent pas `--dart-define` dans cette chaîne d'outils : tout build l'embarquerait. `build-test-apk.ps1` remplace donc temporairement le fichier par `maps_key_test.dart`, vérifie (`verify-isolation.js --maps-swapped`), construit, scanne les artefacts (`check-no-prod-maps-key.js`) puis restaure l'original (empreinte vérifiée). `build-emulator-apk.ps1` repose sur le même mécanisme inefficace : à ne pas utiliser pour un APK distribué. Sans clé de test, les cartes ne s'affichent pas (fond gris) mais le reste fonctionne.

**APIs réellement appelées par le code** (relevé dans `lib/services`) :

| API à activer dans az-express-preprod | Usage | Appelée via |
|---|---|---|
| Maps SDK for Android | affichage des cartes | SDK natif, clé du manifeste |
| Places API (version « legacy ») | `/place/autocomplete/json`, `/place/details/json` | HTTP, `places_search_service.dart` |
| Geocoding API | `/geocode/json` | HTTP, `places_service.dart`, `places_search_service.dart` |
| Directions API | `/directions/json` | HTTP, `google_routes_service.dart` |

Non nécessaires : Routes API, Distance Matrix, Maps SDK for iOS/JavaScript, Static Maps, Places API (New).

**Restrictions proposées**
1. Une clé **Android** : restriction « Applications Android » = package `com.azexpress.app.test` + SHA-1 de l'annexe 7 ; restriction d'API = **Maps SDK for Android** seulement.
2. Les appels HTTP (Places/Geocoding/Directions) n'envoient pas de signature d'application : une clé restreinte « Android » les refuserait. Options pour décision : (a) une seconde clé « services web » limitée aux 3 API HTTP, sans restriction d'application mais avec quotas bas (clé lisible dans l'APK de test) ; (b) ne pas tester ces fonctions en préproduction (adresse saisie à la main). Recommandation : **(b) au départ**, clé Android seule.
3. Quotas par API : plafond journalier proposé 500 requêtes/jour par API ; le plafond de quota est la **seule** limite dure côté Maps (une alerte de budget n'en est pas une).
4. Nom : « az-express-preprod-maps-android » ; aucune réutilisation de la clé de production ; fournie via `TEST_MAPS_API_KEY` (fichier local gitignoré).
5. Coût : Maps SDK for Android (cartes mobiles) sans frais ; Places/Geocoding/Directions facturés à l'usage au-delà du crédit mensuel du compte de facturation (partagé avec la production). Activer une API Maps **exige la facturation liée**.

Séquence (après autorisation) : lier la facturation → activer Maps SDK for Android → créer la clé avec restrictions → plafonner les quotas → renseigner `TEST_MAPS_API_KEY` → construire l'APK.

**Décision séparée (production)** : la clé de production est dans l'historique git et dans `web/downloads/az-express-latest.apk` ; vérifier qu'elle est restreinte (package + SHA de release, APIs) et décider d'une rotation. Rien n'a été modifié.

## Annexe 9 — Activation Blaze de az-express-preprod (PRÉPARATION — facturation NON liée)

État vérifié : `billingEnabled: False`. Compte envisagé : `010C64-86595F-16D108` (« My Billing Account », ouvert, **déjà lié à la production** → facture commune, gratuités partagées).

**Services à activer au déploiement ciblé** : Cloud Functions, Cloud Build, Artifact Registry, Cloud Run, Eventarc, Pub/Sub, Cloud Scheduler (1 tâche), Cloud Storage/Firebase Storage, Cloud Messaging, Authentication. Secret Manager : non nécessaire.
**Coûts prévisibles** (estimation, non garantie) : 21 fonctions, `minInstances` 0, `maxInstances` 1–5 (Σ(cpu×max)=35) ; paliers gratuits Functions/Run/Firestore ; Scheduler : 1 tâche, les 3 gratuites du compte étant probablement consommées par la production → ~0,10 USD/mois ; Artifact Registry/Build : quelques centimes ; Maps : annexe 8. Ordre de grandeur : **< 1 USD/mois** pendant les tests, sauf boucle accidentelle.
**Surveillance** : budget dédié filtré sur `az-express-preprod` (ex. 5 USD, seuils 50/90/100 %). **Une alerte de budget n'est pas une limite de dépense** : elle notifie, ne coupe rien. Arrêt d'urgence manuel : `gcloud billing projects unlink az-express-preprod` ou suppression du projet.

**Étapes exactes avant activation (aucune exécutée)**
1. Votre autorisation explicite de lier `010C64-86595F-16D108` (ou choix d'un autre compte).
2. `gcloud billing projects link az-express-preprod --billing-account=010C64-86595F-16D108`.
3. Création immédiate du budget filtré sur le projet.
4. Activation des APIs listées, sur az-express-preprod uniquement.
5. `deploy-preprod.ps1` en simulation, puis `-Execute` après votre autorisation séparée (règles/index, puis 21 fonctions).
6. Création de la clé Maps (annexe 8) si souhaitée.
7. Semis des comptes/données fictifs, puis APK de test.

## Annexe 10 — Audit (lecture seule) de la clé Maps de production et préparation de la clé de test

**Audit du 2026-10-31** (`gcloud services api-keys list`, aucune modification ; la valeur de la clé n'est pas reproduite) :

| Clé du projet `az-express-b0469` | Restrictions constatées |
|---|---|
| « AZ Express - Maps Android » (créée 2026-10-05) | Applications Android : package `com.azexpress.app` avec **3 empreintes SHA-1** (dont celle de la clé *debug* de ce poste) ; API autorisée : **Maps SDK for Android uniquement** |
| 4 clés « auto created by Firebase » (Android, iOS, Browser, macOS) | aucune restriction d'application ; 26-27 API Firebase chacune ; **aucune API Maps** |

Lecture :
- La clé `AZ Express - Maps Android` est correctement restreinte (application + API). Elle ne permet **pas** Places/Geocoding/Directions : ces appels HTTP du code (`/place/*`, `/geocode/json`, `/directions/json`) ne peuvent pas fonctionner avec elle ; en production seules `maps-android-backend` et `maps-ios-backend` sont activées (pas Places/Geocoding/Directions). Le code retombe donc sur Nominatim (adresses) et sur un tracé direct (itinéraire) : **comportement actuel de la production à confirmer** (je n'ai pas testé sur appareil).
- **Non établi** : la correspondance entre la valeur du dépôt et l'une de ces clés. La lecture de la valeur des clés (`get-key-string`) m'a été refusée par le système de permissions ; je ne la contourne pas. À vérifier par vous dans Console > API et services > Identifiants (afficher la clé et comparer les 4 derniers caractères avec `lib/constants/maps_key.dart`).
- Abus possibles : la valeur est lisible dans le dépôt, dans l'historique git et dans l'APK public ; avec la restriction package+SHA un tiers ne peut pas l'utiliser depuis un autre appareil/application en l'état (il faudrait forger le package et l'empreinte, ce qui est faisable pour qui connaît l'empreinte debug — l'une des 3 empreintes est celle d'une clé debug, moins protégée qu'une clé de release ; à retirer si elle ne sert plus). Les chargements de cartes mobiles sont sans frais ; le risque financier est donc faible tant que la clé ne vise que Maps SDK for Android.
- Quotas : `map_load_requests`, `billable_default` et `premium_map_load_requests` existent avec des limites par défaut ; je n'ai pas modifié les quotas.
- Rotation : créer une nouvelle clé (mêmes restrictions) → la mettre dans `maps_key.dart` et le manifeste → publier une nouvelle version → supprimer l'ancienne **après** adoption. Conséquence : les applications déjà installées (APK public compris) cessent d'afficher la carte tant qu'elles ne sont pas mises à jour. À décider avec la prochaine publication ; rien n'a été fait.

**Clé de test (NON créée)** — nom « az-express-preprod-maps-android », projet `az-express-preprod`, restriction Android = `com.azexpress.app.test` + SHA-1 `E2:BC:99:02:D0:FC:8E:D6:7F:3B:90:C9:70:6C:15:01:0D:0B:2E:8E`, API cible = `maps-android-backend.googleapis.com` seulement. Commandes (après autorisation, facturation liée) :
```
gcloud services enable maps-android-backend.googleapis.com --project az-express-preprod
gcloud services api-keys create --project az-express-preprod --display-name="az-express-preprod-maps-android" --allowed-application=sha1_fingerprint=E2BC9902D0FC8ED67F3B90C9706C15010D0B2E8E,package_name=com.azexpress.app.test --api-target=service=maps-android-backend.googleapis.com
```
La valeur créée va dans `TEST_MAPS_API_KEY` (`test-env/dart-defines.test.json`, gitignoré), jamais dans le dépôt.

**Test des adresses, distances et itinéraires sans clé de production** :
1. Sans aucune clé (état actuel, aucun coût) : recherche d'adresse et géocodage inverse via Nominatim (déjà dans `places_service.dart` / `places_search_service.dart`), distance et tarif par calcul local (`tarif_service`), itinéraire en tracé direct. Les cartes sont grises : on vérifie adresses, distances, prix et suivi par coordonnées, pas le rendu cartographique.
2. Avec la clé Android de test (si autorisée) : fond de carte réel sur le Samsung. Places/Geocoding/Directions restent non activées (donc aucun coût) ; l'itinéraire détaillé n'est pas testé.
3. Si l'itinéraire routier doit être testé : activer Directions API sur une **seconde** clé de test à quota journalier bas (décision séparée, payante).

## Annexe 11 — Budget d'alerte de az-express-preprod (PRÉPARÉ, NON créé)

- Le CLI ne peut pas lister les budgets : l'API Cloud Billing Budget n'est pas activée (et elle serait activée sur le projet de production si on utilisait le projet courant — à éviter). Voie recommandée : **console Google Cloud > Facturation > Budgets et alertes > Créer** (aucune API à activer côté projet).
- Paramètres : nom « az-express-preprod-alerte-5usd » ; compte `010C64-86595F-16D108` ; **Projets : uniquement az-express-preprod** ; montant 5 USD (mensuel) ; seuils 50 %, 90 %, 100 % (réel) et 100 % (prévu) ; notifications e-mail au titulaire.
- Variante gcloud (après activation de `billingbudgets.googleapis.com` sur le projet de préproduction, API gratuite) : `gcloud billing budgets create --billing-account=010C64-86595F-16D108 --display-name="az-express-preprod-alerte-5usd" --budget-amount=5USD --filter-projects=projects/az-express-preprod --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 --billing-project=az-express-preprod`.
- **Un budget n'est pas un plafond** : il prévient, ne coupe rien (délai de facturation de plusieurs heures).
- Ressources déjà présentes dans le projet (aucune ne facture sans Blaze) : Firestore `(default)` europe-west1 (protection de suppression désactivée, ni sauvegarde ni PITR), APIs Firebase par défaut. Après Blaze, les risques de coût inattendu sont : (1) une fonction qui boucle (limitée par `maxInstances` ≤ 5 ; `enforceOrderRateLimit`/`autoExpire` déclenchés par Firestore) ; (2) lectures Firestore massives si un test boucle ; (3) APIs Maps payantes si activées ; (4) journaux. Mesure d'arrêt : délier la facturation.

## Annexe 12 — Compilation locale de l'APK de test (2026-10-31) et corrections du script

Résultat de `test-env\build-test-apk.ps1` (debug, non installé, non distribué) : package `com.azexpress.app.test`, Firebase `az-express-preprod` (app id `1:306761725053:android:51262de719c16f85fd2d14`, bucket `az-express-preprod.firebasestorage.app`), clé Maps du manifeste **vide**, clé Maps de production absente des 800 fichiers de l'APK (UTF-8 et UTF-16), `maps_key.dart` restauré à l'identique, fichiers temporaires supprimés, aucun fichier de production modifié.

Défauts trouvés et corrigés pendant ce contrôle :
1. Les variables `ORG_GRADLE_PROJECT_*` n'arrivent pas à Gradle via `flutter build` : le premier build visait `com.azexpress.app` et aurait lu `MAPS_API_KEY` dans `android/local.properties`. Le script passe désormais `--android-project-arg=azTestSuffix=.test` et `azTestMapsKey=` (toujours défini).
2. `@blobs` éclatait un chemin unique en caractères et faisait scanner la racine du disque : corrigé (tableau forcé). Le scanner `check-no-prod-maps-key.js` lit aussi l'UTF-16 et les dossiers.
3. Ajout du contrôle de l'APK final (`aapt2`, extraction, `audit-apk-content.js`).
Restant, non bloquant : l'APK déclare le lien web de production `az-express-b0469.web.app` (App Links du manifeste, pages légales, liens QR) ; ce sont des liens publics, aucune donnée. `build-emulator-apk.ps1` n'a pas ces protections.

## Annexe 13 — Cloud Storage de préproduction (PRÉPARATION — bucket NON créé, règles NON déployées)

**Pourquoi** : `acceptOrderCF` refuse l'acceptation (`SELFIE_REQUIRED`) tant que le fichier `acceptance_selfies/<commande>/<uid du livreur>.jpg` n'existe pas dans le bucket Storage par défaut (`driverAcceptance.js`, `selfieExists`). Sans bucket, S3 à S5 et S11 sont impossibles.

**Bucket** : `az-express-preprod.firebasestorage.app` (nom déjà inscrit dans `google-services.json` et les dart-defines), région **europe-west1** (même région que Firestore et les fonctions ; disponible, mais hors du palier gratuit réservé aux régions américaines).
Création (après autorisation) — voie recommandée : console Firebase > Storage > « Commencer » > mode production > `europe-west1`. Alternative scriptée à valider avant usage : API `firebasestorage.googleapis.com/v1beta/projects/az-express-preprod/defaultBucket` (création du bucket par défaut avec `location`). Le projet est déjà en Blaze, ce qui est requis.
Durcissement à appliquer juste après création : accès uniforme au niveau du bucket ; **prévention d'accès public activée** (`gcloud storage buckets update gs://… --public-access-prevention --uniform-bucket-level-access`) ; pas de versionnement ; durée de conservation douce (soft delete) à 0 jour ; règle de cycle de vie « supprimer après 30 jours » ; aucune ACL publique ; pas de CORS.

**Règles** : le fichier `storage.rules` de l'arbre isolé (identique à la production) convient sans modification :
- `acceptance_selfies/{commande}/{fichier}` : lecture pour un utilisateur connecté ; création/mise à jour seulement par un compte non anonyme, image, < 5 Mo, et nom de fichier = `<uid de l'appelant>.jpg` ; suppression par ce même compte ;
- toute autre chemin : refusé (aucun accès public, aucune règle générique) ;
- vérification : `rules-tests` Storage, 120 tests sur 120 réussis (émulateur local).
Déploiement (après autorisation) : `firebase deploy --project az-express-preprod --only storage` depuis l'arbre isolé.

**Images fictives uniquement** : JPEG synthétiques (aplat de couleur avec texte « TEST »), < 100 Ko, générés localement ; chemin `acceptance_selfies/<orderId>/<uidLivreurTest>.jpg`. Aucune photo réelle, aucun téléversement avant autorisation ; le téléversement se fera via l'app de test avec le compte livreur fictif (les règles imposent l'uid).

**Coûts (estimation)** : stockage ≈ 0,02 USD/Go/mois en europe-west1 ; quelques dizaines d'images de < 100 Ko → bien moins de 0,01 USD/mois ; opérations et sortie négligeables ; couvert par le budget d'alerte de 5 USD. Cloud Functions ajoute seulement des lectures `exists()`.

## Annexe 14 — Fonctions : dépendances, indispensabilité, comportement en cas d'absence

Groupe minimal : `dispatchOrderToDriver`, `acceptOrderCF`, `deliverOrderCF`, `syncDriverOrderLifecycle` (région europe-west1 ; maxInstances 3 / 5 / 3 / 1 ; aucun secret ; pas de service de paiement ; SMS coupés).

| Besoin | Où c'est garanti |
|---|---|
| Création de commande | écriture client directe dans `orders` (Firestore, règles) — aucune fonction requise |
| Recherche + proposition du livreur | `dispatchOrderToDriver` (appelé par l'app après création) : `zones_livraison` et livreurs en ligne dans la zone requis |
| Commission prélevée **une seule fois** | `acceptOrderCF` : une transaction ; rejeu par le même livreur → succès sans second prélèvement ; txId déterministe `commission_<commande>_<livreur>` |
| Pas de double attribution | statut `ACCEPTABLE` vérifié dans la transaction, livreur déjà en course refusé (`isOnDelivery` / mission active), commande `assigned` à un autre refusée, livreur ayant libéré exclu |
| Crédit du livreur à la livraison | `deliverOrderCF` : un seul crédit, journal `earning`, clé d'opération pour le rejeu ; commission journalisée = celle réellement prélevée |
| Libération du livreur | `deliverOrderCF` applique lui-même `terminalDriverPatch` dans la transaction ; `syncDriverOrderLifecycle` est la **réparation** (annulation, offres résiduelles des autres livreurs après acceptation) et n'écrit que dans `livreurs` |
| Écritures post-transaction | compteurs `deliveries`, `config/az_wallet`, `commissions` : hors transaction, protégées contre le rejeu ; un arrêt entre la transaction et ces écritures laisserait un journal incomplet (jamais un double crédit) |

**Pas indispensables au parcours normal** : `enforceOrderRateLimit` (limite de 10 commandes/heure et annulation automatique en cas d'abus — protection, pas flux), les notifications (`notify*` : push FCM uniquement, aucune écriture métier), `autoExpireOrders` (reprise du dispatch, expiration — nécessaire à S2/S6/S10 mais pas au parcours nominal), `cancelOrderCF` (S4/S5). Si une fonction du groupe manque : sans `dispatchOrderToDriver`, la commande reste `pending` ; sans `acceptOrderCF`, aucune acceptation (les règles interdisent l'écriture directe) ; sans `deliverOrderCF`, pas de livraison ni de crédit ; sans `syncDriverOrderLifecycle`, les offres des autres livreurs peuvent rester affichées jusqu'à la prochaine action.

**Dépendances de déploiement vérifiées dans le CLI Firebase** : l'analyse porte sur les 122 fonctions du code ; `ensureAllRequiredAPIsEnabled` activera Cloud Scheduler (12 fonctions planifiées existent dans le code, aucune ne sera déployée), Cloud Run, Eventarc, Pub/Sub et Storage même avec `--only`. **Nouveau point à autoriser** : le projet n'a pas de compte de service Compute Engine par défaut (seuls `az-express-preprod@appspot…` et `firebase-adminsdk-fbsvc@…` existent) ; les fonctions v2 l'utilisent par défaut, donc l'activation de `compute.googleapis.com` (gratuite, crée le compte) ou le choix explicite d'un compte de service sera probablement nécessaire.
APIs déjà activées par la tentative du 2026-10-31 : `cloudfunctions`, `cloudbuild`, `artifactregistry`, `firebaseextensions` (confirmé) ; aucune ressource facturable créée (0 fonction, 0 bucket, 0 dépôt Artifact Registry, 0 clé API Maps).

## Annexe 15 — Infrastructure créée avant le premier déploiement de fonctions (2026-10-31)

- **Bucket Storage** `az-express-preprod.firebasestorage.app` créé via l'API `firebasestorage` (`defaultBucket`, europe-west1, classe STANDARD) : accès uniforme au niveau du bucket **activé**, prévention d'accès public **imposée**, versionnement désactivé, soft delete 0 s, suppression automatique des objets après 30 jours, bucket **vide**. Règles Storage (identiques à la production) déployées et vérifiées identiques au fichier ; 120/120 tests de règles Storage.
- **API activées** (préproduction seulement) : `firebasestorage`, `compute` (en plus de `cloudfunctions`, `cloudbuild`, `artifactregistry`, `firebaseextensions`). Compute a créé automatiquement le compte `306761725053-compute@developer.gserviceaccount.com` (rôle Éditeur attribué par défaut par Google, non modifié), un réseau VPC `default` (mode auto) et 4 règles de pare-feu par défaut dont `allow-ssh` et `allow-rdp` depuis 0.0.0.0/0. Aucune VM, aucun disque, aucune adresse IP : sans effet tant qu'aucune instance n'existe ; suppression à décider.
- **Permissions que le CLI ajoutera au premier déploiement d'une fonction à déclencheur d'événement** (non accordées) : `roles/iam.serviceAccountTokenCreator` à l'agent Pub/Sub `service-306761725053@gcp-sa-pubsub` ; `roles/run.invoker` et `roles/eventarc.eventReceiver` au compte Compute par défaut.
- **Garde-fou de déploiement** : `test-env/deploy-preprod.ps1` n'accepte plus que `firestore:rules`, `firestore:indexes`, `storage` et les 4 fonctions `dispatchOrderToDriver`, `acceptOrderCF`, `deliverOrderCF`, `syncDriverOrderLifecycle` ; toute autre cible, `functions` seul, un joker ou le projet de production est refusé (testé).
