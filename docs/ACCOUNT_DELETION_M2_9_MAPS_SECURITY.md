# Mission M2.9 — Sécurité des clés Google Maps du build préproduction (F4 et F7)

Travail **local** uniquement, avec de fausses clés. Aucune compilation réelle (APK, AAB, IPA, Web), aucun accès Firebase, aucun IAM, aucune modification de configuration Firebase, de secret réel, de `config/app_versions`, de règles, de `build_mobile.py`, de `run.ps1` ou de la checklist. Aucun nettoyage de cache, aucune suppression de fichier non suivi, aucune commande Git d'écriture. Le premier APK de préproduction reste à autoriser séparément. T0 n'est ni défini ni activé.

## 1. Verdict

| Critère | Statut |
|---|---|
| F4 : une clé de production présente dans l'APK est détectée | **PASS** (Python et Node, UTF-8 et UTF-16, tests) |
| F4 : un original sans clé ne contourne plus le contrôle | **PASS** (échec fermé dans les deux contrôles, tests) |
| F4 : configuration ambiguë ou inattendue refusée | **PASS** |
| F7 : la clé de test n'apparaît plus dans la ligne de commande | **PASS côté moteur** (preuve par test sur la commande réellement construite) |
| F7 : le build Android lit bien la clé depuis le fichier | **NON VÉRIFIÉ** : le fichier Gradle modifié n'a pas pu être compilé (aucun build autorisé) |
| Secrets absents des journaux | **PASS** sur toutes les sorties testées |
| Sauvegarde/restauration de `maps_key.dart` préservées | **PASS** (tests M2.8 conservés + nouveaux) |
| Aucun accès distant ni build | **PASS** |

**F4 est corrigé. F7 est corrigé côté moteur Python, mais ne doit pas être déclaré résolu de bout en bout** tant que le fichier Gradle n'a pas été compilé (§4).

## 2. État initial et fichiers cibles

HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, 60 suivis modifiés, 188 non suivis. `lib/constants/maps_key.dart` propre. Fichiers cibles examinés avant modification : `test-env/check-no-prod-maps-key.js` et `android/app/build.gradle.kts` (suivis, **sans modification locale préexistante**), `scripts/build_preprod.py`, `scripts/test_build_preprod.py`, `test-env/build-test-apk.ps1` (travail M2.6/M2.8, intégralement conservé). Seul appelant du script Node : `build_preprod.py` (recherche dans le dépôt), donc le durcissement ne casse aucun autre usage.

## 3. F4 — détection de la clé de production

Constat M2.8 : si le fichier de référence ne contenait pas de clé `AIza…`, le script Node concluait « aucune clé à rechercher » (code 0) ; une clé de forme inattendue pouvait aussi passer inaperçue.

Corrections :

- **`test-env/check-no-prod-maps-key.js`** (réécrit, même interface) : la clé est identifiée avec la forme d'une clé d'API Google (`AIza` + 35 caractères). Aucune clé, plusieurs clés différentes, forme ou longueur inattendue, fichier de référence illisible, cible absente ou **aucun fichier analysé** → **code 1 (REFUS)**. Messages sans valeur de clé. Détection UTF-8 et UTF-16 conservée.
- **`scripts/build_preprod.py`** :
  - `production_maps_key()` : la clé de production doit être identifiable de façon unique dans `lib/constants/maps_key.dart` (propre dans Git) **avant tout fichier touché** ; sinon le build est bloqué (y compris avec `--maps-disabled`).
  - `scan_for_key()` : second contrôle **indépendant** en Python (octets UTF-8 et UTF-16) sur l'APK extrait, exécuté avant les contrôles Node ; refuse aussi un contenu vide.
  - `validate_test_maps_key()` : une clé de test valide (`AIza` + 35 caractères) et **différente** de la production est exigée, ou bien `--maps-disabled` explicite. Absence, valeur vide, mauvaise forme, type incorrect, clé identique à la production, ou `--maps-disabled` combiné à une clé → refus.
- Vérification sur le **vrai** `maps_key.dart` (sans jamais l'afficher) : sa clé est identifiée sans ambiguïté par les deux contrôles (`check-only` Python et script Node sur un dossier factice).

**Changement de comportement à noter** : la clé de test n'est plus optionnelle en silence. Le fichier local `test-env/dart-defines.test.json` n'en contient pas : le wrapper doit donc recevoir **`-MapsDisabled`** (nouveau commutateur, explicite) pour construire sans cartes, ou le fichier doit définir `TEST_MAPS_API_KEY`. Sans l'un des deux : refus.

## 4. F7 — clé de test hors de la ligne de commande

Avant : `--android-project-arg=azTestMapsKey=<clé>` (clé visible dans la liste des processus).

Après :

- Le moteur écrit la clé dans `maps_test_key.txt`, **fichier temporaire** créé en mode exclusif dans le dossier de travail temporaire du build, permissions `0600` (voir limite ci-dessous). La ligne de commande ne contient que son **chemin** : `--android-project-arg=azTestMapsKeyFile=<chemin>`. Sans clé (`--maps-disabled`), aucun argument Maps n'est passé. La clé va aussi dans le fichier de defines temporaire (déjà `0600`), jamais dans la ligne de commande.
- Le fichier est supprimé avec le dossier temporaire à la fin du build, y compris en cas d'échec. Aucun fichier permanent, rien dans Git.
- **`android/app/build.gradle.kts`** (modification minimale, CRLF conservé, 7 lignes ajoutées / 3 retirées) : en mode test uniquement (`azTestSuffix`), la propriété `azTestMapsKeyFile` est lue (`project.file(...).readText().trim()`) ; sinon repli sur l'ancienne propriété `azTestMapsKey` (les scripts historiques, par exemple `build-emulator-apk.ps1`, continuent de fonctionner) ; la branche **production reste identique** (`localProperties.getProperty("MAPS_API_KEY", "")`).

Limites et risques :

1. **Le fichier Gradle n'a pas été compilé.** C'est un fichier partagé avec les builds de production : une erreur de syntaxe le casserait pour tous les builds. Contrôles possibles sans build : vérification statique (accolades et parenthèses équilibrées, CRLF, branche production inchangée, aucune clé écrite) ; la syntaxe Kotlin elle-même est **NON VÉRIFIÉE**. À valider au premier build autorisé, ou par relecture avant. Pour revenir en arrière sans commande Git destructive, réécrire les 3 lignes d'origine (visibles dans `git diff`).
2. Sous Windows, `os.chmod(..., 0o600)` ne pose pas de vraie ACL restrictive : le fichier est lisible par les processus du même compte pendant le build. La protection contre un autre compte repose sur le dossier temporaire de l'utilisateur.
3. Une clé Maps est, par conception, **intégrée dans le manifeste de l'APK** : F7 ne protège que la ligne de commande et les journaux, pas l'APK produit. Le dossier `build/` (ignoré par Git) peut contenir le manifeste fusionné avec la clé de test.
4. Les journaux de Flutter/Gradle réels n'ont pas été observés : leur contenu avec des options verbeuses est **NON VÉRIFIÉ**.

## 5. Tests

Nouveau fichier `scripts/test_build_preprod_maps.py` (23 tests) + tests existants adaptés (clés factices `AIza…PPP` pour la production, `AIza…TTT` pour le test). Aucune vraie clé, aucun appel réseau, aucune compilation.

| # | Exigence | Tests |
|---|---|---|
| 1 | clé de production présente : refus | `scan_for_key` UTF-8/UTF-16/au milieu d'un contenu, `audit_apk` refuse un APK factice avec la clé (sans appeler Node), **vrai script Node** (UTF-8 et UTF-16) |
| 2 | original sans clé : contrôle toujours effectif | Python (`check-only`, avec et sans `--maps-disabled`, et `build()` avant toute modification) ; vrai script Node (code 1, message « REFUS ») |
| 3 | clé inconnue / ambiguë : refus | deux clés, clé trop longue, clé trop courte, clé courte à côté d'une valide ; côté Node aussi ; référence illisible, dossier vide, cible absente |
| 4 | clé de test valide : acceptation | `check-only` code 0 ; build fictif réussi |
| 5 | absence de clé de test : refus | absente, vide, forme invalide (5 cas), identique à la production, conflit avec `--maps-disabled` ; `--maps-disabled` explicite accepté |
| 6 | secret absent des journaux | sorties de validation (7 scénarios), de build réussi, de build en échec, d'échec de restauration, du script Node |
| 7 | secret absent des arguments Gradle | la commande réelle construite : ni clé de test ni clé de production, aucun `azTestMapsKey=`, seulement `azTestMapsKeyFile=<chemin>` ; contenu du fichier lisible pendant l'appel ; sans clé : aucun argument Maps |
| 8 | nettoyage des fichiers temporaires | fichier de clé et fichier de defines supprimés après succès **et** échec ; fichier natif retiré |
| 9 | restauration de `maps_key.dart` | restauré après succès et échec ; dossier de récupération supprimé ; **restauration corrompue → sauvegarde et état conservés, message sans clé** |
| + | contrôles statiques Gradle | branche test uniquement, repli historique, branche production inchangée, accolades/parenthèses équilibrées, CRLF, aucune clé littérale ; aucune clé dans le moteur, le wrapper ou le script Node ; commutateur `-MapsDisabled` présent |

Résultats exacts : `test_build_preprod*.py` **66 tests réussis** (43 existants + 23 nouveaux) ; suite Python complète **121 tests réussis** ; aucun test ignoré (Node présent).

Vérifications réelles sans build (fichier natif synthétique dérivé des defines locaux, supprimé ensuite) :
- wrapper `-CheckOnly` sans option : **refusé** (« no test Google Maps key »), code non nul ;
- wrapper `-CheckOnly -MapsDisabled` : `validation PASS`, `APP_BUILD_NUMBER=11`, avec `aapt2`, Node et `verify-isolation.js` réels ;
- script Node avec le vrai `maps_key.dart` comme référence et un dossier factice : clé identifiée, code 0 ;
- syntaxe PowerShell analysée sans erreur ; BOM présent ; ASCII.

## 6. Risques résiduels

1. Syntaxe Kotlin du fichier Gradle non compilée (§4, point 1) : **principal risque**, pouvant affecter aussi les builds de production.
2. La clé de test reste lisible brièvement dans un fichier temporaire (Windows : sans ACL stricte) et finit dans le manifeste de l'APK.
3. Une clé de production d'une **forme inhabituelle** (non `AIza` + 35 caractères) bloquerait désormais le build au lieu de passer : comportement voulu, mais à signaler.
4. Un `flutter build` manuel contourne toujours le moteur.
5. Contrôles post-build testés sur des fichiers factices, jamais sur un vrai APK.

## 7. Éléments NON VÉRIFIÉS

Compilation du fichier Gradle modifié ; lecture effective du fichier de clé par Gradle ; manifeste réel de l'APK ; journaux réels de Flutter/Gradle ; comportement des contrôles sur un vrai APK ; `google-services.json` préproduction réel.

## 8. État Git

| | Avant M2.9 | Après M2.9 |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | idem |
| Index / stash | vide / 0 | vide / 0 |
| Suivis modifiés | 60 | **62** (+ `android/app/build.gradle.kts`, + `test-env/check-no-prod-maps-key.js`) |
| Non suivis (`git status --porcelain`) | 188 | **190** (+ `scripts/test_build_preprod_maps.py`, + ce rapport) |

`lib/constants/maps_key.dart` : propre avant et après ; aucun dossier `build/az-preprod-recovery`, aucun fichier natif résiduel. Fichiers protégés inchangés (`git hash-object`, 8 caractères) : `passwordReset.js` 26975f60, `index.js` a9ba2c0d, `firestore.rules` 5341bfd6, `storage.rules` f3b5b608, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a ; checklist `f97ccad5…`. `build_mobile.py` et `run.ps1` non modifiés. Travaux M1 à M2.8 préservés.

## 9. Décisions nécessaires

1. Faire relire (ou compiler lors du premier build autorisé) la modification de `android/app/build.gradle.kts`, ou choisir de la laisser de côté et d'accepter F7 comme « moteur seulement ».
2. Choisir pour le premier APK : `-MapsDisabled` (cartes absentes) ou une clé de test dédiée dans `TEST_MAPS_API_KEY`.
3. Fournir le `google-services.json` préproduction hors dépôt, confirmer le numéro de projet, et autoriser séparément le premier APK Debug (réseau, ≈ 3,7 Go libres).

**Arrêt : aucune autre mission lancée.**
