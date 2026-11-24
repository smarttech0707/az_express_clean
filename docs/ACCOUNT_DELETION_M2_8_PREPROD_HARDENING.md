# Mission M2.8 — Renforcement des garde-fous du build préproduction

Travail **local** uniquement, avec données factices. Aucune compilation réelle (APK, AAB, IPA, Web), aucun accès Firebase (préproduction ou production), aucun IAM, aucune modification de configuration Firebase, de secret, de `config/app_versions`, de règles, de checklist, de `build_mobile.py` ou de `run.ps1`. Aucun nettoyage de cache, aucune suppression de fichier non suivi, aucune commande Git d'écriture. Le premier APK de préproduction reste à autoriser séparément. T0 n'est ni défini ni activé.

## 1. Verdict

| Critère | Statut |
|---|---|
| L'absence d'`aapt2` bloque effectivement le futur build | **PASS** (tests, §3) |
| Le package ne peut plus rester non vérifié silencieusement | **PASS** (plus aucun chemin « avertissement seul ») |
| Protection de `maps_key.dart` démontrée par des tests | **PASS** pour l'exception, l'interruption clavier, l'échec de restauration et l'**arrêt brutal réel** (processus tué) ; **la restauration automatique après arrêt brutal n'est PAS garantie** et n'est volontairement pas tentée (§4) |
| Risques F3 à F9 traités ou documentés | **PASS** (§5) |
| Rapport M2.6 corrigé sans perte d'information | **PASS** (§6) |
| Tests autorisés | **PASS** : 43 tests de `test_build_preprod.py` (17 avant), 98 tests Python au total |
| Aucun build réel ni accès distant | **PASS** |
| Enchaînement Gradle / plugin Google Services / APK réel | **NON VÉRIFIÉ** |

## 2. État initial et protection du travail existant

HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, 60 suivis modifiés, 187 non suivis. Fichiers cibles : `scripts/build_preprod.py`, `scripts/test_build_preprod.py` (non suivis, créés en M2.6, sans travail tiers), `test-env/build-test-apk.ps1` (modifié par M2.2/M2.6, le contenu de M2.6 a été complété, pas remplacé) et le rapport M2.6 (non suivi). `lib/constants/maps_key.dart` : suivi, **propre** au départ (`git status` vide). Aucun travail local non validé n'a été écrasé.

## 3. A — F1 : `aapt2` obligatoire

Dans `scripts/build_preprod.py` :

- `find_aapt2()` cherche dans `ANDROID_HOME`, `ANDROID_SDK_ROOT` et `%LOCALAPPDATA%\Android\Sdk\build-tools` (`aapt2.exe` ou `aapt2`), la **version la plus récente** (tri numérique, pas alphabétique).
- `check_tools()` refuse si l'outil est absent, si le chemin n'est pas un fichier exécutable, si `aapt2 version` ne s'exécute pas (erreur système, délai de 60 s) ou renvoie une erreur/une sortie vide. Elle vérifie aussi que **Node.js** s'exécute (message clair au lieu d'une trace, F3).
- `preflight()` appelle `check_tools()` **avant tout fichier touché**, donc avant Gradle. L'ancien `Warning: aapt2 not found` est supprimé.
- `audit_apk()` rend **bloquantes** toutes les erreurs de la vérification du package : exécution impossible, délai dépassé, code de sortie non nul, package différent de `com.azexpress.app.test`, sortie vide.

Tests (`Aapt2Test`) : présent (version la plus récente choisie, 9.0.0 < 34.0.0), absent (aucun SDK / dossier vide), chemin invalide (dossier nommé `aapt2.exe`), exécution impossible (erreur système et délai), outil qui répond mal, Node absent, `run()` qui enveloppe un exécutable manquant, **build bloqué avant toute modification** (aucun appel `flutter`, `maps_key.dart` intact, ni `build/` ni `android/` créés), erreurs de vérification du package (4 cas), package correct puis audits Node.

Vérification réelle, sans build : `aapt2` du SDK local trouvé et exécutable (versions 35.0.0, 36.1.0 et 37.0.0 présentes) ; `-CheckOnly` du wrapper l'a exécuté avec succès (§7).

## 4. B — F2 : protection de `maps_key.dart`

Mécanisme renforcé :

1. **Avant tout** : `git status --porcelain -- lib/constants/maps_key.dart` doit être **vide** (fichier suivi et sans modification locale). Sinon refus, fichier intact. Toute erreur Git refuse aussi (échec fermé). Conséquence : le contenu d'origine est toujours aussi récupérable depuis Git, et aucune modification locale préexistante n'est ni écrasée ni « restaurée » à tort.
2. **Sauvegarde vérifiée** dans `build/az-preprod-recovery/maps_key.dart.original` (dossier gitignoré du dépôt, plus le dossier temporaire du système), créée en mode exclusif (ne remplace jamais un fichier existant), puis comparée par empreinte SHA-256.
3. **Fichier d'état** `state.json` (empreinte de l'original, empreinte de la version de test, heure de début), écrit en mode exclusif, **après** la sauvegarde vérifiée.
4. **Remplacement atomique** (copie à côté puis `os.replace`) : le fichier n'est jamais à moitié écrit. Même mécanisme pour la restauration.
5. **Restauration dans `finally`** (erreur, exception, `Ctrl+C`), puis vérification d'empreinte ; sauvegarde et état supprimés **uniquement** si la restauration est prouvée identique. Sinon : message d'erreur, **sauvegarde et état conservés**.
6. **Nouvelle exécution** : si la sauvegarde, l'état ou un fichier `.az-partial` existe → refus « Recovery required », avec un état **identifiable** en texte fixe : « `maps_key.dart` est égal à l'original sauvegardé », « est la version de TEST (remplacée) », « ne correspond à aucune des deux (modification locale possible) », « état incomplet » ou « illisible ». **Rien n'est supprimé ni modifié.**

Tests (`BuildTest`) : sauvegarde et état présents pendant l'utilisation de la version de test ; restauration après échec Flutter, exception et `KeyboardInterrupt` ; échec du garde Node avant Flutter ; fichier modifié localement refusé et intact ; échec Git ; **vrai dépôt Git temporaire** (non suivi, propre, modifié) ; fichier natif résiduel refusé et conservé ; trois états de reprise incomplets refusés et conservés ; état identifiable (4 variantes) ; **restauration corrompue → sauvegarde et état conservés** ; et un test d'**arrêt brutal réel** : un processus Python lance `build()` puis est tué par `os._exit` (aucun `finally`). Résultat : sauvegarde, état et fichier natif sont présents, `maps_key.dart` est visiblement en version de test, la relance **refuse sans rien supprimer**, et la récupération manuelle ci-dessous restitue l'original à l'octet près.

**Limite déclarée (BLOQUÉE volontairement) :** après un arrêt brutal, **il n'existe aucune restauration automatique**. Elle n'est pas tentée, car elle devrait décider seule entre plusieurs états possibles. Ce qui est garanti : détection, refus de continuer, aucune destruction, état identifiable, et copie d'origine disponible à deux endroits (sauvegarde + Git). Limite supplémentaire : `flutter clean` après un arrêt brutal supprimerait `build/`, donc la sauvegarde ; l'original reste alors récupérable depuis Git.

Procédure de reprise manuelle (sans `git checkout` ni `git restore`) :

1. `git status --porcelain -- lib/constants/maps_key.dart` et lire `build\az-preprod-recovery\state.json` (empreintes).
2. Vérifier `(Get-FileHash build\az-preprod-recovery\maps_key.dart.original -Algorithm SHA256).Hash` contre `original_sha256`.
3. Si identique : `Copy-Item build\az-preprod-recovery\maps_key.dart.original lib\constants\maps_key.dart -Force`, puis vérifier que `git status --porcelain -- lib/constants/maps_key.dart` est vide.
4. Si `android\app\src\debug\google-services.json` existe : confirmer qu'il vient du build interrompu, puis le retirer.
5. Seulement après ces vérifications, retirer le dossier `build\az-preprod-recovery`. En cas de doute, ne rien supprimer et demander.

## 5. C — F3 à F9

| # | Risque (M2.7) | Impact | Décision |
|---|---|---|---|
| F3 | `node` absent → trace brute | fiabilité | **Corrigé** : refus clair dans `check_tools()` et `run()` (tests) |
| F4 | `check-no-prod-maps-key.js` sans clé dans la sauvegarde → « rien à chercher » (code 0) | intégrité (marginal) | **Documenté, non modifié** : sans clé de production dans l'original il n'y a rien à fuiter ; dépend d'un script Node hors périmètre. Mission séparée si le format de clé change |
| F5 | `--check-only` ne lançait ni outils ni garde Node | fiabilité | **Corrigé** : il vérifie maintenant `aapt2`, Node et `verify-isolation.js` (maps non remplacée). Un `PASS` couvre donc aussi `DELIVERY_PROOFS_UI` et les références de production élargies. Il ne couvre toujours pas Gradle, `maps_key.dart` ni l'audit de l'APK |
| F6 | Liste des identifiants de production en double (Python / `guards.js`) | **séparation prod/préprod** | **Corrigé** : le moteur lit `test-env/lib/guards.js` (identifiants, numéro, fragments d'app ID) et les ajoute à sa liste minimale ; échec fermé si le fichier est illisible ou sans les deux identifiants de production. Les fragments d'app ID de production sont donc désormais refusés par le moteur (test) |
| F7 | `TEST_MAPS_API_KEY` dans la ligne de commande Gradle | secrets (clé de test, faible) | **Documenté** : le déplacer vers un fichier de propriétés Gradle toucherait le build Android ; mission séparée si la clé de test devient sensible |
| F8 | Priorité de `src/debug/google-services.json` sur `android/app/google-services.json` (production) | **séparation prod/préprod** | **Non corrigeable sans build.** Preuve statique ajoutée : le plugin local `google-services-4.4.2.jar` contient `getJsonLocations` avec un tri décroissant (`sortedByDescending`), cohérent avec « emplacement le plus spécifique d'abord », mais l'ordre exact reste **NON VÉRIFIÉ** sans build. Défense maintenue : le garde Dart `FirebaseProjectGuard` (fail-closed) compare le projet effectif ; le build préproduction l'active toujours |
| F9 | Dépendance au lanceur `py` | fiabilité | **Corrigé** : le wrapper vérifie `Get-Command py` avant l'appel et échoue avec un message clair (test statique : présent, avant l'appel, ASCII) |

## 6. D — Correction du rapport M2.6

`docs/ACCOUNT_DELETION_M2_6_PREPROD_BUILD_IMPLEMENTATION.md` : la mention d'une entrée Git « non attribuée » est retirée ; le tableau §7 indique 183 → 186 (3 fichiers) ; la décision 4 du §8 est barrée comme sans objet ; un **rectificatif** explique que le comptage du rapport M2.5 était incorrect et reprend les chiffres de l'audit M2.7 (182 → 183 → 185 → 186). Les conclusions techniques et les autres constats sont conservés. Aucun autre rapport n'a été modifié.

## 7. Tests exécutés

- `py -m unittest discover -s scripts -p "test_build_preprod.py"` : **43 tests réussis** (15 de validation, 4 de marqueurs de production, 10 d'`aapt2`/outils, 12 de build/récupération, 2 de wrapper).
- Suite Python complète : **98 tests réussis**.
- Tests d'arrêt brutal : un vrai processus tué, dans une racine temporaire factice. Le dépôt réel n'a pas été touché (`maps_key.dart` propre, pas de dossier `build/az-preprod-recovery`, `android/app/src/debug/` inchangé).
- Vérification réelle sans build : `build-test-apk.ps1 -CheckOnly` avec un fichier natif **synthétique** dérivé des defines locaux (valeurs jamais affichées, fichier supprimé) → `aapt2` réel, Node réel et `verify-isolation.js` réel exécutés : `validation PASS`, `APP_BUILD_NUMBER=11`. Syntaxe PowerShell analysée sans erreur, BOM présent, fins de ligne inchangées.
- Aucun appel réseau, aucun émulateur, aucun Gradle.

## 8. Risques résiduels

1. Aucune restauration **automatique** de `maps_key.dart` après arrêt brutal (détection, refus et procédure manuelle seulement).
2. F8 : priorité du fichier natif de debug non vérifiée par un build ; reste couverte par la garde de démarrage Dart.
3. `check-no-prod-maps-key.js` inerte si l'original n'a pas de clé (F4) ; clé de test visible dans la ligne de commande (F7).
4. Un `flutter build` manuel contourne toujours le moteur.
5. Si `git status` indique que `maps_key.dart` est modifié, le build refuse : l'opérateur doit d'abord traiter cette modification (comportement voulu).
6. Contrôles post-build (`audit_apk`, `check-no-prod-maps-key.js`, `audit-apk-content.js`) testés par simulation et sur fichiers factices, **jamais sur un vrai APK**.

## 9. Éléments NON VÉRIFIÉS

Compilation réelle ; sélection du `google-services.json` par le plugin ; transmission effective de `APP_BUILD_NUMBER`, `DISABLE_FCM` et `AZ_REQUIRED_FIREBASE_PROJECT` dans un binaire ; `aapt2 dump badging` sur un vrai APK ; existence du `google-services.json` préproduction réel ; numéro de projet côté console Firebase.

## 10. État Git

| | Avant M2.8 | Après M2.8 |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | idem |
| Index / stash | vide / 0 | vide / 0 |
| Suivis modifiés | 60 | 60 |
| Non suivis (`git status --porcelain`) | 187 | **188** (ce rapport) |

`lib/constants/maps_key.dart` : propre avant et après. Fichiers protégés inchangés (`git hash-object`, 8 caractères) : `passwordReset.js` 26975f60, `index.js` a9ba2c0d, `firestore.rules` 5341bfd6, `storage.rules` f3b5b608, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a. Checklist de suppression de compte non touchée (blob `f97ccad5…`). `build_mobile.py` et `run.ps1` non modifiés.

## 11. Décisions nécessaires

1. Fournir le `google-services.json` préproduction (app `com.azexpress.app.test`) hors dépôt et confirmer le numéro de projet dans la console.
2. Autoriser séparément le premier APK Debug préproduction (réseau, ≈ 3,7 Go libres sur C:, cache Gradle non nettoyé).
3. Décider si F4 et F7 justifient une mission séparée.

**Arrêt : aucune autre mission lancée.**
