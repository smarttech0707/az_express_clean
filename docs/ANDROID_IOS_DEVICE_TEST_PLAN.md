# Tests réels Android et iPhone — préparation (2026-10-30)

Base : branche `apple-resubmission-azia-consent`, commit `7a76f18` (identique à `origin`). **Tout le travail de modernisation est non commité** : 47 fichiers modifiés, 41 non suivis. Rien n'a été commité, poussé, déployé ni publié.

## 1. Android — Samsung Galaxy A11 (`R9PN9018DDJ`)

Prérequis déjà vérifiés : appareil détecté par ADB ; clé Google Maps Android autorisée pour l'empreinte de debug de ce PC (3 empreintes).

```powershell
cd D:\az_express_clean
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb devices                      # R9PN9018DDJ doit être « device »
flutter devices
.\run.ps1 -Device R9PN9018DDJ                 # injecte APP_BUILD_NUMBER (pubspec.yaml) ; refus si absent, nul ou invalide
```
Variante sans session `flutter run` (installation d'un APK debug) : le numéro de build est obligatoire (même source que `run.ps1`), un build à 0 ne serait jamais invité à se mettre à jour :
```powershell
$n = & .\scripts\get-app-build-number.ps1; if ($LASTEXITCODE -ne 0) { throw 'APP_BUILD_NUMBER invalide' }
flutter build apk --debug --dart-define-from-file=.env --dart-define=APP_BUILD_NUMBER=$n
& $adb install -r build\app\outputs\flutter-apk\app-debug.apk
```
(`.\run.ps1 -DryRun -Device R9PN9018DDJ` affiche la commande sans lancer Flutter.) Les builds de release passent par `py scripts/build_mobile.py` (voir `docs/MOBILE_FIREBASE_BUILD.md`).
Outils utiles pendant les tests :
```powershell
& $adb shell cmd uimode night yes     # mode sombre   (night no = clair, night auto = système)
& $adb shell settings put system font_scale 1.5   # grande police (remettre 1.0 ensuite)
& $adb shell input keyevent 4         # bouton Retour système
& $adb logcat -c ; & $adb logcat | Select-String -Pattern "Authorization failure|FATAL|Exception"
```
Ne collez jamais `.env` dans un message ; les journaux ci-dessus ne l'affichent pas.

### Check-list (cocher sur l'appareil)
1. **Nouvel accueil** : carte visible, carte « Livraison » en avant, 6 cartes de services, bouton « Plus de services » (4 catégories).
2. **Google Maps** : la carte d'Abengourou s'affiche (aucune erreur d'autorisation).
3. **Panneau déplaçable** : 3 positions (poignée : toucher et glisser) ; la poignée reste visible quand les services défilent ; glisser le contenu déplace aussi le panneau ; la carte reste utilisable au-dessus.
4. **Barre du bas** : Accueil, Djassa, Suivi, Profil + « + » central, lisibles.
5. **Espace professionnel** (3 appuis cachés ou carte « Pro ») : 3 catégories, 8 accès ; chaque carte ouvre la bonne connexion ; flèche Retour.
6. **Menu administrateur** (5 appuis sur le logo de l'écran de lancement, puis connexion super-admin) : 8 catégories, recherche (« recharge », « QR »), 41 fonctions ; Carte live et Tracking Live présentes.
7. **14 écrans admin à onglets** : Événementiel, Auto & Moto, Zones Géo, Recharges, Stats Géo, E-Kbine, Boutique, Support, Commissions, Flottes, Demandes (restaurants, vendeurs, boulangeries, pharmacies, prestataires). Pour chacun : onglet actif lisible, tous les onglets atteignables, indicateur de bord, contenu conforme au titre.
8. **Boutons Retour** : flèche de l'application et bouton système depuis chaque écran ci-dessus, y compris les connexions pro.
9. **Clair / sombre** : refaire 1, 3, 4, 5 en sombre. (Les écrans admin gardent un fond clair : limite connue.)
10. **Grande police (×1,5)** : accueil, menu Plus, onglets admin sans texte coupé.
11. **Note du livreur** : *à ne tester qu'après le déploiement des règles et de la fonction* (sinon la moyenne du livreur ne bouge pas). Avant : la note s'enregistre sur la commande sans erreur.

## 2. iPhone — méthode sûre (Mac)

**Principe : ne jamais appliquer le travail Windows dans le dossier de travail principal du Mac.** On teste dans un second dossier de travail Git isolé (`git worktree`). Le dossier principal du Mac, avec ses modifications locales GPS / Google Maps, n'est pas touché.

Dossier de transfert sur le PC Windows : `D:\az_express_transfer\2026-10-30_modernisation\`
- `windows_modernisation.patch` : 105 fichiers (59 modifiés, 46 ajoutés), **sans** `.env`, clés, keystores, `.aab`, `qr-release/`, `web/downloads/`, journaux. Vérifié : s'applique sans conflit sur `7a76f18`, 0 secret détecté.
- `windows_files.txt` : liste des fichiers du patch.
- `BASE_COMMIT.txt` : `7a76f18b8e58d3b9cc56c3a23f4fbf2fa73ccae0`.
- `mac_precheck.sh` : contrôle **en lecture seule** à lancer sur le Mac.
- `windows_versions/` : versions Windows complètes des 3 fichiers à risque (`client_map.dart`, `driver_tracking_screen.dart`, `pubspec.yaml`) pour une fusion à trois voies.
- Le fichier `az_express_lot_7_10.bundle` déjà présent dans `D:\az_express_transfer\` est un ancien transfert : **non touché**.

> Rien n'a été transféré. Le transfert (clé USB, AirDrop, partage) se fait à votre demande.

### Étapes sur le Mac
```bash
# 0. Dans le dépôt principal du Mac — ne rien modifier, juste lire
cd ~/chemin/vers/az_express_clean
git status
bash /chemin/2026-10-30_modernisation/mac_precheck.sh /chemin/2026-10-30_modernisation
```
Le script : (1) compare la base ; (2) **sauvegarde tout le travail local du Mac** (`git diff HEAD --binary`, copie des fichiers non suivis, référence Git de secours `refs/backup/mac-local-…`) ; (3) liste les fichiers modifiés des deux côtés ; (4) signale les fichiers iOS/GPS/Maps du Mac ; (5) teste à blanc l'application du patch. **Envoyez-moi sa sortie avant la suite.**

```bash
# 1. Dossier de test isolé, à partir de la même base que Windows
git worktree add ../az_ios_test 7a76f18
cd ../az_ios_test
git apply --index --3way /chemin/2026-10-30_modernisation/windows_modernisation.patch
git status --short | head
```
Si `mac_precheck.sh` a signalé un recouvrement (probable pour `client_map.dart`, `driver_tracking_screen.dart`) : ne pas forcer. Fusion à trois voies manuelle, fichier par fichier :
```bash
# base = HEAD, nôtre = version Mac, leur = version Windows
git show 7a76f18:lib/screens/client/client_map.dart > /tmp/base.dart
git merge-file -p ../az_express_clean/lib/screens/client/client_map.dart /tmp/base.dart \
   /chemin/2026-10-30_modernisation/windows_versions/client_map.dart > /tmp/merged.dart
# Relire /tmp/merged.dart (marqueurs <<<<<<<), puis seulement ensuite le copier dans az_ios_test.
```
Les réglages GPS / Maps propres au Mac et absents du patch (fichiers `ios/…`, `AppDelegate.swift`) se reportent ainsi, sans écraser :
```bash
cd ../az_express_clean && git diff HEAD --binary -- ios > /tmp/mac_ios.patch
cd ../az_ios_test && git apply --3way /tmp/mac_ios.patch
```
Fichiers de configuration locaux (jamais dans Git) à copier **depuis le dossier principal du Mac** : `.env` et `ios/Runner/GoogleService-Info.plist`.

### Lancer sur l'iPhone
```bash
cd ../az_ios_test
cp ../az_express_clean/.env .env
cp ../az_express_clean/ios/Runner/GoogleService-Info.plist ios/Runner/
flutter pub get
cd ios && pod install && cd ..
flutter devices                               # repérer l'identifiant de l'iPhone
# APP_BUILD_NUMBER obligatoire (suffixe +N de pubspec.yaml) : un build à 0 ne serait jamais invité à se mettre à jour
N=$(sed -n 's/^version:[[:space:]]*[^[:space:]]*+\([0-9][0-9]*\)[[:space:]]*$/\1/p' pubspec.yaml)
case "$N" in ''|0*|*[!0-9]*) echo "APP_BUILD_NUMBER invalide (pubspec.yaml)";; *)
  flutter run -d <ID_IPHONE> --dart-define-from-file=.env --dart-define=APP_BUILD_NUMBER=$N;; esac
```
Avec Xcode :
```bash
# N : calculé comme ci-dessus (ne lancer la commande que s'il est valide)
flutter build ios --debug --no-codesign --dart-define-from-file=.env --dart-define=APP_BUILD_NUMBER=$N   # génère la config Dart
open ios/Runner.xcworkspace
```
Dans Xcode : cible **Runner** → *Signing & Capabilities* → votre équipe → choisir l'iPhone en haut → ⌘R. (Premier lancement : sur l'iPhone, Réglages → Général → VPN et gestion de l'appareil → faire confiance au développeur.)

**Pas de TestFlight, pas de push, pas de Codemagic** à ce stade.

### Check-list iPhone (en plus de la liste Android)
1. **Google Maps** : la carte s'affiche. La clé iOS est dans `AppDelegate.swift` ; elle doit être restreinte au bundle `com.azexpress.app` côté Google Cloud (à vérifier, non modifié ici).
2. **Localisation** : demande d'autorisation, point bleu, bouton recentrer.
3. **Geste de retour** : glissement depuis le bord gauche sur les écrans poussés (routes iOS natives).
4. **Zones de sécurité** : barre du bas au-dessus de l'indicateur d'accueil ; panneau déplaçable sur iPhone à encoche.
5. **Onglets admin** : surtout Zones Géo, Auto & Moto, Recharges (défilants) : indicateur blanc visible, chevrons.
6. **Clair/sombre** et **grande police** (Réglages → Accessibilité → Taille du texte).

## 3. Risques à connaître
- Les fichiers **`client_map.dart`** et **`driver_tracking_screen.dart`** sont modifiés sur Windows *et* probablement sur le Mac (GPS/Maps) : fusion manuelle obligatoire.
- `pubspec.yaml` : ajoute la déclaration des polices Urbanist locales (`assets/google_fonts/`) ; à fusionner si le Mac l'a aussi modifié.
- Le patch ne contient pas `ios/` : la clé Maps iOS et les réglages Xcode du Mac ne sont pas écrasés.
- La clé Maps iOS est écrite en dur dans `AppDelegate.swift` (fichier suivi) : acceptable si restreinte, à garder en tête pour la publication.
- **Déploiements en attente de votre accord** (non faits) : règles Firestore de notation et fonction `applyDriverRatingOnOrderUpdate` ; plan dans `docs/DRIVER_RATING_DEPLOYMENT_PLAN.md`.
