# Mission L4.10.3 — Audit complémentaire des règles et parcours d'identité

Audit en **lecture seule** : aucun code, test, règle, configuration ou secret modifié ; aucun accès Firebase, production ou préproduction ; aucun test lancé ; rien créé (`account_phone_bindings` incluse). Légende : **[F]** fait confirmé par lecture ; **[H]** hypothèse ; **[NV]** non vérifiable ici ; **[R]** recommandation.

**Résultats clés.**
1. Fermer `sellers.create` ou `livreurs.create` **casserait deux écrans administratifs** (approbation des demandes vendeurs et livreurs) qui écrivent depuis le client ; fermer seulement le champ `phone` du sous-admin sur `sellers.update` ne casse rien d'observé.
2. Découverte nouvelle : `checkClientPhone` est appelable **sans authentification** et renvoie l'**e-mail réel** associé à un numéro (énumération + fuite de donnée personnelle) [F].
3. `service_providers` permet à n'importe quel utilisateur réel de **s'attribuer** (`artisanUid`) un profil non réclamé, premier arrivé premier servi [F].
4. Aucun parcours du dépôt ne lie un numéro à un compte Auth : la connexion téléphonique par `signInWithCredential` produit une session **distincte** utilisée uniquement comme jeton de preuve [F pour le code ; [H] pour la plateforme].

## 1. Périmètre inspecté

Règles : `sellers`, `livreurs`, `pharmacies`, `pharmacie_credentials`, `pharmacie_requests`, `real_estate_agents`, `service_providers`, `artisan_credentials`, `clients`, `fleet_owners`, `ekbine_agents`, `restaurant_owners`, `boulangeries`, `admins` (déjà lues), `*_requests`. Flutter : écrans vendeur (`seller_dashboard`, `seller_login`, `seller_register`), administration (`admin_sellers_page`, `admin_seller_requests_page`, `driver_requests_page`, `admin_partner_account_service`, pages partenaires), auth (`client_auth_page`, `otp_verify_page`, `reset_password_page`, `generic_forgot_password_page`, `forgot_password_page`, `auth_service`), web (`drivers_page`, `merchants_page`, formulaires de candidature). Fonctions : `passwordReset.js`, `manageSellerAccount.js`, `adminPartnerAccounts.js`, `artisanAccounts.js`, `artisanCredentials.js`, `serviceProviderApplication.js`, `pharmacieLogin`/`setPharmaciePassword`, `checkClientPhone`, `fleetDriverCreation.js`, `realestate.js` (extraits). Non inspectés **[NV]** : écrans web d'administration complets, `storage.rules`, données réelles.

## 2. Cartographie des interfaces vendeurs (`sellers`)

| Parcours | Acteur | Champs | Autorisation | OTP | Audit serveur | Si l'écriture directe est fermée |
|---|---|---|---|---|---|---|
| `admin_sellers_page` modification (appel `manageSeller` → `manageSellerAccountCF`) | sous-admin `demandes_vendeurs` / super | `name, phone, type, isActive, lat, lng` | `requireAdminPermission`, limite de débit | non | **oui** (booléen `phoneChanged`) | **Aucun effet** : passe déjà par la fonction [F] |
| `admin_sellers_page` création (`AdminPartnerAccountService.create`, serveur) | super | profil + compte Auth | `manageAdminPartnerAccount` | non | oui | aucun effet |
| **`admin_seller_requests_page` approbation** (`runSellerApproval`, transaction **client** `tx.set(sellers/{uid})`) | super (règle `create: isAdmin()`) | profil complet dont `phone` issu de `seller_requests` (saisi par le demandeur, non vérifié) | règle seule | non | **non** | **CASSÉ** si `create` est fermé |
| `seller_dashboard` (photo) | titulaire | `photoUrl` (`set merge`, `update`) | règle propriétaire (`partnerActivated`) | non | non | aucun effet tant que seul `photoUrl` est écrit |
| `seller_login` (reprise de session) | titulaire | lecture | règle | — | — | aucun effet |
| `client_auth_page` (recherche d'un vendeur) / `home_screen` / `firestore_service` | tous / titulaire | lecture | règles de lecture | — | — | aucun effet |
| Lecture admin (liste) | sous-admin/super | lecture | règle | — | — | aucun effet |
| Écriture directe sous-admin (hors application) | sous-admin | 6 champs dont `phone` | règle | non | **non** | bloquée (objectif) ; aucun écran connu ne l'utilise |

Aucun écran vendeur ne modifie `phone` par le titulaire [F] : la règle propriétaire est plus large que l'usage réel (fermable sans casser l'application actuelle, **mais** de **vieilles versions** de l'application peuvent écrire — non vérifiable).

## 3. Audit des collections restantes

| Collection | Création | Modification | Peut modifier `phone` | Document d'un autre uid | Admin direct | Contrôle serveur | Preuve d'identité serveur |
|---|---|---|---|---|---|---|---|
| `pharmacies` | super seul (`write: isAdmin()`, sans `password/accessCode`) | super ; session liée (`currentUid`) seulement `fcmToken`, `logoUrl`, `isOnDuty` | **super seulement** | non | oui (super, sans MFA) | `pharmacieLogin` (mot de passe haché, `currentUid`), `setPharmaciePassword` | mot de passe haché ; **pas de Firebase Auth** ; la lecture est ouverte à tout utilisateur connecté (**numéro public**) |
| `service_providers` | super ; serveur (`serviceProviderApplication.js`) | super ; **tout utilisateur réel** peut poser `artisanUid` si absent (réclamation) ; artisan lié : `photos` | **super / serveur** (`phone` non modifiable par l'artisan) | oui : un utilisateur réel peut **réclamer** un profil non lié (`artisanUid == uid()`) | oui | `artisanLogin` (`phone` + PIN, limite 10/5 min par numéro), `setArtisanPin` | PIN haché (4–6 chiffres) ; **pas de Firebase Auth** (session anonyme) |
| `real_estate_agents` | super (règle) ; serveur `realestate.js` | super ; titulaire (sauf `deletionRequested`, `isVerified`, `isActive`) | **titulaire : oui**, super : oui | non | oui | `realestate.js` valide la forme, pas de preuve | aucune sur `phone` |
| `livreurs` | super (règle) ; `fleetDriverCreation.js` ; approbation **client** `driver_requests_page.dart` (`batch.set`) | super ; titulaire (hors `wallet`, `isSuspended`, `deletionRequested`, `ownerId`, `ownerName`) | **titulaire : oui**, super : oui | non | oui | `fleetDriverCreation.js` | aucune ; lecture ouverte à tout utilisateur connecté (**numéro public** inclus) [F, commentaire des règles] |

Observations : `livreurs`/`pharmacies`/`service_providers` ne sont **pas** dans la table de `resetAccountPassword` sauf `pharmacies` et `service_providers` (le livreur est volontairement exclu, cf. commentaire de `forgot_password_page.dart`). Les protections ne sont pas extrapolées d'une collection à l'autre.

## 4. Inventaire des parcours téléphoniques

| Parcours | Côté client | Côté serveur | Règles | Constat |
|---|---|---|---|---|
| Inscription client/partenaire | `phone` saisi, `checkClientPhone` (unicité) | `checkClientPhone` | création propriétaire (liste fermée) | `phone` non vérifié par OTP à l'inscription |
| Connexion par téléphone | `verifyPhoneNumber` + `signInWithCredential` (récupération) ; `admin_otp_page` / `web/admin_auth_service` pour le second facteur administrateur | — | — | la connexion SMS produit une session **séparée** ; aucun lien au compte |
| Changement de numéro | `AuthService.updatePhone` (réauthentification par mot de passe **dans l'application**, puis `update` Firestore direct) | **aucun** | `clients`, `livreurs` : owner `update` libre | **protection côté client uniquement** [F] |
| Réinitialisation | `reset_password_page` (`userType:'client'` codé en dur), `generic_forgot_password_page` | `resetAccountPassword` | — | cf. L4.10 |
| Récupération artisan | PIN via `resetAccountPassword`/`artisanLogin` | `artisanLogin`, `setArtisanPin` | — | PIN court, limite par numéro uniquement |
| Pharmacie | `pharmacieLogin` (par `pharmacieId`, non par numéro) | oui | `pharmacies` | numéro non utilisé pour l'authentification |
| Modification par un administrateur | pages admin (écritures directes `pharmacies`, `restaurants`, `boulangeries`…) ; `manageSellerAccountCF` ; `manageAdminPartnerAccount` | partiel | `isAdmin()` | écritures directes sans MFA ni audit |
| Création de profil avec numéro existant | `checkClientPhone` côté client uniquement ; aucune unicité serveur | non | non | contournable par écriture directe |
| **Existence d'un numéro** | `client_auth_page` | **`checkClientPhone` sans contrôle d'authentification** : renvoie `exists` et l'**e-mail réel** | — | énumération + fuite d'e-mail ; limite 10/5 min **par numéro**, non par appelant |
| Liaison/déliaison Auth | **absentes** | **absentes** | — | aucun champ de liaison ni `linkWithCredential`/`updatePhoneNumber` dans `lib/` ni `functions/` |

## 5. Comptes multiprofils (code seulement)

- **Même uid, plusieurs profils** : possible (aucune exclusivité) ; garde partielle dans les suppressions (`OTHER_ROLE_COLLECTIONS` dans `ekbineOrders.js`, `manualAccountDeletion.js`, `accountDeletion.js`). Détectable par lecture de code : **oui** (absence de contrainte) ; occurrences réelles : **inventaire à blanc requis**.
- **Admin + profil ordinaire** : possible ; `adminPartnerAccounts.js` refuse les cibles admin ; `passwordReset.js` n'y est pas protégé. Occurrences : inventaire requis.
- **Numéro sur plusieurs uid** : possible (aucune unicité serveur) ; `checkClientPhone`/`findUniqueAccountByPhone` le détectent à l'usage seulement. Inventaire requis.
- **Profil créé avec un uid déjà utilisé** : possible par un super (règles `create`), par création serveur sans collision d'uid inter-collections ; détection par code : oui (chemin) ; inventaire pour l'existant.
- **Profil supprimé alors qu'un autre subsiste** : les suppressions utilisent des tombstones (`account_tombstones`) et refusent certains cas ; les profils restants d'un même uid ne sont pas traités par un contrôle global. Inventaire requis.
- **Compte fermé/anonymisé/quarantaine** : `assertTargetNotClosing` dans `passwordReset.js` couvre l'id du document et `currentUid` ; pas de contrôle sur le profil d'un autre rôle du même uid. Inventaire requis pour l'existant.
- **Compte partenaire sans Auth** (pharmacie, artisan) : l'identité est un secret haché ; le téléphone sert de clé de recherche et de cible de réinitialisation ; le reset opère sur un document que le **super** peut éditer directement.

## 6. Matrice des vulnérabilités

| Id | Vulnérabilité | Statut | Gravité |
|---|---|---|---|
| V1 | Sous-admin `demandes_vendeurs` écrit `phone` d'un vendeur sans trace | **Confirmé** (règle + test) | Élevé |
| V2 | Super-admin édite `phone` d'une pharmacie/artisan (ou crée un profil) puis réinitialise | **Confirmé** par lecture | Élevé |
| V3 | Titulaire change son `phone` sans OTP serveur (`clients`, `livreurs`, `sellers`, `boulangeries`, `fleet_owners`, `ekbine_agents`, `real_estate_agents`) | **Confirmé** | Moyen |
| V4 | `checkClientPhone` non authentifié : énumération de numéros et fuite d'e-mails | **Confirmé** | Élevé (confidentialité) |
| V5 | Réclamation libre d'un profil `service_providers` non lié | **Confirmé** | Moyen |
| V6 | Numéros publics (livreurs, pharmacies, artisans) lisibles par tout utilisateur connecté (anonymes inclus) | **Confirmé** (règles de lecture) | Moyen (facilite l'ingénierie sociale/SIM-swap) |
| V7 | PIN artisan 4–6 chiffres, limite par numéro uniquement | **Confirmé** | Moyen |
| V8 | Aucune unicité serveur de `phone` ; doublons possibles | **Confirmé** | Moyen |
| V9 | Approbations (vendeur, livreur) par transaction côté client avec données de la demande non vérifiées | **Confirmé** | Moyen |
| V10 | Super-admin : aucune exigence MFA par règle sur toutes ces écritures | **Confirmé** | Élevé |
| V11 | Recyclage de numéro / SIM-swap | **Hypothèse** | Moyen |
| V12 | Réinitialisation d'un uid administrateur à double rôle | **Confirmé** (chemin), **Hypothèse** (existence) | Élevé |

## 7. Impacts des corrections envisagées

| Correction | Écrans / fonctions affectés | Utilisateurs légitimes bloqués | Migration | Retour arrière | Tests avant activation |
|---|---|---|---|---|---|
| **A. Fermer `phone` direct dans `sellers`** (sous-admin ; titulaire) | Aucun écran connu pour le sous-admin ; titulaire : aucun écran actuel ne modifie `phone`. **Fermer `create` casserait `admin_seller_requests_page`** (approbation) | anciennes versions d'application qui écriraient `phone` ; sous-admin utilisant un outil externe | basculer l'approbation vers une fonction (comme `manageAdminPartnerAccount`) **avant** de fermer `create` | redéployer l'ancienne règle | tests de règles, test d'interface de l'approbation, version minimale d'application |
| **B. Vérification serveur des changements de numéro** | `AuthService.updatePhone` (client, livreur), écrans partenaires ; nouvelle fonction + écran OTP | utilisateurs sans accès à l'ancien/nouveau numéro, anciennes versions | liens `pending_confirmation` | mode `log` puis `enforce` | émulateur Auth, OTP simulé, panne Phone Auth |
| **C. Exclure `admins` du reset ordinaire** | `passwordReset.js` seulement | administrateur utilisant la voie SMS (ne devrait pas exister) | inventaire des double rôle | mode `log` | uid admin + profil de chaque collection |
| **D. Registre `account_phone_bindings`** | `passwordReset.js`, fonction de liaison, créations de profils (`manageAdminPartnerAccount`), approbations | comptes sans lien (réinitialisation SMS fermée → support) | backfill à blanc → `pending_confirmation` → confirmation à l'usage | repasser en `log` ; aucune donnée supprimée | unicité concurrente, rotation de clé |
| **E. Séparer identité du compte et possession du numéro** | `passwordReset.js`, connexion partenaires par téléphone (e-mail technique) | partenaires dont l'identifiant de connexion est le numéro (e-mail technique) si le numéro change | traitement du changement d'identifiant (support) | maintenir l'ancien identifiant jusqu'à confirmation | parcours de connexion partenaire complets |

**Aucune activation immédiate n'est proposée.**

## 8. Matrice de tests

| # | Test | Préconditions | Attendu | Contrôle serveur requis | Type |
|---|---|---|---|---|---|
| 1 | Vendeur modifie son numéro sans OTP | vendeur activé | refus (après correction) | règle + fonction | règles (émulateur) |
| 2 | Vendeur modifie avec OTP valide | lien actif, OTP récent | succès, audit, notification | fonction de remplacement | émulateur + unitaire |
| 3 | Sous-admin écriture directe | permission `demandes_vendeurs` | refus du champ `phone` | règle | règles |
| 4 | Sous-admin via `manageSellerAccountCF` | idem | succès journalisé ; reset gelé selon politique | fonction | unitaire |
| 5 | Super-admin modifie le numéro d'un administrateur | admin cible | refus (pas de profil lié ; `admins` exclu) | fonction | unitaire |
| 6 | Utilisateur à plusieurs profils | uid dans 2 collections | refus uniforme au reset ; détection | transaction multi-lecture | unitaire |
| 7 | Deux uid, même numéro | doublon | refus + anomalie | index d'unicité | unitaire + concurrence |
| 8 | Numéro recyclé | lien ancien | contrôles renforcés | ancienneté, notification | unitaire (horloge simulée) |
| 9 | Compte sans Auth change de numéro | pharmacie/artisan | secret + OTP requis | fonction dédiée | unitaire |
| 10 | Compte fermé tente une récupération | tombstone | refus uniforme | `assertTargetNotClosing` | unitaire existant à étendre |
| 11 | Compte en quarantaine tente une récupération | état closing | refus | idem | unitaire |
| 12 | Ancienne version de l'application | écriture directe du `phone` | comportement défini (refus avec message) | règle + version minimale | manuel / règles |
| 13 | Interface Web écriture directe | formulaire de candidature | inchangé (collections de demandes) ; écriture profil refusée | règles | règles |
| 14 | Fonction reçoit un uid ≠ demandeur | `uid` forgé | refus | comparaison `request.auth.uid` | unitaire |
| 15 | `checkClientPhone` sans authentification | appel anonyme | refus ou réponse neutre sans e-mail | contrôle d'appelant | unitaire |
| 16 | Réclamation de `service_providers` | utilisateur réel, profil libre | selon décision | règle/fonction | règles |

Aucun test lancé ; tous à exécuter sur faux Firestore ou émulateurs `demo-*`, un à la fois.

## 9. Architecture cible

- **Firebase Auth** : prouve la session et le mot de passe ; **ne porte pas** le téléphone comme moyen de connexion sauf décision explicite (le téléphone reste facteur de **récupération**).
- **Profils Firestore** : contiennent le numéro d'affichage/contact ; jamais une preuve ; écritures des champs d'identité réservées aux fonctions.
- **`account_phone_bindings`** (HMAC à clé serveur, index d'unicité, événements append-only, `write:false`) : source de vérité du droit de récupération, `pending_confirmation` pour l'héritage.
- **OTP** : preuve de possession récente (`auth_time` ≤ 5 min) pour lier/remplacer ; usage unique.
- **Récupération** : `resetAccountPassword` résout la cible **via le lien**, refuse `admins`, double rôle, compte fermé, incohérence ; réponse neutre ; limites par appelant/numéro/cible ; audit serveur ; notification ; `revokeRefreshTokens`.
- **Rôles/multiprofils** : un uid = un rôle ; exceptions par registre serveur à double approbation ; `admins` exclusif.
- **Administration** : écritures sensibles uniquement par fonctions (approbations vendeur/livreur incluses), MFA et audit.
- **Lecture** : retirer `phone` des documents publiquement lisibles (migration vers documents publics sans numéro) ; `checkClientPhone` rendu neutre/authentifié.
Rien n'est créé par cette mission.

## 10. Plan de migration et retour arrière

1. **Corrections indépendantes du schéma** (sur autorisation) : `checkClientPhone` neutre ; uniformisation des messages ; exclusion `admins` en mode `log` ; audit/HMAC dans `manageSellerAccount.js`.
2. **Remplacer les écritures client-admin** (approbation vendeur, approbation livreur, pages partenaires) par des fonctions, **avant** toute fermeture de règles.
3. **Fermer** `phone` du sous-admin sur `sellers`, puis les créations directes ; version minimale de l'application forcée ou tolérance temporaire.
4. **Inventaire à blanc → revue → liens `pending_confirmation` → confirmation à l'usage.**
5. **`enforce`** de la résolution par lien, puis retrait de la preuve par `profile.phone`.
6. **Retour arrière** par étape : mode `log`, ancienne règle (artefact conservé), aucun profil ni compte supprimé/désactivé ; support via l'action administrative existante.

## 11. Risques résiduels

Anciennes versions d'application ; panne ou coût de Phone Auth ; données historiques de `phone` déjà falsifiées ; recyclage de numéros ; numéros publics ; PIN artisan court ; super-admins et propriétaires GCP gardent un pouvoir de contournement (limite incompressible) ; écrans non inspectés **[NV]**.

## 12. Décisions à demander avant implémentation

1. Autorisation de modifier `passwordReset.js`, `index.js` (protégés), `manageSellerAccount.js`, règles Firestore, écrans Flutter (approbations).
2. Rendre `checkClientPhone` authentifié/neutre ; politique sur les numéros publics (livreurs, pharmacies, artisans).
3. Politique de réclamation de `service_providers` ; durcissement du PIN artisan (longueur, verrouillage).
4. Le titulaire peut-il changer son numéro seul ? (OTP obligatoire, délai, notification.)
5. Version minimale de l'application et calendrier de fermeture des règles.
6. Choix registre seul vs registre + liaison Auth (téléphone moyen de connexion ?).
7. Inventaire à blanc : périmètre, environnement, personnes de revue.
8. Gestion du poivre HMAC ; état de Phone Auth ; canal de notification.

## 13. Compte rendu final

- **Fichiers inspectés** : voir §1 (règles Firestore des collections listées ; `manageSellerAccount.js`, `artisanAccounts.js`, `artisanCredentials.js`, `serviceProviderApplication.js`, `pharmacieLogin`, `checkClientPhone`, `passwordReset.js`, `adminPartnerAccounts.js` ; écrans Flutter et web listés).
- **Règles confirmées** : §2–§3. **Vulnérabilités vérifiées** : V1–V10, V12 (V11 hypothèse). **Protections existantes** : fonction auditée pour la fiche vendeur, mots de passe/PIN hachés CF-only, limites de débit sur logins, tombstones, `isDeleted`.
- **Écrans qui pourraient être cassés** : approbation des demandes vendeurs (`admin_seller_requests_page`) et livreurs (`driver_requests_page`) si `create` est fermé avant migration ; `AuthService.updatePhone` (client, livreur) si le titulaire perd l'écriture directe.
- **Tests indispensables** : §8 (1–5, 12, 14, 15 en priorité).
- **Non vérifiables** : données réelles, Phone Auth, comportement Firebase, `storage.rules`, écrans web d'administration, versions d'application en circulation.
- **État Git** : vérifié avant (HEAD `d65c8f0`, 35 modifiés, 166 non suivis, index vide, stash 0, C: ≈ 7,98 Go) et après (voir message final).
- Aucun code, test, règle ni configuration modifié ; aucun accès Firebase ; aucun test ; aucun nettoyage ; L4.11 non lancée.

Arrêt : en attente d'une nouvelle autorisation explicite.
