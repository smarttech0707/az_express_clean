# Mission M1.2 — Compatibilité du SDK Flutter, cycle de vie des sessions, sécurité du prototype, fiabilité du lanceur

Complète M1 (`ACCOUNT_DELETION_M1_LOCAL_FEASIBILITY.md`) et M1.1 (`ACCOUNT_DELETION_M1_1_LOCAL_INTEGRATION.md`), dont les tests sont rejoués et inchangés. **Tout résultat ci-dessous vient des émulateurs locaux (projet fictif `demo-m1-feasibility`) et ne prouve pas le comportement de production.** Légende : **[T]** testé en local ; **[H]** hypothèse sur la plateforme réelle, NON VÉRIFIÉ ; **[NV]** non vérifiable ici.

## 1. Procédure reproductible

```
node scripts/m1_feasibility/run-m1-local.js --suite all        # core + security + flutter (≈ 2 min 15 s, dont ≈ 50 s de build Flutter)
node scripts/m1_feasibility/run-m1-local.js --suite core|security|flutter
node scripts/m1_feasibility/run-m1-local.js --clean-stale       # retire les dossiers laissés par un arrêt brutal
powershell -NoProfile -File scripts\m1_feasibility\ctrlc-test.ps1 [-Mode Startup|Tests]   # test Ctrl+C réel
```
Dernière exécution complète depuis un état propre (sans `.dart_tool`) : **50 tests, 50 réussis, 0 échec** (36 core dont les 14 de M1 + 7 sécurité + 7 Flutter). Prérequis : Java, `firebase-tools`, Chrome, Flutter, `functions/node_modules` et `node_modules/firebase` installés.

## 2. Versions exactes (pubspec.lock du dépôt, recopiées dans `flutter_probe/pubspec.yaml`)
Flutter 3.44.5 / Dart 3.12.2 ; `firebase_core` 4.11.0, `firebase_auth` 6.5.2, `cloud_functions` 6.3.2, `cloud_firestore` 6.5.0 ; `firebase_core_web` 3.9.0, `firebase_auth_web` 6.2.2 ; SDK JS Firebase 12.15.0 (version supportée par `firebase_core_web`, servie depuis `node_modules/firebase` du dépôt) ; `firebase-tools` 15.18.0 ; Node 24.22.1 ; Chrome 157 headless. `pubspec.lock` de la sonde = copie de celui du dépôt.

## 3. Tests Flutter [T] — SDK réel, **Flutter web uniquement**
Sonde `scripts/m1_feasibility/flutter_probe/` (non importée par l'application ; n'importe aucun code d'AZ Express ; reproduit les appels de `auth_service.dart`), exécutée dans Chrome headless contre les émulateurs. Chaque phase est un **nouveau processus Chrome sur le même profil** (vrai redémarrage, IndexedDB persistant, fermeture propre par DevTools). Un proxy local refuse et journalise tout trafic non local.

| # | Opération demandée | Résultat |
|---|---|---|
| 1 | Jeton depuis la callable | OK : réponse = `ok, customToken, role` seulement |
| 2-3 | `signInWithCustomToken`, UID | OK, UID exact |
| 4 | `currentUser.email` | OK : e-mail du compte conservé (client : e-mail réel ; vendeur : alias `<tél>@az-seller.ci`) |
| 5 | `providerData` | `[password]` conservé ; `isAnonymous=false`, `emailVerified=false`, `signInProvider=custom` ; `additionalUserInfo.providerId=null`, `isNewUser=false` |
| 6 | Persistance après redémarrage | OK : session restaurée (uid, e-mail, providerData), jeton renouvelé, déconnexion persistée au redémarrage suivant. Témoin session mot de passe : identique |
| 7 | Réauthentification (`EmailAuthProvider`) | OK (bon mot de passe) ; mauvais mot de passe : `auth/wrong-password` |
| 8 | `updateEmail` | **N'existe plus dans `firebase_auth` 6.5.2** ; l'application utilise `verifyBeforeUpdateEmail` (`auth_service.dart:149`) : OK, e-mail inchangé tant que le lien n'est pas validé (demande `VERIFY_AND_CHANGE_EMAIL` enregistrée) |
| 9 | `updatePassword` | OK ; le nouveau mot de passe fonctionne ensuite dans la callable, l'ancien est refusé de façon uniforme (`ok:false`, `invalid-credentials`) |
| 10 | Suppression du compte | OK après réauthentification ; l'utilisateur Auth n'existe plus ; **le profil Firestore `clients/{uid}` n'est pas supprimé** (reste à la charge du flux de suppression) ; plus aucune connexion possible |
| 11 | Erreurs | jeton invalide : `auth/invalid-custom-token` ; callable protégée sans session : `functions/unauthenticated` ; charge utile `null` : `functions/invalid-argument` ; mauvais identifiants : pas d'exception, réponse uniforme |
| 12 | Rôle non modifiable | refusés (`permission-denied`) : écrire `admins/{uid}`, `sellers/{uid}`, son `wallet`, lire un autre profil ; écrire `role:'admin'` sur son profil client est toléré par les règles **sans effet** (rôle = collection, relu par le serveur : `whoami=client`) ; jeton rafraîchi sans revendication `admin`/`role` ; le SDK n'offre aucune API pour poser une revendication |

**Limites [NV]** : SDK natifs Android/iOS non testés (aucun émulateur Android/appareil ; Visual Studio incomplet pour Windows desktop) — le stockage de session natif (Keystore/Keychain) diffère ; écrans réels non lancés ; `reload()`/`reauthenticate` avec `phoneNumber`, MFA, App Check non testés.

### Constat de test important
Au redémarrage, le SDK web valide la session persistée **dès l'initialisation**. Si l'émulateur est branché *après* (`useAuthEmulator` appelé par Flutter), cette validation part vers les **vrais** `identitytoolkit.googleapis.com` / `securetoken.googleapis.com` : le proxy les a refusés et la session était alors perdue ou non renouvelable. La sonde branche donc l'émulateur avant Flutter (`web/index.html`, mêmes options que `firebase_auth_web`) ; après ce correctif le proxy ne voit plus aucun hôte d'API Firebase (test F6). Ceci concerne le harnais, pas la production — mais prouve que les premières exécutions sans proxy ont pu contacter des hôtes Google réels avec une fausse clé API : aucun jeton ni donnée réelle n'était en jeu.

## 4. Sécurité du prototype
- **Tentatives répétées** [T] : 40 échecs d'affilée → toujours réponses uniformes, le titulaire se connecte ensuite ; **l'émulateur n'applique aucune limitation** (comportement réel NON VÉRIFIÉ [H]).
- **Limitation simulée** (proxy qui renvoie `TOO_MANY_ATTEMPTS_TRY_LATER` après 5 échecs par adresse — hypothèse [H]) : chaque tentative = **3 vérifications** (×3 de pression, y compris pour un numéro inconnu) ; une fois l'adresse limitée, **le titulaire est aussi refusé**, de façon uniforme. Risque de déni de service ciblé à mesurer en préproduction. Corrections proposées : limitation applicative par numéro et par appelant **avant** les vérifications (ralentissement croissant, jamais verrou dur) ; ne vérifier qu'une adresse quand le profil désigne l'e-mail réel (les 3 appels fixes servent au temps constant, pas à la sécurité) ; journaliser rafales et doublons dans `security_events`.
- **Temps de réponse** [T] : sans plancher (prototype direct), médianes en ms : succès 6,9 ; mauvais mot de passe 4,6 ; inconnu 4,5 ; **entrée invalide ≈ 0** (réponse immédiate) → fuite de temps réelle sur les entrées invalides. Avec un plancher de 400 ms dans la callable, médianes : 417 / 418 / 417 / 417 / 417 (succès / mauvais mdp / inconnu / désactivé / invalide), écart < 2 ms. Valeur à recalibrer (≥ p95 d'un succès réel) en préproduction.
- **Création involontaire d'UID** [T] : aucune tentative (inconnu, désactivé, alias historique réutilisé par un autre profil, profil sans compte) ne crée d'utilisateur ; `createCustomToken` nu sur un UID inexistant **crée** le compte à l'échange — d'où `getUser` obligatoire avant. À ajouter en M3 : `account_tombstones`, fermeture en cours.
- **Signatures** : l'émulateur n'authentifie pas les jetons (un jeton `alg:none` forgé est accepté par l'émulateur Firestore, S7). **Rien de local ne prouve la signature.** En réel [H, NON VÉRIFIÉ] : le compte de service d'exécution doit pouvoir signer (`iam.serviceAccounts.signBlob`, rôle *Service Account Token Creator* sur lui-même) ; pas de clé de compte de service dans le code ; restreindre qui détient ce droit (il permet d'incarner n'importe quel UID, cf. M1.1 C10) ; journaliser chaque émission sans le jeton ; durée de validité (≈ 1 h) et rejeu NON VÉRIFIÉS.

## 5. Fiabilité du lanceur (`run-m1-local.js`)
- **Ctrl+C réel** [T] (`ctrlc-test.ps1`, vrai `CTRL_C_EVENT` dans une console dédiée, 2 scénarios) : pendant le démarrage des émulateurs et pendant les tests → **arrêt en 3,1 s, code de sortie 130, ports libérés, dossier temporaire supprimé, `functions/node_modules` inchangé (361 entrées), aucun processus résiduel**. Verdict OK ×2.
- **Arrêt brutal** (processus tué par l'outil, deux fois pendant la mise au point) : les émulateurs s'arrêtent mais les dossiers `m1-local-*` / `m1-probe-chrome-*` restent ; `--clean-stale` les a retirés (3 + 3 dossiers) sans toucher `functions/node_modules` (359 entrées avant et après).
- **Corrections apportées au lanceur** : suppression par `removeRunDir` (parent = dossier temporaire réel, nom attendu, dossier non lien, jonction `functions/node_modules` retirée par `rmdir` après contrôle `isSymbolicLink`, refus s'il reste un lien, jamais de suppression récursive avant) ; `--clean-stale` (refuse si un port est occupé, ne supprime un `m1-local-*` que s'il porte la signature du lanceur) ; ports du serveur de sonde (29610), du proxy (29611) et du proxy de sécurité (29620) contrôlés au démarrage ; arrêt de Chrome borné par des délais (une attente sans limite avait gelé une exécution ~22 min avant correction).
- **Reste** : un `Remove-Item -Recurse`/`rm -rf` manuel sur un dossier `m1-local-*` laissé après arrêt brutal suivrait la jonction : utiliser `--clean-stale`. Ctrl+C sous Linux/macOS non testé (le lanceur utilise `taskkill` sous Windows uniquement).

## 6. Anomalies et constats
1. `updateEmail` supprimé de `firebase_auth` 6.x : sans conséquence (l'application utilise `verifyBeforeUpdateEmail`).
2. Le profil Firestore survit à la suppression de l'utilisateur Auth (comportement attendu du SDK).
3. Un client peut écrire un champ `role` arbitraire dans son profil (règles actuelles) : sans effet tant que le rôle est dérivé de la collection ; à ne jamais utiliser comme source d'autorité.
4. La callable rate/plancher ne couvre pas `m1WhoAmI` (non sensible aux identifiants).
5. Journal du lanceur sous `cmd` : l'encodage des accents est dégradé (cosmétique).
6. Un avertissement Firebase signale la présence d'identifiants Google par défaut sur la machine ; les fonctions de test refusent de s'exécuter sans variables d'émulateur et le projet `demo-*` interdit les services réels.

## 7. À valider en préproduction (jamais en production directement)
Signature réelle et IAM ; limitation de tentatives du service d'identité et effet des 3 appels ; clé API Web côté serveur ; durée/rejeu du jeton ; révocation réelle ; latence réelle (calibrage du plancher) ; SDK natifs Android/iOS (persistance, `reauthenticate`, `verifyBeforeUpdateEmail`, suppression de compte via `account_deletion_service.dart:101-104`) ; App Check ; Phone Auth (`passwordReset.js` exige `token.phone_number`) ; compatibilité des anciennes versions de l'application.

## 8. Fichiers
Créés (tous sous `scripts/m1_feasibility/`, non suivis) : `run-m1-local.js` (modifié depuis M1.1), `m1_1_helpers.js` (inchangé), `m1_2_security.test.js`, `m1_2_flutter.test.js`, `ctrlc-test.ps1`, `flutter_probe/{pubspec.yaml, pubspec.lock, lib/main.dart, web/index.html}`, `emulator/functions/index.js` (plancher de latence ajouté) et `emulator/functions/package.json` (dépendances déclarées) ; ce rapport. Aucun fichier de l'application, des fonctions de production, des règles ou de la configuration Firebase n'est modifié. Artefacts générés (`.dart_tool`, build, profils Chrome, journaux) supprimés.

## 9. État Git
HEAD `d65c8f0` avant et après ; index vide ; stash 0 ; 62 fichiers suivis modifiés avant et après ; `firestore.rules` (9380c0e0…) et `functions/index.js` (9c2bd8ed…) inchangés. Seules entrées non suivies ajoutées : ce rapport (le dossier `scripts/m1_feasibility/` figurait déjà). Aucun commit, push, stash, reset, clean ni action sur l'index. Aucun accès distant : proxy de blocage actif pendant les tests Flutter (aucun hôte d'API Firebase atteint, test F6).

## 10. Conclusion
**FAISABLE AVEC RÉSERVES.** Démontré en local avec le vrai SDK Flutter web : connexion par jeton personnalisé, UID et e-mail corrects, `providerData=[password]` (donc réauthentification, changement de mot de passe, demande de changement d'e-mail et suppression de compte fonctionnent comme avec une session mot de passe), persistance après redémarrage, erreurs cohérentes, aucune élévation de rôle, lanceur fiable sous Ctrl+C. Réserves : SDK natifs non testés, signature/IAM, limitation de tentatives et risque de blocage du titulaire, fuite de temps à corriger par un plancher calibré, tous NON VÉRIFIÉS hors émulateur.

**Arrêt : M1.2 terminée, attente d'une nouvelle autorisation.**
