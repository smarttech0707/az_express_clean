# Mission M2.6 — Implémentation du script de build préproduction

Travail **local** uniquement : aucune compilation réelle (APK, AAB, IPA, Web), aucun accès Firebase (préproduction ou production), aucun IAM, aucun secret modifié, aucune écriture dans `config/app_versions`, aucune règle modifiée, aucun déploiement, aucun nettoyage de cache, aucune commande Git d'écriture. `scripts/build_mobile.py` et `run.ps1` ne sont pas modifiés. Le vrai `.env` n'a pas été lu. T0 n'est ni défini ni activé.

## 1. Verdict

| Critère | Statut |
|---|---|
| Script centralisé fonctionnel avec configurations factices | **PASS** (17 tests, §5) |
| Scénarios de refus (12 demandés) | **PASS** |
| Le wrapper PowerShell délègue au script Python | **PASS** (test statique + exécution réelle de `-CheckOnly`, §4) |
| Séparation production/préproduction démontrée | **PASS** pour la validation ; l'effet sur un binaire réel est **NON VÉRIFIÉ** |
| Protections FCM et package | **PASS** (validation et injection) ; **NON VÉRIFIÉES** sur un APK réel |
| Numéro de projet `306761725053` vérifié localement | **PASS (cohérence interne)** : identique dans `test-env/lib/guards.js`, `test-env/dart-defines.test.json` (sender ID et app ID) et la documentation préproduction du dépôt. **NON VÉRIFIÉ** côté console Firebase (aucun accès autorisé) |
| Aucun accès distant, build réel ni déploiement | **PASS** |
| Compilation `flutter build apk --debug` de bout en bout | **NON VÉRIFIÉE** (interdite) |
| Contrôles Node (`verify-isolation.js`, audit APK) et `aapt2` dans le moteur | **NON VÉRIFIÉS** : appelés par le moteur mais mockés dans les tests |

Aucune incohérence d'identifiant ni de package n'a été constatée : aucune valeur attendue n'a été corrigée.

## 2. État initial et protection du travail existant

HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, 60 fichiers suivis modifiés. Seul fichier cible déjà modifié : `test-env/build-test-apk.ps1` (modification **de la mission M2.2**, ajout du calcul de `APP_BUILD_NUMBER`, validée et rapportée). Elle est remplacée par la délégation ; sa version précédente est conservée hors dépôt dans le dossier temporaire de la session. Aucun travail non validé d'un tiers n'était présent dans les fichiers cibles. Travaux M1 à M2.5 et checklist préservés.

## 3. `scripts/build_preprod.py`

Android **debug** pour `az-express-preprod` uniquement. Constantes en dur : projet `az-express-preprod`, numéro `306761725053`, package `com.azexpress.app.test`. Aucune option `--project`, aucune variable d'environnement.

Utilisation (Windows) :

```
py scripts/build_preprod.py apk --config <defines.json> --google-services <google-services.json> [--check-only]
```

Arguments obligatoires : `--config` (dart-defines préproduction) et `--google-services` (fichier natif préproduction). Aucun chemin par défaut. `--check-only` valide sans compiler et affiche `validation PASS (values hidden). APP_BUILD_NUMBER=N`.

Garde-fous implémentés :

| Garde | Comportement |
|---|---|
| Cible | seul `apk` est accepté ; `appbundle`, `ipa`, `web`, `release` et l'option `--release` sont refusés |
| Chemins | refus du vrai `.env` (et de tout `.env*`), refus de `android/app/google-services.json` (production), refus si les deux fichiers sont identiques |
| Production | refus de toute occurrence de `az-express-b0469`, `az-express-clean` ou du numéro de projet de production dans l'un des deux fichiers (texte intégral) |
| Clés | liste fermée : toute clé inconnue dans la configuration est refusée ; `APP_BUILD_NUMBER` y est interdit |
| Projet | `FIREBASE_PROJECT_ID` = préproduction ; `google-services.json` : `project_id` présent et égal, `project_number` présent et égal |
| Numéro | `FIREBASE_MESSAGING_SENDER_ID` = numéro de projet ; bucket contenant le projet |
| Package | exactement un client Android, package `com.azexpress.app.test` |
| Cohérence Dart/natif | app ID et clé API des defines retrouvés dans `google-services.json` |
| FCM | `DISABLE_FCM` doit valoir `true` s'il est présent (`false`, `0`, `null` refusés) ; injecté à `true` |
| Garde de démarrage | `AZ_REQUIRED_FIREBASE_PROJECT` refusé s'il est différent ; injecté à la valeur préproduction |
| Build number | `build_mobile.resolve_build_number` importé en lecture seule (1 à 2 100 000 000, refus de 0, négatif, non entier, absent) ; transmis par `--dart-define=APP_BUILD_NUMBER=N`, jamais dans le fichier |
| Fichiers résiduels | refus si `android/app/src/debug/google-services.json` ou la sauvegarde de `maps_key.dart` préexiste (le fichier préexistant n'est pas supprimé) |
| Nettoyage | fichier natif retiré et `maps_key.dart` restauré (empreinte vérifiée) dans `finally`, y compris en cas d'échec ; fichier de defines temporaire hors dépôt, permissions `0o600` |
| Messages | texte fixe, jamais de valeur de configuration |
| Réseau | aucun appel Firebase ni réseau dans le script |

Déroulement d'un build (non exécuté ici) : copie du fichier natif en `src/debug/`, échange de la clé Maps de production par `maps_key_test.dart` (comportement repris de l'ancien script), `node test-env/verify-isolation.js … --require-preprod`, `flutter build apk --debug` avec `--android-project-arg=azTestSuffix=.test` et la clé Maps de test, puis contrôle de l'APK (`aapt2` pour le package si disponible, `check-no-prod-maps-key.js`, `audit-apk-content.js`).

## 4. Wrapper `test-env/build-test-apk.ps1`

Réduit à 23 lignes : lit `-GoogleServices` (et `-CheckOnly`), fixe `--config` sur `test-env\dart-defines.test.json`, appelle `py scripts\build_preprod.py apk …` et échoue si le code de sortie est non nul. Il ne contient plus aucune logique de projet, de numéro de build, de clé Maps ni de `flutter build`. BOM UTF-8 conservé, fins de ligne LF comme avant, syntaxe analysée sans erreur.

Vérifications réelles (sans compilation) :
- `-CheckOnly` avec un fichier natif **synthétique** construit à partir du fichier local `dart-defines.test.json` (valeurs jamais affichées, fichier supprimé ensuite) : `validation PASS`, `APP_BUILD_NUMBER=11`. Cela confirme aussi que le fichier de defines local actuel est conforme au contrat.
- `-CheckOnly` avec `android/app/google-services.json` (production) : **refusé**, code non nul.

Écart par rapport à l'ancien script : le nom de l'option `-CheckOnly` est nouveau ; les contrôles d'isolation (`verify-isolation.js`) sont maintenant lancés par le moteur et non plus par le wrapper.

## 5. Tests — `scripts/test_build_preprod.py`

Valeurs entièrement factices, racine temporaire, `subprocess` et `shutil.which` simulés : aucun Firebase, aucun secret, aucune compilation. **17 tests, tous réussis.** Suite Python complète du dépôt : **72 tests réussis**.

| # demandé | Test | Cas |
|---|---|---|
| 1 | `test_01` | configuration correcte acceptée, `APP_BUILD_NUMBER=11`, aucune valeur affichée |
| 2 | `test_02` | projet de production refusé (defines, natif, bucket, ancien ID) |
| 3 | `test_03` | numéro de projet incorrect, ou celui de la production, refusé |
| 4 | `test_04` | `project_id` absent (defines et natif) refusé |
| 5 | `test_05` | `project_number` incohérent ou absent refusé |
| 6 | `test_06` | package de production ou plusieurs clients refusés |
| 7 | `test_07` | build number absent, 0, non numérique, > 2 100 000 000, négatif, ou présent dans la config refusés |
| 8 | `test_08` | fichier absent (config, natif) et deux chemins identiques refusés |
| 9 | `test_09` | vrai `.env`, copie `.env` et fichier natif de production refusés |
| 10 | `test_10` | `appbundle`, `ipa`, `web`, `release` et `--release` refusés |
| 11 | `test_11` | `DISABLE_FCM` à `false`, `'false'`, `0`, `null` refusé |
| 12 | `test_12` | app ID / clé API Dart ≠ natif, garde de démarrage ≠ préproduction, clé inconnue refusés |
| bonus | `test_13` | `--check-only` ne lance ni Flutter ni sous-processus |
| bonus | `BuildTest` ×3 | commande : `build apk --debug`, sans `--release`, avec `APP_BUILD_NUMBER`, `azTestSuffix=.test` ; `DISABLE_FCM` et garde injectés ; fichier natif retiré et `maps_key.dart` restauré après succès **et** après échec ; fichier résiduel non supprimé ; refus de reprise sur sauvegarde existante |
| bonus | `WrapperTest` | le wrapper appelle `build_preprod.py`, ne contient plus `flutter build`, `verify-isolation`, `get-app-build-number`, `maps_key` ni la production, BOM présent |

Commande : `py -m unittest discover -s scripts -p "test_build_preprod.py"` depuis la racine (ne pas utiliser `-I`, qui retire le dossier courant du chemin d'import).

## 6. Limites

- Aucun APK n'a été produit : l'enchaînement Gradle réel, `verify-isolation.js`, `aapt2`, l'audit de l'APK et la restauration réelle de `maps_key.dart` sont **NON VÉRIFIÉS**.
- Le moteur remplace l'ancien script PowerShell : toute régression dans l'ancienne logique non reprise (par exemple `Write-Warning` sur `kernel_blob.bin`, supprimé ; le contrôle final de l'APK reste présent) n'est vérifiable qu'avec un vrai build.
- Un `flutter build` tapé à la main contourne toujours le moteur.
- Le fichier natif préproduction réel n'existe pas dans le dépôt : un build réel exige que vous le fournissiez.
- Le numéro de projet n'est confirmé que par cohérence interne du dépôt.
- iOS, release signé, AAB : hors périmètre, refusés par le script.
- `DELIVERY_PROOFS_UI` n'est exigé que par `verify-isolation.js` (ancien garde conservé), pas par la validation Python.
- `run.ps1`, `build_mobile.py`, `codemagic.yaml` et la checklist ne sont pas modifiés ; la ligne 91 de la checklist ne mentionne pas encore `build_preprod.py`.
- Documentation `docs/MOBILE_FIREBASE_BUILD.md` non mise à jour (hors périmètre).

## 7. État Git

| | Avant M2.6 | Après M2.6 |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | idem |
| Index / stash | vide / 0 | vide / 0 |
| Fichiers suivis modifiés | 60 | 60 (`build-test-apk.ps1` était déjà modifié) |
| Fichiers non suivis (`git status --porcelain`) | 183 | **186** : `build_preprod.py`, `test_build_preprod.py` et ce rapport (3 fichiers, aucun autre) |

**Rectificatif (audit M2.7, rédigé en M2.8).** La version initiale de ce rapport signalait « 1 entrée non attribuée » et partait de 182 fichiers non suivis. C'était faux : le comptage du rapport M2.5 était incorrect (il indiquait « avant 181, après 182 » alors que la fin de M2.4 était déjà à 182, et son « 182 » précédait la création du rapport M2.5). Chiffres établis par l'audit M2.7 : 182 (fin de M2.4) → 183 (rapport M2.5) → 185 (`build_preprod.py`, `test_build_preprod.py`) → 186 (ce rapport). **Aucun fichier supplémentaire n'existe**, aucun fichier inconnu n'est plus récent que le début de M2.5. Les conclusions techniques de ce rapport sont inchangées ; les limites F1 à F9 relevées ensuite sont traitées dans `ACCOUNT_DELETION_M2_8_PREPROD_HARDENING.md` (le comportement décrit au §3 pour `aapt2` et la sauvegarde de `maps_key.dart` y est renforcé).

Empreintes inchangées (sha1, 8 caractères) : `passwordReset.js` 2669c0c5, `index.js` e2c1fcb5, `firestore.rules` 5fa856b2, `storage.rules` c7b9ca85. `build_mobile.py` et `run.ps1` : dates de modification antérieures à cette mission (M2.x). `android/app/src/debug/` ne contient que son manifeste d'origine (aucun fichier natif résiduel).

## 8. Décisions nécessaires

1. Fournir le `google-services.json` préproduction (app `com.azexpress.app.test`) hors dépôt, et confirmer le numéro de projet dans la console.
2. Autoriser un premier APK de préproduction réel (réseau, ≈ 3,7 Go libres sur C:, cache Gradle non nettoyé).
3. Mettre à jour la ligne 91 de la checklist et `docs/MOBILE_FIREBASE_BUILD.md` pour citer `build_preprod.py`.
4. ~~Décider du sort d'une entrée non suivie non attribuée~~ : sans objet, voir le rectificatif ci-dessous.

**Arrêt : aucune autre mission lancée.**
