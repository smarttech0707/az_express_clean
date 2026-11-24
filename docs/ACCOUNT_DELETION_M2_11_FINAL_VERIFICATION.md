# Mission M2.11 — Vérification finale du dispositif de build préproduction

Vérifications **locales** uniquement, avec fichiers et clés synthétiques. Aucun APK/AAB construit, ni Gradle ni build Flutter lancés, aucun accès Firebase, aucune modification de `build.gradle.kts`, `build_mobile.py`, `run.ps1` ou `build_preprod.py`, aucun secret ou configuration de production touché, FeexPay non activé, `operations_control/account_deletion` ni créé ni réactivé. Aucune commande Git d'écriture. Le seul fichier créé est `scripts/test_preprod_m211.py` (nouveau) plus ce rapport.

## Conclusion : VALIDÉ AVEC RÉSERVES

Le dispositif tient dans tous les scénarios testés : chemins accentués et avec espaces, échecs injectés à chaque étape, arrêts brutaux avec reprise manuelle. Quatre réserves, aucune bloquante, dont une (propriété ambiante `azTestMapsKeyFile`) et une (clé dans le cache Gradle) qui demandent une décision ou une autorisation pour être traitées (§3, §4, §7). Le comportement de Flutter et de Gradle eux-mêmes reste **NON VÉRIFIÉ** faute de build autorisé.

## 1. Chemins avec espaces et caractères accentués (point 1)

Racine du dépôt factice `…\dépôt é àç ñ avec espaces\repo é`, configuration dans `config é`, dossier temporaire `tmp é`, fichiers `google-services é.json`, `defines é.json`.

| Test | Résultat |
|---|---|
| `--check-only` avec ces chemins | **PASS** |
| `build()` : le fichier de clé est créé dans le dossier temporaire accentué, contient exactement la clé de test (UTF-8 sans BOM), le chemin contient `é` et des espaces, la ligne de commande n'a que le chemin, le fichier est supprimé ensuite, `maps_key.dart` restauré | **PASS** |
| Vrai processus fils (frontière Python → processus Windows, citation des arguments) : l'argument arrive à l'identique et le fichier s'ouvre | **PASS** |
| Vrais scripts Node (`verify-isolation.js`, `check-no-prod-maps-key.js`) sur dossiers/fichiers accentués : accepte le cas sain, refuse la fuite factice, **sans afficher la clé** | **PASS** |
| Vrai wrapper `build-test-apk.ps1 -CheckOnly -MapsDisabled` avec `-GoogleServices` dans un dossier accentué avec espaces (PowerShell 5.1 → `py`) : `validation PASS`, aucune valeur sensible dans la sortie | **PASS** |
| Flutter → `gradlew.bat` → Gradle avec ces chemins | **NON VÉRIFIÉ** (aucun build) |

Risque : le dossier temporaire dépend du profil Windows de l'utilisateur ; un nom de profil avec accents ou espaces serait transmis tel quel jusqu'à Gradle. Probabilité faible (ce poste : `C:\Users\User`), gravité faible (échec visible de configuration, pas de fuite). Correction proposée (nécessite une autorisation, voir §7) : placer le fichier de clé dans un dossier ASCII du dépôt (`build\`), ou refuser les chemins non ASCII.

## 2. Propriété ambiante `azTestMapsKeyFile` avec `-MapsDisabled` (point 2)

Scénario : une valeur `azTestMapsKeyFile` existe hors de la ligne de commande — `ORG_GRADLE_PROJECT_azTestMapsKeyFile`, `~/.gradle/gradle.properties`, `android/gradle.properties`. En mode `--maps-disabled`, le moteur ne passe que `azTestMapsKey=` (vide) : la propriété ambiante serait lue et sa valeur intégrée au manifeste.

| Constat | Résultat |
|---|---|
| Présence sur ce poste (diagnostic en lecture seule : variables d'environnement, `android/gradle.properties`, `gradle.properties` racine, `~/.gradle/gradle.properties`, `GRADLE_USER_HOME`, `GRADLE_OPTS`) | **aucune** (le fichier utilisateur n'existe pas) |
| Le diagnostic détecte bien des sources ambiantes factices (3 emplacements) | **PASS** |
| Modèle : le comportement actuel laisse passer une valeur ambiante | **confirmé** (test de documentation) |
| Modèle : l'effet ne concerne jamais la production (le test-mode exige `azTestSuffix`) | **PASS** |

Gravité : faible à moyenne (une ancienne clé Maps de **test** — ou un chemin vers n'importe quel fichier lisible — dans un build « sans cartes ») ; elle ne touche ni Firebase ni la production. Probabilité : très faible (nom de propriété introduit en M2.9, inexistant ailleurs).

Correction proposée, **sans toucher à Gradle** : en mode `--maps-disabled`, transmettre aussi `azTestMapsKeyFile=<fichier vide créé dans le dossier temporaire>`. Une propriété `-P` l'emporte sur les propriétés ambiantes ; la lecture d'un fichier vide donne `""` (démontré par le modèle). Alternative : refuser le build si le diagnostic ci-dessus détecte une source ambiante. **Non appliquée** (modification de `build_preprod.py` non autorisée) : demande d'autorisation distincte.

## 3. Clé Maps de test dans le cache Gradle local (point 3)

Faits établis (sans lire d'entrée de cache ni exécuter Gradle) :

- `android/gradle.properties` contient `org.gradle.caching=true` (cache de build local actif) ; le démon est désactivé ; le cache de configuration ne l'est pas.
- Dans `gradle-8.11.1.jar` (AGP local), `ProcessApplicationManifest` est annotée **`@CacheableTask`** et référence `manifestPlaceholders` : sa sortie, le manifeste fusionné, contient la clé en clair ; avec le cache actif, cette sortie peut être stockée dans `~/.gradle/caches/build-cache-1`.
- Le cache local existe sur ce poste : 63 entrées, 2,8 Mo, toutes datées du jour (contenu non inspecté). Il reçoit déjà les sorties des builds de production avec leur clé de production.
- La rétention n'a pas été mesurée ; Gradle supprime par défaut les entrées inutilisées depuis environ 7 jours (comportement documenté, **NON VÉRIFIÉ** ici).
- Le dossier `build/` (ignoré par Git) contient aussi le manifeste fusionné.

Gravité : faible (une clé Maps est de toute façon intégrée à l'APK ; ce n'est pas un secret Firebase). Probabilité : élevée **si** une clé de test est utilisée, nulle avec `-MapsDisabled` (aucune clé, rien à stocker).

Recommandations : (1) utiliser **`-MapsDisabled`** pour le premier APK ; (2) si une clé de test est un jour utilisée, exécuter le build avec le cache de build désactivé (par exemple `GRADLE_OPTS=-Dorg.gradle.caching=false` dans l'environnement du sous-processus Flutter — correction proposée, **non appliquée et non vérifiée**, car elle modifierait `build_preprod.py`) ; (3) ne pas nettoyer le cache sans autorisation séparée, conformément aux règles du projet.

## 4. Procédure de récupération après interruption brutale (point 4)

Procédure (PowerShell, depuis la racine du dépôt ; elle est exécutée telle quelle dans les tests, avec `-SkipGit` sur le dépôt factice). Pour un usage réel, la dernière étape vérifie `git status --porcelain -- lib/constants/maps_key.dart` (doit être vide). **Aucun `git checkout` ni `git restore`.**

1. Constater : `build\az-preprod-recovery\` existe, ou un `lib\constants\maps_key.dart.az-partial`, ou `android\app\src\debug\google-services.json`.
2. Lire `state.json` (empreinte de l'original `original_sha256`, empreinte de la version de test `test_sha256`). S'il est **vide ou illisible**, l'interruption a eu lieu entre la sauvegarde et l'écriture de l'état : la substitution n'a pas commencé.
3. Calculer l'empreinte SHA-256 de `maps_key.dart.original` : elle doit égaler `original_sha256` (sinon **ARRÊT**, la sauvegarde est suspecte). Sans état exploitable : `maps_key.dart` doit être identique à la sauvegarde (sinon **ARRÊT**).
4. Calculer l'empreinte de `lib\constants\maps_key.dart` : elle doit être l'original ou la version de test ; toute autre valeur (modification manuelle) → **ARRÊT**, ne rien écraser.
5. Copier la sauvegarde sur `lib\constants\maps_key.dart` et revérifier l'égalité des empreintes.
6. Supprimer `lib\constants\maps_key.dart.az-partial` et `android\app\src\debug\google-services.json` s'ils existent (provenance : le build interrompu).
7. Supprimer `build\az-preprod-recovery` et vérifier que `git status --porcelain -- lib/constants/maps_key.dart` est vide.
8. En cas de doute à n'importe quelle étape : ne rien supprimer et demander.

Scénarios exécutés avec un vrai processus tué (`os._exit`, sans `finally`) puis la procédure PowerShell réelle :

| Point d'arrêt | État laissé | Procédure | Reprise du moteur |
|---|---|---|---|
| pendant l'étape Flutter | sauvegarde + état + fichier natif, `maps_key.dart` en version de test | **RECOVERED** | `preflight()` passe de nouveau |
| entre la sauvegarde et l'état | sauvegarde + `state.json` **vide**, `maps_key.dart` intact | **RECOVERED** | idem |
| en pleine restauration | `maps_key.dart.az-partial` + version de test | **RECOVERED** | idem |
| `maps_key.dart` modifié à la main | — | **ARRÊT** (code 3), fichier **non touché** | — |
| sauvegarde altérée | — | **ARRÊT** (code 3), **rien supprimé** | — |

Avant correction de la procédure, le cas « état vide » arrêtait la reprise (« backup does not match the saved hash ») : la procédure a été corrigée pour traiter un état vide comme absent. Le script de reprise n'est pas versionné dans le dépôt (procédure documentée seulement).

## 5. Nettoyage et scénarios d'échec (point 5)

Une défaillance injectée à chaque étape ; résultat attendu : état d'origine, ou état de reprise identifiable avec l'original conservé.

| Étape défaillante | Résultat |
|---|---|
| Flutter renvoie 1 / lève une exception / interruption clavier | tout restauré (fichier natif, `maps_key.dart`, sauvegarde, état, fichier de clé, defines) |
| APK absent après le build ; audit de l'APK en échec ; garde Node en échec | tout restauré |
| Copie du `google-services.json` en échec (fichier à moitié écrit) | fichier retiré, tout restauré |
| Écriture du fichier de clé en échec | tout restauré |
| Échec du remplacement (swap) de `maps_key.dart` | restauré depuis la sauvegarde |
| Vérification de la sauvegarde en échec | rien ne reste (un dossier vide peut rester) |
| **Échec de la restauration elle-même** | exception, **sauvegarde et état conservés**, état « version de test » identifiable ; aucune clé dans les journaux |
| Échec d'écriture de l'état | `maps_key.dart` intact, sauvegarde conservée avec `state.json` vide ; la relance **refuse** (« Recovery required »), rien n'est supprimé |

Aucune clé de test ni de production dans les journaux de ces scénarios.

Observations (aucune bloquante) :
- **F-A** — `state.json` est créé avant d'être écrit : un échec ou un arrêt laisse un fichier vide. Sûr (refus + procédure §4) mais inutilement bloquant. Correction proposée : écrire l'état sous un nom temporaire puis le renommer (modification de `build_preprod.py`, non autorisée ici).
- **F-B** — Un dossier `build\az-preprod-recovery` vide peut subsister après un échec de vérification de la sauvegarde ; il ne bloque pas la relance. Correction triviale proposée.

## 6. Commandes exécutées

Lecture : `git rev-parse`, `git status --porcelain`, `git diff --cached --name-only`, `git stash list`, `git hash-object`, `stat`, `ls` ; inspection en lecture seule de `gradle-8.11.1.jar` (présence d'annotations) et du dossier `~/.gradle/caches/build-cache-1` (nombre et taille d'entrées). Tests : `py -m unittest scripts.test_preprod_m211` (25 tests), `py -m unittest discover -s scripts -p "test_*.py"` (suite complète). Dans les tests : interpréteur Python (processus tués), Node (scripts de contrôle sur fichiers factices), PowerShell (procédure de reprise et wrapper `-CheckOnly -MapsDisabled`). Aucun Gradle, aucun `flutter`.

## 7. Résultats exacts

- `scripts/test_preprod_m211.py` : **25 tests, 25 réussis, 0 ignoré** (Unicode 5, propriété ambiante 5, faits de cache 2, injections d'échec 8, reprise après arrêt brutal 5).
- Suite Python complète : **164 tests réussis**.
- Dépôt réel après tests : `maps_key.dart` propre, aucun dossier de récupération, `android/app/src/debug/` inchangé.

## 8. Risques résiduels et décisions (autorisations distinctes requises)

| # | Risque | Gravité | Probabilité | Correction proposée |
|---|---|---|---|---|
| R1 | Propriété ambiante `azTestMapsKeyFile` en mode `--maps-disabled` | faible à moyenne | très faible | fichier de clé vide transmis en mode désactivé, ou refus si une source ambiante est détectée |
| R2 | Clé de test conservée dans le cache de build local et dans `build/` | faible | élevée avec une clé de test, nulle avec `-MapsDisabled` | premier APK en `-MapsDisabled` ; cache désactivé pour le sous-processus si une clé est utilisée |
| R3 | Profil Windows avec accents ou espaces vers Flutter/Gradle | faible | faible | fichier de clé dans un dossier ASCII du dépôt |
| R4 | `state.json` créé avant d'être écrit (F-A) ; dossier vide résiduel (F-B) | faible | faible | écriture atomique de l'état ; suppression du dossier vide |
| R5 | Syntaxe Kotlin de `build.gradle.kts` non compilée | moyenne | faible | compiler lors du premier build autorisé |

## 9. Éléments NON VÉRIFIÉS

Flutter/Gradle réels (chemins, arguments, journaux) ; compilation du script Kotlin ; contenu du cache de build ; durée de rétention du cache ; APK réel et `aapt2 dump badging` sur celui-ci ; `google-services.json` préproduction réel ; numéro de projet côté console Firebase.

## 10. État Git

| | Avant M2.11 | Après M2.11 |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | idem |
| Index / stash | vide / 0 | vide / 0 |
| Suivis modifiés | 62 | 62 |
| Non suivis (`git status --porcelain`) | 192 | **194** (+ `scripts/test_preprod_m211.py`, + ce rapport) |

Aucun fichier existant modifié par cette mission. Empreintes inchangées (`git hash-object`, 8 caractères) : `passwordReset.js` 26975f60, `index.js` a9ba2c0d, `firestore.rules` 5341bfd6, `storage.rules` f3b5b608, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a ; checklist `f97ccad5…` ; `build.gradle.kts` `29bd8394…` (identique à M2.9). `build_mobile.py` (19:59) et `run.ps1` (20:00) non modifiés. Travaux M1 à M2.10 préservés.

**Cette autorisation ne vaut pas autorisation de build réel. Arrêt : aucune autre mission lancée.**
