# Mission L4.10 — Audit de la réinitialisation des mots de passe et des UID à double rôle

Lecture seule. Aucun code, test, règle, configuration ou secret modifié ; aucun accès Firebase, production ou préproduction ; aucun inventaire de comptes réels possible. Légende : **[F]** fait vérifié par lecture du dépôt ; **[H]** hypothèse (plateforme ou production) ; **[R]** recommandation ; **[NE]** non exécuté (aucun test lancé).

**Verdict.** Le parcours de réinitialisation ne cible pas `admins`, mais son modèle de confiance est inversé : il fait confiance au champ `phone` d'un document de profil, **champ modifiable par des tiers** (sous-admin « demandes_vendeurs », super-admin) ou librement posé par n'importe quel titulaire. Deux chemins confirmés par lecture ressortent, en plus du risque de double rôle : (1) un **sous-admin** peut prendre le mot de passe d'un compte vendeur ; (2) un **super-admin** peut prendre le mot de passe de n'importe quel compte Firebase Auth (autre super-admin compris) en créant un document de profil factice. Le double rôle aggrave mais n'est pas nécessaire à ces attaques.

## 1. Architecture actuelle

- Autorité administrative = `admins/{uid}` (L4.9). Un uid Firebase Auth peut être référencé par des documents dans **plusieurs collections de rôles** : le « rôle » est la collection du document (charte du projet), aucune contrainte d'exclusivité n'existe dans les règles ni dans un index/registre. [F]
- La réinitialisation `resetAccountPassword` (callable, `passwordReset.js`, câblée dans `index.js`, `maxInstances: 2`) utilise l'identifiant du **document** retrouvé par téléphone comme UID Auth. [F]
- Des fonctions du dépôt supposent explicitement qu'un uid puisse exister dans plusieurs collections et refusent alors certaines opérations : `ekbineOrders.js` (quarantaine : refus si un document existe dans l'une des 9 collections « autres rôles », dont `admins`) ; `manualAccountDeletion.js` (liste `OTHER_ROLE_COLLECTIONS` de 10+ collections) ; `accountDeletion.js` (refus si `admins` contient l'uid) ; `adminPartnerAccounts.js` (cibles présentes dans `admins` refusées). [F] **Ces gardes manquent dans `passwordReset.js`.**

## 2. Analyse complète de `passwordReset.js` (108 lignes + dépendances lues)

Dépendances : `artisanCredentials.setPin` (PIN haché, artisan), `accountAdmission.assertTargetNotClosing` (tombstone/fermeture), `hashSecret` (pharmacie), `checkRateLimit` (par uid appelant). [F]

| Point | Constat [F] |
|---|---|
| Types autorisés | `client`→`clients`, `fleet`→`fleet_owners`, `seller`→`sellers`, `restaurant`→`restaurant_owners`, `boulangerie`→`boulangeries`, `pharmacie`→`pharmacies`, `artisan`→`service_providers` ; le reste ⇒ `invalid-argument` (le type est répété dans le message d'erreur). **Ni `admins`, ni `livreurs`, ni `ekbine_agents`, ni `real_estate_agents`.** |
| Recherche | Pour le type choisi : `where('phone','==',x)` sur 3 formes du numéro (brute, E.164, E.164 sans `+225`), `limit(2)` par forme, résultats fusionnés par id ; 0 ⇒ `not-found`, >1 ⇒ `failed-precondition` « Plusieurs comptes utilisent ce numéro ». |
| Preuve d'identité | `request.auth.token.phone_number` présent **et** égal au numéro fourni (après normalisation). Aucune comparaison avec le numéro/l'e-mail du compte Auth cible ; la seule liaison est le champ `phone` du document. |
| Fermeture/suppression | `isDeleted === true` ⇒ refus ; `assertTargetNotClosing(db, …, [id du document, currentUid])`. |
| Débit | `checkRateLimit(uid appelant, 'reset_password', 5, 3600)` appliqué **après** la vérification du numéro et **avant** la recherche. Pas de limite par numéro cible ni par IP. |
| Rejeu | Aucun jeton d'usage unique ni date de vérification : un jeton Phone Auth valide permet jusqu'à 5 changements/h (dans la limite de l'âge du jeton, ≤ 1 h [H]). |
| Effet Auth | `auth.getUser(id)` puis `auth.updateUser(id, { password })` ; vérification que `targetUser.uid === id`. Aucune vérification que l'utilisateur Auth correspond au propriétaire du numéro (e-mail, fournisseurs liés). |
| Sessions | **Aucun `revokeRefreshTokens`** dans le module. Effet réel de `updateUser({password})` sur les sessions existantes : [H], à vérifier sur l'émulateur Auth/préprod. |
| Notification titulaire | **Aucune**. |
| Traçabilité | **Aucune** (`logAudit`/`logSecurityEvent` absents). |
| MFA | Non évalué : un second facteur éventuel du compte cible n'est ni exigé ni désactivé ; le claim `sign_in_second_factor` n'est pas consulté. |
| Énumération | Les messages distinguent `not-found` / « Plusieurs comptes » / « Compte supprimé » / `invalid-argument`, mais le numéro interrogé doit égaler **le numéro vérifié de l'appelant** : l'énumération est limitée à son propre numéro. Risque **faible**. L'erreur de type révèle la liste des types seulement via le message. |
| Pharmacie / artisan | Pas de compte Firebase Auth ; hachage via `pharmacie_credentials` / `artisan_credentials` ; mêmes lacunes d'audit et de limite par cible. |
| Code mort | L'ancienne implémentation (`resetAccountPasswordLegacy`) est commentée dans `index.js` ; non exécutée. |
| Tests | `functions/test/passwordReset.test.js` : aucune mention d'admin ni de double rôle (recherche textuelle). [NE] aucun test lancé. |

## 3. Inventaire des collections de profils (règles lues)

| Collection | Création (règle) | Phone écrit par | Lié à l'Auth ? | Dans le parcours reset |
|---|---|---|---|---|
| `admins` | super seul | — | oui | non |
| `clients` | **propriétaire** (liste fermée de champs dont `phone`) | propriétaire (update libre sauf wallet…) ; super | oui (anonyme ou e-mail) | oui |
| `livreurs` | **super-admin** (+ `fleetDriverCreation.js` serveur) | propriétaire (hors wallet/suspension), super | oui | non |
| `sellers` | **super-admin** ; sous-admin « demandes_vendeurs » met à jour `name, phone, type, isActive, lat, lng` | propriétaire (partnerActivated), sous-admin, super | oui | oui |
| `restaurant_owners` | `write: isAdmin()` (super) | super | oui | oui |
| `restaurants` | admin | — | non (établissement) | non |
| `boulangeries` | super | propriétaire (activé), super | oui | oui |
| `pharmacies` / `pharmacy_owners` | admin / `write:false` | admin | **non** | oui (pharmacie) |
| `fleet_owners` | **propriétaire** (liste fermée dont `phone`, `status:'pending'`) | propriétaire, super | oui | oui |
| `ekbine_agents` | **propriétaire** (`isVerified:false`…) | propriétaire, super | oui | non |
| `real_estate_agents` | création serveur (`realestate.js`) | serveur | oui | non |
| `service_providers` | voir règle | — | non | oui (artisan) |
| `*_requests`, `driver_applications` etc. | utilisateur (`uid == uid()`) | demandeur | — | non |

Collections confirmées par lecture du dépôt (liste des règles, fonctions de suppression/quarantaine) : `admins, clients, livreurs, sellers, restaurant_owners, restaurants, boulangeries, pharmacies, pharmacy_owners, fleet_owners, ekbine_agents, real_estate_agents, service_providers` (+ les collections de demandes). **Il n'existe pas de collection `drivers` : le rôle livreur est `livreurs`.** Inventaire réel des documents : **impossible sans accès aux données** (non fait).

## 4. Cartographie des créations de profils

[F] Création par le propriétaire depuis le client (même uid que l'Auth) : `clients` (`client_auth_page.dart`, règle propriétaire), `fleet_owners` (inscription), `ekbine_agents` (propriétaire, règle) ; création par super-admin directement (règles) : `livreurs`, `sellers`, `boulangeries`, `restaurant_owners` ; création serveur : `fleetDriverCreation.js` (`livreurs`), `realestate.js` (`real_estate_agents`), `adminPartnerAccounts.js` (lot Admin SDK : `batch.create` de documents partenaires + compte Auth, avec marqueur de provisioning ; refuse si l'uid est dans `admins`). `createSubAdmin` ne crée **que** `admins` (aucun profil supplémentaire). **Aucun chemin ne vérifie qu'un uid n'a pas déjà un autre profil**, à l'exception de la création partenaire serveur qui refuse les uid d'`admins`. Rien n'empêche un administrateur d'ouvrir ensuite un profil `clients`/`fleet_owners`/`ekbine_agents` pour son propre uid depuis l'application (créations propriétaire). Migrations historiques : non examinées en détail (documents de migration non relus dans cette mission) ; pas d'évidence d'une migration unifiant les rôles.

Un uid Firebase supprimé n'est pas recyclé par la plateforme [H] ; les tombstones (`account_tombstones/{uid}`) sont permanents [F, charte], donc « uid supprimé puis recréé dans une autre collection » reste limité à des documents sous un uid encore vivant.

## 5. Risques liés aux doubles rôles et à la confiance dans `phone`

| # | Scénario | Statut |
|---|---|---|
| 1 | UID admin également `clients` | **Confirmé possible** (création propriétaire, aucune exclusivité). Exploitable seulement si un tiers contrôle le numéro du document (recyclage de numéro, échange de SIM) [H] ou si le titulaire est lui-même malveillant |
| 2 | UID super-admin également vendeur | Possible seulement si un super crée `sellers/<uid>` (règle `create: isAdmin`) ; **Confirmé possible** |
| 3 | UID admin également livreur | Possible (création super ou serveur) ; livreur hors parcours reset ⇒ pas d'exposition via ce parcours |
| 4 | Uid supprimé puis recréé dans un autre rôle | Limité par tombstone permanent ; risque théorique |
| 5 | Plusieurs profils, même téléphone | **Confirmé** : `clients` autorise n'importe quelle chaîne `phone` sans unicité ; deux documents ⇒ `failed-precondition` pour tous (déni de la réinitialisation du titulaire légitime, **[NE]**) |
| 6 | Réinitialisation d'un uid à double rôle | Chemin de code confirmé (aucune lecture de `admins`) ; exécution **[NE]** |
| 7 | Ancien jeton après changement de mot de passe | Révocation non demandée par le code ; effet plateforme **[H]** |
| 8 | Aucune notification/trace | **Confirmé** |
| 9 | **Sous-admin « demandes_vendeurs » → prise du mot de passe d'un vendeur** | **Confirmé par lecture** : la règle `sellers` autorise ce sous-admin à écrire `phone` sur tout document vendeur ; `resetAccountPassword` utilise ce champ comme preuve d'identité ; il peut y poser le numéro de sa propre session Phone Auth, réinitialiser, puis restaurer `phone`. Contourne l'interdiction de toucher au wallet. **Exécution [NE]** |
| 10 | **Super-admin → prise de mot de passe de tout compte** | **Confirmé par lecture** : `sellers`, `boulangeries`, `restaurant_owners` acceptent la création par un super avec n'importe quel id et `phone` ; le reset met alors à jour le mot de passe de **l'uid Auth portant cet id** (autre super-admin compris). Sous `ADMIN_MFA_MODE=log` : accès complet sans second facteur ; sous `enforce` : bloqué par le facteur déjà enrôlé **[H]**. Aucune trace |
| 11 | Preuve manquante | Tous les scénarios ci-dessus : aucun n'a été exécuté ; pas de données réelles ; aucun test existant |

## 6. Matrice de scénarios (résumé)

Confirmés par le code : 5 (déni), 8, 9, 10, 1/2 (possibles). Hypothèses : 7 (sessions), MFA après reset, recyclage de numéro. Risques théoriques : 4. Preuves manquantes : exécution de chaque chemin, état réel des comptes, état MFA de production.

## 7. Politique recommandée [R] (à valider)

1. **Un uid = un seul rôle métier principal** ; l'appartenance à `admins` est **exclusive** : aucun autre profil sous un uid administrateur, et inversement. Exceptions listées dans un registre serveur (`config/dual_role_exceptions`, écriture serveur seul), motivées, datées, validées à deux personnes.
2. Le parcours de réinitialisation **refuse tout uid présent dans `admins`** (message identique à « introuvable » + événement de sécurité) et tout uid ayant un profil dans une collection « d'un autre rôle » non listée en exception.
3. Le champ `phone` n'est plus une preuve d'identité à lui seul : lier le numéro à l'utilisateur Auth (fournisseur téléphone lié, ou comparaison avec le numéro Auth du compte) avant de modifier le mot de passe ; ou exiger une vérification complémentaire (e-mail) pour les comptes à portefeuille ; **interdire les modifications de `phone` par un sous-admin** sur `sellers`, ou les journaliser et geler la réinitialisation pendant un délai après tout changement de `phone` par un tiers.
4. Après reset : `revokeRefreshTokens`, `logAudit` + `logSecurityEvent`, notification au titulaire, limites **par numéro cible** et par uid, unicité de `phone` appliquée à la création/modification (index d'unicité serveur).
5. Aucune suppression ni désactivation automatique de compte existant.

## 8. Plan de migration progressif sans perte d'accès [R]

1. **Inventaire en lecture** (autorisation séparée) : pour chaque uid, collections où il apparaît ; pour chaque admin, présence dans `clients`, `fleet_owners`, `ekbine_agents`, `sellers`, `livreurs`, etc. ; doublons de `phone` ; changements récents de `phone` sur vendeurs.
2. Ajouter la **détection** (déclencheur d'alerte ou rapport périodique) des uid à double rôle, sans refus, et journaliser.
3. Introduire les refus dans un module séparé en mode `log` puis `enforce` (même schéma que le MFA), après avoir traité chaque cas listé ; les exceptions légitimes passent par le registre.
4. Corriger les règles `sellers` (retirer `phone` des champs du sous-admin, ou le rendre non-preuve) et durcir les créations super sur `sellers`, `boulangeries`, `restaurant_owners` (passage serveur uniquement) — mission distincte.
5. Les administrateurs concernés : migration manuelle assistée (décision par cas), jamais automatique ; maintenir deux super joignables.
6. Retour arrière : désactiver le mode `enforce` du refus ; aucune donnée supprimée.

## 9. Tests à préparer (ne pas écrire ici)

- Réinitialisation : refus pour uid présent dans `admins` (quel que soit `userType` et la collection) ; refus pour double rôle non exempté ; exception enregistrée acceptée ; parcours normal (client, fleet, seller, restaurant, boulangerie, pharmacie, artisan) inchangés.
- Limites : 5/h par appelant et par numéro cible ; épuisement ; fenêtre ; numéro cible partagé.
- Traces : `audit_logs` et `security_events` écrits (succès et refus), notification envoyée au titulaire (simulée), absence de données sensibles dans les journaux.
- Sessions : **test sur émulateur Auth** vérifiant le comportement réel de `updateUser({password})` vis-à-vis des refresh tokens et de `revokeRefreshTokens`, puis réutilisation d'un ancien jeton.
- Énumération : messages indistinguables pour inexistant / admin / double rôle / supprimé ; temps de réponse comparable ; seule la propre ligne du numéro vérifié interrogeable.
- Règles : sous-admin « demandes_vendeurs » ne peut plus altérer `phone` (ou l'altération gèle le reset) ; super ne crée plus de profils par écriture directe ; doublons de `phone` refusés ; test de non-régression des créations propriétaires.
- Concurrence : deux resets simultanés ; création de profil pendant un reset.
- Mutations sur chaque garde. Aucun test sur production.

## 10. Dépendances avec L4.11 et les missions N2

- **L4.11** (gestion des administrateurs par fonctions auditées, registre d'approbateurs) : la politique « admin exclusif » doit être appliquée à la création/promotion d'un administrateur ; un uid ne peut être promu que s'il n'a aucun autre profil.
- Le **reset** doit être corrigé (autorisation séparée pour `passwordReset.js`, hash `26975f60`) **avant** que le registre N2 ne s'appuie sur des comptes dont le mot de passe peut être réinitialisé par téléphone.
- Les décisions N2 supposent l'identité des approbateurs : sans exclusivité de rôle et sans reset sûr, un approbateur peut être usurpé par un tiers ayant la main sur un document de profil.
- Aucune mission n'est lancée.

## 11. Conditions bloquantes avant implémentation

1. Validation de la règle « un uid = un rôle » et de la liste d'exceptions.
2. Inventaire réel des uid à double rôle et des doublons de `phone` (autorisation de lecture sur production/préproduction requise, non effectuée).
3. Décision sur le champ `phone` des vendeurs (qui peut le modifier) et sur la création directe de profils par un super.
4. Autorisation explicite de modifier `passwordReset.js`, `index.js` (fichiers protégés) et les règles Firestore.
5. Vérification en environnement isolé du comportement Firebase (sessions après changement de mot de passe, second facteur conservé, claim `phone_number` d'un compte e-mail avec facteur SMS).
6. Valeur de `ADMIN_MFA_MODE` en production (inconnue) et état de l'enrôlement MFA.
7. Décision produit sur la notification du titulaire et sur la période de gel après changement de `phone`.

## 12. Compte rendu final

- **Fichiers consultés** : `functions/passwordReset.js` (intégral), `functions/index.js` (câblage reset, bloc legacy commenté, usages de `clients`/`phone`), `functions/ekbineOrders.js` (`OTHER_ROLE_COLLECTIONS` et usage), `functions/manualAccountDeletion.js` (liste), `functions/adminPartnerAccounts.js` (créations), `functions/fleetDriverCreation.js` et `functions/realestate.js` (appels de création, par recherche), `firestore.rules` (blocs `admins`, `clients`, `livreurs`, `sellers`, `restaurant_owners`, `boulangeries`, `fleet_owners`, `ekbine_agents`, liste des collections de profils), recherches ciblées dans `lib/` (création `clients`), rapports L4.9 et L4.9.1.
- **Collections identifiées** : voir §3. **Chemins de création** : §4. **Risques confirmés (par lecture)** : 5, 8, 9, 10 ; possibles : 1, 2, 3, 6 ; hypothèses : 7, MFA après reset.
- **Impossible à vérifier** : documents réels (double rôle, doublons de `phone`), configuration MFA de production, comportement Firebase des sessions, historique de migrations, `storage.rules` pour ce parcours, règles `service_providers`/`pharmacies` en détail, `real_estate_agents`/`fleetDriverCreation.js` au-delà des appels de création.
- **Difficulté d'environnement** : le volume `C:` de la machine est plein (0 Go libre) ; la sortie de certaines commandes a été coupée une fois, le travail a été repris avec des lectures plus petites. Aucun fichier n'a été supprimé pour libérer de l'espace. Je recommande de libérer de l'espace sur `C:` avant toute autre mission.
- **État Git final** : HEAD `d65c8f0`, index vide, stash 0, 35 suivis modifiés, 164 non suivis (163 + ce rapport) — à vérifier par la commande ci-dessous dans le compte rendu de conversation.
- Aucun code, test, règle ni configuration modifié ; aucun accès Firebase ; aucun déploiement, commit, push ou stash ; L4.11 et le registre des créances non commencés.

Arrêt : en attente d'une nouvelle autorisation explicite.
