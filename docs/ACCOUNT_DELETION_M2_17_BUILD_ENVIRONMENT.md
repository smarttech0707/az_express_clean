# M2.17 — Préparation de l'environnement de build préproduction

Date : 2026-11-11. Lecture seule : aucun build, aucun Gradle/Flutter, aucun accès Firebase (un seul test DNS sur `dl.google.com`), aucun fichier du dépôt modifié, aucune variable persistante changée, aucun cache déplacé.

## 1. Espace disque

| Lecteur | Utilisé | Libre |
|---|---|---|
| C: | 96,5 Go | **3,7 Go** |
| D: | 31,9 Go | **105,5 Go** |

## 2. Emplacements et tailles

| Élément | Emplacement | Taille |
|---|---|---|
| Home Gradle (`GRADLE_USER_HOME` non défini, donc défaut) | `C:\Users\User\.gradle` | 4,96 Go (caches 3,21 ; wrapper 1,71) |
| dont caches du Gradle 8.14.1 / modules-2 / jars-9 | `…\.gradle\caches\` | 1,98 / 0,84 / 0,38 Go ; `build-cache-1` ≈ 0 ; distributions présentes de 8.4 à 9.8.1, dont **8.14.1-bin** |
| Pub cache (`PUB_CACHE` non défini) | `C:\Users\User\AppData\Local\Pub\Cache` | 0,33 Go |
| Android SDK (`ANDROID_HOME` non défini ; `sdk.dir` dans `local.properties`) | `C:\Users\User\AppData\Local\Android\Sdk` | 4,43 Go (build-tools 35.0.0, 36.1.0, 37.0.0 ; NDK, cmake) |
| Flutter SDK | `C:\flutter` | 3,09 Go |
| Temp (`TEMP`/`TMP`, utilisateur) | `C:\Users\User\AppData\Local\Temp` | 1,31 Go |
| `.android` | `C:\Users\User\.android` | 0,01 Go |
| Sorties du projet | `D:\az_express_clean\build` (4,85 Go), `android\.gradle` (0,08), `.dart_tool` (1,04) | sur D: |

Aucune variable (`GRADLE_USER_HOME`, `PUB_CACHE`, `ANDROID_*`, `JAVA_HOME`, `GRADLE_OPTS`, `ORG_GRADLE_PROJECT_*`) n'est définie, donc aucune propriété ambiante ne peut injecter une clé. Java : JDK 21 (Adoptium) dans le PATH. Aucun lien ni jonction sur ces dossiers. `android/gradle.properties` : daemon off, `caching=true`, `-Xmx3g`, `kotlin.incremental=false` (le commentaire du fichier relève le conflit projet sur D: / pub cache sur C:).

Cache « chaud » : un APK debug du même dépôt a été construit le 2026-11-07 23:30 (`build\app\outputs\apk\debug\app-debug.apk`, 218 Mo) et `.dart_tool\package_config.json` est présent. Aucun `build\app\outputs\flutter-apk\app-debug.apk` périmé n'existe (seul un `app-release.apk` d'octobre), donc le moteur ne peut pas auditer un ancien APK par erreur.

## 3. Besoin en espace pour le premier build debug

Estimation (non mesurée, aucun build lancé) :
- **Cache chaud conservé sur C:** (recommandé) : écritures sur C: = Temp (≈ 0,3–0,8 Go) + éventuelles nouvelles transformations Gradle (quelques centaines de Mo), soit ≈ **0,5–1,5 Go** ; sorties (`build`, ~0,3–1 Go) sur D:. Les 3,7 Go libres suffisent, avec peu de marge.
- **Home Gradle neuf sur D:** ≈ 3–5 Go sur D: (re-téléchargement de Gradle 8.14.1, AGP, Kotlin, dépendances), **réseau obligatoire**, build nettement plus long ; ne libère que ~1,5 Go sur C:.
- L'estimation de 3,7 Go de M2.10 correspondait à un cas à froid, pas au cas actuel.

## 4. Faisabilité d'un environnement de build sur D: (sans modifier les scripts)

| Option | Faisable | Remarque |
|---|---|---|
| **A. `TEMP`/`TMP` vers `D:\az-build-temp` pour la session PowerShell uniquement** | Oui, **recommandée** | Variables de processus (`$env:TEMP`), héritées par Python, Flutter et Gradle (`subprocess.call` sans `env=` hérite de `os.environ`). Rien de persistant. Chemin ASCII, compatible avec `ascii_scratch_parent()`. Supprime l'écriture du Temp sur C: |
| B. `GRADLE_USER_HOME=D:\gradle-home` pour la session | Oui, **non recommandée** | Cache vide : téléchargement complet (réseau), perte du cache chaud ; ne résout pas le Pub cache ni le SDK (restent sur C:) |
| C. Déplacer ou copier `.gradle`, SDK ou Pub cache | Non (interdit ici) | Nécessiterait une autorisation distincte ; non nécessaire |
| D. Libérer ≥ 5 Go sur C: par l'utilisateur | Oui | Option la plus simple et la plus sûre (décision propriétaire) |

Aucune modification du projet n'est nécessaire. Mise en route proposée (**non appliquée**) :

```powershell
New-Item -ItemType Directory -Force D:\az-build-temp | Out-Null
$env:TEMP = 'D:\az-build-temp'; $env:TMP = $env:TEMP     # cette session seulement
powershell -ExecutionPolicy Bypass -File test-env\build-test-apk.ps1 -GoogleServices <chemin hors dépôt> -MapsDisabled
```

Garde-fou proposé : vérifier `Get-PSDrive C` avant (≥ 3 Go) et interrompre si C: passe sous 1 Go libre pendant le build.

## 5. `build_preprod.py` et un `google-services.json` hors du dépôt

**Oui.** `check_paths` ne refuse que : `.env*`, `android/app/google-services.json` (production) et config identique au natif ; aucune obligation d'être dans le dépôt. Vérifié en réel en M2.13 (wrapper `-CheckOnly` avec un fichier dans `%TEMP%\M2.13 dossier été à vérifier\`, accents et espaces). Au build, le moteur copie le fichier vers `android/app/src/debug/google-services.json` (dossier de test, ignoré par Git) et le supprime ensuite (`finally`) ; l'original hors dépôt n'est ni modifié ni déplacé.

## 6. Procédure de validation locale du vrai fichier Firebase préproduction

Script de contrôle en lecture seule (scratchpad, hors dépôt) :
`C:\Users\User\AppData\Local\Temp\claude\d--az-express-clean\c579b050-5748-4442-a523-d168d26fdffb\scratchpad\validate_preprod_gs.py <chemin>`. Il n'affiche que PASS/FAIL, aucune valeur, aucun réseau. 15 contrôles :
- fichier régulier, hors dépôt, différent du fichier de production ;
- `project_id` = `az-express-preprod` ; `project_number` = `306761725053` ;
- un seul client, package `com.azexpress.app.test` ; `mobilesdk_app_id` de la forme `1:306761725053:android:…` ;
- une clé API (forme seulement) ; bucket `az-express-preprod…` ;
- aucun marqueur de production (liste de `guards.js` + `az-express-b0469`, `az-express-clean`, `697217052961`) ;
- égalité avec les defines Dart (projet, expéditeur, app id, bucket, clé), `AZ_REQUIRED_FIREBASE_PROJECT`, `DISABLE_FCM=true`, pas de `TEST_MAPS_API_KEY`.

Essais : fichier de production → **échec** (plusieurs contrôles FAIL, exit 1) ; fichier synthétique dérivé des defines → **15/15 PASS** (supprimé ensuite). Cela ne prouve pas que le vrai fichier de la console est conforme (il n'existe pas encore ici).

Séquence recommandée à la réception du fichier : 1) `validate_preprod_gs.py` ; 2) wrapper `-CheckOnly -MapsDisabled` ; 3) seulement ensuite M2.16.

## 7. Préconditions restantes pour reprendre M2.16

1. **Fournir le vrai `google-services.json`** de l'app `com.azexpress.app.test` (console `az-express-preprod`), hors dépôt, avec son chemin exact. *Bloquant.*
2. Confirmer que `306761725053` est bien le numéro de la console (le script le compare en dur). *Bloquant.*
3. Décider de l'espace : option A seule (marge d'environ 3 Go sur C:) ou libération préalable sur C: (option D).
4. Réseau et dépôts Maven : non testés (DNS seulement). Un cache chaud réduit le risque sans l'exclure. Le Kotlin de M2.9 n'a jamais été compilé : NON VÉRIFIÉ ; en cas d'échec Gradle, arrêt et nouvelle autorisation.
5. Autorisation M2.16 à reconduire explicitement après réception du fichier.

## 8. État Git

HEAD d65c8f0, index 0, stash 0, 62 modifiés ; non suivis 200 → 201 (ce rapport). Aucun fichier du dépôt ni cache modifié, aucune variable système changée. Aucun commit, push, stash, reset ni clean.

## Conclusion : **VALIDÉ AVEC RÉSERVES**

Environnement faisable sans toucher au projet (option A, non persistante). Réserves : fichier Firebase réel absent, numéro de projet non confirmé, réseau et compilation Kotlin non vérifiés, marge disque faible sur C:.

**STOP.**
