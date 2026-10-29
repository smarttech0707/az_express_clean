# Compiler AZ Express iOS sur Mac (Xcode) — sans rien envoyer à Apple

Préparé le 28 octobre 2026. Ce guide s'arrête à l'IPA/archive **locale**. L'envoi vers App Store Connect (TestFlight) est une étape distincte, à ne faire qu'après autorisation.

## 0. Prérequis sur le Mac
- macOS récent avec Xcode installé (Codemagic utilise Xcode 26.0 : prendre la même branche majeure), ligne de commande Xcode (`xcode-select --install`), CocoaPods 1.17.x (`pod --version`), Flutter **3.44.5** stable (`flutter --version`).
- Xcode → Settings → Accounts : se connecter avec le compte Apple Developer de l'équipe `F6XWK2W7XG`. Le compte doit être actif (adhésion payée) et les contrats App Store Connect acceptés.
- Récupérer le dépôt à l'état courant (les modifications locales du 28 octobre ne sont pas committées : copier le dossier ou utiliser une branche approuvée par vous).

## 1. Fichiers de configuration non versionnés (à placer à la main)
1. `ios/Runner/GoogleService-Info.plist` : Firebase Console → projet `az-express-b0469` → application iOS `com.azexpress.app` (appId `1:697217052961:ios:f7b1b0d0f2e67372ea4e60`). Ne jamais le committer.
2. `lib/firebase_options.dart` : version « variables d'environnement » du projet (le fichier du dépôt lit `FIREBASE_IOS_*` via `String.fromEnvironment`). Si absent, le restaurer depuis la sauvegarde sécurisée (variable Codemagic `FIREBASE_DART_OPTIONS_B64`).
3. Vérification (n'affiche aucune valeur) :
   `python3 scripts/build_mobile.py ipa --check-only` → doit afficher `Firebase ios: validation PASS`.

## 2. Contrôles de configuration avant compilation
- `ios/Runner/Info.plist` : `UIBackgroundModes` = `fetch`, `location`, `remote-notification` (pas de `bluetooth-peripheral`) ; descriptions caméra, photos, micro, reconnaissance vocale, localisation présentes.
- `ios/Runner/PrivacyInfo.xcprivacy` présent ; dans Xcode (ouvrir `ios/Runner.xcworkspace`, **jamais** `.xcodeproj`) → cible Runner → Build Phases → Copy Bundle Resources : le fichier doit apparaître.
- Signing & Capabilities (cible Runner) : Team `F6XWK2W7XG`, Bundle Identifier `com.azexpress.app`, capacités **Push Notifications**, **Associated Domains** (`applinks:az-express-b0469.web.app`), **Background Modes** (Location updates, Background fetch, Remote notifications).
- Developer portal → Identifiers → `com.azexpress.app` : Push Notifications et Associated Domains cochés. Une clé APNs (.p8) doit être chargée dans Firebase Console → Project settings → Cloud Messaging → Apple app configuration (sinon aucune notification sur iPhone).
- `ios/Podfile` : contient `PERMISSION_LOCATION=1` et `PERMISSION_MICROPHONE=1` (sinon micro et localisation « toujours » toujours refusés).

## 3. Dépendances
```bash
flutter config --no-enable-swift-package-manager   # le projet reste en CocoaPods
flutter pub get
flutter precache --ios
cd ios && pod install --repo-update && cd ..
```
`ios/Podfile.lock` peut changer légèrement : ne pas le committer sans relecture.

## 4. Numéro de build — NE PAS INVENTER
La version marketing est `1.0.10` (`pubspec.yaml` : `1.0.10+11`, **ne pas modifier** le suffixe, il commande aussi Android).
1. App Store Connect → My Apps → AZ Express → TestFlight (et onglet iOS App) : relever le **plus grand numéro de build déjà envoyé** pour la version 1.0.10.
2. Prendre un entier strictement supérieur. Exemple d'usage : `export IOS_BUILD_NUMBER=<valeur confirmée>`.
Les builds 12 et 13 apparaissent dans l'historique git, mais rien ne prouve qu'ils ont été envoyés ni qu'ils sont les derniers.

## 5. Compilation locale de l'IPA signée (sans envoi)
Créer `export_options.plist` hors du dépôt (par exemple `~/export_options.plist`) :
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>F6XWK2W7XG</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><false/>
</dict></plist>
```
`destination=export` garantit que rien n'est envoyé. Puis :
```bash
python3 scripts/build_mobile.py ipa --build-number "$IOS_BUILD_NUMBER" --export-options "$HOME/export_options.plist"
```
Sortie : `build/ios/ipa/*.ipa` et `build/ios/archive/Runner.xcarchive`.
Si l'étape « FlutterFire upload-crashlytics-symbols » de Xcode tente un envoi, la neutraliser comme le fait `codemagic.yaml` (commande `flutterfire` factice) ou compiler depuis Xcode.

## 6. Vérifications de l'IPA (toujours locales)
```bash
unzip -q -o build/ios/ipa/*.ipa -d /tmp/azipa
ls /tmp/azipa/Payload/Runner.app | grep -E "PrivacyInfo|GoogleService"
plutil -p /tmp/azipa/Payload/Runner.app/Info.plist | grep -E "CFBundleShortVersionString|CFBundleVersion|UIBackgroundModes" -A4
codesign -d --entitlements :- /tmp/azipa/Payload/Runner.app 2>/dev/null | grep -A1 aps-environment   # attendu : production
```
Attendus : `PrivacyInfo.xcprivacy` présent ; version 1.0.10 ; build = `IOS_BUILD_NUMBER` ; `aps-environment` = `production` ; pas de `bluetooth-peripheral`. Dans Xcode Organizer → archive → « Generate Privacy Report » : lire les API signalées (cas `firebase_auth` à confirmer).

## 7. Paramètres App Store Connect / TestFlight à vérifier (lecture seule)
- App créée avec le bundle `com.azexpress.app`, nom, langue principale, catégorie, classification d'âge.
- Informations de confidentialité (« App Privacy ») alignées sur `PrivacyInfo.xcprivacy` : coordonnées, position précise, photos, audio, contenu utilisateur, identifiants, historique d'achats, données financières (solde), diagnostics ; **pas de suivi**.
- URL de politique de confidentialité (`/confidentialite`), URL d'assistance, URL ou procédure de suppression de compte.
- TestFlight : testeurs internes ajoutés ; « Informations sur le test » avec compte de démonstration (client et livreur fictifs) pour le relecteur ; conformité export (chiffrement standard HTTPS).
- Aucun envoi tant que vous ne l'avez pas autorisé. Envoi possible ensuite via Xcode Organizer (Distribute App → App Store Connect) ou Transporter, ou le workflow Codemagic (qui publie vers App Store Connect avec `submit_to_testflight: false`).

## 8. Tests sur iPhone (aucun n'est fait à ce jour)
Première ouverture et connexion de chaque rôle ; notifications (premier plan, arrière-plan, app fermée) ; selfie obligatoire du livreur (caméra frontale) ; GPS livreur avec écran verrouillé 10 minutes (pastille bleue) ; micro (message vocal chat) ; dictée AZ IA ; liens universels ; suppression de compte (client puis partenaire) ; paiements électroniques masqués ; recharge manuelle depuis l'admin ; voix AZ IA ; rotation et petits écrans.

## 9. Si la compilation échoue
Ne pas modifier les certificats ni les profils. Noter l'erreur exacte : `pod install` (version CocoaPods), signature (équipe, profil), ou plugin. Les erreurs de signature se règlent dans Xcode → Signing & Capabilities, pas dans le code.
