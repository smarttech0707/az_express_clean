# Mission L4.8 — Audit des prérequis de sécurité N2

Audit en **lecture seule**. Aucun fichier source, test, configuration ou secret modifié ; aucun accès Firebase ; aucune activation de `ADMIN_MFA_MODE`. Légende : **[F]** fait vérifié dans le dépôt ; **[H]** hypothèse non vérifiable depuis le dépôt (souvent : configuration du projet Firebase/GCP, comportement de la plateforme) ; **[R]** recommandation.

**Verdict** : le système **ne peut pas aujourd'hui garantir** que deux approbateurs N2 sont deux personnes physiques distinctes, authentifiées par un second facteur et autorisées par une permission dédiée. Les conditions d'activation d'un registre de décisions ne sont pas réunies (§11).

## 0. État Git

Avant : HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, 35 suivis modifiés, 160 non suivis. Après : identique (+ ce rapport = 161 non suivis). Hashes protégés inchangés (`ekbineOrders.js` ff24d2c8, `index.js` a9ba2c0d, `professionalSubscriptions.js` 976c2396, `adminPartnerAccounts.js` 1a5cde55, `passwordReset.js` 26975f60, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a).

## 1. Architecture de sécurité actuelle

- **Identité** [F] : Firebase Auth, fournisseur e-mail/mot de passe pour les administrateurs. L'autorisation administrative **n'utilise aucun custom claim** : `setCustomUserClaims` n'apparaît nulle part dans `functions/` ni `lib/` ; le seul claim lu est `partnerMustChangePassword` (partenaires). Le rôle vit dans le document **`admins/{uid}`** : `role ∈ {super, sub}`, `isActive`, `permissions[]` (sous-admin).
- **Côté serveur** [F] : `adminGuards.js` — `readValidAdmin` (authentifié non anonyme, document présent, `isActive === true`, rôle valide, puis `enforceAdminSecondFactor`) ; `requireSuperAdmin` (rôle `super`) ; `requireAdminPermission` (sous-admin : clé de permission). 23 fichiers de fonctions les appellent. Journalisation : `logAudit` → `audit_logs` (écriture serveur, lecture super-admin) ; `logSecurityEvent`/`security_events` ; `checkRateLimit`.
- **Règles Firestore** [F] : `isAdmin()` = document `admins/{uid}` actif **de rôle super** ; `hasAdminPermission(p)` pour les sous-admins. **Aucune règle ne lit `sign_in_second_factor`** (recherche dans `firestore.rules` et `storage.rules` : zéro occurrence). Donc un jeton obtenu avec le seul mot de passe passe `isAdmin()` pour toutes les lectures/écritures directes que les règles autorisent aux administrateurs, quel que soit `ADMIN_MFA_MODE`.
- **Gestion des administrateurs** [F] : `createSubAdmin` (super-admin ; crée un compte Auth avec e-mail + mot de passe **fournis par l'appelant**, document `admins` de rôle `sub`) et `deleteSubAdmin`. **Aucune fonction ne crée un `super`** : les super-admins sont créés hors code (provenance non documentée dans le dépôt). Règles de `admins` [F] : `allow create/delete: if isSuperAdmin()` et `allow update` par un super-admin sur n'importe quel champ (rôle, `isActive`, `permissions`) — **écritures directes depuis le client, sans fonction, sans audit, sans contrôle de second facteur**.
- **Client** [F] : écran de connexion admin (`admin_login.dart`) ; si le compte n'a pas de second facteur, le flux force l'**enrôlement** (SMS ou TOTP) ; contournement `adminDevelopmentBypassAllowed` : exige `kDebugMode` + indicateur de build + identifiants valides + document admin + rôle actif + e-mail vérifié + téléphone configuré (inopérant en build release). Le contrôle côté application n'est **pas** une garantie : seul le serveur compte.

## 2. Fonctionnement réel du MFA

- **Méthodes prises en charge** [F, code client] : téléphone (SMS) et TOTP (`PhoneMultiFactorInfo`, `TotpMultiFactorInfo` dans `admin_otp_page.dart`). L'ancien OTP maison est supprimé (champs `otp*` non écrivables, règle S7).
- **Vérification serveur** [F] : `enforceAdminSecondFactor` teste uniquement la **présence** de `request.auth.token.firebase.sign_in_second_factor` (valeur non lue : ni type de facteur, ni identifiant du facteur). Le jeton est signé par Firebase ; **le client ne peut pas forger ce champ** [H : propriété de la plateforme, non testable ici].
- **Récence** [F] : **aucun contrôle de récence du second facteur dans `adminGuards.js`**. Certaines fonctions contrôlent `auth_time` (≤ 300 s : suppression de compte `accountDeletion.js`, `pharmacyOwnerIdentity.js` ; `manualAccountDeletion.js` `RECENT_AUTH_SECONDS` ; `partnerFirstLogin.js`) mais ce contrôle est local à ces fonctions, ne mentionne pas le second facteur et n'est pas appelé par `readValidAdmin`. [H] `auth_time` est l'instant de la dernière authentification complète ; il ne change pas lors d'un rafraîchissement de jeton, et le claim de second facteur persiste tant que la session n'est pas rouverte : une exigence « MFA < 15 min » se traduit donc par `auth_time` récent **et** claim présent, pas par un défi MFA séparé.
- **Contournement client** [F/H] : aucun pour les fonctions qui appellent `readValidAdmin` en mode `enforce`. Les chemins qui **ne passent pas par `readValidAdmin`** n'ont aucun contrôle MFA : `partnerQr.js` (vérifie `admins/{actor}.role === 'super'` directement, **0 appel de garde MFA**) ; `adminPartnerAccounts.js` (lit `admins` directement dans deux helpers, mais appelle 4 gardes ailleurs) ; toutes les écritures directes Firestore autorisées par `isAdmin()` (règles).

## 3. `ADMIN_MFA_MODE`

Utilisations [F] : une seule lecture, `process.env.ADMIN_MFA_MODE || 'log'` dans `adminGuards.js`, et le test `adminGuards.test.js` (S7). Aucune occurrence dans `functions/.env`, `.env.az-express-preprod`, `.env.example`, `.github`, `firebase.json`, `OPERATIONS_RUNBOOK.md` (comptage de lignes seulement, contenu des fichiers `.env` non lu). Valeur effective en production [H] : **`log`** (défaut), sauf variable posée hors dépôt (console Cloud Run) — non vérifiable.

Comportement exact [F] : `off` → aucun contrôle ; présence du claim → accepté dans tous les modes ; `enforce` → `permission-denied` « Second facteur d'authentification requis » ; **toute autre valeur (y compris une faute de frappe : `enforced`, `ENFORCE`, `on`) se comporte comme `log`** (journalise une fois par compte et par instance via `console.warn`, **sans** écrire dans `audit_logs` ni `security_events`). Le mode est lu **à chaque appel** (pas de cache), donc un changement de variable d'environnement prend effet au prochain démarrage d'instance. Conséquence de `enforce` : tout administrateur sans second facteur reçoit `permission-denied` sur **toutes** les fonctions gardées (pas de granularité par fonction), y compris la suppression de compte, la facturation, les litiges, les règlements ; il n'a aucune voie serveur pour s'enrôler (l'enrôlement se fait côté client avec le mot de passe).

## 4. Identité physique des approbateurs

**Ce qui existe [F]** : un compte = un uid Firebase = un document `admins` ; rien n'exprime « une personne ». Aucun champ `personRef`, aucune pièce d'identité, aucune procédure d'enrôlement écrite, aucun registre d'approbateurs. Le moteur (`verifyDecision`) compare des chaînes (`approvedBy ≠ requestedBy ≠ originBy`).

**Faits aggravants [F]** : (1) un super-admin peut créer (`createSubAdmin`) ou, via les règles, écrire directement des documents `admins` ; il peut donc détenir **plusieurs comptes** et promouvoir un compte à `super` sans trace ni second regard ; (2) `createSubAdmin` reçoit le mot de passe du nouveau compte : le créateur le connaît ; (3) l'enrôlement MFA du premier facteur est fait par celui qui possède le mot de passe : un compte non enrôlé volé est « réclamé » par l'attaquant qui y enrôle son propre téléphone/TOTP ; (4) un SMS (SIM-swap) est un facteur plus faible que TOTP [H générique].

**Évaluation de `personRef`** : un identifiant opaque dans un registre serveur n'a de valeur que si **la procédure qui l'attribue est sûre** ; seul, il déplace le problème. Il faut : vérification d'identité hors-ligne par le propriétaire (pièce d'identité contrôlée, procès-verbal), le justificatif **jamais stocké dans Firestore** (conservé hors système, seule une référence/empreinte salée dans le registre), désignation écrite, double contrôle à l'enrôlement et à la révocation, et **détection des doublons** : impossible à automatiser sans donnée d'identité ; reste donc procédural (chaque `personRef` ne peut être rattaché qu'à un uid actif ; changement d'uid = révocation + nouvelle désignation). **Ce qui n'est pas garanti par la technique** : qu'une personne n'ait pas de second compte ; seule la procédure et l'audit humain l'assurent. [R] Documenter explicitement cette limite plutôt que la masquer.

**Confidentialité** [R] : aucune copie de pièce d'identité dans Firestore/Storage ; registre = {uid, personRef opaque, date de désignation, désigné par, statut, empreinte salée optionnelle}.

## 5. Permission financière

Existant [F] : liste fermée de 31 clés (`adminPermissions.js`), **miroirs obligatoires** : fonction, règle `admins` (`adminPermissionsKnown`), `adminPermissionKeys` Dart (`admin_mfa_security.dart`), test de parité ; le super-admin **n'a pas de clés** (`role == 'super'` ouvre tout) ; aucune clé d'approbation financière.

Analyse : une clé de plus ne suffit pas, parce que (a) le super-admin la contourne par construction ; (b) un super-admin peut s'attribuer des clés par écriture directe (règle `admins` update) ; (c) l'écriture n'est pas auditée. [R] Distinguer **deux couches** : (1) un **registre d'approbateurs serveur seul** (`config/n2_approvers`, `allow write: if false`, modifié uniquement par une fonction N2 à double approbation) comme source de vérité ; (2) en option, une clé de permission dédiée pour l'interface seulement. Les contrôles côté serveur de chaque transition N2 : rôle `super` actif **ET** membre actif du registre **ET** MFA (claim) **ET** `auth_time` récent **ET** `uid` ∉ {demandeur, décideur initial, titulaire, bénéficiaire} **ET** `personRef` ≠. Révocation : transition auditée par fonction, effective immédiatement (relue à chaque appel), et invalidant les approbations non exécutées du révoqué. Auto-approbation : refus par uid **et** par `personRef`. Aucune permission n'est créée ici.

## 6. Matrice des scénarios d'attaque

| Scénario | Situation actuelle [F] | Protection réalisable [R] | Limite incompressible |
|---|---|---|---|
| Une même personne, deux comptes admin | non détecté ; création de comptes libre pour un super | registre `personRef` + procédure de désignation écrite + contrôle humain | seule la procédure, pas la technique, établit « une personne » |
| Admin modifie directement un document Firestore | règles autorisent les écritures directes admin sur de nombreuses collections (dont `admins`) ; collections N2 futures : `write:false` | collections N2 serveur seul ; empreintes/chaînage recalculés par le moteur ; ne **jamais** s'appuyer sur `isAdmin()` pour N2 | un super-admin garde ses droits sur les autres collections |
| Compte perd son rôle pendant une demande | rôle relu à chaque appel mais rien ne lie les demandes | relire rôle + registre à **chaque** transition ; approbation d'un révoqué refusée | demande déjà exécutée non annulable (décision compensatoire) |
| MFA expire entre deux approbations | pas de récence MFA | `auth_time` récent + claim à chaque approbation ; fenêtre de demande bornée | `auth_time` mesure l'authentification, pas le défi MFA exact [H] |
| Approbateur révoqué avant la seconde approbation | pas de registre | registre relu ; approbation du révoqué refusée ; demande reste `requested` | — |
| Approbation rejouée | n/a | `requestId` serveur, `create`-only, transition d'état idempotente | — |
| Deux approbations simultanées | n/a | transaction + précondition d'état + `version` ; une seule exécute | rejets d'infrastructure possibles (relance) |
| Propriétaire GCP modifie les données | possible sur tout | détection : empreintes recalculées, chaînage, alertes sur écritures non issues des fonctions, IAM restreint, export des empreintes | **impossible à empêcher** par l'application |
| Vol du mot de passe d'un admin non enrôlé | jeton valide avec le seul mot de passe (mode `log`) | `enforce` + enrôlement supervisé avant désignation d'approbateur | tant que l'enrôlement se fait au premier login, un attaquant peut le réclamer |
| Écriture directe de `admins` pour promouvoir/créer un `super` | autorisée par les règles à tout super | déplacer les changements de rôle vers une fonction auditée ; règles `update/create/delete` admin fermées ; alerte | requiert changement de règles (mission dédiée) |
| Faute de frappe dans `ADMIN_MFA_MODE` | silencieusement `log` | valider la valeur (refus de démarrage/alerte si hors liste) | — |
| Contournement MFA par les chemins non gardés (`partnerQr`, règles) | non gardés | appeler `readValidAdmin`/MFA partout où un super-admin agit | règles Firestore ne voient pas le second facteur sans claim lu |

## 7. Écarts de sécurité

1. `ADMIN_MFA_MODE` par défaut `log`, valeurs inconnues acceptées comme `log`, trace non persistée.
2. Aucune récence du second facteur dans les gardes admin ; claim lu sans type ni identifiant de facteur.
3. Règles Firestore sans condition de second facteur ; `partnerQr.js` hors garde MFA.
4. Écritures directes des documents `admins` par tout super-admin (création, promotion, désactivation, suppression), sans audit ni MFA.
5. Aucun registre d'approbateurs, aucun `personRef`, aucune procédure d'enrôlement/révocation, aucune vérification d'identité.
6. Aucune permission/contrôle dédié à l'approbation financière ; contrôles du moteur sur chaînes.
7. Création des super-admins hors code, non traçable depuis le dépôt ; nombre réel de super-admins inconnu [H].
8. Enrôlement du premier facteur possible par quiconque connaît le mot de passe d'un compte non enrôlé.
9. Comportement de `enforce` global (tout ou rien, sans granularité, sans voie serveur d'enrôlement) : risque de verrouillage de l'administration.
10. État de la configuration MFA du projet Firebase (Identity Platform, méthodes activées, fournisseur SMS, quotas) **non vérifiable** depuis le dépôt [H].

## 8. Architecture recommandée

1. **Verrou propre aux opérations N2**, indépendant de la variable globale : une garde `requireN2Actor` (nouveau module, mission suivante) qui impose **toujours** claim MFA + `auth_time` ≤ 15 min + super actif + appartenance au registre, quel que soit `ADMIN_MFA_MODE`. Cela supprime le besoin d'activer `enforce` globalement avant de pouvoir démarrer N2, mais le plan d'activation global (§9) reste recommandé.
2. **Registre `config/n2_approvers`** serveur seul, modifié par fonction à double approbation ; contenu minimal ci-dessus ; amorçage unique, documenté et supervisé hors ligne (l'amorçage ne peut pas lui-même être N2).
3. **Fermer les écritures directes** sur `admins` (rôle, `isActive`, `permissions`) au profit de fonctions auditées avec MFA ; au moins interdire côté règles la promotion à `super` et la création directe.
4. **Valider `ADMIN_MFA_MODE`** (liste fermée) et persister les trois résultats (`ok`, `denied`, `logged_without_factor`) dans `security_events`.
5. **Procédure humaine** d'enrôlement et de révocation écrite par le propriétaire (identité, double contrôle, justificatifs conservés hors système).
6. Les collections de décisions/preuves/historique restent `write:false` ; toute lecture super-admin ; le moteur recalcule les empreintes (cf. L4.7).

## 9. Plan d'activation futur du MFA (théorique, rien n'est activé)

**Prérequis** : (a) liste exhaustive des comptes `admins` (actifs, rôle, dernier usage) et décision de désactiver les inutiles ; (b) chaque administrateur actif enrôlé avec **TOTP** de préférence (SMS en secours) ; (c) au moins **deux** super-admins enrôlés et testés, plus un compte de secours documenté ; (d) vérification dans la console Firebase de l'activation du MFA et du fournisseur SMS/quotas [H, hors dépôt] ; (e) procédure de récupération écrite (un admin verrouillé : comment il est rétabli sans contourner la sécurité) ; (f) correction de `partnerQr.js` et des chemins hors garde, ou décision explicite de les laisser.
**Tests préalables** : `adminGuards.test.js` étendu (valeurs inconnues, absence de claim, claim vide, récence) ; essai sur **émulateur ou préprod** avec comptes fictifs : connexion sans facteur refusée sur chaque famille de fonctions admin, connexion avec facteur acceptée, enrôlement possible ; test des écrans Flutter admin face à `permission-denied` (message clair) ; test de parité des règles inchangé.
**Vérification des comptes** : pour chaque admin, claim `sign_in_second_factor` observé lors d'une connexion réelle de test (journal `log` pendant une période d'observation).
**Déploiement** : (1) période en mode `log` avec journalisation persistante ; (2) fenêtre annoncée, deux responsables présents ; (3) poser la variable sur **une seule fonction/instance** si la plateforme le permet, sinon sur l'ensemble hors heures de pointe ; (4) test immédiat de chaque administrateur ; (5) déploiement ciblé, jamais automatique (règle du projet : aucun déploiement sans demande explicite).
**Surveillance** : taux de `permission-denied` MFA par fonction, tentatives d'enrôlement, alertes sur toute connexion admin sans facteur, vérification du support administratif.
**Retour arrière** : repasser la variable à `log` (effet à la prochaine instance) ; ne jamais passer à `off` sans décision écrite ; conserver la valeur précédente notée avant tout changement.
**Conditions d'arrêt** : un super-admin ne peut pas se connecter ; échec d'un test d'enrôlement ; augmentation anormale des refus ; indisponibilité du fournisseur SMS ; second super-admin non testé.

## 10. Tests nécessaires (future implémentation)

Unitaires : `requireN2Actor` (chaque contrainte isolément) ; mode MFA inconnu → refus de configuration ; récence ; révocation entre deux appels ; même `personRef`, même uid, uid ≠ mais `personRef` identique ; demandeur = décideur initial ; claim sans type. Règles (émulateur) : `config/n2_approvers` et collections N2 `write:false` pour tout client y compris super-admin ; `admins` : promotion à `super` refusée côté client ; parité des permissions inchangée. Concurrence (émulateur) : deux approbations parallèles, révocation contre approbation, perte de rôle pendant la demande. Mutations sur chaque contrôle. Audit : chaque refus et chaque transition journalisés. Aucun test sur production.

## 11. Conditions bloquantes avant l'implémentation

1. Décision et calendrier d'activation de `ADMIN_MFA_MODE=enforce` (ou adoption de la garde N2 autonome).
2. **Nombre réel de super-admins** et désignation écrite d'**au moins deux personnes physiques** ; compte de secours.
3. Procédure écrite d'enrôlement, d'identité et de révocation validée par le propriétaire.
4. Décision sur la fermeture des écritures directes de `admins` (règles) — sinon un super-admin contourne le registre.
5. Vérification de la configuration MFA du projet (hors dépôt, lecture autorisée requise).
6. Avis juridique sur le traitement des justificatifs d'identité des approbateurs (données personnelles) et sur la valeur probante des approbations.

## 12. Découpage recommandé des missions suivantes

- **L4.9** — lecture seule autorisée du projet : comptes `admins`, valeur effective de `ADMIN_MFA_MODE`, configuration Identity Platform ; état des super-admins.
- **L4.10** — durcissement : validation de `ADMIN_MFA_MODE`, persistance des traces MFA, gardes sur les chemins hors garde, tests ; aucune activation.
- **L4.11** — gestion des administrateurs par fonctions auditées + règles `admins` fermées + registre `config/n2_approvers` + `requireN2Actor` (tests règles/émulateur).
- Procédure humaine et activation de `enforce` (décision et exécution séparées, sur autorisation explicite).
- Ensuite seulement : moteur/identifiants (L4.7 §13), puis writers de décisions, preuves, rattrapage.
(Numérotation à aligner avec la vôtre ; aucune mission n'est lancée.)

## 13. Compte rendu final

- **Fichiers consultés** : `functions/adminGuards.js`, `adminPermissions.js`, `index.js` (`createSubAdmin`, `deleteSubAdmin`, `logAudit`), `partnerQr.js`, `adminPartnerAccounts.js`, `manualAccountDeletion.js`, `accountDeletion.js`, `pharmacyOwnerIdentity.js`, `partnerFirstLogin.js` (extraits `auth_time`), `accountObligations.js` (`verifyDecision`), `test/adminGuards.test.js`, `firestore.rules`, `storage.rules`, `lib/screens/admin/admin_login.dart`, `admin_otp_page.dart`, `admin_mfa_security.dart`, liste de `rules-tests/` (dont `admin-security`, `admin-doc-s7-s8`, `sub-admin-s1-s3`), 2D2A10, 7E-102, L4.7, comptage de lignes `ADMIN_MFA_MODE` dans les fichiers `.env*` (**contenu non lu**).
- **Protections présentes** : garde serveur des rôles, second facteur vérifié côté serveur (en `enforce`), liste de permissions fermée avec parité testée, règles de `admins` limitant les champs que le propriétaire peut modifier, audit générique, limitation de débit, collections sensibles serveur seul.
- **Protections absentes** : `enforce` actif ; récence MFA ; MFA dans les règles et sur certains chemins ; registre d'approbateurs ; `personRef` ; permission financière ; audit des changements de rôle ; procédure d'enrôlement/identité ; détection des comptes multiples.
- **Difficultés d'accès** : aucune pour le dépôt ; configuration Firebase/GCP (MFA, variables d'environnement déployées, liste des comptes `admins` en production) **inaccessible par principe** (lecture seule locale) — marquée [H].
- **État Git final** : HEAD `d65c8f0`, index vide, stash 0, 35 suivis modifiés, 161 non suivis.
- **Aucun fichier de code, test, configuration ou secret modifié ; aucun accès Firebase en écriture ni en lecture ; aucune activation de `enforce`.**
- **Risques ouverts** : ceux de §7 ; en particulier le contournement N2 par écriture directe de `admins` et l'absence de preuve de distinction des personnes.
- **Recommandation** : lancer d'abord une lecture seule autorisée du projet (L4.9), puis le durcissement MFA et la gestion auditée des administrateurs, avant tout registre.

Arrêt : en attente d'une nouvelle autorisation explicite.
