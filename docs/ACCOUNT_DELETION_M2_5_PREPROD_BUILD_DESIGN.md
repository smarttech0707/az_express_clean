# Mission M2.5 — Étude et conception du build préproduction

Étude **locale** uniquement. Aucun build (Android, AAB, IPA, Web), aucun accès Firebase (préproduction ou production), aucun IAM, aucune lecture du vrai `.env`, aucun nettoyage de cache, aucune écriture dans `config/app_versions`, aucune règle modifiée, aucun déploiement, aucune commande Git d'écriture. `build_mobile.py`, `run.ps1` et les configurations Firebase n'ont pas été modifiés. Le script définitif n'est pas créé. T0 n'est ni défini ni activé.

## 1. Verdict

| Critère | Statut |
|---|---|
| Sélection du projet Firebase documentée | **PASS** (§2) |
| Séparation production/préproduction démontrée par scénarios factices | **PASS sur prototype jetable** (§6) ; le futur script lui-même n'existe pas, donc rien n'est démontré sur lui |
| Risques de substitution identifiés | **PASS** (§3) |
| Fonctionnement du futur script spécifié | **PASS** (§4–§5) |
| Aucun fichier protégé ou travail existant écrasé | **PASS** (§9) |
| Aucun accès distant, build ou déploiement | **PASS** |
| Un build préproduction réel fonctionne | **NON VÉRIFIÉ** (aucun build autorisé) |
| Valeurs réelles de la préproduction (clés, app ID) | **NON VÉRIFIÉES** : jamais lues ; le fichier `test-env/dart-defines.test.json` en contient, il n'a été affiché que masqué |

## 2. Architecture actuelle (sélection du projet Firebase)

Le projet visé par un binaire est déterminé par **deux canaux indépendants**, qui doivent être cohérents :

| Canal | Mécanisme | Où | Contrôlé aujourd'hui par |
|---|---|---|---|
| A. Dart | `String.fromEnvironment('FIREBASE_*')` dans `lib/firebase_options.dart` (aucune valeur en dur) ; valeurs fournies par `--dart-define-from-file` | `build_mobile.py`, `run.ps1`, `test-env/*.ps1` | `build_mobile.py` : `FIREBASE_PROJECT_ID == az-express-b0469` (ligne 73) |
| B. Natif Android | plugin Gradle `com.google.gms.google-services` lit `android/app/google-services.json` (gitignoré ; contient aujourd'hui `az-express-b0469`) | Gradle, au moment du build | **Rien dans `build_mobile.py`** : il ne lit jamais ce fichier |
| B'. Natif iOS | `ios/Runner/GoogleService-Info.plist` (gitignoré, restauré par Codemagic) | Xcode | `build_mobile.py ipa` : mappe le plist vers les defines, impose `az-express-b0469` ; `codemagic.yaml` répète la vérification (lignes 95 et 287) |
| C. Garde de démarrage | `lib/services/firebase_project_guard.dart` : si `AZ_REQUIRED_FIREBASE_PROJECT` est défini, l'app refuse de démarrer sur un autre projet ; **inerte par défaut** | runtime | `--dart-define=AZ_REQUIRED_FIREBASE_PROJECT=…` |

Par type de build :

| Build | Canal A | Canal B | Garde C | Projet effectif |
|---|---|---|---|---|
| `build_mobile.py apk/appbundle` | `.env` (JSON) ou `--config` | `android/app/google-services.json` **non contrôlé** | non passé | prod (imposé en A uniquement) |
| `build_mobile.py ipa` | dérivé du plist | plist | non passé | prod |
| `run.ps1` (web, run, autres) | `.env` | selon cible | non passé | ce que contient `.env` |
| `test-env/build-test-apk.ps1` (préprod, existant) | `test-env/dart-defines.test.json` | `android/app/src/debug/google-services.json` temporaire, package `com.azexpress.app.test` | passé (`AZ_REQUIRED_FIREBASE_PROJECT`) | `az-express-preprod` ; contrôlé par `test-env/verify-isolation.js --require-preprod` et `test-env/lib/guards.js` (`checkPreprodBuild`) |
| `test-env/build-emulator-apk.ps1` | aucun `.env` | `google-services.json` factice `demo-az-express` | n/a | émulateurs |

Constats utiles :

- Il existe **déjà** un chemin préproduction (`build-test-apk.ps1`) : APK **debug**, package `com.azexpress.app.test` (installé à côté de la production), `google-services.json` posé dans `src/debug/` puis retiré, clé Maps de production remplacée, audit de l'APK. Constantes de référence dans `guards.js` : projet `az-express-preprod`, numéro de projet `306761725053`, package `.test`. **Ce n'est pas un build release** et il ne passe pas par `build_mobile.py`.
- `guards.js` détecte aussi les références de production (`az-express-b0469`, ancien `az-express-clean`, numéro de projet de production, fragments d'app ID).
- Le suffixe d'application est piloté par `-PazTestSuffix` (Gradle `applicationId`) ; il désactive aussi la clé Maps de production.

## 3. Risques identifiés

| # | Risque | Gravité | Constat |
|---|---|---|---|
| R1 | **Divergence canal A / canal B** : defines préprod + `google-services.json` de production (ou l'inverse). L'app démarre avec des identifiants Firebase mélangés (FCM, App ID) | élevée | Aujourd'hui `build_mobile.py` ne contrôle pas `google-services.json` ; le jour où il acceptera un autre projet, ce risque devient réel |
| R2 | **Remplacement silencieux de configuration** : `--config` pointant un fichier quelconque, ou `.env` de production utilisé par défaut | élevée | `build_mobile.py` retombe sur `.env` si `--config` est absent : pour la préproduction, un défaut implicite vers `.env` serait dangereux |
| R3 | **Build préprod publié comme prod** (ou l'inverse) : même package `com.azexpress.app`, même keystore release | élevée | Séparation par package `.test` existe côté debug seulement. Un build *release* préprod avec le package de production remplacerait la prod sur un téléphone |
| R4 | **Clé Google Maps de production** embarquée dans un build de test (`lib/constants/maps_key.dart` versionné) | moyenne (coût) | Gérée aujourd'hui par `build-test-apk.ps1` (échange + restauration + audit) ; à reprendre ou à interdire |
| R5 | **Fichier natif résiduel** : un `src/debug/google-services.json` oublié influence les builds suivants | moyenne | `build-test-apk.ps1` le retire dans `finally` ; un plantage brutal le laisse en place |
| R6 | **Garde de démarrage inerte** si la define est omise | élevée | `AZ_REQUIRED_FIREBASE_PROJECT` doit être *injectée par le script*, jamais laissée à l'opérateur |
| R7 | **APP_BUILD_NUMBER** : mêmes règles qu'en M2, plus risque d'un numéro dans le fichier de config | moyenne | Déjà traité dans `build_mobile.py` (refus s'il est dans la config) ; à reproduire à l'identique |
| R8 | **Fuite de secrets** dans logs ou rapports | moyenne | Ne jamais afficher de valeur ; messages d'erreur à texte fixe, jamais d'exception brute |
| R9 | **Codemagic** : `PROJECT_ID == az-express-b0469` codé en dur aux lignes 95 et 287 | info | Un build iOS préprod devra être une option explicite et séparée ; non conçu ici (§8) |
| R10 | **Notifications/FCM** : un build préprod ne doit envoyer aucun jeton vers de vrais utilisateurs | moyenne | `DISABLE_FCM=true` déjà exigé par `guards.js` |

## 4. Fonctionnement proposé de `scripts/build_preprod.py`

Principe : **script distinct** de `build_mobile.py` (qui reste inchangé et production-only), avec une liste blanche à **une seule valeur** plutôt qu'un paramètre « projet ». Pas de variable d'environnement, pas d'option `--project`.

Constantes en dur dans le script : `PREPROD_PROJECT_ID = 'az-express-preprod'`, `PREPROD_PROJECT_NUMBER` (valeur de `guards.js`, à reconfirmer par le propriétaire), `PREPROD_PACKAGE = 'com.azexpress.app.test'`, `FORBIDDEN_PROJECTS = ('az-express-b0469', 'az-express-clean')`, plage du numéro de build : 1 à 2 100 000 000. Il ne doit contenir aucune clé.

Interface proposée (Android d'abord) :

```
py scripts/build_preprod.py apk --config <chemin> --google-services <chemin> [--check-only]
```

Pas de défaut implicite (R2) : `--config` et `--google-services` sont obligatoires ; l'absence est une erreur. Le script refuse un chemin égal à `<racine>/.env` ou situé hors d'un dossier dédié (§5, garde G7).

Étapes :

1. **Lire** la config des defines (JSON) et `google-services.json` (JSON) ; erreurs à texte fixe.
2. **Valider** selon les gardes G1 à G10 (§5). Toute violation : code de sortie 2 et message clair sans valeur.
3. **Résoudre** `APP_BUILD_NUMBER` en réutilisant la logique validée de `build_mobile.py` (`resolve_build_number` : même plage, refus de 0, négatif, non entier, booléen). Pour éviter de modifier `build_mobile.py`, la fonction est soit importée (`from build_mobile import resolve_build_number, pubspec_build_number`, lecture seule du module) soit copiée avec ses tests. **Recommandation : importer**, une seule source de vérité.
4. **Injecter** `AZ_REQUIRED_FIREBASE_PROJECT=az-express-preprod`, `DISABLE_FCM=true`, `APP_BUILD_NUMBER=N` dans un fichier de defines temporaire (hors dépôt, `0o600`, supprimé même en cas d'échec), comme `build_mobile.py`.
5. **Placer** le `google-services.json` validé dans `android/app/src/debug/` (comme le fait déjà `build-test-apk.ps1`), jamais dans `android/app/` ; **refuser** si un fichier y existe déjà (R5) ; supprimer dans un `finally`.
6. **Construire** avec `--android-project-arg=azTestSuffix=.test` et clé Maps neutralisée (R3, R4), puis relancer les contrôles post-build existants (package, références de production, clés inconnues) via `test-env/audit-apk-content.js`.
7. `--check-only` s'arrête après l'étape 3 et affiche `validation PASS (values hidden)`.

Type de build : **debug APK** dans une première version (comme l'existant). Un build release préprod soulève R3 (même keystore, même package) : voir décision D2.

## 5. Garde-fous

| Id | Garde | Motif |
|---|---|---|
| G1 | `FIREBASE_PROJECT_ID == az-express-preprod` exactement | séparation |
| G2 | Refus explicite de tout identifiant de `FORBIDDEN_PROJECTS` dans les defines **et** dans `google-services.json` (texte intégral, insensible à la casse), plus numéro de projet de production, plus fragments d'app ID | R1, R2 |
| G3 | Paramètres obligatoires présents, chaîne non vide : `FIREBASE_PROJECT_ID`, `FIREBASE_ANDROID_APP_ID`, `FIREBASE_ANDROID_API_KEY`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_STORAGE_BUCKET` | config absente |
| G4 | Cohérence croisée canal A / canal B : `project_id`, `project_number` = `FIREBASE_MESSAGING_SENDER_ID`, `mobilesdk_app_id` = `FIREBASE_ANDROID_APP_ID`, clé API présente dans `google-services.json`, bucket contenant `az-express-preprod`, exactement un client Android | R1 |
| G5 | Package du client Android == `com.azexpress.app.test` | R3 |
| G6 | `AZ_REQUIRED_FIREBASE_PROJECT` : valeur injectée par le script ; **refusée** si le fichier de config la contient avec une autre valeur | R6 |
| G7 | Pas de chemin implicite ; `--config` ne peut pas être `.env` (comparaison de chemins résolus) ; `--google-services` ne peut pas être `android/app/google-services.json` | R2 |
| G8 | `APP_BUILD_NUMBER` entier de 1 à 2 100 000 000 ; interdit dans le fichier de config | R7 |
| G9 | `android/app/src/debug/google-services.json` ne doit pas préexister ; retrait dans `finally` | R5 |
| G10 | Messages d'erreur à texte fixe ; aucune exception brute ; aucune valeur affichée | R8 |
| G11 | Jamais d'appel réseau Firebase : le script ne fait que lire des fichiers et lancer `flutter build` | périmètre |

Limite assumée : ces gardes protègent le **script**. Un `flutter build` tapé à la main les contourne (même constat qu'en M2.3) ; seule la documentation et, plus tard, une garde Gradle pourraient le réduire (non conçu ici).

## 6. Tests prévus et vérification sur prototype

Le prototype a été écrit dans le dossier temporaire de la session (**hors dépôt, non conservé**), avec des valeurs factices (`az-express-preprod`, numéro `000000000001`, clé `FAKE-KEY`), sans aucun appel réseau. Résultat réel : **7 tests, 7 réussis** (`py -I`).

| Scénario demandé | Cas couverts dans le prototype | Résultat |
|---|---|---|
| 1. Préprod correct accepté | config cohérente + numéro 11 | accepté, renvoie 11 |
| 2. Production refusé | `FIREBASE_PROJECT_ID` de prod ; `project_id` de prod dans `google-services.json` ; bucket de prod | refusés |
| 3. Identifiant absent refusé | chacun des 6 paramètres supprimé, un paramètre blanc | refusés |
| 4. Identifiant incohérent refusé | mauvais numéro de projet ; garde de démarrage ≠ préprod ; app ID différent de `google-services.json` ; package de production | refusés |
| 5. Numéro de build invalide refusé | `None`, 0, −5, `'abc'`, `True`, 2 100 000 001, 1,5 ; `APP_BUILD_NUMBER` présent dans la config | refusés |
| 6. Fichier de configuration manquant refusé | fichier absent ; config vide ; `google-services.json` vide | refusés |
| 7. Substitution refusée | fichier de config hors de l'emplacement attendu refusé ; le bon emplacement accepté | refusé / accepté |

Ce que cela **prouve** : la logique de décision décrite au §5 sépare bien ces cas. Ce que cela **ne prouve pas** : le comportement du futur script réel (lecture de fichiers, codes de sortie, temp files, intégration Gradle). **NON VÉRIFIÉ** pour tout le reste.

Tests à écrire en mission d'implémentation (Python `unittest`, comme `scripts/test_build_mobile.py`) :
- les 7 scénarios ci-dessus, via `main()` avec racine temporaire (`mock.patch.object(…,'ROOT',…)`), en vérifiant les **codes de sortie** et l'**absence de valeurs** dans stdout/stderr ;
- `subprocess.call` simulé : aucune compilation réelle, aucune valeur dans la ligne de commande autre que le chemin du fichier temporaire ;
- le fichier temporaire de defines est supprimé même si le build échoue ;
- `src/debug/google-services.json` n'existe plus après succès, échec et interruption ; refus s'il préexiste ;
- `--check-only` ne lance pas Flutter ;
- test statique : le script ne contient ni chaîne de production autre que sa liste interdite, ni import réseau (`urllib`, `requests`, `socket`).

## 7. Fichiers à modifier ou créer dans une future mission

| Fichier | Action | Remarque |
|---|---|---|
| `scripts/build_preprod.py` | créer | nouveau, jamais `build_mobile.py` |
| `scripts/test_build_preprod.py` | créer | tests du §6 |
| `docs/MOBILE_FIREBASE_BUILD.md` | compléter | section préproduction ; supprimer l'ambiguïté « un seul projet » |
| `docs/ACCOUNT_DELETION_RELEASE_CHECKLIST.md` (ligne 91) | ajuster | renvoyer vers `build_preprod.py` pour l'environnement de validation (ligne corrigée en M2.4) |
| `test-env/build-test-apk.ps1` | à décider | soit reste tel quel (chemin debug), soit délègue à `build_preprod.py` |
| `scripts/build_mobile.py`, `run.ps1`, `firebase_options.dart`, `.env`, `google-services.json` | **ne pas toucher** | |
| `codemagic.yaml` | hors périmètre | iOS préprod = décision séparée (R9) |

## 8. Décisions supplémentaires nécessaires

| # | Décision | Recommandation |
|---|---|---|
| D1 | Confirmer par écrit le numéro de projet préprod (`306761725053` dans `guards.js`), le package `com.azexpress.app.test` et que le client Android préprod est enregistré dans le projet | confirmer avant toute implémentation |
| D2 | Type de build préprod : debug seulement (existant, package `.test`) ou **release** signé (R3) ? | debug d'abord ; un release préprod exige un package distinct et une décision sur la signature |
| D3 | Où stocker durablement les defines préprod et le `google-services.json` préprod (hors dépôt) | dossier local hors dépôt, gitignoré ; jamais dans la CI sans décision |
| D4 | `build_preprod.py` réutilise-t-il ou remplace-t-il `build-test-apk.ps1` ? | réutiliser ses contrôles (`guards.js`, audit APK) plutôt que dupliquer |
| D5 | Clé Google Maps : cartes désactivées en préprod ou clé de test dédiée | cartes désactivées par défaut (comportement actuel) |
| D6 | iOS préprod : nécessaire ou non ? (nouveau bundle ID, plist préprod, profil de signature, Codemagic) | différer ; Q12 (App Store) reste en attente |
| D7 | Autoriser un build réel de vérification, avec réseau et espace disque (≈ 3,7 Go libres sur C:, cache Gradle ≈ 2,8 Go non nettoyé) | séparément autorisé |

## 9. État Git et protections

| | Avant M2.5 | Après M2.5 |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | idem |
| Index | vide | vide |
| Stash | 0 | 0 |
| Fichiers suivis modifiés | 60 | 60 |
| Fichiers non suivis (`git status --porcelain`) | 181 | **182** (ce rapport uniquement) |

Empreintes inchangées (8 premiers caractères, relevées avant et non modifiées) : `passwordReset.js` 2669c0c5, `index.js` e2c1fcb5, `firestore.rules` 5fa856b2, `storage.rules` c7b9ca85. *Remarque :* ces valeurs sont des `sha1sum` ; les empreintes citées dans les rapports précédents provenaient d'un autre algorithme, elles ne sont donc pas comparables entre elles. Aucun fichier de ces quatre n'a été ouvert en écriture. Le vrai `.env`, `google-services.json` et le plist n'ont pas été lus (seul le champ public `project_id` de `google-services.json` a été extrait par recherche textuelle ; `dart-defines.test.json` n'a été affiché qu'avec les clés API masquées). Travaux M1, M2, M2.1 à M2.4 et la checklist préservés.

## 10. Éléments NON VÉRIFIÉS

Fonctionnement d'un build préprod réel ; existence et contenu du `google-services.json` préprod local ; exactitude du numéro de projet préprod côté Firebase ; comportement de `FirebaseProjectGuard` sur appareil ; présence effective des defines dans un binaire ; traitement iOS/Codemagic ; contenu de `config/app_versions`.

**Arrêt : aucune autre mission lancée. La création de `build_preprod.py` et toute compilation exigent une autorisation écrite distincte.**
