# Audit des permissions des sous-administrateurs

Date : 2026-10-30. Règles analysées : **règles réellement déployées** (relevé du 2026-10-30, `docs/FIRESTORE_RULES_DEPLOYED_2026-10-30.rules.txt`) et code des Cloud Functions du dépôt. Aucune règle ni fonction n'a été modifiée.

## 0. Correction d'une idée reçue

Notre note interne (`.claude/rules/firestore-rules.md`) dit que le tableau `permissions` « n'est PAS appliqué dans les règles » et qu'un sous-admin a l'accès `isAdmin()` complet. **C'est faux pour les règles déployées** :
- `isAdmin()` = **super-admin uniquement** (`role == 'super'`).
- `hasAdminPermission(clé)` existe (super, ou sous-admin porteur de la clé) mais n'est utilisé qu'à **12 endroits**.

Un sous-admin est donc *refusé par défaut* presque partout. Le problème réel est double : (1) quelques trous précis où il obtient plus que sa permission ; (2) l'inverse, la plupart des permissions n'ouvrent rien côté base.

## 1. Les « trois profils »

Je n'ai trouvé **aucun profil prédéfini** dans le code ni dans les documents : un sous-admin est `role: 'sub'` avec une liste libre parmi **29 clés** (`_kSections` dans `admin_sub_admins_page.dart`), créé par `createSubAdmin` (super-admin seul, clés non validées côté serveur). **À définir avec vous** : si trois profils sont prévus (par exemple Support, Opérations, Finances), indiquez-moi leur contenu ; le tableau 5 en propose un point de départ.

## 2. Ce qu'un sous-admin atteint réellement (Firestore)

| Collection / opération | Condition dans les règles | Verdict |
|---|---|---|
| `sellers` : lecture, création, modification **de tous les champs** | `hasAdminPermission('demandes_vendeurs')` | **TROU (critique)** : wallet, abonnement, VIP, suspension modifiables |
| `pharmacy_guards` : suppression | `hasAdminPermission('demandes_vendeurs')` (création/modification : super seul) | **Mauvaise clé** : un approbateur de vendeurs supprime des gardes de pharmacie |
| `simple_services`, `simple_service_private` | `hasAdminPermission('tricycle')` | Correct (pièces d'identité et GPS séparés du catalogue) |
| `admins/{son uid}` | seulement `otpHash, otpCode, otpExpiry, otpAttempts, fcmToken, photoUrl` | Pas d'auto-promotion possible ; voir §4 (2FA) |
| `orders`, `clients`, wallets, `commissions`, demandes, SOS, support, avis IA, `app_config`, `audit_logs`… | `isAdmin()` | Refusé au sous-admin (conforme à l'intention) |
| `livreurs` (lecture) | `isAuth()` | **Lisible par tout utilisateur connecté, anonyme compris, `wallet` inclus** (voir §3, S6) |
| `restaurants`, `pharmacies`, `boulangeries`, `ekbine_agents`, `service_providers`, `zones_livraison`, `locations`, `residences`, `reviews`, `boutique_products`, menus | `isAuth()` en lecture | Catalogues publics : acceptable, sauf champs sensibles (S6) |

## 3. Écarts précis (où un sous-admin dépasse sa permission)

| # | Gravité | Où | Problème | Correction proposée |
|---|---|---|---|---|
| S1 | **Critique** | règle `sellers` | Un sous-admin avec **la seule** permission « Dem. Vendeurs » peut écrire n'importe quel champ de n'importe quel vendeur : `wallet`, `subscriptionStatus`, `vipStatus`, `isSuspended`… (règle argent du projet : aucun wallet hors Cloud Function). Il lit aussi tous les vendeurs et peut créer un document arbitraire. | Remplacer par : lecture par permission ; **création interdite** (passe par `manageAdminPartnerAccount`, déjà protégé) ; mise à jour limitée par `affectedKeys().hasOnly([name, phone, type, isActive, lat, lng])` ; `wallet`/abonnement/VIP **jamais** côté client. |
| S2 | **Élevé** | `checkWithdrawalStatus` (`index.js`) | Tout admin actif (sous-admin **sans** permission financière) peut déclencher la machine d'états d'un retrait de n'importe quel utilisateur ; cette machine peut régler ou **rembourser** (`failed_refunded`). | `requireSuperAdmin` pour les retraits d'autrui (ou une clé `retraits` dédiée si vous voulez la déléguer). |
| S3 | Moyen | règle `pharmacy_guards` (suppression) | Clé `demandes_vendeurs` au lieu de `pharmacies` (incohérent avec création/modification réservées au super-admin). | Aligner les trois opérations (`hasAdminPermission('pharmacies')` ou super seul). |
| S4 | Moyen | `manageProfessionalSubscription`, action `renew` | La branche « admin » accepte **tout** admin actif, sans permission : il peut déclencher le renouvellement (débit du wallet du compte, si échu) de n'importe quel compte. | Exiger `requireAdminPermission` avec `ADMIN_PERMISSIONS[collection]` dans cette branche. |
| S5 | Moyen | notifications serveur (`security_alert`, nouveau livreur, nouveau prestataire) | Envoyées à **tous** les admins actifs, sous-admins compris : description d'événements de sécurité et noms de candidats visibles par des profils sans permission. | Filtrer les destinataires : super-admins, ou porteurs de la clé concernée. |
| S6 | Élevé (hors rôles) | règle `livreurs` : `read: if isAuth()` | Tout utilisateur connecté, **y compris anonyme**, lit tous les documents livreurs (dont `wallet`, position). Nécessaire à la carte client, mais bien plus large que le besoin. | Document public minimal (position, disponibilité, nom affiché) séparé du document privé (`wallet`, KYC) ; chantier à planifier, pas un correctif de règle seul. Même vérification à faire pour `ekbine_agents` et `service_providers` (le code mentionne déjà un PIN artisan hérité en clair). |
| S7 | Bas | 2FA admin | Les champs OTP (`otpHash`, `otpCode`…) sont écrits par l'admin lui-même depuis le client : la vérification du second facteur est côté client. Un bandeau « 2FA contournée » existe déjà. | À traiter dans un chantier 2FA serveur, hors de cet audit. |
| S8 | Bas | `createSubAdmin` | Les clés de `permissions` ne sont pas validées. La clé `auto_moto`, exigée par `moderateVehicleEntity`, n'existe pas dans l'interface : cette fonction n'est atteignable que par le super-admin. | Valider contre une liste unique partagée. |

**Vérifié sans problème** : `createSubAdmin`, `deleteSubAdmin`, `logAdminAuditEvent` (super seul) ; `adminBillingCF`, `settleTransferEarningsCF` (hors encaissement), `diagnoseDriverOccupancy`, suppression de comptes, QR, immobilier : super seul ; `adminDriverRechargeCF` (`recharges`), `moderateVehicleEntity`, `setPharmaciePassword` (`pharmacies`), `artisanAccounts` (`services`), `manageAdminPartnerAccount` (clé du type de partenaire, avec contrôle de cible) : permissions vérifiées côté serveur.

## 4. L'inverse : permissions sans effet réel

Une permission donne une **entrée de menu**, mais la base refuse les lectures ou écritures de la page. Constat par page (lecture refusée / écriture refusée pour un sous-admin porteur de la bonne clé) :

- **Complètement bloquées** : Commandes (`orders`), Gains, Commissions, Classement, Stats Géo, Carte live (commandes), Anti-fraude, Cash à régler, Demandes (livreurs, restos, boulangeries, pharmacies, vendeurs*), SOS, Support, Flottes, Événementiel, Boutique, Tableau de bord IA.
- **Lecture possible, actions refusées** : Livreurs (suspension, modification), Restaurants, Pharmacies, Boulangeries, Résidences, Locations, Zones Géo, Services ; Agents E-Kbine (liste lisible, commandes et écritures refusées).
- **Fonctionnent de bout en bout** : Tricycle & Taxi ; Recharges (via fonction serveur) ; création/gestion de partenaires (via fonctions serveur).

\* « Dem. Vendeurs » ouvre la lecture de `sellers` (S1) mais pas de `seller_requests`.

Conséquence : aujourd'hui, un sous-admin voit des écrans vides ou des erreurs ; la sécurité est « fermée par défaut » mais l'outil n'est pas utilisable. C'est le bon sens de l'erreur, et la raison pour laquelle S1 est le seul vrai trou de données.

## 5. Système de permissions appliqué côté serveur (proposition)

Principes, sans toucher au super-administrateur (toujours `isAdmin() || hasAdminPermission(clé)`) :

1. **Une table unique clé → ressources** (`functions/adminPermissions.js`, miroir dans les règles et dans `admin_menu.dart`), pour qu'une clé ne puisse plus avoir trois sens différents.
2. **Lecture par permission** : `hasAdminPermission(clé)` sur chaque collection de la table ci-dessous.
3. **Écriture par liste blanche de champs** (`affectedKeys().hasOnly([...])`) pour les champs de profil et de statut ; **jamais** d'écriture client sur `wallet`, abonnement, VIP, commissions : Cloud Function avec `requireAdminPermission`, `checkRateLimit`, `logAudit`.
4. **Opérations destructrices et financières** : super-admin, ou fonction dédiée avec clé spécifique et journal d'audit (suppression de compte, purge, retraits, règlements, suspension de livreur avec motif).
5. **Menu = reflet du serveur** : `admin_menu.dart` n'affiche une entrée que si la clé *et* son backend sont opérationnels.
6. **Tests générés depuis la table** : pour chaque clé P et chaque collection C, un sous-admin avec P est accepté, un sous-admin avec une autre clé est refusé, le super-admin est toujours accepté (émulateur de règles).

Table de départ (lecture / écriture de champs de profil) :

| Clé | Collections | Écritures client permises (liste blanche) | Via fonction serveur |
|---|---|---|---|
| `livreurs` | `livreurs` (+ `fleet_owners` lecture) | `isSuspended`, `isActive` avec motif | modification de wallet : jamais |
| `commandes` | `orders` lecture | aucune | annulation (`commandes`, déjà en place) |
| `gains` | `commissions`, `orders` lecture | aucune | — |
| `demandes`, `demandes_resto`, `demandes_vendeurs`, `demandes_boulangeries`, `demandes_pharmacies` | `*_requests` | `status`, motif de refus | création du compte : fonction existante |
| `restaurants`, `boulangeries`, `pharmacies`, `boutique`, `flottes`, `ekbine`, `services`, `locations`, `residences`, `eventiel`, `zones` | leur collection | champs de profil/statut | abonnement/VIP/mots de passe : fonctions existantes |
| `sos`, `support`, `anti_fraude`, `cash_marchand`, `ai_dashboard` | leur collection | `status`, `resolved`, notes | règlement de cash : fonction à créer |
| `recharges` | `recharge_requests` | aucune | `adminDriverRechargeCF` (déjà) |
| `tricycle` | `simple_services*` | déjà en place | — |
| *(super seul)* | `app_config`, `audit_logs`, `security_events`, retraits, suppression de comptes, purge, QR, facturation, gestion des admins | — | — |

**Déploiement progressif recommandé** :
- *Phase 0 — avant le lancement* : S1, S2, S3, S4 (corrections ciblées, petites, testables).
- *Phase 1* : S5 et validation des clés (S8).
- *Phase 2* : lecture par permission pour les collections du tableau (ouvre les écrans aux sous-admins).
- *Phase 3* : écritures en liste blanche et fonctions serveur manquantes.
- *Phase 4* (chantier séparé) : S6 (documents publics/privés des livreurs) et S7 (2FA serveur).

## 6. Si vous n'avez pas besoin de sous-admins au lancement
Option la plus sûre et la moins chère : **ne créer aucun sous-admin** jusqu'à la phase 3, et appliquer S1–S4 quand même (ils restent des trous si un sous-admin est créé plus tard). Les `admins` actuels (`role == 'sub'`) sont à relever en lecture seule avant tout choix.

## Corrections locales S1–S4 (2026-10-30) — NON déployées

| # | Correction (dépôt local) | Tests |
|---|---|---|
| S1 | `firestore.rules`, `sellers` : `create` = super-admin seul ; `update` = super-admin, ou sous-admin `demandes_vendeurs` limité à `affectedKeys().hasOnly(['name','phone','type','isActive','lat','lng'])`, ou propriétaire (inchangé). Lecture inchangée. | `rules-tests/sub-admin-s1-s3.rules.test.js` : 14 champs sensibles refusés un par un, mélange refusé, création/suppression refusées, sans permission / désactivé / anonyme refusés, super-admin et propriétaire inchangés |
| S2 | `functions/adminGuards.js` : `requireWithdrawalAccess` (propriétaire ou **super-admin**), utilisé par `checkWithdrawalStatus` (`index.js`). Aucun appel Flutter à cette fonction : pas d'impact écran. | `functions/test/adminGuards.test.js` : propriétaire, super OK ; sous-admin (même avec permissions financières), désactivé, rôle inconnu, anonyme, retrait sans propriétaire : refusés |
| S3 | `firestore.rules`, `pharmacy_guards` : `delete` = `isAdmin()` (aligné sur create/update). | même fichier de règles : ancienne clé `demandes_vendeurs`, clé `pharmacies`, autre clé, désactivé refusés ; super OK |
| S4 | `functions/professionalSubscriptions.js`, action `renew` : le propriétaire renouvelle son compte ; toute autre personne doit passer `requireAdminPermission(ADMIN_PERMISSIONS[collection])`. | `functions/test/professionalSubscriptions.test.js` : 4 nouveaux tests (sous-admin sans permission, désactivé/rôle inconnu/simple client, bonne permission + super, restaurateur propriétaire vs autre restaurant) |

Non traité (hors S1–S4, restent ouverts) : S5 notifications aux sous-admins, S6 lecture de `livreurs` (avec `wallet`) par tout utilisateur connecté, S7 contrôle OTP admin côté client, S8 clés de permission non validées / `auto_moto` absente de l'interface.
Effet de bord à connaître : un sous-admin ne peut plus créer ni supprimer de vendeur depuis le client (la création passe déjà par `manageAdminPartnerAccount`).

## Mise à jour S5–S8 (2026-10-30, soir)
S5–S8 traités localement : voir `docs/ADMIN_SECURITY_S5_S8.md`. **Correction de ce document** : la ligne S7 ci-dessus décrit l'ancien OTP côté client ; le code actuel utilise le MFA natif de Firebase (TOTP/SMS) et plus aucun code ne lit les champs `otp*`. Profils : `docs/ADMIN_PERMISSION_PROFILES.md`. Plan de déploiement : `docs/SECURITY_DEPLOYMENT_PLAN.md`. Relevé de production : 1 admin (super), 0 sous-admin.
