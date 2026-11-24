# Mission M2.2 — Corrections et alignement final du contrôle des versions

Travaux **locaux** uniquement. Aucun accès Firebase (production, préproduction, distant), aucune écriture dans `config/app_versions`, aucune règle, IAM, secret ni configuration modifiés, aucun déploiement. **Aucun build Android, APK, App Bundle ou IPA lancé** ; aucun cache supprimé ni nettoyé. La checklist de suppression de compte n'a pas été touchée (date de modification inchangée : 2026-11-06 18:32 UTC, travail non validé préexistant). T0 n'est ni défini ni activé.

## 1. Verdict

| Critère | Statut |
|---|---|
| Valeurs non positives ou invalides rejetées (`0`, `-5`, `abc`, absente, et au-delà de 2 100 000 000) | **PASS** (Python et PowerShell, §3) |
| Tests ciblés passent | **PASS** (§5) |
| Scripts/documents concernés alignés sur le mécanisme centralisé | **PASS** pour `run.ps1`, plan de test appareil, deux scripts `test-env` ; **les deux scripts `test-env` n'ont pas été exécutés** (ils lancent un vrai build) : analyse syntaxique seule → **NON VÉRIFIÉ en exécution** |
| Aucun fichier protégé / travail préexistant écrasé | **PASS** (§7) |
| Aucun accès distant, déploiement ou build | **PASS** |

La vérification de `APP_BUILD_NUMBER` dans un APK/IPA réel reste **BLOQUÉE / NON VÉRIFIÉE** (héritée de M2.1, hors périmètre de M2.2).

## 2. Contrôles préalables [F]

HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0 ; 53 fichiers suivis modifiés, 177 non suivis. Aucun des fichiers cibles ne contenait de modification préexistante en dehors de M2/M2.1 (`run.ps1`, `scripts/build_mobile.py`, `scripts/test_build_mobile.py` modifiés par M2/M2.1 ; `docs/ANDROID_IOS_DEVICE_TEST_PLAN.md`, `test-env/build-emulator-apk.ps1`, `test-env/build-test-apk.ps1` propres). Travaux M1/M2/M2.1 préservés.

## 3. A — Validation du numéro de build

Règle commune : **entier strictement positif, au plus 2 100 000 000** (limite du `versionCode` Google Play). Tout le reste est refusé avec un code de sortie non nul, sans afficher de valeur sensible.

| Fichier | Changement |
|---|---|
| `scripts/build_mobile.py` | `MAX_BUILD_NUMBER`; `positive_int` (option `--build-number`) et `resolve_build_number` (surcharge IPA ou `+N` de `pubspec.yaml`) refusent 0, négatif, non entier, booléen, trop grand. Les erreurs sortent par `parser.exit(2)` / erreur argparse (**code 2**) |
| `scripts/get-app-build-number.ps1` (nouveau) | **Source unique côté PowerShell** : lit `pubspec.yaml`, mêmes règles, `exit 1` + message sur stderr si invalide ; affiche seulement le numéro si valide |
| `run.ps1` | n'analyse plus `pubspec.yaml` lui-même : appelle l'assistant ; refus (code non nul) si invalide ou si `APP_BUILD_NUMBER` figure dans `.env`. Nouveau paramètre `-Device <id>` (équivalent de `flutter run -d`), les paramètres `-release`, `-build`, `-DryRun` sont conservés |

Comportement des compilations valides préservé : `+11` ⇒ `APP_BUILD_NUMBER=11` ; commande `flutter run` identique avec `-d` en plus quand `-Device` est fourni.

## 4. B — Procédures secondaires alignées

| Fichier | Changement |
|---|---|
| `docs/ANDROID_IOS_DEVICE_TEST_PLAN.md` | Android : `.\run.ps1 -Device R9PN9018DDJ` ; APK debug : numéro obtenu via l'assistant, puis `--dart-define=APP_BUILD_NUMBER=$n` ; renvoi vers le script pour les releases. iPhone : calcul de `N` depuis `pubspec.yaml` avec refus si invalide, puis `flutter run`/`flutter build ios` avec `--dart-define=APP_BUILD_NUMBER=$N` |
| `test-env/build-emulator-apk.ps1` | calcule le numéro (assistant) et **annule le build** s'il est invalide ; ajoute `--dart-define=APP_BUILD_NUMBER=…` à la commande. Garanties d'isolation (aucun `.env`, contrôle de l'APK) inchangées |
| `test-env/build-test-apk.ps1` | idem ; refuse en plus un fichier de dart-defines de test contenant déjà `APP_BUILD_NUMBER` |

BOM UTF-8 et mise en forme d'origine des scripts préservés (diffs : 7 et 10 lignes). Vérification : analyse syntaxique PowerShell (Parser) des 4 scripts → **0 erreur**. **Exécution complète des scripts `test-env` : NON VÉRIFIÉE** (elle déclencherait un build Android ; interdit).

## 5. Tests exécutés (résultats exacts)

| Commande | Résultat |
|---|---|
| `py -m unittest test_app_build_number test_build_mobile test_ios_build_guard` (dossier `scripts`) | **55 tests, OK** (42 existants + 13 nouveaux) |
| dont `test_app_build_number.py` — table `resolve_build_number` ; `main()` avec racine temporaire et configuration factice : `--build-number` ∈ {`0`, `-5`, `abc`, `1.5`, vide, espace, `2100000001`, 20 chiffres} ⇒ code **2**, jamais « PASS » ; numéro absent/`+0`/`+-5`/`+abc`/sans `+N`/sans `pubspec.yaml` ⇒ code **2** ; valide ⇒ code 0 et `APP_BUILD_NUMBER=11` ; `--build-number` sur Android refusé | OK |
| dont assistant PowerShell : `+11`, `+2100000000` ⇒ 0 et valeur ; absent, `+0`, `+-5`, `+abc`, `+2100000001`, 20 chiffres, fichier manquant ⇒ code 1, sortie vide | OK |
| dont `run.ps1 -DryRun` copié dans un dossier temporaire (faux `.env`, pubspec variable) : valide ⇒ commande attendue ; `+0`/`+-5`/`+abc`/absent ⇒ refus sans `DRYRUN` ; clé dans `.env` ⇒ refus | OK |
| Analyse syntaxique PowerShell des 4 scripts | 0 erreur |
| `powershell -File scripts/get-app-build-number.ps1` sur le dépôt | `11`, code 0 |

Non lancés : `flutter test`/`flutter analyze` (aucun fichier Dart modifié dans M2.2), `npm test`, émulateurs, tout build.

## 6. Contournements restants

1. `test-env/README-EMULATEURS.md:45` cite `flutter build apk --debug --dart-define=USE_FIREBASE_EMULATORS=true …` sans le numéro (document hors liste autorisée, non modifié).
2. `docs/PROTOCOLE_TESTS_LANCEMENT.md:69` et `docs/ACCOUNT_DELETION_LOCAL_STATUS.md:27` citent `flutter build appbundle --release` direct ; `docs/PUBLICATION_1_0_10_PLAN.md:102,142` citent `flutter build ipa` direct. Non modifiés (hors périmètre).
3. `docs/ACCOUNT_DELETION_RELEASE_CHECKLIST.md:91` : même commande directe ; **exclue** de la mission, intacte.
4. Un `flutter build`/`flutter run` tapé directement reste techniquement possible ; seules les procédures documentées sont alignées.
5. Le web et les binaires déjà publiés restent non bloquables (build 0).
6. Côté Dart, un build à 0 reste volontairement toléré (jamais bloqué) pour ne pas pénaliser les anciens binaires.

## 7. Limites, risques et éléments NON VÉRIFIÉS

- **NON VÉRIFIÉ** : exécution réelle de `test-env/build-emulator-apk.ps1` et `build-test-apk.ps1` ; présence de `APP_BUILD_NUMBER` dans un APK/IPA (BLOQUÉ, voir M2.1) ; contenu de `config/app_versions` et versions publiées.
- `run.ps1` dépend désormais de `scripts/get-app-build-number.ps1` : à copier avec lui si le script est déplacé.
- Le plan de test iPhone suppose un shell `sed`/`case` (macOS) — non exécuté.
- Le cache Gradle regénéré à M2.1 (≈ 2,8 Go) est toujours en place : rien n'a été supprimé (non autorisé).

## 8. Fichiers

Modifiés (3 nouveaux suivis, en plus de ceux de M2/M2.1) : `docs/ANDROID_IOS_DEVICE_TEST_PLAN.md`, `test-env/build-emulator-apk.ps1`, `test-env/build-test-apk.ps1`. Retouchés (déjà modifiés auparavant) : `run.ps1`, `scripts/build_mobile.py`. Créés : `scripts/get-app-build-number.ps1`, `scripts/test_app_build_number.py`, ce rapport. Aucun fichier supprimé.

## 9. État Git

| | Avant M2.2 | Après M2.2 |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | idem |
| Index | vide | vide |
| Stash | 0 | 0 |
| Fichiers suivis modifiés | 53 | **56** (+3) |
| Fichiers non suivis | 177 | **180** (assistant PowerShell, test Python, ce rapport) |

Empreintes inchangées : `passwordReset.js` 26975f60, `index.js` a9ba2c0d, `firestore.rules` 5341bfd6, `storage.rules` f3b5b608, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a. Aucune opération Firebase, aucun émulateur, aucun commit/push/stash/reset/checkout.

## 10. Décisions nécessaires

1. Aligner aussi `README-EMULATEURS.md`, `PROTOCOLE_TESTS_LANCEMENT.md`, `ACCOUNT_DELETION_LOCAL_STATUS.md`, `PUBLICATION_1_0_10_PLAN.md` ? Et la checklist de suppression de compte (stratégie à définir, car elle porte du travail non validé).
2. Autoriser un build réel (Android avec réseau/espace disque, IPA sur Mac/CI) pour vérifier l'injection dans un binaire.
3. Autoriser le nettoyage du cache Gradle regénéré.
4. Liens de mise à jour par canal et écriture de `config/app_versions`.

**Arrêt : aucune autre mission lancée.**
