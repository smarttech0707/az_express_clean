# Mission M2.10 — Relecture de sécurité Gradle Kotlin

Relecture **locale** de la modification de `android/app/build.gradle.kts` (M2.9). Gradle n'a pas été lancé, aucune compilation (APK, AAB, IPA, Web), aucun accès Firebase, aucun IAM, aucune écriture dans `config/app_versions`, aucun nettoyage de cache, aucune commande Git d'écriture (seule lecture : `git show HEAD:…`, `git diff`, `git status`). `build_mobile.py` et `run.ps1` ne sont pas modifiés. Le fichier Gradle lui-même n'a **pas** été modifié par cette mission.

## 1. Verdict

| Critère | Statut |
|---|---|
| Cohérence syntaxique Kotlin DSL (lecture) | **PASS par relecture** ; compilation **NON VÉRIFIÉE** (interdite) |
| Types et conversions | **PASS par relecture** (§3) |
| Comportement production avant/après identique | **PASS** pour la logique (modèle + comparaison octet à octet de tout le reste du fichier) ; exécution Gradle **NON VÉRIFIÉE** |
| Chemin de transmission de la clé de test | **compris et testé côté Python** ; lecture effective par Gradle **NON VÉRIFIÉE** |
| `-MapsDisabled` : aucune clé transmise, aucune ancienne clé réactivée | **PASS après une correction ciblée** (régression de M2.9 trouvée, §5) |
| `-MapsDisabled` ne contourne aucun contrôle de séparation Firebase | **PASS** (tests) |
| Fuite de la clé dans journaux ou messages | **PASS** sur toutes les sorties testées ; journaux réels de Gradle **NON VÉRIFIÉS** |
| Aucun build, Gradle ni accès distant | **PASS** |

## 2. Lignes examinées

Fichier `android/app/build.gradle.kts` (CRLF dans la copie de travail, LF dans Git à cause de `core.autocrlf=true` : le diff Git est donc lu avec normalisation). Seule la zone `defaultConfig`, lignes 50 à 61, diffère de `HEAD` (7 lignes ajoutées, 3 retirées) :

```kotlin
manifestPlaceholders["MAPS_API_KEY"] =
    if (project.hasProperty("azTestSuffix")) {
        val testMapsKeyFile = project.findProperty("azTestMapsKeyFile") as String?
        if (testMapsKeyFile != null) project.file(testMapsKeyFile).readText().trim()
        else (project.findProperty("azTestMapsKey") as String? ?: "")
    } else localProperties.getProperty("MAPS_API_KEY", "")
```

Avant (HEAD) :

```kotlin
manifestPlaceholders["MAPS_API_KEY"] =
    if (project.hasProperty("azTestSuffix")) (project.findProperty("azTestMapsKey") as String? ?: "")
    else localProperties.getProperty("MAPS_API_KEY", "")
```

Preuves de la portée de la modification (test `KotlinTextReviewTest`) : tout ce qui précède et suit ces lignes (`applicationId`, `minSdk`, `versionCode`, signature, `buildTypes`, `sourceSets`, plugins) est **identique octet pour octet** à `HEAD` ; seules les lignes attendues ont changé ; la condition `project.hasProperty("azTestSuffix")` et l'appel `localProperties.getProperty("MAPS_API_KEY", "")` sont conservés mot pour mot (seule une accolade fermante `} ` précède désormais le `else`).

## 3. Relecture Kotlin DSL

| Point | Analyse | Statut |
|---|---|---|
| Structure | `if (cond) { val …; if (x != null) A else B } else C` : un `if` utilisé comme expression prend la valeur de la dernière expression du bloc ; `else` sur la ligne suivante est admis (le code d'origine le faisait déjà). Les trois chemins produisent un `String` | cohérent |
| `findProperty(...) as String?` | `Any?` converti en `String?` ; une valeur `-P` est toujours une chaîne ; même idiome que le code existant | cohérent |
| `project.file(testMapsKeyFile)` | `testMapsKeyFile` est un `val` local, converti automatiquement en `String` après le test `!= null` ; `Project.file(Object)` résout un chemin relatif depuis `android/app` et accepte un chemin absolu. Le préfixe explicite `project.` évite toute ambiguïté dans la portée `defaultConfig` (le code d'origine utilisait déjà `project.findProperty` au même endroit) | cohérent |
| `.readText().trim()` | `File.readText()` (bibliothèque Kotlin) lit en UTF-8 par défaut ; le moteur Python écrit en UTF-8 **sans BOM**, sans retour à la ligne (test). `trim()` retire les blancs en début/fin ; un BOM éventuel **ne serait pas** retiré (non pertinent ici) | cohérent |
| Affectation à `manifestPlaceholders` | map `Map<String, Any>` du DSL Android : un `String` est accepté, comme avant | cohérent |
| Chemins Windows | le chemin est transmis tel quel ; Gradle découpe `-Pnom=valeur` au **premier** `=` : un chemin avec `\`, des espaces ou un `=` reste intact (test sur 3 formes). Le découpage en arguments par Flutter sur Windows pour un chemin avec **espaces ou caractères non ASCII** n'a pas pu être exercé : **NON VÉRIFIÉ** (le chemin temporaire de ce poste, `C:\Users\User\AppData\Local\Temp\az-preprod-…\maps_test_key.txt`, n'en contient pas) | partiel |
| Exécution | le bloc s'exécute à la **configuration** de Gradle. `org.gradle.configuration-cache` n'est pas activé dans `android/gradle.properties` ; `org.gradle.caching=true` (cache local) et `org.gradle.daemon=false` sont activés | voir §6 |
| Compilation du script | Gradle 8.14.1 / AGP 8.11.1 : aucune construction non standard n'est utilisée | **NON VÉRIFIÉE** |

Comportement du fichier de clé (modèle de décision, `ProductionBeforeAfterModelTest`) :

| Situation (mode test) | Résultat |
|---|---|
| fichier valide | contenu nettoyé des blancs ; **il prime** sur l'ancienne propriété `azTestMapsKey` |
| fichier vide ou blanc | `""` : cartes silencieusement désactivées (le moteur Python ne produit jamais ce cas) |
| fichier absent ou illisible | exception à la configuration : **échec franc, aucun repli** vers une autre clé ; le message du JDK contient le **chemin**, pas la clé |
| contenu invalide | **non validé par Gradle** (la validation est faite par Python avant) |
| propriété absente | ancien comportement (`azTestMapsKey` ou `""`) |

## 4. Production avant / après

Tableau de décision (16 combinaisons : suffixe présent/absent × `azTestMapsKeyFile` × `azTestMapsKey` × `MAPS_API_KEY` local) :

| Cas | Avant | Après | Identique |
|---|---|---|---|
| sans `azTestSuffix` (build de production), 8 combinaisons, y compris si les propriétés de test sont définies par erreur | `MAPS_API_KEY` de `local.properties` (ou `""`) | idem | **oui (8/8)** |
| mode test sans `azTestMapsKeyFile` | `azTestMapsKey` ou `""` | idem | **oui** |
| mode test avec `azTestMapsKeyFile` | `azTestMapsKey` | contenu du fichier | non (voulu, réservé au test) |
| mode test, repli sur la clé locale de production | jamais | jamais | oui |

La branche production n'est ni lue ni évaluée dans les nouveaux chemins ; les propriétés de test sont **ignorées** sans `azTestSuffix` (aucune activation accidentelle en production). C'est un **modèle** transcrit à la main, relié au texte Kotlin par un test d'ordre des éléments : la logique est démontrée, l'exécution par Gradle ne l'est pas.

## 5. Chaîne `-MapsDisabled` et régression trouvée

Chemin : `build-test-apk.ps1 -MapsDisabled` → `--maps-disabled` → `build_preprod.py` → `flutter build apk --debug … --android-project-arg=…` → `-P…` → Gradle.

- Le wrapper ne contient aucun paramètre de clé (test) et ne fait que transmettre `--maps-disabled`.
- Le moteur refuse `--maps-disabled` si le fichier de configuration contient une clé, n'écrit aucun fichier de clé, n'ajoute **pas** `TEST_MAPS_API_KEY` aux defines Dart, et conserve tous les contrôles Firebase : projet de production, numéro de projet, `DISABLE_FCM`, garde de démarrage et fichier natif de production sont toujours refusés avec `--maps-disabled` (tests) ; la garde Node `verify-isolation.js` est toujours appelée (build : avec `--maps-swapped`).

**Régression introduite par M2.9 (corrigée ici, cible étroite).** Avant M2.9, le moteur passait toujours `-PazTestMapsKey=` (vide). M2.9 a supprimé cet argument en mode `--maps-disabled`. Conséquence : une propriété `azTestMapsKey` **ambiante** (`gradle.properties` de l'utilisateur, variable `ORG_GRADLE_PROJECT_azTestMapsKey`) aurait pu injecter silencieusement une ancienne clé dans un build « sans cartes ». Vérification sur ce poste : aucune propriété `azTest*` ambiante (`android/gradle.properties` : aucune ; `~/.gradle/gradle.properties` : absent ; variables d'environnement : aucune) — le risque était latent, pas actif.

Correction (une instruction dans `scripts/build_preprod.py`) : l'argument `--android-project-arg=azTestMapsKey=` (vide, ne contient aucun secret) est de nouveau **toujours** transmis ; une propriété passée en ligne de commande l'emporte sur celles de `gradle.properties` et de l'environnement. Tests adaptés. Aucune autre modification de code.

Limite restante : une propriété ambiante **`azTestMapsKeyFile`** (nom introduit en M2.9, inexistant ailleurs) l'emporterait en mode `--maps-disabled`. La neutraliser exige de modifier le fichier Gradle (traiter une valeur vide comme absente) : **hors périmètre de cette mission**, risque jugé très faible, proposé comme évolution éventuelle (autorisation distincte).

## 6. Fuites et risques résiduels

1. Journaux : le moteur n'affiche jamais la clé (tests avec fausses clés, succès, échec, restauration en échec, mode désactivé). Les journaux réels de Gradle/Flutter (notamment `--info`, `--debug`) n'ont pas été observés : **NON VÉRIFIÉ**. Une exception de lecture de fichier cite le chemin, pas le contenu.
2. La clé de test est l'une des **entrées** de la tâche de fusion du manifeste ; avec `org.gradle.caching=true`, une sortie contenant la clé peut rester dans le cache de build local de l'utilisateur. Même nature que pour la clé de production aujourd'hui ; faible.
3. Fichier temporaire de clé : sous Windows, pas d'ACL restrictive réelle (`0600` limité), supprimé avec le dossier temporaire ; interruption brutale = fichier résiduel dans le dossier temporaire de l'utilisateur.
4. La clé est de toute façon intégrée au manifeste de l'APK (propriété de Google Maps).
5. Le fichier Gradle est **partagé avec la production** : toute erreur de compilation que la relecture n'aurait pas vue casserait aussi ces builds. Elle serait immédiatement visible (échec de configuration, rien de publié).

## 7. Tests exécutés

Nouveau `scripts/test_gradle_maps_review.py` (18 tests) : relecture textuelle contre `HEAD` (reste du fichier identique, lignes modifiées attendues, fins de ligne/encodage, ordre des éléments du modèle, propriété lue uniquement dans la branche test), modèle avant/après (production identique, jamais de repli vers la clé locale, sémantique du fichier : vide, absent, BOM, priorité), arguments réellement générés (forme du fichier de clé sans BOM ni saut de ligne, chemins Windows, mode désactivé sans clé, garde Node toujours appelée, séparation Firebase non assouplie, refus sans fuite de clé), wrapper (commutateur transmis, aucune clé).

Résultats exacts : `test_gradle_maps_review.py` **18 réussis** ; `test_build_preprod*.py` **66 réussis** (après adaptation de 2 assertions M2.9) ; suite Python complète **139 réussis**. Vérification réelle sans build : `build-test-apk.ps1 -CheckOnly -MapsDisabled` avec fichier natif synthétique → `validation PASS`, `APP_BUILD_NUMBER=11`. `maps_key.dart` propre, aucun dossier de récupération, `android/app/src/debug/` inchangé.

Non fait (interdit) : Gradle, compilation Kotlin, build.

## 8. Éléments NON VÉRIFIÉS

Compilation du script Kotlin ; lecture effective du fichier de clé par Gradle ; découpage des arguments par Flutter pour un chemin avec espaces ou caractères non ASCII ; journaux réels ; contenu du cache de build ; propriété ambiante `azTestMapsKeyFile` neutralisée ; un APK réel.

## 9. État Git

| | Avant M2.10 | Après M2.10 |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | idem |
| Index / stash | vide / 0 | vide / 0 |
| Suivis modifiés | 62 | 62 (`build.gradle.kts` non modifié par cette mission) |
| Non suivis (`git status --porcelain`) | 190 | **192** (+ `scripts/test_gradle_maps_review.py`, + ce rapport) |

Fichier modifié par cette mission : `scripts/build_preprod.py` (une instruction, non suivi) et deux assertions de `scripts/test_build_preprod_maps.py`. `build.gradle.kts` : blob `29bd8394…` (identique à M2.9). Fichiers protégés inchangés (`git hash-object`) : `passwordReset.js` 26975f60, `index.js` a9ba2c0d, `firestore.rules` 5341bfd6, `storage.rules` f3b5b608, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a ; checklist `f97ccad5…`. `build_mobile.py` et `run.ps1` inchangés. Travaux M1 à M2.9 préservés.

## 10. Décisions nécessaires

1. Accepter le risque Kotlin résiduel (relecture seule) ou faire compiler le script lors du premier build autorisé, avec la possibilité de revenir aux 3 lignes d'origine (visibles dans `git diff`).
2. Souhaitez-vous neutraliser aussi une propriété ambiante `azTestMapsKeyFile` (évolution mineure du Gradle) ? Non recommandé sans besoin.
3. Pour le premier APK : `-MapsDisabled` ou clé de test dédiée.
4. Fournir le `google-services.json` préproduction et autoriser séparément le premier APK Debug (réseau, ≈ 3,7 Go libres).

**Arrêt : aucune autre mission lancée.**
