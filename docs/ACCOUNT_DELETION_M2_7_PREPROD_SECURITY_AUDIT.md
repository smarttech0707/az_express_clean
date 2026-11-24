# Mission M2.7 — Audit de l'anomalie Git et des garde-fous préproduction

Audit **local** uniquement. Aucune compilation (APK, AAB, IPA, Web), aucun accès Firebase, aucun IAM, aucune modification de configuration, de secret, de `config/app_versions`, de règles ou de la checklist, aucun nettoyage de cache, aucune suppression, aucune commande Git d'écriture. `build_mobile.py`, `run.ps1`, `build_preprod.py` et le wrapper n'ont pas été modifiés (aucun défaut critique n'a été trouvé, donc aucune correction à différer). Les tests ad hoc ont été écrits dans le dossier temporaire de la session, hors dépôt.

## 1. Verdict

| Critère | Statut |
|---|---|
| Anomalie Git expliquée sans suppression | **PASS : l'anomalie est une erreur de mon propre tableau M2.5, pas un fichier supplémentaire** (§2) |
| Fichiers de M2.6 identifiés | **PASS** (§3) |
| Garde-fous critiques examinés | **PASS** (§4) |
| Défaut critique | **Aucun** ; 6 défauts mineurs ou moyens documentés (§5) |
| Tests autorisés | **PASS** : 72 tests Python, 16 vérifications ad hoc (§6) |
| Aucun accès distant ni build | **PASS** |
| Modifications préexistantes intactes | **PASS** (§8) |
| Build réel (Gradle, plugin Google Services, `aapt2`) | **NON VÉRIFIÉ** |

## 2. Anomalie Git : origine établie

Constat actuel : HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, 60 suivis modifiés, **186 non suivis**.

Le « fichier supplémentaire » n'existe pas. C'est une **erreur de comptage de ma part dans le rapport M2.5** :

| Étape | Non suivis | Source |
|---|---|---|
| Fin de M2.3 | 181 | rapport M2.3 |
| Fin de M2.4 (+ rapport M2.4) | **182** | rapport M2.4 : « 181 → 182 » |
| M2.5 — mon tableau écrivait « avant 181, après 182 » | — | **erroné** : l'état avant M2.5 était déjà 182 (fin de M2.4) ; j'avais repris 181 par erreur, et le 182 « après » correspondait en fait à l'état *avant* la création du rapport M2.5 |
| Après rapport M2.5 | 183 | calcul (182 + 1) |
| Après `build_preprod.py` et `test_build_preprod.py` | 185 | **constaté en M2.6 avant le rapport** |
| Après rapport M2.6 | 186 | constaté |

Vérification indépendante : parmi les 186 entrées non suivies, les fichiers les plus récents par date de modification sont, dans l'ordre, le rapport M2.6 (20:59), `test_build_preprod.py` (20:55), `build_preprod.py` (20:54), le rapport M2.5 (20:39), le rapport M2.4 (20:34), puis M2.3, M2.2, `test_app_build_number.py`, `get-app-build-number.ps1`, M2.1. **Aucun fichier inconnu** n'est plus récent que le début de M2.5. L'arithmétique est cohérente ; je retire la mention « 1 entrée non attribuée » du rapport M2.6 (§7 de ce rapport). Le rapport M2.6 n'a pas été modifié dans cette mission (interdiction de modifier hors rapport M2.7) : cette correction est donc ici.

Limite d'honnêteté : je ne possède pas la liste nominative des 181 fichiers du début de M2.3 ; la preuve repose sur l'arithmétique des rapports et sur l'absence de fichier récent inconnu. Statut : **expliqué, avec cette limite**. Aucun fichier n'a été supprimé, déplacé ou modifié.

## 3. Fichiers de M2.6

| Attendu | Constaté | Taille | Date (UTC) |
|---|---|---|---|
| `scripts/build_preprod.py` | présent, non suivi | 11 436 | 20:54:57 |
| `scripts/test_build_preprod.py` | présent, non suivi | 11 787 | 20:55:32 |
| `docs/ACCOUNT_DELETION_M2_6_PREPROD_BUILD_IMPLEMENTATION.md` | présent, non suivi | 11 388 | 20:59:15 |
| `test-env/build-test-apk.ps1` (modifié) | présent, suivi, modifié | 1 303 | 20:55:32 |

Autres fichiers créés par M2.6 : aucun dans le dépôt (`__pycache__` est ignoré par Git). Dates inchangées depuis M2.6 : aucun de ces fichiers n'a bougé pendant M2.7.

## 4. Audit des garde-fous (lecture ligne à ligne de `build_preprod.py` et du wrapper)

| Point | Résultat |
|---|---|
| Projet accepté | `az-express-preprod` en constante unique ; aucune option ni variable pour le changer |
| Numéro | `306761725053` exigé dans `FIREBASE_MESSAGING_SENDER_ID` et `project_number` natif (cohérence interne du dépôt ; console Firebase NON VÉRIFIÉE) |
| Cohérence Dart/natif | `project_id`, `project_number`, app ID, clé API, package, un seul client |
| Production refusée | recherche textuelle de `az-express-b0469`, `az-express-clean`, numéro de projet de production dans les deux fichiers entiers |
| Sélection silencieuse | impossible : `--config` et `--google-services` obligatoires ; le wrapper fixe `test-env\dart-defines.test.json` (explicite, gitignoré) et `-GoogleServices` obligatoire ; `.env*` et `android/app/google-services.json` refusés |
| Package | `com.azexpress.app.test` exigé dans le fichier natif ; Gradle reçoit `azTestSuffix=.test` |
| Type de build | seul `apk` ; `--release`, AAB, IPA, web refusés avant toute lecture de fichier ; la commande construite est `build apk --debug` |
| `APP_BUILD_NUMBER` | réutilise `build_mobile.resolve_build_number` (1 à 2 100 000 000) ; refusé dans le fichier de config ; transmis par `--dart-define` |
| FCM | `DISABLE_FCM` doit valoir `true` s'il est présent, injecté à `true` ; le code Dart le lit via `bool.fromEnvironment('DISABLE_FCM')` (`lib/services/fcm_policy.dart`) |
| Garde de démarrage | `AZ_REQUIRED_FIREBASE_PROJECT` injecté ; `lib/services/firebase_project_guard.dart` compare au projet **effectif** de l'application Firebase initialisée et bloque (fail-closed) : c'est la protection qui couvre un `google-services.json` de production embarqué par erreur |
| Secrets dans les logs | messages à texte fixe ; vérifié : ni clé, ni app ID, ni numéro de projet dans les sorties d'erreur ; la ligne de commande de Flutter ne contient ni clé API ni app ID (seuls le chemin du fichier de defines temporaire, le suffixe et la clé Maps de test éventuelle) |

## 5. Défauts et risques relevés (aucun critique ; rien corrigé)

| # | Gravité | Constat | Effet |
|---|---|---|---|
| F1 | moyenne | **Contrôle du package de l'APK en échec ouvert** : si `aapt2` est introuvable, le moteur affiche seulement un avertissement | le package n'est alors pas vérifié sur l'APK ; atténué par le plugin Google Services (aucun client correspondant au package ⇒ échec Gradle) et par la garde de démarrage, mais **NON VÉRIFIÉ** |
| F2 | moyenne | **Interruption brutale** (arrêt du processus, coupure) : `finally` ne s'exécute pas | `lib/constants/maps_key.dart` (suivi par Git) resterait remplacé par la version de test, et `src/debug/google-services.json` resterait en place. Le moteur refuse de relancer tant qu'ils existent (vérifié) et ne les supprime pas, mais l'opérateur pourrait **commiter la version de test** de `maps_key.dart` sans le voir. À signaler dans le mode d'emploi |
| F3 | basse | `node` absent : le moteur échoue avec une trace Python brute (`FileNotFoundError`) au lieu d'un message clair ; le build n'est pas lancé et tout est restauré (vérifié) | ergonomie |
| F4 | basse | `check-no-prod-maps-key.js` répond « aucune clé à rechercher » (code 0) si la sauvegarde ne contient pas de clé `AIza…` | contrôle post-build sans effet dans ce cas ; la clé de production actuelle y est présente |
| F5 | basse | `--check-only` (et donc `-CheckOnly`) ne lance **pas** les contrôles Node (`DELIVERY_PROOFS_UI`, références de production élargies, état de `maps_key.dart`) ni la clé Maps | un `PASS` en `-CheckOnly` n'équivaut pas à un build autorisé ; le build complet est plus strict |
| F6 | basse | La liste des identifiants de production est écrite à deux endroits (`build_preprod.py` et `test-env/lib/guards.js`) | dérive possible ; `guards.js` contient en plus des fragments d'app ID absents du moteur |
| F7 | basse | `TEST_MAPS_API_KEY` passe par la ligne de commande Gradle (visible dans la liste des processus) | clé de test, non secrète de production |
| F8 | info | Le plugin Google Services choisit `src/debug/google-services.json` avant `android/app/google-services.json` (production) : comportement connu, **non vérifié dans ce dépôt sans build**. Si le fichier de debug manquait, le fichier de production serait utilisé ; la garde de démarrage Dart (fail-closed) reste le dernier rempart |
| F9 | info | Le moteur suppose `py` (lanceur Windows) dans le wrapper | Windows seulement |

## 6. Tests exécutés (aucun réseau, aucune compilation)

- **Suite Python du dépôt : 72 tests réussis** (dont 17 de `test_build_preprod.py`).
- **16 vérifications ad hoc, toutes réussies** (script hors dépôt, racine temporaire factice, `subprocess` simulé) :
  - interruption clavier pendant la compilation : fichier natif retiré, sauvegarde retirée, `maps_key.dart` restauré ;
  - `node` absent : build non lancé, tout restauré (trace brute, F3) ;
  - échec de Flutter : erreur propre, tout restauré, **aucune clé, app ID ni numéro de projet dans les journaux** ;
  - fichiers résiduels (arrêt brutal simulé) : refus de relancer **et fichiers conservés** ;
  - ligne de commande : ni clé API ni app ID ;
  - **vrais scripts Node** sur fichiers factices : `verify-isolation.js` accepte la config cohérente, refuse le projet de production, `DISABLE_FCM=false`, `DELIVERY_PROOFS_UI=false` et le mauvais package ; sa sortie ne contient ni clé ni app ID.
- Wrapper : syntaxe PowerShell analysée sans erreur (M2.6) ; BOM présent ; contenu inchangé depuis.
- Aucun émulateur lancé.

## 7. Correction du rapport M2.6

Dans `docs/ACCOUNT_DELETION_M2_6_PREPROD_BUILD_IMPLEMENTATION.md`, §7, la ligne « 1 entrée non attribuée » et la décision 4 de §8 sont **sans objet**. Ce rapport n'a pas été modifié (hors périmètre) ; la décision de le corriger est à prendre.

## 8. État Git

| | Avant M2.7 | Après M2.7 |
|---|---|---|
| Branche / HEAD | `finalisation/az-express` / `d65c8f0` | idem |
| Index / stash | vide / 0 | vide / 0 |
| Suivis modifiés | 60 | 60 |
| Non suivis (`git status --porcelain`) | 186 | **187** (ce rapport uniquement) |

Empreintes inchangées (`git hash-object`, 8 premiers caractères, même méthode que les rapports M2.x) : `passwordReset.js` 26975f60, `index.js` a9ba2c0d, `firestore.rules` 5341bfd6, `storage.rules` f3b5b608, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a. Checklist : blob `f97ccad53b8e517fd0ecd1078643712468190bf9`, 18 093 octets, modifiée le 2026-11-11 20:33:51, identique à M2.4 (la valeur `sha1sum` brute diffère car `git hash-object` ajoute un en-tête de blob : il s'agit de deux méthodes, non d'un changement). `build_mobile.py` (19:59), `run.ps1` (20:00) inchangés. `android/app/src/debug/` ne contient que son manifeste d'origine.

*Rectificatif M2.5/M2.6* : les empreintes « sha1 » citées dans ces rapports pour les mêmes fichiers (2669c0c5, e2c1fcb5, 5fa856b2, c7b9ca85) sont des `sha1sum` du contenu, valables entre elles mais non comparables aux valeurs `git hash-object` des rapports antérieurs ; les deux séries sont inchangées.

## 9. Éléments NON VÉRIFIÉS

Compilation réelle ; priorité `src/debug/google-services.json` du plugin dans cette version de Gradle ; présence d'`aapt2` sur le poste ; exécution réelle de `verify-isolation.js` avec `--maps-swapped` et des audits d'APK ; numéro de projet côté console Firebase ; existence du `google-services.json` préproduction réel ; liste nominative des non suivis avant M2.3.

## 10. Décisions nécessaires avant le premier APK

1. Faut-il corriger F1 (échec fermé si `aapt2` manque) et F3 (message clair si `node` manque) avant le premier build ? Recommandé pour F1.
2. Ajouter au mode d'emploi la procédure de reprise après arrêt brutal (F2) : vérifier `git status` sur `lib/constants/maps_key.dart` avant tout commit.
3. Corriger le rapport M2.6 (§7).
4. Fournir le `google-services.json` préproduction et autoriser séparément le premier APK Debug (réseau, ≈ 3,7 Go libres).

**Arrêt : aucune autre mission lancée.**
