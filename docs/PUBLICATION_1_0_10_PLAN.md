# Publication AZ Express 1.0.10 — Google Play (Android) et App Store (iOS) — plan préparé le 28 octobre 2026

Statut : **PRÉPARÉ, RIEN DÉPLOYÉ.** Aucun commit, aucune écriture en production. Périmètre de lancement : Abengourou, paiements **en espèces**, FeexPay reporté.
Constats de production en lecture seule : `firebase functions:list` (85 fonctions déployées, 112 dans le code local avant ce lot ; **113** avec `adminDriverRechargeCF`, **116** avec les trois fonctions du lot E §11) ; document `operations_control/account_deletion` **absent** (404).

## 1. Fonctions à déployer

### 1.1 Les 28 fonctions absentes de la production (27 existantes + `adminDriverRechargeCF`, nouvelle)

| Lot | Fonctions | Pourquoi indispensable |
|---|---|---|
| A — livreur / commandes / recharge (critique) | `acceptOrderCF`, `releaseOrderBeforePickupCF`, `declineLegacyOrderCF`, `deliveryTransferCF`, `settleTransferEarningsCF`, `expireDeliveryTransfers` (planifiée), **`adminDriverRechargeCF`** | Sans elles, l'application 1.0.10 ne peut ni accepter (commission serveur + selfie), ni libérer, ni refuser, ni transférer une course ; l'écran admin de recharge appelle `adminDriverRechargeCF`. |
| B — suppression de compte (exigence Google Play) | `requestAccountDeletionCF`, `getAccountDeletionStatusCF`, `manageAccountDeletionCF`, `managePharmacyOwnerIdentityCF`, `retryAccountDeletions` (planifiée) | Le dialogue de suppression de l'application les appelle. Traitement désactivé tant que le drapeau (§1.3) n'est pas posé. |
| C — partenaires | `completePartnerFirstPasswordChange`, `adminBillingCF` | Premier changement de mot de passe des partenaires créés par l'administration ; revue de facturation. |
| D — preuves de livraison / QR (désactivés par défaut) | `prepareOrderProof`, `confirmOrderPickupWithProof`, `confirmOrderDeliveryWithProof`, `createRecipientProofAccess`, `redeemRecipientProofAccess`, `configureDeliverySms`, `getDeliverySmsStatus`, `markDeliverySmsArrival`, `retryDeliverySms`, `dispatchDeliverySms`, `getPartnerQr`, `listPartnerQrEstablishments`, `resolvePartnerQr`, `setPartnerQrManager` | Pour que les écrans n'échouent pas ; aucun SMS réel tant que `DELIVERY_SMS_ENABLED` n'est pas activé. Le paquet QR est isolé : ne pas le modifier. |

Quota Cloud Run CPU : `adminDriverRechargeCF` est déclarée avec `maxInstances: 2` (cpu par défaut). Déployer par lots ciblés ; une erreur « total allowable CPU » = réduire la charge, pas insister.

### 1.2 Fonctions déjà en production dont le code local a changé
Fichiers modifiés : `index.js`, `orderActions.js`, `dispatch.js`, `ekbineFlow.js`, `marketplacePublishing.js`, `passwordReset.js`, `professionalSubscriptions.js`, `adminPartnerAccounts.js`, `azia/tools/*`, `driverAcceptance.js` (selfie), nouveau `adminDriverRecharge.js`. Les fonctions qui les importent sont redéployées avec les lots (annulation, livraison, dispatch, création de commandes, AZ IA).

### 1.3 Activation de la suppression de compte (action de production, autorisation explicite requise)
`accountDeletion.js` ne traite une demande que si `operations_control/account_deletion` contient `enabled: true` et `inventoryVersion: 1` (et `partnerInventoryVersion: 1` pour les partenaires). Le document n'existe pas : les demandes restent `pending` (`server_rollout_not_enabled`). Ne créer ce document qu'**après** validation des blocages de `docs/ACCOUNT_DELETION_RELEASE_CHECKLIST.md` (pharmacies historiques, couverture des producteurs, inventaire de rétention, dette d'établissement partagé) et test avec un compte fictif.

### 1.4 Configuration optionnelle de la recharge
`config/driver_recharge` → `{ maxPerOperation: <entier FCFA> }`. Absent, invalide ou > 1 000 000 : plafond **50 000 FCFA**. Aucune création nécessaire au lancement.

## 2. Règles
- `firestore.rules` : nouvelles collections fermées (`partner_qr*`, `account_tombstones`, `pharmacy_owners*`, `account_deletions`, `delivery_proofs`, `transfer_settlements`, `delivery_transfers`) + verrous commission/transfert. Valider par `firebase deploy --only firestore:rules --dry-run`. Tests de règles locaux : 246/246.
- `storage.rules` : inchangé par ce lot (non assoupli). Le selfie est désormais envoyé avec `contentType: image/jpeg` explicite (`driver_dashboard.dart`), ce qui satisfait `isImage()` quel que soit le type déduit par le système.
- **Ne pas fermer l'acceptation directe** (`assigned → accepted` côté Firestore) : les anciennes applications livreur l'utilisent (`docs/DRIVER_ACCEPT_RULE_MIGRATION.md`).
- La recharge admin n'écrit plus le solde depuis l'application ; la règle `allow update: if isAdmin()` sur `livreurs` reste en place pour les anciennes versions admin (à resserrer après leur disparition).

## 3. Ordre de déploiement, contrôles après chaque étape, retour arrière
(Rien n'est lancé sans autorisation explicite à chaque étape.)

| # | Étape | Commande (préparée) | Contrôle après | Retour arrière |
|---|---|---|---|---|
| 0 | Sauvegardes | copie de `storage.rules`/`firestore.rules` de production (`docs/firestore-production/`) | fichiers présents | — |
| 1 | Lot A | `firebase deploy --only functions:acceptOrderCF,functions:releaseOrderBeforePickupCF,functions:declineLegacyOrderCF,functions:deliveryTransferCF,functions:settleTransferEarningsCF,functions:expireDeliveryTransfers,functions:adminDriverRechargeCF --project az-express-b0469` | `functions:list` montre les 7 ; journaux sans erreur de démarrage ; ancienne app livreur accepte encore | `firebase functions:delete <nom>` (nouvelles fonctions, n'écrasent rien) |
| 2 | Fonctions existantes modifiées (par petits groupes : commandes/annulation/livraison ; dispatch ; AZ IA ; ekbine/marketplace ; mot de passe/abonnements/partenaires) | `--only functions:<liste>` | création d'une commande espèces de test, dispatch, annulation | redéployer depuis le commit de référence |
| 3 | Lots C puis B puis D puis **E** (§11) | idem | `functions:list` = 116, zéro écart | suppression ciblée |
| 4 | Règles Firestore | `--dry-run` puis `firebase deploy --only firestore:rules` | tests §4 ; pas de `permission-denied` anormal | redéployer la copie de production |
| 5 | Règles Storage | `--only storage` | upload selfie livreur OK | idem |
| 6 | Hosting (pages légales) | `flutter build web` puis `firebase deploy --only hosting` | `/confidentialite` et `/delete-account` renvoient du HTML lisible **sans JavaScript** (`curl`), `/suppression-compte` ouvre le formulaire, `/` inchangé | version Hosting précédente (console → Rollback) |
| 7 | Drapeau suppression (§1.3) | écriture du document, autorisation séparée | compte fictif : demande → traitement → statut | supprimer le document (le traitement s'arrête) |
| 8 | Application 1.0.10 (+11) | AAB signé → test interne Play → production | cf. §4 | retirer la version du canal Play |

Compatibilité : `acceptOrderCF` exige le selfie côté serveur ; seul appelant = `OrderRequestDialog` (selfie obligatoire à l'écran). L'ancienne application accepte par écriture directe et n'est pas concernée. Anciennes apps admin : recharge directe toujours permise par les règles (sans plafond) — à retirer ensuite.

## 4. Vérifications sur téléphone (non réalisées à ce jour)
1. Acceptation d'une course avec selfie réel, vraie configuration de production : upload accepté (MIME), commission 100 FCFA prélevée **une fois** (5000 → 4900), rejeu sans second débit.
2. Refus serveur sans selfie (message `SELFIE_REQUIRED`) — test de non-régression côté UI.
3. Recharge manuelle : confirmation du montant ; 50 000 accepté, 50 001 refusé ; double appui = un seul crédit ; ligne `wallet_transactions` avec admin et clé ; entrée `audit_logs`.
4. Wallet client/livreur/partenaires : message « Service bientôt disponible » à la place de la recharge/retrait électroniques ; commande en espèces non affectée.
5. Suppression de compte avec compte fictif (après §1.3).
6. Ancienne application livreur : acceptation toujours possible.
7. Pages légales ouvertes sur téléphone (navigateur) sans connexion.
8. Livraison avec preuve, annulation avec remboursement au payeur.
Surveillance 24 h : `permission-denied` sur `orders`, `walletReconciliationCheck` sans écart.

## 5. Retour arrière (synthèse)
- Fonctions : supprimer les nouvelles ou redéployer le commit de référence (`git stash` interdit).
- Règles : redéployer la copie de production (`docs/firestore-production/`).
- Hosting : rollback de version dans la console.
- Application : retirer la version du canal Play ; une suppression de compte exécutée est irréversible.
- Argent : aucun retour automatique ; corriger par écriture compensatoire tracée (la recharge est idempotente : un rejeu ne double pas).

## 6. Google Play Console — éléments à compléter
- URL politique de confidentialité `https://<domaine>/confidentialite` et URL de suppression de compte `https://<domaine>/delete-account` : pages HTML statiques créées (`web/legal/`), à déployer (étape 6) puis à vérifier. Le domaine e-mail est incohérent (`privacy@az-express.ci` dans la politique, `support@azexpress.ci` dans l'application) et les durées de conservation ne sont pas validées juridiquement : à trancher avant soumission.
- Section Sécurité des données (caméra/selfie, position, photos, identifiants ; FeexPay non actif au lancement mais présent dans le code ; Anthropic).
- Localisation en arrière-plan (`ACCESS_BACKGROUND_LOCATION`) et service au premier plan ; permissions photos (`READ_MEDIA_IMAGES`, stockage).
- Classification du contenu, public cible, déclaration publicitaire, comptes de test pour évaluateurs (fictifs, hors dépôt).
- Signature de l'AAB (`key.properties` + keystore, non versionnés) et `versionCode` 11 > dernier téléversé.

---

## 7. Fonctions ajoutées le 28 octobre 2026 (à ajouter au lot 1.1 — communes à Android et iOS)

`createFleetDriverCF` (maxInstances 2), `manageArtisanPhotosCF` (2), `completeManualAccountDeletionCF` (1). Modifiées : `acceptOrderCF`, réservations d'événements, abonnements professionnels. Règle : `account_deletion_requests` accepte les rôles `artisan` et `event_provider`. Les Cloud Functions sont les mêmes pour Android et iOS (callables Firebase, aucune logique par plateforme).

## 8. PUBLICATION iOS (App Store) — un test Android ne valide pas iOS

### 8.1 Vérifié sur Windows (code et configuration)
| Sujet | État |
|---|---|
| Identifiant `com.azexpress.app`, équipe `F6XWK2W7XG`, iOS 15.0 minimum | Présents (`project.pbxproj`, `Podfile`, `codemagic.yaml`) |
| Version / build | `pubspec.yaml` 1.0.10+11 → `CFBundleShortVersionString`/`CFBundleVersion` via Flutter. Des builds 12 et 13 ont été préparés dans l'historique git, mais **le dernier build réellement envoyé à App Store Connect est inconnu du dépôt**. `codemagic.yaml` ne code plus de numéro : il exige la variable Codemagic `IOS_BUILD_NUMBER` (entier) et échoue sinon. À définir après lecture de la liste des builds dans App Store Connect (valeur > dernier build de la version 1.0.10). Android : `versionCode` 11 / `versionName` 1.0.10 (via `flutter.versionCode`), à comparer au dernier code envoyé dans Play Console. |
| Info.plist | Caméra, photos, micro, reconnaissance vocale, localisation (en cours d'usage + toujours) : textes en français présents. Modes d'arrière-plan : `fetch`, `location`, `remote-notification`. |
| Firebase iOS | `GoogleService-Info.plist` et `firebase_options.dart` sont injectés par Codemagic (variables `FIREBASE_IOS_PLIST_B64`, `FIREBASE_DART_OPTIONS_B64`) ; le script vérifie bundle ID et projet `az-express-b0469`. Fichiers gitignorés : bon. |
| Connexion sociale | Aucune (pas de Google/Facebook) : « Se connecter avec Apple » non exigé. |
| Suppression de compte dans l'app (guideline 5.1.1(v)) | Présente pour client, livreur, partenaires (feuille partenaire), artisan, prestataire d'événements. Page web `/suppression-compte` + pages légales statiques. |
| Paiements électroniques | Masqués par `AppConfig.electronicPaymentsEnabled=false`, indépendant de la plateforme. Paiement cash pour services physiques : pas d'achat intégré Apple requis. |
| Recharge manuelle, commissions, commandes | Logique 100 % Cloud Functions : identique sur iOS. |

### 8.2 Corrections iOS faites localement le 28 octobre 2026
1. **`ios/Podfile`** : ajout de `PERMISSION_LOCATION=1` et `PERMISSION_MICROPHONE=1`. Sans ces macros, `permission_handler` désactive le code iOS de ces permissions : messages vocaux (chat, marketplace, courses) et « localisation toujours » du livreur auraient été refusés en permanence sur iPhone alors que tout marchait sur Android.
2. **`lib/services/driver_location_service.dart`** : sur iOS, le flux GPS utilise `AppleSettings` (`allowBackgroundLocationUpdates`, `pauseLocationUpdatesAutomatically:false`, pastille de localisation). Sans cela iOS suspend le suivi livreur dès que l'app passe en arrière-plan.
3. **`ios/Runner/Info.plist`** : retrait du mode d'arrière-plan `bluetooth-peripheral` (aucun code Bluetooth, aucune description d'usage : motif classique de refus à l'examen Apple).

### 8.3 Nécessite un Mac + Xcode (ou Codemagic) — NON fait
- `pod install`, `flutter build ipa`, archive signée, vérification que `aps-environment` passe bien en `production` dans l'IPA exporté (le fichier source contient `development`).
- **Manifeste de confidentialité** : `ios/Runner/PrivacyInfo.xcprivacy` créé et déclaré dans `project.pbxproj` (référence, groupe Runner, phase Resources). À confirmer sur Mac : ouverture dans Xcode, présence dans l'IPA (`Payload/Runner.app/PrivacyInfo.xcprivacy`) et rapport de confidentialité Xcode (Product → Archive → Generate Privacy Report).
- Notifications push : clé APNs (.p8) à charger dans Firebase → Cloud Messaging, puis vrai test iPhone (token APNs, banner, ouverture).
- Appareil réel : caméra frontale (selfie d'acceptation), GPS arrière-plan livreur, micro, reconnaissance vocale, App Check (DeviceCheck à activer dans la console Firebase), liens universels (`applinks:az-express-b0469.web.app` : fichier `apple-app-site-association` à vérifier sur le domaine).
- Clé Google Maps iOS codée dans `AppDelegate.swift` : vérifier dans Google Cloud qu'elle est restreinte au bundle `com.azexpress.app`.
- Voix : `android_tts_provider` est limité à Android ; confirmer sur iPhone que `flutter_tts`/fournisseurs cloud donnent une voix correcte.

### 8.4 Checklist Apple
1. Compte Apple Developer actif (adhésion payée et valide), contrats « Paid Apps »/accords à jour.
2. Identifiant d'app `com.azexpress.app` créé avec capacités Push et Associated Domains ; certificat de distribution et profil App Store (Codemagic : intégration « AZ Express Codemagic »).
3. App Store Connect : fiche app, catégorie, âge, pays, URL confidentialité (`/confidentialite`), URL support, URL de suppression de compte.
4. Version 1.0.10, build > dernier build envoyé.
5. Archive signée → IPA → envoi TestFlight (le workflow Codemagic exporte sans envoyer automatiquement : l'envoi reste une décision explicite).
6. Tests TestFlight sur iPhone (liste §8.3) pour chaque rôle : inscription, connexion, suppression de compte.
7. « Confidentialité de l'app » Apple : localisation précise, coordonnées (nom, téléphone, e-mail), photos, contenu utilisateur, identifiants, données d'achat/transactions ; usage : fonctionnement de l'app, pas de suivi publicitaire (à confirmer).
8. Compte de démonstration pour le relecteur Apple (client + livreur fictifs, avec notes expliquant selfie/localisation).
9. Captures d'écran iPhone 6,9" et 6,5" ; textes, mots-clés, notes de version.
10. Soumission à l'examen Apple, seulement après autorisation.

### 8.5 Manifeste de confidentialité iOS (28 octobre 2026)
- **Suivi** : `NSPrivacyTracking=false`, aucun domaine de suivi.
- **API à raison requise** : une seule déclarée par l'app, `UserDefaults` (raison `CA92.1`), car `flutter_foreground_task` 8.17 l'utilise sans fournir de manifeste. Les autres plugins utilisés fournissent le leur (connectivity_plus, firebase_messaging, flutter_sound, geolocator_apple, google_maps_flutter_ios, image_picker_ios, mobile_scanner, package_info_plus, permission_handler_apple, record_ios, shared_preferences_foundation, share_plus, sqflite_darwin, url_launcher_ios) ; les SDK Firebase 12.x embarquent les leurs. Vérifié par lecture du cache pub ; `speech_to_text`, `flutter_tts`, `path_provider_foundation`, `audioplayers_darwin` et les plugins Firebase Flutter n'utilisent aucune API à raison requise dans leurs sources iOS (un cas `firebase_auth` détecté par recherche textuelle : à confirmer par le rapport de confidentialité Xcode).
- **Données collectées déclarées** (toutes liées à l'utilisateur, aucune pour le suivi) : nom, e-mail, téléphone, adresse, position précise, photos (profil, pièces, preuves, selfies), audio (messages vocaux), contenu utilisateur (messages), identifiant utilisateur, identifiant d'appareil (jeton de notification, installation Firebase), historique d'achats (commandes), autres informations financières (solde de portefeuille), données de plantage, performance, interactions produit (Firebase Analytics/Crashlytics). Cette liste doit rester identique aux réponses « Confidentialité de l'app » d'App Store Connect.
- À valider sur Mac : le SDK Analytics ne lit pas l'IDFA sans consentement (aucune boîte ATT n'est affichée ; `NSUserTrackingUsageDescription` absent volontairement).

## 9. Vérifications faites le 28 octobre 2026 (Windows)
- `npm test` (functions) : 1353 réussis / 1385 ; l'unique échec (`partnerQrCache`) est un artefact de répertoire courant : `node --test functions/test/partnerQrCache.test.js` lancé depuis la racine passe.
- `flutter test` : 966 réussis. `flutter analyze` des fichiers modifiés : 1 information préexistante (`fleet_register.dart:42`), aucune erreur.
- Émulateurs Auth+Firestore+Storage : 27/27 (nouveaux flux 7, cycle de vie 8, suppression réelle 12). Règles Firestore : 258/258. `firebase deploy --only firestore:rules --dry-run` : valide.
- Non vérifiable ici : tout ce qui touche iPhone/Xcode, téléphone Android, console Apple/Google, production.

## 10. Checklists de lancement

### ANDROID — Google Play
**Prêt (code et tests locaux)** : correctifs inscription/MIME, recharge manuelle plafonnée et idempotente, création de chauffeur par patron de flotte (`createFleetDriverCF`), photos artisan (`manageArtisanPhotosCF`), suppression manuelle (`completeManualAccountDeletionCF`), gardes pendant suppression, paiements électroniques masqués, pages légales statiques, version 1.0.10 (+11).
**À tester sur téléphone** : §4 complet (selfie d'acceptation, commission unique, recharge, wallet masqué, suppression avec compte fictif après §1.3, ancienne application livreur, pages légales), ajout/suppression de photo artisan, création de chauffeur par un patron de flotte, GPS arrière-plan livreur.
**Empêche encore la publication** : (1) déploiements non faits (lots A→E, règles, hosting) ; (2) AAB signé non produit ni vérifié (signature, `key.properties`) ; (3) `versionCode` à comparer à Play Console ; (4) fiche Play (confidentialité, sécurité des données, URL de suppression de compte) à saisir ; (5) incohérence des e-mails de contact (`privacy@az-express.ci` / `support@azexpress.ci`) ; (6) aucune validation sur appareil.

### IOS — Apple App Store
**Prêt (préparé localement)** : identifiant `com.azexpress.app` et équipe ; textes d'autorisation ; modes d'arrière-plan réduits à `fetch`, `location`, `remote-notification` ; macros `permission_handler` (micro, localisation) ; réglages GPS arrière-plan iOS ; manifeste de confidentialité ajouté au projet ; build forcé via `IOS_BUILD_NUMBER` ; connexion sociale absente (pas de « Sign in with Apple ») ; suppression de compte dans l'app ; Cloud Functions identiques à Android.
**À tester (Mac/Xcode/iPhone obligatoires)** : `pod install` + `flutter build ipa` ; contenu de l'IPA (manifeste, `aps-environment=production`, absence de `bluetooth-peripheral`) ; push APNs réelle ; caméra frontale (selfie) ; GPS arrière-plan et pastille ; micro et dictée ; liens universels (`apple-app-site-association` sur `az-express-b0469.web.app`) ; App Check DeviceCheck ; voix AZ IA ; parcours rôle par rôle (inscription, connexion, suppression) ; TestFlight.
**Empêche encore la publication** : (1) aucune compilation iOS depuis ces changements ; (2) numéro de build à confirmer dans App Store Connect puis à saisir dans `IOS_BUILD_NUMBER` ; (3) clé APNs `.p8` à charger dans Firebase ; (4) fiche App Store Connect, réponses de confidentialité, captures iPhone, compte de démonstration pour le relecteur ; (5) clé Google Maps iOS (en clair dans `AppDelegate.swift`) à restreindre au bundle ; (6) le workflow Codemagic publie vers App Store Connect (`submit_to_testflight:false`, `submit_to_app_store:false`) : le lancer envoie un build, ce qui exige une autorisation ; (7) aucun test sur iPhone. **Un test Android ne valide pas ces points.**

## 11. Ordre de déploiement complet des fonctions et dépendances
1. Lot A (commandes/recharge) — `adminDriverRechargeCF` dépend de `accountAdmission.js` (partagé avec les lots B et E ; déployer le code complet, pas un fichier isolé).
2. Fonctions existantes modifiées (commandes, dispatch, AZ IA, ekbine/marketplace, mot de passe/abonnements/partenaires, **réservations d'événements**).
3. Lots C, B, D.
4. **Lot E** : `createFleetDriverCF` (dépend de `fleet_owners` approuvé et d'`assertPartnerActivated` ; crée des comptes Auth `<id>@az-driver.ci`), `manageArtisanPhotosCF` (dépend de `artisanLogin` déjà déployée, du bucket Storage par défaut et de `service_providers.artisanUid`), `completeManualAccountDeletionCF` (dépend de `account_deletion_requests`, `requireSuperAdmin`, du bucket par défaut ; mémoire 512 MiB, délai 300 s, 1 instance).
5. Règles Firestore (rôles `artisan` et `event_provider` pour `account_deletion_requests`) — déployer les règles avant l'application mobile qui propose le bouton.
6. Hosting, puis applications (AAB Play, IPA TestFlight). Les anciennes applications continuent de fonctionner ; la nouvelle création de chauffeur et les photos artisan exigent la nouvelle version.
Quota Cloud Run : les fonctions du lot E (2+2+1 instances) et `adminDriverRechargeCF` (2) s'ajoutent au calcul `Σ(cpu×maxInstances)` ; recontrôler le total régional avant le lot E.

## 12. Phase 1 — état réel de la production et lot 1 (lecture seule, 28 octobre 2026)

**Constat** (`firebase functions:list --project az-express-b0469`, nodejs22, europe-west1) : **85 fonctions déployées**, 120 exports locaux, **35 absentes de la production**, aucune fonction de production absente du code local. Les 35 : lot A (7) + B (5) + C (2) + D (18, dont les 4 déclencheurs `syncPartnerQr_*` absents du tableau §1.1) + E (3). Le « 28 » du §1.1 était incomplet.

### 12.1 Lot 1 — 5 fonctions, toutes NOUVELLES (décision du 28 octobre 2026)
| Fonction | maxInstances | Remarque |
|---|---|---|
| `acceptOrderCF` | 5 | acceptation serveur : commission une seule fois, selfie exigé |
| `releaseOrderBeforePickupCF` | 2 | libération avant récupération, commission remboursée une fois |
| `declineLegacyOrderCF` | 2 | refus d'une course historique |
| `settleTransferEarningsCF` | 2 | règlement admin des gains de transfert (super-admin) ; indépendante de `deliveryTransferCF` (elle ne dépend que de `driverLifecycle.js`) |
| `adminDriverRechargeCF` | 2 | recharge manuelle plafonnée et idempotente |

Plafonds posés dans `functions/index.js` (`onCall: (h) => onCall({ maxInstances: N }, h)`).
- **Exclue du lot 1 : `deliveryTransferCF`.** Elle est liée au secret `DELIVERY_PROOF_PEPPER` qui n'existe pas dans Secret Manager (`firebase functions:secrets:get` → 404). La déployer imposerait de créer un secret de production : décision distincte. Même traitement pour `expireDeliveryTransfers` et le lot D.
- **Application publiée** : le remplacement de livreur est désactivé par `AppConfig.deliveryTransferEnabled = false` (`lib/constants/app_constants.dart`) : l'icône « Remplacements de livreur » est masquée et « Signaler un problème » après récupération affiche « Le remplacement de livreur n'est pas encore disponible ». La libération avant récupération (`releaseOrderBeforePickupCF`) reste disponible. Passer le drapeau à `true` seulement après déploiement de `deliveryTransferCF`.
- Dépendances (même source) : `orderActions.js`, `driverAcceptance.js`, `driverRelease.js`, `driverDecline.js`, `transferSettlement.js`, `adminDriverRecharge.js`, `driverLifecycle.js`, `accountAdmission.js`, `legacyPartnerPolicy.js`, `dispatch.js`. Aucun secret, aucun paramètre, aucune variable d'environnement liée aux cinq fonctions (vérifié sur leurs `__endpoint` : `secretEnvironmentVariables` vide ; `DELIVERY_PROOF_PEPPER` n'est lu que dans `driverTransfer.js` et dans la branche « preuve » d'`orderActions.js`, non utilisée par le lot).
- Aucune fonction existante n'est remplacée ; aucune migration ; aucune modification de règles. Aucune référence à ces noms dans le code applicatif commité (`git grep` sur HEAD : 0) → les applications installées ne les appellent pas. L'acceptation directe `assigned → accepted` reste ouverte pour les anciennes applications.
- Commande préparée (NON exécutée), à lancer fonction par fonction si une erreur de quota apparaît :
  `firebase deploy --only functions:acceptOrderCF,functions:releaseOrderBeforePickupCF,functions:declineLegacyOrderCF,functions:settleTransferEarningsCF,functions:adminDriverRechargeCF --project az-express-b0469`
- **Quota** : `firebase functions:list` donne Σ(cpu×maxInstances) = 149,5 pour les 85 fonctions (77 à cpu 1, 7 à 0,5, 1 à 512 MiB). Le lot ajoute 13 (5+2+2+2+2, cpu 1 par défaut) → **162,5**. Le seuil de blocage observé au Prompt 122 était 168 et 149,5 est accepté : la marge est de 5,5 et le plafond exact de la région n'est pas lisible (l'API de quotas renvoie 20 000 milli-vCPU pour `CpuAllocPerProjectRegion` en europe-west1, valeur qui ne correspond pas au modèle Σ(cpu×max) puisque 149,5 est déjà déployé). Un échec de quota n'abîme rien (la fonction n'est simplement pas créée) : réduire cpu/maxInstances, ne pas insister.

### 12.2 Lots suivants (ordre)
2. `deliveryTransferCF` (après création autorisée du secret `DELIVERY_PROOF_PEPPER`) + `expireDeliveryTransfers`, lot E (`createFleetDriverCF`, `manageArtisanPhotosCF`, `completeManualAccountDeletionCF`), lot C (`completePartnerFirstPasswordChange`, `adminBillingCF`).
3. Lot B suppression de compte (5 fonctions) — drapeau toujours absent.
4. Fonctions existantes modifiées, par petits groupes, après vérification de compatibilité (§12.3).
5. Lot D (preuves/QR) seulement si ces écrans sont voulus ; les 4 `syncPartnerQr_*` écrivent dans `partner_qr*` : pas sans décision explicite.
6. Règles Firestore, Storage, Hosting, applications.

### 12.3 Compatibilité (lots suivants)
- `adminPartnerAccounts.js` : le profil vendeur/boulangerie est complété côté serveur avec tous les champs obligatoires ; l'ancienne application admin (qui envoyait `{}`) serait refusée.
- `orderActions.js` : `legacyPartnerPolicy` vaut `block` par défaut → `APP_UPDATE_REQUIRED` pour une facturation « historique » ; à fixer avant ce lot.
- Règles : `partnerActivated()` bloque les écritures d'un partenaire créé par l'administration tant que le mot de passe temporaire n'est pas changé ; `onCall` d'`index.js` refuse toute session d'un compte en quarantaine.
- `isAdmin()` est déjà « super-admin seulement » en production (copie du 6 septembre).

### 12.4 Contrôles immédiatement après le lot 1 (aucun compte fictif en production)
1. `functions:list` : 90 fonctions (85 + 5), aucune fonction existante avec une `updateTime` modifiée.
2. `firebase functions:log --only <nom>` sans erreur au démarrage pour chacune.
3. Appel sans authentification de chaque fonction (`POST https://europe-west1-az-express-b0469.cloudfunctions.net/<nom>` avec `{"data":{}}`) : réponse `UNAUTHENTICATED`, preuve qu'elle répond sans rien écrire.
4. Aucune erreur de quota ; surveillance 24 h : `permission-denied` sur `orders`, réconciliation des portefeuilles.
5. Le test de bout en bout avec un vrai compte attend la nouvelle application (commission 5000 → 4900 une seule fois, recharge, libération).

### 12.5 Retour arrière
- Fonction nouvelle : `firebase functions:delete <nom> --region europe-west1 --project az-express-b0469 --force` (personne ne l'appelle avant la nouvelle application). Le lot n'écrit aucune donnée par lui-même.
- Règles : non modifiées par le lot 1. Pour les lots suivants, retélécharger les règles actives avant déploiement (la copie du dépôt date du 6 septembre 2026).
- Argent : pas de retour automatique ; écritures compensatoires tracées.

### 12.6 Migrations de données et règles (lots suivants)
- Aucune migration obligatoire pour le lot 1. Optionnels : `config/driver_recharge` (plafond, défaut 50 000), politique `legacyPartnerPolicy`. `operations_control/account_deletion` : non créé.
- Règles Firestore modifiées localement vs copie du 6 septembre : `account_tombstones`, `pharmacy_owners`, `pharmacy_owner_invitations`, `account_deletions`, `artisan_credentials`, `simple_services*`, `ai_tool_executions`, `delivery_proofs`, `transfer_settlements`, `delivery_transfers`, `partner_qr*`, `partnerActivated()`, `account_deletion_requests` (rôles artisan/event_provider). `storage.rules` : 120 lignes ajoutées vs HEAD, à relire contre la version active.
- Index : aucune requête composite nouvelle dans le lot E.
