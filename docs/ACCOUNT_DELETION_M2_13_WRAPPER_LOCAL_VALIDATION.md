# M2.13 — Validation locale du wrapper préproduction

Date : 2026-11-11. Aucun build Flutter/Gradle, aucun APK/AAB, aucun accès distant, aucune modification de dépôt.

## 1. Commandes exécutées

Dossier de travail temporaire (hors dépôt, créé puis supprimé) : `%TEMP%\M2.13 dossier été à vérifier\` (espaces + accents).

1. Fichier natif **synthétique** généré depuis les valeurs de `test-env/dart-defines.test.json` (aucune valeur affichée), package `com.azexpress.app.test` :
   `py <scratchpad>\make_native_m213.py "%TEMP%\M2.13 dossier été à vérifier\google-services.json"`
2. Wrapper réel :
   `powershell -NoProfile -ExecutionPolicy Bypass -File test-env\build-test-apk.ps1 -GoogleServices "%TEMP%\M2.13 dossier été à vérifier\google-services.json" -CheckOnly -MapsDisabled`
3. Fichier de clé Maps vide : `py <scratchpad>\keyfile_m213.py <fichier natif>` — appelle le vrai `build_preprod.build(..., maps_disabled=True)` dans une **copie jetable** du dépôt (chemin `dépôt été à test`, fausse clé de prod synthétique), l'appel à `flutter` étant remplacé par un enregistreur. Rien n'est compilé.
4. Contrôles négatifs via le wrapper : natif avec `az-express-b0469` ; natif absent.

## 2. Résultats

| Vérification | Résultat |
|---|---|
| Wrapper `-CheckOnly -MapsDisabled`, chemin avec espaces/accents | **OK**, code 0 : « Isolation validée… » / « validation PASS (values hidden). APP_BUILD_NUMBER=11 » |
| Préconditions Firebase préprod sans accès distant | OK : contrôle purement local (config + natif + garde Node `guards.js`) ; aucun appel réseau dans ce chemin de code |
| Natif pointant vers la production | **Refusé** (« reference to the production Firebase project »), wrapper en erreur |
| Natif absent | **Refusé** (« file not found ») |
| Fichier de clé Maps en mode désactivé | contenu `b''` (vide) ; chemin ASCII ; `azTestMapsKey=` vide ; aucun `AIza` dans argv, defines, logs |
| Nettoyage | fichier de clé et dossier scratch supprimés ; `maps_key.dart` restauré à l'identique ; pas de dossier `az-preprod-recovery` ; pas de copie native résiduelle ; copie jetable et dossier de test supprimés |
| Fichiers de production/préprod modifiés | **aucun** : hachage de tous les fichiers modifiés/non suivis identique avant/après (437 fichiers hors `build/`), `git status` identique |

Précision : `--check-only` s'arrête avant la création du fichier de clé ; la vérification du fichier vide (point 3) passe donc par `build()` réel avec appel `flutter` simulé, pas par le wrapper lui-même.

## 3. Fichiers

Consultés : `test-env/build-test-apk.ps1`, `scripts/build_preprod.py` (`main`), `test-env/dart-defines.test.json` (clés seulement, valeurs non affichées), `lib/constants/maps_key_test.dart`, `test-env/lib/guards.js` (copiés dans la copie jetable).
Modifiés dans le dépôt : **aucun**. Créé : ce rapport. Scratchpad : `make_native_m213.py`, `keyfile_m213.py`, listes de hachages avant/après.

## 4. Anomalies

- **63 dossiers `az-preprod-*` résiduels dans le dossier temporaire système** (tous datés du 2026-11-11 ; 43 contiennent `defines.json` + `maps_test_key.txt`, 20 `defines.json`). Cause probable : les tests de « kill » (sous-processus terminés par `os._exit`, M2.8/M2.11/M2.12) ne laissent pas le `finally` nettoyer. Contenu : fausses valeurs de test uniquement (non ouvert). Aucun lien avec le wrapper (aucun résidu `az-preprod-check-*`). Non supprimés (aucune autorisation) ; correction possible plus tard : faire utiliser aux tests de kill un `TMP` dédié supprimé en `tearDown`.
- Le message d'échec du wrapper passe par `NativeCommandError` de PowerShell 5.1 (cosmétique, le code de sortie et le message de l'engine sont corrects).
- `android/app/google-services.json` existe (ignoré par Git, daté 2026-08-14) ; non touché, non lu, hors du chemin `--check-only`.

## 5. Limites restantes (NON VÉRIFIÉ)

- Compilation Kotlin de `build.gradle.kts` et transmission réelle de `-PazTestMapsKeyFile` par Flutter/Gradle : NON VÉRIFIÉ (aucun build autorisé).
- Fichier natif réel de préproduction et numéro de projet `306761725053` en console : NON VÉRIFIÉ (fichier synthétique utilisé).
- Contrôle de l'APK (`aapt2`, scan de clé) : non exercé hors tests unitaires.
- Cache de build Gradle avec clé de test : inchangé ; évité par `-MapsDisabled`.

## 6. État Git

| | Avant | Après |
|---|---|---|
| HEAD | d65c8f0 | d65c8f0 |
| Index / Stash | 0 / 0 | 0 / 0 |
| Modifiés | 62 | 62 |
| Non suivis (porcelain) | 196 | 196 + ce rapport = 197 |

Hachages inchangés : passwordReset 26975f60, index a9ba2c0d, firestore.rules 5341bfd6, storage.rules f3b5b608, build.gradle.kts 29bd8394 ; `build_mobile.py` (4b1e02fe) et `run.ps1` (1066170e) identiques avant/après. Aucun commit/push/stash/reset/clean.

## 7. Conclusion : **VALIDÉ AVEC RÉSERVES**

Le wrapper réel fonctionne en `-CheckOnly -MapsDisabled` avec chemin accentué/espacé, refuse la production et un natif absent, et le fichier de clé est vide, ASCII et nettoyé en mode désactivé. Réserves : Kotlin/Gradle/Flutter non exercés, natif réel non fourni, 63 dossiers temporaires résiduels issus des tests.

**STOP** — en attente d'une autorisation écrite pour la mission suivante.
