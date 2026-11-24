# Mission L4.9 — Audit des écritures et de la gestion des comptes administrateurs

Audit en **lecture seule** (aucun code, test, règle, configuration ou secret modifié ou lu ; aucun accès Firebase ; rien exécuté contre un projet). Légende : **[F]** fait vérifié par lecture du dépôt ; **[H]** hypothèse (comportement plateforme ou état de production non vérifiable) ; **[R]** recommandation. Les recommandations de L4.8 sont traitées comme **non implémentées**.

**Verdict** : la gestion des administrateurs repose sur deux fonctions serveur (création/suppression de sous-admin) mais **toute autre modification de `admins` (rôle, activation, permissions, création, suppression) peut se faire par écriture directe du client** avec le seul statut « super-admin », sans MFA, sans validation serveur et avec une trace d'audit *déclarative* seulement. Ce chemin contourne tout futur registre N2 tant qu'il reste ouvert.

## 1. Architecture actuelle

- **Autorité = document `admins/{uid}`** [F] (`role ∈ {super, sub}`, `isActive`, `permissions[]`). **Aucun custom claim n'est lu** par les fonctions, les règles Firestore/Storage ou le client (recherche `token.admin`, `claims.admin`, `getIdTokenResult` : seuls usages = partenaires `partnerMustChangePassword`). Chaque appel serveur et chaque évaluation de règle relit le document (`readValidAdmin`, `isActiveAdmin`) ⇒ pas de cache d'autorisation.
- **Gardes serveur** [F] : `adminGuards.js` (`readValidAdmin` → `requireSuperAdmin` / `requireAdminPermission`), MFA via `enforceAdminSecondFactor` (mode `ADMIN_MFA_MODE`, défaut `log`, cf. L4.8).
- **Règles** [F] : `isAdmin()` = super actif ; `hasAdminPermission(p)` ; aucune condition de second facteur (Firestore et Storage).
- **Interfaces** [F] : `admin_sub_admins_page.dart` (liste des sous-admins, création/suppression par callable, activation/désactivation/permissions par `update` direct, puis `logAdminAuditEvent` « best-effort ») ; `admin_dashboard.dart` (photo) ; `admin_login.dart`/`admin_otp_page.dart`/`web/admin_auth_service.dart` (lecture seule). Aucun écran de création/promotion de super-admin.

## 2. Inventaire exhaustif des écritures sur `admins`

| # | Chemin | Opération | Acteur autorisé | Contrôle de rôle | MFA | Contrôle serveur | Audit | Risque |
|---|---|---|---|---|---|---|---|---|
| W1 | `index.js` `createSubAdmin` (callable) | `auth.createUser` + `set admins/{uid}` (`role:'sub'`) | super | `requireSuperAdmin` | via garde, **seulement si mode enforce** | liste de permissions validée (`validatePermissions`), limitation 10/h | `logAudit` (serveur, erreurs avalées) | mot de passe choisi par le créateur ; compte Auth orphelin si l'écriture échoue ; seul chemin sûr |
| W2 | `index.js` `deleteSubAdmin` (callable) | `auth.deleteUser` puis `delete admins/{uid}` | super | `requireSuperAdmin` ; refuse uniquement `uid == soi-même` | idem | **rôle de la cible non vérifié** | `logAudit` | **un super peut supprimer un autre super** (compte Auth + document) ; ordre non atomique ; aucune protection « dernier super » |
| W3 | Règle `admins` `create` | `set` direct client | super | `isSuperAdmin()` + `adminPermissionsKnown()` | **aucun** | `role` non contraint (`super` possible), uid arbitraire, existence Auth non vérifiée | **aucun** | **création directe d'un super-admin** ; promotion de n'importe quel uid existant (y compris un compte client) |
| W4 | Règle `admins` `update` (super) | `update` direct client (`isActive`, `permissions`, `role`, tout champ) | super | `isSuperAdmin()` ; `permissions` validées seulement si elles changent | **aucun** | aucun (pas d'exclusion de son propre document, pas de transition d'état, pas de motif) | `logAdminAuditEvent` appelé *après*, côté client, best-effort, actions limitées à 3 libellés | **promotion/rétrogradation/auto-attribution/désactivation de tout admin, soi-même compris**, sans trace obligatoire |
| W5 | Règle `admins` `delete` (super) | `delete` direct client | super | `isSuperAdmin()` | **aucun** | aucun | aucun | suppression du document d'un autre super ou de soi (verrouillage) sans passer par W2 |
| W6 | Règle `admins` `update` (propriétaire) | `fcmToken`, `photoUrl` | admin actif (soi) | `isOwner && isActiveAdmin` + `hasOnly` | aucun | champs limités | aucun | faible (tests rules `admin-doc-s7-s8` couvrent le refus de `role`, `isActive`, `permissions`) |
| W7 | `admin_dashboard.dart` (photo) | `update/delete photoUrl` | soi | via W6 | — | — | — | faible |
| W8 | `admin_sub_admins_page.dart` 309/315/604 | `update isActive` / `permissions` direct | super | via W4 | aucun | aucun | callable déclaratif | voir W4 |
| W9 | `scripts/set_admin_claim.js` | `auth.setCustomUserClaims(uid,{admin:true})` (clé de service locale, e-mail personnel codé en dur) | opérateur détenant une clé de service | aucun | aucun | aucun | aucun | **inerte** : le claim n'est lu nulle part [F] ; mais `setCustomUserClaims` **remplace** tous les claims existants du compte ; fichier de clé non présent, non ignoré explicitement par `.gitignore` (aucune règle `serviceAccountKey`) ⇒ risque de commit accidentel [F] |
| W10 | `scripts/restaurant-v2-pilot/lot.js` (+ `prepare.js`, `cleanup.js`) | écrit/supprime `admins/t7e-admin` (`role:'super'`, fixture marquée) | script pilote | garde du dossier (`guard.js`, non audité ici) | aucun | — | — | création d'un super par script ; cible (émulateur/préprod) non vérifiée ici [H] |
| W11 | Console Firebase / Admin SDK / `gcloud` | toute écriture | propriétaires GCP / Editor | contourne règles et fonctions | — | — | journaux d'audit Cloud [H] | **limite incompressible** |

**Écritures indirectes** [F] : `accountDeletion.js`, `manualAccountDeletion.js`, `accountDeletionScope.js` **lisent** `admins` pour refuser la suppression automatique (`ADMIN_ACCOUNT_MANUAL_PROCESS`) ; `adminPartnerAccounts.js`, `partnerFirstLogin.js`, `ekbineOrders.js` refusent un compte admin comme cible ; `eventNotifications.js`, `stuckOrderAlerts.js`, `index.js` lisent les admins actifs (notifications). Aucune de ces fonctions n'écrit dans `admins`. `fcmTokenCleanup.js` liste `admins` parmi les collections à nettoyer : **écriture potentielle de `fcmToken` par l'Admin SDK, non lue en détail** (à confirmer en L4.10). `passwordReset.js` (fichier sensible, non ouvert) : le traitement des comptes admin **non vérifié**.
**Nombre de chemins d'écriture identifiés : 11** (2 serveur contrôlés, 5 client direct dont W7/W8 qui en sont des usages, 2 scripts, 1 hors application ; sans doublons : W1, W2, W3, W4, W5, W6, W9, W10, W11 = 9 mécanismes distincts + 2 usages Flutter).

## 3. Cartographie des autorisations

| Action | Aujourd'hui | Observations |
|---|---|---|
| Créer un sous-admin | W1 serveur **ou** W3 direct | W3 rend W1 optionnel |
| Créer un super | W3 / W4 / W10 / W11 | aucun chemin « officiel » |
| Promouvoir/rétrograder | W4 | aucun contrôle ni audit forcé |
| Désactiver/réactiver | W4 | y compris soi et le dernier super |
| Supprimer | W2 (serveur) / W5 (direct) | W2 sans contrôle du rôle de la cible |
| Permissions | W4 (liste officielle de 30 clés dans la règle, 31 comptées par L4.8 selon source) | aucune clé financière |
| Lire `admins` | propriétaire ou super (tous les documents, e-mail inclus) | un super lit tous les profils admin |
| Actions sensibles par non-super | `requireAdminPermission` | MFA conditionné à `enforce` |

## 4. Règles Firestore et Storage

- **Firestore** [F] : `admins` — lecture propriétaire/super ; `create` super + permissions connues ; `update` super (sans limite de champ) ou propriétaire (`fcmToken`, `photoUrl`) ; `delete` super. Aucune vérification de second facteur, de `request.auth.token.auth_time`, de transition de rôle, d'auto-modification, ni de cardinalité (dernier super). `audit_logs`, `security_events` : écriture interdite au client, lecture super/admin. Tests : `rules-tests/admin-doc-s7-s8` (création par super, clés inconnues, désactivation d'un compte à clé obsolète, suppression, champs OTP, champs autorisés du propriétaire), `admin-security`, `sub-admin-s1-s3`. **Aucun test n'affirme qu'un super *ne peut pas* se promouvoir ou promouvoir un autre** : le comportement actuel est testé comme *permis*.
- **Storage** [F] : `isAdmin()/isActiveAdmin()` relisent `admins/{uid}` via `firestore.get` ; **aucun contrôle MFA** ; `admin_photos/{adminId}/*` : écriture par le propriétaire (image ≤ 5 Mo), lecture par tout utilisateur authentifié. Les droits Storage suivent donc fidèlement W3/W4 (promotion Firestore ⇒ droits Storage immédiats).
- **Conséquence** [F] : la révocation est **immédiate** pour règles et fonctions (document relu), mais l'élévation l'est aussi.

## 5. Scénarios de contournement

| # | Scénario | Résultat | Statut |
|---|---|---|---|
| 1 | Super crée un autre super | **Possible** : W3 (`set` direct avec `role:'super'`), ou W4 sur un sous-admin existant, sans MFA ni trace obligatoire | **Confirmé par lecture des règles** (non exécuté) |
| 2 | Admin s'accorde une permission | Sous-admin : **refusé** (`hasOnly(['fcmToken','photoUrl'])`, testé). Super : permissions sans effet (il a tout), mais **peut modifier son propre document** : une future permission/registre stocké dans `admins` serait auto-attribuable | Confirmé |
| 3 | Admin désactive un autre admin | Super : possible sur tout compte, y compris un autre super, via W4 ; sous-admin : non | Confirmé |
| 4 | Admin modifie son propre document | Sous-admin : seulement `fcmToken`/`photoUrl` ; super : **tous les champs**, y compris `isActive:false` (auto-verrouillage) | Confirmé |
| 5 | Compte modifie ses custom claims | Impossible côté client (API réservée à l'Admin SDK) [H plateforme] ; aucun claim d'autorité n'est lu [F] ; `set_admin_claim.js` inerte mais efface les claims existants | Confirmé (code) |
| 6 | Écriture Firestore contourne une Cloud Function | **Oui** : W3/W4/W5 doublent W1/W2 ; l'audit n'est qu'un appel client postérieur, omissible, avec libellés choisis par l'appelant (`ADMIN_AUDIT_ACTIONS`) | Confirmé |
| 7 | Compte sans MFA réalise une opération sensible | **Oui** : mode `log` par défaut [F], valeur déployée inconnue [H] ; règles Firestore/Storage jamais conditionnées ; `partnerQr.grant` ne passe pas par `readValidAdmin` | Confirmé (code) |
| 8 | Admin révoqué garde une autorisation via jeton valide | **Non pour l'autorité** : fonctions et règles relisent `admins` (désactivé/supprimé ⇒ refus immédiat) ; aucun claim d'autorité. Réserves : `revokeRefreshTokens` n'est **pas** appelé à la désactivation (le jeton reste valide ≤ 1 h [H] mais n'ouvre rien d'administratif) ; `deleteSubAdmin` supprime le compte Auth ; un compte désactivé **peut se reconnecter** et reste propriétaire de ses données partenaires éventuelles | Confirmé (code) |
| 9 | Perte du dernier super / auto-verrouillage | Possible par W2 (autre super), W4, W5 ; aucune garde de cardinalité | Confirmé |
| 10 | Prise de contrôle d'un compte admin par e-mail/mot de passe (réinitialisation, compte non enrôlé) | Voie standard Firebase Auth ; `createSubAdmin` fixe le mot de passe ; enrôlement MFA au premier login par le détenteur du mot de passe | Hypothèse (L4.8) |
| 11 | Promotion d'un compte non-admin (client, partenaire) | W3 accepte tout uid ; aucune vérification de type de compte ni d'exclusivité de rôle (un uid peut être client **et** admin) | Confirmé (règle) |

## 6. Risques et gravité

| Id | Risque | Gravité |
|---|---|---|
| R1 | Création/promotion directe de super-admin (W3/W4) sans MFA ni audit | **Critique** |
| R2 | Écritures `admins` sans second facteur (règles) et MFA en `log` | **Critique** |
| R3 | Audit déclaratif client (omissible, falsifiable) pour activation/permissions | **Élevé** |
| R4 | `deleteSubAdmin` sans contrôle du rôle cible ; pas de garde « dernier super » | **Élevé** |
| R5 | Auto-modification du document par un super (futurs droits N2 non protégés) | **Élevé** (dépend de L4.11) |
| R6 | `partnerQr.grant` hors garde MFA (lien : le même super y gère des accès partenaires) | Moyen |
| R7 | Script `set_admin_claim.js` (clé de service locale, e-mail codé en dur, pas d'ignore) | Moyen (inerte, hygiène) |
| R8 | Création non atomique (compte Auth orphelin) / suppression non atomique | Moyen |
| R9 | Mot de passe choisi par le créateur | Moyen |
| R10 | Propriétaires GCP / console : modification hors règles | **Incompressible** (détection seulement) |
| R11 | Aucune ré-authentification récente sur les actions de gestion | Moyen |

## 7. Architecture recommandée [R]

1. **Fermer `create`/`delete` et restreindre `update` de `admins` côté client** : `allow create, delete: if false` ; `allow update` réservé au propriétaire sur `fcmToken`/`photoUrl` uniquement. Toute modification de `role`, `isActive`, `permissions` passe par des callables.
2. **Callables dédiées** (nouveau module, enveloppe `{success,error,message,data,code}`) : `adminSetActive`, `adminSetPermissions`, `adminPromote`/`adminDemote`, `adminCreate`, `adminRevoke` — chacune : MFA obligatoire (claim) + `auth_time` récent (indépendants de `ADMIN_MFA_MODE`), super actif, cible ≠ soi pour les changements de privilège, refus si la cible est la dernière super active, transaction avec précondition de `version`/`updatedAtMs` du document, `requestId` unique idempotent (rejeu), journal **dans la même transaction** (`admin_changes`, `write:false`, chaînage d'empreinte) et `logAudit`. Promotion d'un super = N2 (deux super distincts, registre `config/n2_approvers` de L4.8) ; aucune auto-promotion.
3. **Séparer l'autorité financière du document modifiable par un super** : registre N2 dans une collection/document serveur seul (`write:false`), jamais dans `admins`.
4. **Audit côté serveur** : supprimer la dépendance à `logAdminAuditEvent` (déclaratif) ; garder l'endpoint pour compatibilité mais ne plus s'y fier.
5. **Révocation** : à la désactivation/suppression, `revokeRefreshTokens(uid)` et désactivation du second facteur si requis ; réactivation = action auditée avec MFA récent.
6. **Détection hors-bande** : déclencheur `onDocumentWritten('admins/{uid}')` comparant à un journal `admin_changes` ; toute écriture sans entrée correspondante ⇒ `security_events` critique + alerte (limite : un propriétaire GCP peut aussi toucher ce journal ; la détection est le seul remède). Alertes Cloud Audit Logs sur écritures `admins` hors compte de service des fonctions.
7. **Hygiène** : ajouter une règle d'ignore pour les clés de service, retirer l'e-mail codé en dur du script (ou le retirer de l'usage), documenter/clore `set_admin_claim.js` (inutile).
8. **Protections réalisables vs limites** : réalisables — fermeture des écritures client, MFA/récence serveur, double approbation, journal chaîné, détection. Incompressibles — un propriétaire GCP ou un compte avec rôles IAM Datastore/Auth modifie tout ; un attaquant maîtrisant le projet efface aussi les journaux applicatifs (seuls les journaux Cloud Audit externes/exportés limitent ce risque).

## 8. Plan de migration sans perte d'accès administrateur [R]

Aucune suppression ni révocation automatique de compte existant.
1. **Inventaire en lecture** (autorisé séparément) des `admins` : uid, rôle, état, MFA enrôlé, dernier accès. Au moins **deux super** enrôlés et testés + un compte de secours documenté.
2. Déployer les **callables en parallèle** des écritures directes (additif), sans changer les règles ni l'UI ; tests complets (§9).
3. **Basculer l'UI Flutter** (activation, désactivation, permissions) vers les callables ; garder l'ancien chemin disponible.
4. Période d'**observation** : compter les écritures directes restantes via le déclencheur de détection (§7.6), sans bloquer.
5. **Fermer les règles** (`create`/`delete` interdits, `update` limité au propriétaire) seulement après : callables éprouvées, deux super joignables, procédure de récupération écrite, annulation de règles testée (retour arrière = redéploiement de l'ancienne règle).
6. **Récupération d'accès** (verrouillage) : procédure hors application, tenue par un propriétaire GCP selon une procédure écrite à deux personnes (limite incompressible assumée) ; jamais de contournement dans le code.
7. Compatibilité : les fonctions existantes ne changent pas (elles relisent `admins`) ; les sous-admins gardent leurs droits ; les comptes ordinaires ne sont pas touchés ; support : les actions d'activation/désactivation restent disponibles via l'UI avec un message d'erreur d'authentification récente ; un `permission-denied` de rôle doit être lisible côté Flutter.

## 9. Tests nécessaires

- **Règles (émulateur)** : après fermeture — un super ne peut ni créer, ni supprimer, ni changer `role`/`isActive`/`permissions` en direct ; le propriétaire ne change que `fcmToken`/`photoUrl` ; sous-admin, client, anonyme refusés ; un super ne s'auto-attribue rien. Mettre à jour les tests actuels qui affirment le comportement permissif (`admin-doc-s7-s8`, `sub-admin-s1-s3`) **uniquement** à cette mission.
- **Fonctions** : chaque callable — rôle, MFA absent, `auth_time` ancien, cible = soi, cible = dernier super, cible inconnue, rejeu (`requestId`), versions concurrentes (deux changements simultanés), rollback de transaction, audit écrit dans la même transaction, suppression Auth/document cohérente.
- **Concurrence** (émulateur) : désactivation simultanée de deux super (le dernier doit rester), approbation N2 vs révocation, création concurrente du même e-mail.
- **Détection** : écriture directe simulée ⇒ événement de sécurité.
- **Parité** : trois miroirs de permissions inchangés (test existant).
- **Mutations** sur chaque contrôle ; aucun test sur production.

## 10. Dépendances avec L4.10 et L4.11

- **L4.10** (durcissement MFA, [R] de L4.8) : validation de `ADMIN_MFA_MODE`, traces persistantes, MFA et récence sur chemins hors garde (`partnerQr.grant`) — **prérequis** des callables de ce rapport (elles réutilisent la garde).
- **L4.11** (gestion des administrateurs + registre N2) : implémente §7.1–7.6 ; **bloquée par** : décision sur la fermeture des règles, deux super enrôlés, procédure d'identité/`personRef` (L4.8 §4, §11).
- Ordre conseillé : L4.10 → L4.11 (callables, parallèle) → bascule UI → fermeture des règles → registre des créances. Aucune n'est lancée ici.

## 11. Conditions bloquantes avant implémentation

1. Inventaire autorisé des comptes `admins` en production (nombre de super, MFA enrôlé) et valeur effective de `ADMIN_MFA_MODE` — **inconnus**.
2. Au moins deux super-admins enrôlés et joignables ; compte de secours et procédure de récupération validés par le propriétaire.
3. Décision explicite sur la fermeture des écritures directes (impact UI : activation/permissions) et sur la politique « un uid = un seul rôle » (R11/scénario 11).
4. Décision sur la création/promotion d'un super : N2 obligatoire ou procédure externe.
5. Avis sur la conservation des journaux (rétention, export externe) et sur la détection hors-bande.
6. Vérification de `fcmTokenCleanup.js` et du traitement des admins dans `passwordReset.js` (fichier sensible : autorisation séparée).
7. Autorisation séparée pour toucher `index.js`, `adminPartnerAccounts.js`, `passwordReset.js` (fichiers protégés).

## 12. Compte rendu final

- **Fichiers inspectés** : `functions/adminGuards.js`, `index.js` (`logAudit`, `logSecurityEvent`, `createSubAdmin`/`deleteSubAdmin`, enregistrement de `logAdminAuditEvent`), `authEvents.js` (`buildLogAdminAuditEvent`), `partnerQr.js` (`grant`, `ensure`), `adminPartnerAccounts.js` (lectures `admins`), `accountDeletion*.js`/`manualAccountDeletion.js` (références), recherche transversale des références `admins` dans `functions/*.js`, `lib/`, `scripts/` ; `firestore.rules` (`isActiveAdmin`, `isAdmin`, `hasAdminPermission`, `adminPermissionsKnown`, `admins`, `audit_logs`, `security_events`) ; `storage.rules` (fonctions admin, `admin_photos`) ; Flutter `admin_sub_admins_page.dart`, `admin_dashboard.dart`, `admin_login.dart`, `admin_otp_page.dart` (références) ; `scripts/set_admin_claim.js`, références de `scripts/restaurant-v2-pilot/*` ; `rules-tests/admin-doc-s7-s8.rules.test.js` (extraits), liste des tests de règles ; `.gitignore` (lignes pertinentes).
- **Chemins d'écriture** : 11 (9 mécanismes distincts + 2 usages Flutter) ; **non protégés** : W3, W4, W5, W8 (directs), W9/W10 (scripts), W11 (hors application) ; partiellement protégés : W1, W2.
- **Contournements confirmés (par lecture)** : création directe de super (1), auto-modification par un super (4), désactivation d'un autre super (3), contournement des fonctions par écriture directe (6), opérations sensibles sans MFA en mode `log` (7), suppression d'un super par `deleteSubAdmin` (R4). Aucun n'a été **exécuté** (aucun test lancé, aucune écriture).
- **Protections existantes** : documents relus à chaque appel (révocation immédiate), sous-admin non auto-promouvable, liste fermée de permissions dans règle et fonction avec test de parité, champs OTP supprimés, audit serveur de W1/W2, limitation de débit sur création, comptes admin exclus des suppressions et opérations partenaires automatiques, `audit_logs`/`security_events` non écrivables par le client.
- **Difficultés** : aucun accès à la production (comptes, MFA, variables déployées, IAM) ; `passwordReset.js` non ouvert (fichier protégé) ; `fcmTokenCleanup.js` non lu en détail ; `guard.js` des scripts pilotes non audité ; aucun test exécuté.
- **Aucune modification** de code, test, règle ou configuration ; aucun secret consulté ; aucun accès Firebase (lecture ou écriture) ; aucun commit/push/stash/index/déploiement ; L4.10, L4.11 et registre des créances non commencés.
- **État Git final** : HEAD `d65c8f0`, index vide, stash 0, 35 suivis modifiés, 162 non suivis (161 + ce rapport).

Arrêt : en attente d'une nouvelle autorisation explicite.
