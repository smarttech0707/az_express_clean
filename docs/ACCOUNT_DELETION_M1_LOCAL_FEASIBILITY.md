# Mission M1 — Faisabilité locale des jetons personnalisés et de la connexion client

Étude avec code d'essai **strictement local** (émulateur Firebase Auth, projet fictif `demo-m1-feasibility`, port 29199, données fictives). Aucun accès à `az-express-b0469`, `az-express-preprod` ni à un service distant ; aucun fichier applicatif, règle, configuration ou fichier protégé modifié. Légende : **[T]** testé sur l'émulateur ; **[F]** fait lu dans le dépôt (fichier:ligne) ; **[H]** hypothèse sur la plateforme réelle, **non testée** ; **[NV]** non vérifiable ici. Un résultat [T] ne vaut que pour l'émulateur.

## 1. Architecture actuelle de l'authentification [F]

- Connexion client : `lib/screens/auth/client_auth_page.dart:130-205`. Entrée téléphone → `AuthService.getClientAuthEmail` (`auth_service.dart:25-43`) → callable `checkClientPhone` (`functions/index.js:1712-1727`, sans contrôle `request.auth`, renvoie `{exists, email}`) ; repli `<téléphone nettoyé>@azexpress.app` (le nettoyage conserve `+` : `[^0-9+]`, `auth_service.dart:41`) ; puis `signInWithEmailAndPassword` ; repli vendeur `<téléphone>@az-seller.ci` (`client_auth_page.dart:160-166`). La même page sert clients et vendeurs.
- Inscription : `createUserWithEmailAndPassword` depuis le client, puis profil `clients/{uid}` écrit directement (`client_auth_page.dart:240-252`).
- Autorité : le rôle est la collection du document ; les règles et fonctions n'excluent que `sign_in_provider == 'anonymous'` (`firestore.rules:80`, `storage.rules:16,119`, ~25 fonctions dont `adminGuards.js:6`, `orderActions.js:654`, `ekbineOrders.js:91`). Aucun contrôle sur `token.email` ni sur `sign_in_provider == 'password'`.
- Réinitialisation : `passwordReset.js:44` exige `token.phone_number` (Phone Auth).
- Code client qui suppose une session « e-mail + mot de passe » : `reauthenticateEmail(user.email!, …)` (`auth_service.dart:133-135`, `updateEmail :147`, `updatePassword :164`, `updatePhone :177`) ; `account_deletion_service.dart:101-104` exige `providerData` contenant `password` et `user.email != null`.
- Revendications personnalisées déjà utilisées : `partnerMustChangePassword` (`adminPartnerAccounts.js:340,373,468`, `partnerFirstLogin.js:89,187-189`, `partnerActivationGuard.js`). `revokeRefreshTokens` est utilisé seulement par la fermeture de compte (`accountClosureProtocol.js:158`, `manualAccountDeletion.js:142,181`, `partnerFirstLogin.js:187`).
- Aucun `createCustomToken`, `signInWithCustomToken` ni appel REST d'identité n'existe aujourd'hui dans `functions/` ni `lib/`.

## 2. Stockage et vérification actuels des mots de passe

- **[F]** Le mot de passe d'un client n'est jamais écrit dans Firestore ni transmis à une fonction : le profil `clients/{uid}` ne contient que `name, phone, email, wallet, cashOnDeliveryEnabled, fakeOrderCount, createdAt` (`client_auth_page.dart:244-252`). Le mot de passe n'existe que dans **Firebase Authentication**, qui en garde le haché dans un format interne.
- **Conséquence** : il n'existe aucun haché applicatif à vérifier ou à migrer. Le SDK Admin ne propose pas de vérification de mot de passe [H, connue ; non utilisée ici]. La seule voie sans secret supplémentaire est l'appel REST « sign in with password » du service d'identité, avec la clé API Web (identifiant public, non lu dans cette mission). Aucun haché n'a été lu, exporté ni affiché.
- Comptes existants préservés : la vérification passe par les mêmes comptes Auth, donc **aucune migration de mot de passe** n'est nécessaire [T sur l'émulateur : D1, D2].

## 3. Prototype réalisé

Fichiers créés (non suivis, isolés, **non importés** par l'application ni par `functions/`) :
- `scripts/m1_feasibility/clientPhoneLoginPrototype.js` — fabrique `makeClientPhoneLogin({auth, directory, restBase, apiKey})`. Étapes : (1) résolution des documents par numéro (annuaire injecté, aucun Firestore) ; (2) candidats d'e-mail dans l'ordre du client actuel (e-mail réel du profil, alias `@azexpress.app`, alias `@az-seller.ci`) ; (3) **3 appels REST de vérification toujours**, sans sortie anticipée, avec mot de passe factice pour un numéro inconnu ou en doublon ; (4) le profil doit désigner exactement l'UID vérifié ; (5) `getUser` (existence, compte non désactivé) ; (6) `createCustomToken(uid)` ; (7) réponse `{ok, customToken, role}` — **jamais d'e-mail** — ou la réponse uniforme `{ok:false, code:'invalid-credentials', message:'Identifiants incorrects'}`. Garde d'exécution : toute requête vers un hôte autre que `127.0.0.1`/`localhost` lève une erreur.
- `scripts/m1_feasibility/m1_feasibility.test.js` — 14 tests (`node:test`) contre l'émulateur, mots de passe aléatoires générés à l'exécution et jamais journalisés.

Infrastructure temporaire (hors dépôt, dossier scratchpad de la session) : configuration d'émulateur dédiée, journaux, script de diagnostic. L'émulateur de M1 (PID 18872) a été arrêté ; les émulateurs préexistants (ports 8080 et 9099) n'ont pas été touchés.

## 4. Résultats des tests locaux (émulateur uniquement)

Commande : `node --test scripts/m1_feasibility/m1_feasibility.test.js` — **14 tests, 14 réussis, 0 échec** (dernière exécution). Une recherche du motif des mots de passe dans la sortie complète : 0 occurrence.

| Test | Résultat [T] |
|---|---|
| A1 | Succès client : la réponse ne contient que `ok, customToken, role` ; le jeton personnalisé ne contient pas d'e-mail ; l'échange donne une session avec le **bon UID** |
| A2 | `accounts:lookup` après échange : `email` présent et fournisseur `password` présent (donc `user.email` et `providerData` seraient renseignés) |
| A3 | `sign_in_provider = 'custom'` (≠ `anonymous`) ⇒ passe les contrôles actuels des règles et fonctions ; `phone_number` absent (inchangé pour `passwordReset.js`) |
| B1 | Le renouvellement par refresh token conserve l'UID |
| B2 | Une session ouverte avant par mot de passe n'est pas affectée par un nouveau `clientPhoneLogin` (ID token valide avec `checkRevoked`, refresh OK) |
| B3 | Après `revokeRefreshTokens` : `verifyIdToken(…, true)` refuse ; l'ancien ID token est refusé par `accounts:lookup` ; un **nouveau login est possible** (pas de verrou du titulaire). **Limite émulateur** : le renouvellement par refresh token répond **200 après révocation** (mot de passe comme jeton personnalisé) |
| C1 | Le claim stocké `partnerMustChangePassword` est présent dans l'ID token issu du jeton personnalisé, **avec ou sans** copie explicite dans le jeton |
| D1 | Vendeur (`@az-seller.ci`) : même fonction, rôle `seller` renvoyé, aucun e-mail |
| D2 | Ancien compte (`<téléphone>@azexpress.app`) : connexion réussie |
| E1 | Mauvais mot de passe, numéro inconnu, compte désactivé, doublon de numéro, numéro seul (mot de passe vide ou absent) : **réponses strictement identiques** |
| E2 | Médianes de 15 essais (ms) après correction : e-mail réel 5,2 ; inconnu 5,3 ; alias 6,0. **Première version (sortie anticipée, 1 appel pour un inconnu) : 6,0 / 1,7 / 3,8 — fuite de temps nette** ; corrigée par 3 appels fixes. Mesure d'émulateur sur machine locale, **non représentative** de la production |
| F1 | `createCustomToken` pour un UID inexistant **crée un compte à l'échange** (le prototype vérifie l'existence avant) |
| F2 | Le jeton personnalisé de l'émulateur est **non signé** (`alg: none`) |
| G1 | La garde refuse un hôte non local |

## 5. Compatibilité Firebase Custom Tokens

- **[T]** Échange, UID exact, profil de compte (e-mail et fournisseur `password` conservés), renouvellement, absence d'e-mail dans le jeton.
- **[H, non testé]** Signature réelle : l'émulateur ne signe pas. En production, `createCustomToken` signe via le compte de service d'exécution ; cela exige une permission de signature (voir §10). Ce chemin n'a **pas** été exercé.
- **[NV]** Comportement du SDK Flutter (`signInWithCustomToken`, `currentUser.email`, `providerData`) : seul l'équivalent REST a été testé. Les écrans réels n'ont pas été lancés.
- Durée du jeton personnalisé : l'émulateur n'a pas été utilisé pour la mesurer ; la durée de validité réelle d'un jeton personnalisé (≈ 1 h [H]) et le caractère rejouable jusqu'à expiration [H] ne sont pas vérifiés.

## 6. Gestion des sessions

- Persistance/renouvellement : [T] OK sur l'émulateur.
- Sessions existantes : [T] non invalidées par un nouveau login ; coexistence des sessions mot de passe et jeton.
- Déconnexion : opération côté client uniquement (non testée ici, aucun SDK Flutter).
- Révocation : [T] `checkRevoked` fonctionne côté Admin. **[NV]** Le comportement réel du renouvellement après révocation n'est **pas** établi (l'émulateur répond 200) ; ne pas s'appuyer sur ce test. Les règles Firestore ne vérifient pas la révocation (`firestore.rules:80`) [F] : un ID token reste utilisable jusqu'à expiration (≈ 1 h [H]). Un point inexpliqué : dans B3, `verifyIdToken(token, false)` a aussi refusé le jeton révoqué dans l'émulateur ; ne pas en tirer de conclusion sur la production.
- Anonyme : la fonction ne doit pas considérer une session anonyme comme preuve d'authentification ; le prototype n'utilise aucune session (testé directement via Admin SDK).

## 7. Risques de sécurité

1. **Verrouillage du titulaire par un tiers** [H] : les appels de vérification passent par le service d'identité, qui peut limiter les tentatives par compte/IP (`TOO_MANY_ATTEMPTS_TRY_LATER`). Trois appels par tentative multiplient la pression sur les trois adresses candidates (dont l'alias du vendeur) ; un attaquant pourrait déclencher la limitation et gêner aussi la connexion directe par e-mail. À mesurer hors émulateur avant M3.
2. **Fuite de temps** [T] : prouvée sur la première version, supprimée par 3 appels fixes. À reconfirmer en conditions réelles, avec un plancher de latence.
3. **Création de compte involontaire** [T] : `createCustomToken` sur un UID inexistant crée un compte ; contrôle d'existence et de statut obligatoires (désactivé, tombstone, fermeture en cours : `account_tombstones`, `assertTargetNotClosing` à intégrer en M3).
4. **Jeton personnalisé = secret au porteur** [H] : à ne jamais journaliser ; rejouable jusqu'à expiration.
5. **Clé API Web restreinte** [H] : une clé limitée à des applications ou référents pourrait refuser un appel serveur. Non testable ici.
6. **Alias réutilisables** : l'exigence « le profil désigne l'UID vérifié » est nécessaire (couverte par le prototype) pour qu'un alias historique ne ouvre pas un autre compte.
7. **Doublons de numéro** : échec uniforme + événement d'anomalie à journaliser (non implémenté ici).
8. **Pas de limitation de débit ni d'audit dans le prototype** : à concevoir en M3 avec `checkRateLimit`/`logAudit`.

## 8. Compatibilité des comptes existants

- Clients avec e-mail réel [T], anciens comptes `@azexpress.app` [T] : connexion réussie, UID inchangé, aucune migration.
- Profil du compte conservé (e-mail, `password`) [T] ⇒ `reauthenticateEmail`, `updateEmail`, `updatePassword` et la suppression de compte (`account_deletion_service.dart:101-104`) devraient continuer à fonctionner [H : non testé avec le SDK Flutter].
- Claims stockés : conservés dans la session [T émulateur] ; en production, copier explicitement les claims dans le jeton (comportement [H] non vérifié).
- Numéro saisi avec `+` : l'alias historique conserve `+` ; le prototype reproduit ce nettoyage.
- Comptes sans profil, désactivés, doublons : échec uniforme [T].

## 9. Compatibilité des vendeurs

- [T] Le vendeur (`@az-seller.ci`) se connecte via la même fonction et reçoit le rôle `seller` ; le nom de rôle renvoyé remplace `isSeller` côté écran (`client_auth_page.dart:174-205`) — modification d'écran **non réalisée**.
- Les vendeurs sans profil `sellers` correspondant, ou dont le profil change de numéro (écriture admin directe, L4.10.2), ne sont pas couverts par ce prototype ; le registre de liaison reste hors périmètre.

## 10. Dépendances et permissions IAM théoriquement nécessaires (non accordées, non demandées)

- **[H]** Signature des jetons personnalisés en production : le compte de service d'exécution des fonctions doit pouvoir signer (permission `iam.serviceAccounts.signBlob`, via le rôle « Service Account Token Creator » sur lui-même). Alternative décrite par la plateforme : initialiser le SDK avec une clé de compte de service — **à écarter** (secret à gérer).
- **[H]** API Identity Toolkit accessible depuis les fonctions avec la clé API Web fournie en configuration.
- Aucune dépendance npm ou Flutter nouvelle n'a été nécessaire (`firebase-admin ^12.0.0` déjà présent).
- Aucun IAM n'a été consulté, modifié ou demandé.

## 11. Limites rencontrées

- L'émulateur ne signe pas les jetons (F2), n'applique pas la révocation au renouvellement (B3) et ne reproduit ni limitation de tentatives, ni restrictions de clé API, ni IAM.
- Pas de SDK Flutter ni de Firestore dans le test : annuaire de profils simulé en mémoire.
- Mesures de temps non représentatives.
- Phone Auth, App Check, comptes réels, `checkClientPhone` réel et clé API Web : non testés (hors périmètre ou interdits).

## 12. Verdict

**FAISABLE SOUS CONDITIONS.**
Démontré sur l'émulateur : vérification serveur du mot de passe, aucun e-mail dans la réponse, réponses d'échec identiques, UID inchangé, comptes existants et vendeurs servis, sessions existantes non affectées. **Non démontré** : signature réelle (IAM), limitation de tentatives du service d'identité, comportement du SDK Flutter, révocation réelle, clé API Web côté serveur. Ces points conditionnent la faisabilité en production.

## 13. Recommandation pour M3

1. Module séparé `functions/clientAuth.js` avec dépendances injectées (comme le prototype) ; `index.js` ne reçoit que l'export (accord spécifique pour ce fichier protégé).
2. Garder : 3 vérifications fixes, UID du profil = UID vérifié, contrôle d'existence/désactivation/fermeture avant `createCustomToken`, réponse uniforme, plancher de latence, aucun journal du jeton ni du mot de passe.
3. Ajouter : `checkRateLimit` par appelant, par numéro (ralentissement, jamais verrou dur) ; `security_events` pour doublons et rafales ; mode de compatibilité à valeurs fermées pour `checkClientPhone` ; copie explicite des claims.
4. Prévoir avant M3 une vérification **hors émulateur** de la limitation de tentatives et du rôle de signature, sur un environnement explicitement autorisé.
5. Écran : une seule modification, remplacer l'appel à `getClientAuthEmail` ; tester le SDK Flutter (`currentUser.email`, `providerData`, réauthentification) avant tout déploiement.

## 14. Conditions avant toute intégration réelle

- Autorisation écrite distincte pour M3 (y compris `index.js`) ; décision sur le chemin d'accès à un environnement réel (préproduction) pour les points [H] — jamais en production directement.
- Validation de la permission de signature et de sa nécessité avant toute demande IAM.
- Vérification de la clé API Web côté serveur et de la limitation de tentatives.
- Tests Flutter des flux dépendant de `user.email`/`providerData`.
- Plan de compatibilité des anciennes versions (30 jours) et mode de `checkClientPhone`.
- Aucune des fonctions du prototype ne doit être importée telle quelle.

## 15. Compte rendu final

- **Git** : HEAD `d65c8f0` avant et après ; index vide avant/après ; stash 0 ; **35** fichiers suivis modifiés avant/après ; fichiers non suivis **171 → 173** (dossier `scripts/m1_feasibility/` = 1 entrée de statut, plus ce rapport).
- **Fichiers créés** : `scripts/m1_feasibility/clientPhoneLoginPrototype.js`, `scripts/m1_feasibility/m1_feasibility.test.js`, ce rapport. Aucun fichier existant modifié. Empreintes des fichiers protégés inchangées : `passwordReset.js` 26975f60, `index.js` a9ba2c0d, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a, `ekbineOrders.js` ff24d2c8, `professionalSubscriptions.js` 976c2396, `adminPartnerAccounts.js` 1a5cde55, `firestore.rules` 5341bfd6, `storage.rules` f3b5b608 (non modifié, absent de la liste des fichiers modifiés).
- **Commandes** : démarrage de l'émulateur Auth (`firebase emulators:start --only auth --project demo-m1-feasibility`, configuration dédiée hors dépôt), `node --test scripts/m1_feasibility/m1_feasibility.test.js` (4 exécutions : 12/14 puis 2 échecs de fixture et de limite d'émulateur corrigés, 14/14 deux fois), un script de diagnostic ponctuel, arrêt de l'émulateur de M1.
- **Environnement** : uniquement l'émulateur Auth local (127.0.0.1:29199), aucune opération Firebase distante (le prototype et le test refusent tout hôte non local).
- Ni M2 ni M3 lancées ; aucune permission IAM demandée ; prototype non intégré ; ni commit, push, stash, reset ni nettoyage.

**Arrêt : attente de l'examen du rapport et d'une nouvelle autorisation écrite.**
