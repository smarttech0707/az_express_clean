# Mission M1.1 — Intégration locale Auth / Functions / Firestore des jetons personnalisés

Complète `ACCOUNT_DELETION_M1_LOCAL_FEASIBILITY.md` (M1, non refaite, ses 14 tests sont inchangés et rejoués). **Tout ce qui est « testé » ci-dessous l'est sur les émulateurs locaux, projet fictif `demo-m1-feasibility`. Aucun résultat ne prouve le comportement en production.** Légende : **[T]** testé en local ; **[H]** hypothèse sur la plateforme réelle, **NON VÉRIFIÉ** ; **[F]** fait lu dans le dépôt.

## 1. Procédure reproductible

```
node scripts/m1_feasibility/run-m1-local.js      # depuis la racine du dépôt
```
Le script : vérifie que les ports 29199 (Auth), 29080 (Firestore), 29501 (Functions), 29400 (hub), 29500 (logs) sont libres, sinon s'arrête avec le code 2 sans rien toucher [T] ; crée un dossier `m1-local-*` dans le dossier temporaire du système (copie des fonctions jetables + jonction en lecture seule vers `functions/node_modules`) ; lance `firebase emulators:exec` (Auth + Firestore + Functions) avec les **vraies règles `firestore.rules`**, lues en place ; exécute en série les 3 fichiers de test ; arrête les émulateurs ; retire la jonction (`rmdir`, sans suivre le lien) puis le dossier temporaire ; vérifie que les ports sont libérés. Code de sortie = celui des tests. Gestionnaires SIGINT/SIGTERM/SIGBREAK et erreurs non rattrapées appellent le même arrêt.
Prérequis : Java, `firebase-tools`, `functions/node_modules` installé.
**Si le script est tué brutalement**, le dossier `m1-local-*` peut rester : supprimer d'abord `m1-local-*\functions\node_modules` avec `rmdir` (jamais `Remove-Item -Recurse` ni `rm -rf` dessus : suivre la jonction effacerait `functions/node_modules` du dépôt).

## 2. Tests exécutés (3 exécutions complètes : dernière = 36/36, 0 échec, 15,8 s)

| Fichier | Tests | Contenu |
|---|---|---|
| `m1_feasibility.test.js` (M1, inchangé) | 14 | Auth seul, voir rapport M1 |
| `m1_1_functions.test.js` | 11 | callable locale `clientPhoneLoginM1` + `m1WhoAmI`, annuaire Firestore émulé |
| `m1_1_firestore_rules.test.js` | 11 | vraies règles, ID tokens issus du parcours complet |

Historique : la 1re exécution a échoué (chemin `functions.source` doublé dans la configuration temporaire ; fonctions non chargées) ; corrigé dans le script, pas dans les tests.

### B — Cloud Functions Emulator [T]
- B1/B2 : client et vendeur → callable → jeton → échange ; UID exact, `sign_in_provider = custom`, rôle (`client`/`seller`) relu depuis Firestore.
- B3 : ni e-mail, ni alias (`@az-seller.ci`, `@azexpress.app`), ni mot de passe, ni UID d'un autre compte dans les réponses (succès, échec, fonction protégée) ni dans le jeton.
- B4 : échec **uniforme** pour mauvais mot de passe, numéro inconnu, compte désactivé, mot de passe vide, types invalides, identifiant de 500 caractères, objet vide.
- B5 : corps sans `data` ou `data` non objet → `INVALID_ARGUMENT` (400), aucun détail interne (pile, chemin, service).
- B6 : champs `role`, `claims`, `uid` injectés par le client sont ignorés ; le jeton n'a aucun privilège.
- B7 : une session fournie à la connexion (anonyme ou valide) n'ouvre rien sans mot de passe correct.
- B8 : `m1WhoAmI` : non connecté → `UNAUTHENTICATED`, anonyme → `PERMISSION_DENIED`, client et vendeur acceptés.
- B9 : compte Auth sans profil → refusé. B10 : même numéro chez un client et un vendeur → échec uniforme. B11 : une revendication stockée est copiée dans la session.

### C — Règles Firestore réelles [T] (200 = autorisé, 403 = refusé par les règles)
Sessions comparées : personnalisée client, personnalisée vendeur, anonyme, mot de passe (témoin).
- C1 client : lire/modifier son profil, lire sa commande → autorisé.
- C2 client : profil/commande d'autrui, profil vendeur, écriture produit, `ai_conversations` → refusé.
- C3 pas d'élévation : `wallet`, `cashOnDeliveryEnabled`, création de `admins/{uid}`, lecture `admins`, écriture `audit_logs` → refusé.
- C4 vendeur : son profil et son produit → autorisé ; profil/commande client, `wallet`, `isActive`, `admins` → refusé.
- C5 client ≠ vendeur dans les deux sens → refusé.
- C6 **anonyme vs personnalisée** : création `driver_requests` (règle `isRealUser`) refusée en anonyme, acceptée en session personnalisée et en session mot de passe.
- C7 anonyme : aucune lecture de profil, commande ou vendeur.
- C8 **parité** : mêmes statuts, session personnalisée et session mot de passe, sur 6 opérations.
- C9 revendication `partnerMustChangePassword` copiée dans la session : écriture produit bloquée, lecture du profil permise (comportement voulu par `partnerActivated()`).
- C10 un jeton forgé via Admin SDK pour un autre UID donne exactement les droits de cet UID : le contrôle est l'accès à la signature, pas les règles.

Les règles ont pu être testées **sans modification** ; aucune limitation à déclarer sur ce point. Couverture limitée aux collections ci-dessus (pas l'ensemble des ~70 collections).

## 3. Risques d'authentification

1. **`revokeRefreshTokens`** : [T] `verifyIdToken(…, true)` refuse un jeton révoqué (Admin) ; un nouveau login reste possible. **NON VÉRIFIÉ** : l'émulateur renouvelle encore une session par refresh token après révocation (200, mot de passe comme jeton personnalisé). [F] les règles Firestore ne contrôlent pas la révocation : un ID token reste utilisable jusqu'à expiration [H ≈ 1 h]. Le jeton personnalisé lui-même n'est pas invalidé par la révocation [H].
2. **`createCustomToken` sur UID inexistant** : [T, M1 F1] crée un compte à l'échange. Le prototype vérifie l'existence (`getUser`) et la désactivation juste avant ; B9 montre qu'un compte Auth sans profil est refusé par la fonction protégée. À ajouter en intégration : `account_tombstones`, fermeture en cours.
3. **IAM en environnement réel [H, NON VÉRIFIÉ, rien demandé]** : le compte de service d'exécution doit pouvoir signer (`iam.serviceAccounts.signBlob`, rôle « Service Account Token Creator » sur lui-même). Alternative par clé de compte de service : à écarter (secret). Accès à l'API d'identité avec la clé API Web. Quiconque obtient cette permission peut incarner tout UID (C10).
4. **Signatures** : l'émulateur délivre des jetons non signés (`alg: none`, [T] M1 F2) et n'authentifie pas les ID tokens (l'émulateur Firestore les décode sans vérification de signature). Les résultats C prouvent la logique des règles, **pas** la vérification de signature en production. Durée de validité réelle d'un jeton personnalisé (≈ 1 h) et rejouabilité : **NON VÉRIFIÉ**.
5. **Tentatives répétées** : [T] l'émulateur n'en limite aucune ; le prototype n'a ni `checkRateLimit` ni `logAudit`. **NON VÉRIFIÉ** : la limitation côté service d'identité (`TOO_MANY_ATTEMPTS_TRY_LATER`), son effet sur 3 appels par tentative, et le verrouillage possible du titulaire par un tiers. À concevoir : limitation par appelant et par numéro (ralentissement, jamais verrou dur), `security_events` pour doublons et rafales, plancher de latence (B4 montre des échecs précoces en ~2 ms contre ~40 ms pour un cas complet : la fuite de temps n'est corrigée que pour le chemin « numéro connu / inconnu » du prototype, **pas** pour les entrées invalides ; à uniformiser).
6. **Environnement** : l'avertissement « Application Default Credentials detected » est apparu sur cette machine. Les fonctions de test ne touchent que Auth et Firestore émulés et refusent de démarrer sans les variables d'émulateur ; le projet `demo-*` empêche l'accès aux services réels. Aucun appel distant n'a été fait [F : prototype et garde `assertLocalUrl`].
7. Divers : Node 24 hôte utilisé (le runtime déclaré est 22) ; `firebase-functions` v7 chargé avec succès.

## 4. À valider sur Flutter (NON VÉRIFIÉ, aucun SDK Flutter lancé)
`signInWithCustomToken`, puis `currentUser.email`/`providerData` ; `reauthenticateEmail`, `updateEmail`, `updatePassword`, `updatePhone` (`auth_service.dart:133-177`) ; suppression de compte (`account_deletion_service.dart:101-104`, exige un fournisseur `password`) ; persistance après redémarrage ; déconnexion ; compatibilité des anciennes versions ; modification de `client_auth_page.dart` (non faite). Seul l'équivalent REST a été testé.

## 5. À valider en environnement réel (préproduction autorisée, jamais production d'emblée)
Signature réelle et permission IAM ; limitation de tentatives du service d'identité ; restrictions de la clé API Web côté serveur ; révocation réelle ; durée du jeton ; App Check ; latence réelle ; Phone Auth (`passwordReset.js` exige `token.phone_number`).

## 6. Fichiers
Créés (tous sous `scripts/m1_feasibility/`, non suivis, non importés par l'application ni par `functions/`) : `run-m1-local.js`, `m1_1_helpers.js`, `m1_1_functions.test.js`, `m1_1_firestore_rules.test.js`, `emulator/functions/index.js`, `emulator/functions/package.json` ; plus ce rapport. Aucun fichier existant modifié (le prototype M1 et ses 14 tests sont inchangés). Temporaires de la session (hors dépôt) : journaux et configuration dans le dossier scratchpad.

## 7. État Git
HEAD `d65c8f0` avant et après ; index vide ; stash 0 ; `git status --short` : 265 entrées avant et après, identiques (le dossier `scripts/m1_feasibility/` était déjà une entrée non suivie) ; `firestore.rules` (9380c0e0…) et `functions/index.js` (9c2bd8ed…) non modifiés. Aucun commit, push, stash, reset, clean ni action sur l'index. Après la dernière exécution : 0 port d'émulateur ouvert, 0 dossier `m1-local-*` restant.

## 8. Conclusion
**FAISABLE AVEC RÉSERVES.** Démontré en local : parcours complet callable → jeton → session, bon UID et bon rôle, aucune fuite de données, rejet des sessions non autorisées, **mêmes droits Firestore que la session par mot de passe**, pas d'élévation de privilèges, distinction anonyme/personnalisée respectée par les règles réelles. Réserves : signature et IAM, limitation de tentatives, révocation réelle, uniformité des temps de réponse, comportement du SDK Flutter — tous NON VÉRIFIÉS hors émulateur.

**Arrêt : M1.1 terminée, attente d'une nouvelle autorisation.**
