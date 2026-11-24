# Mission L4.10.2 — Audit des règles `sellers`, des modifications de téléphone et de la migration d'identité

Audit en **lecture seule**. Aucun code, test, règle, configuration ou secret modifié ; aucun accès Firebase, production ou préproduction ; `account_phone_bindings` **non créée**, aucune donnée écrite, aucun secret généré. Légende : **[F]** fait vérifié dans le dépôt ; **[H]** hypothèse (comportement Firebase/production non vérifié) ; **[R]** recommandation.

**Verdict.** (1) La règle `sellers` autorise encore l'écriture **directe** de `phone` par un sous-admin « demandes_vendeurs », alors que l'application n'utilise plus ce chemin et qu'une fonction auditée équivalente existe : la fermeture est possible sans casser l'interface vendeur [F pour `admin_sellers_page.dart`]. (2) Le titulaire peut changer son `phone` **sans OTP** sur la plupart des profils ; l'exigence de mot de passe de `updatePhone` n'existe que dans l'application. (3) Le modèle `account_phone_bindings` doit utiliser un **HMAC à clé serveur**, pas un sel par enregistrement. (4) Le lien du numéro au compte Firebase Auth (option A de L4.10.1) a un inconvénient nouveau à arbitrer : il fait du téléphone un moyen de **connexion**, donc le recyclage d'un numéro par l'opérateur devient une prise de compte complète ; je recommande de revoir ce choix (§5).

## 1. Architecture actuelle

- `resetAccountPassword` prend `profile.phone` comme preuve (L4.10). Les profils partenaires créés par l'administration sont créés **côté serveur** (`manageAdminPartnerAccount`, Admin SDK, e-mail technique `<téléphone>@az-seller.ci`, `@az-restaurant.ci`…). [F]
- Deux chemins coexistent pour modifier un vendeur par l'administration : la **fonction** `manageSellerAccountCF` (`manageSellerAccount.js`, permission `demandes_vendeurs` ou super, champs `name, phone, type, isActive, lat, lng`, limitation de débit, `logAudit` avec `phoneChanged: true/false` sans valeur) et la **règle Firestore** `sellers.update` qui autorise la même liste de champs en écriture directe. [F]
- Le téléphone sert à : la réinitialisation, la connexion partenaire par identifiant téléphone (e-mail technique), les contacts commande, FeexPay/Ekbine (numéros de paiement distincts, `phoneNumber` des comptes de dépôt), la création de comptes de flotte. [F]

## 2. Analyse des règles `sellers` (lue intégralement, lignes 433–466)

| Opération | Acteur | Condition | Champs | `phone` ? | MFA |
|---|---|---|---|---|---|
| `read` | propriétaire, `hasAdminPermission('demandes_vendeurs')` (donc super) | uid / permission | tous | lisible | non |
| `create` | `isAdmin()` (super) | aucun contrôle de contenu ni d'existence Auth | tous | oui, arbitraire | non |
| `update` (super) | `isAdmin()` | aucune | tous | oui | non |
| `update` (sous-admin) | `hasAdminPermission('demandes_vendeurs')` | `diff.affectedKeys().hasOnly(['name','phone','type','isActive','lat','lng'])` | 6 champs | **oui** | non |
| `update` (propriétaire) | `isOwner && partnerActivated()` | pas de `isActive/isSuspended/isDeleted/status` ; `wallet`, abonnement, VIP, plan inchangés | tous les autres, **dont `phone`** | **oui, sans OTP** | non |
| `delete` | super | — | — | — | non |

- `isActiveAdmin()` ne vérifie ni second facteur ni récence [F]. Test de règles : `rules-tests/sub-admin-s1-s3.rules.test.js` **affirme que le sous-admin peut écrire `phone`** (`assertSucceeds`) et que les champs sensibles sont refusés ; aucun test n'affirme que `phone` est sensible. [F]
- `manageSellerAccountCF` : journalise `changedFields` et `phoneChanged` mais **jamais** l'ancienne/nouvelle valeur du téléphone (empreinte absente) : on sait *qu'*un numéro a changé, pas *vers quoi*. L'audit n'existe que pour le chemin fonction ; une écriture directe n'en laisse **aucun**. [F]
- L'application d'administration (`admin_sellers_page.dart`) appelle `AdminPartnerAccountService.manageSeller` (fonction) pour modifier et `create` (serveur) pour créer ; **aucun `.update`/`.set` Firestore direct** dans ce fichier. [F] D'autres écrans (web, `merchants_page`, etc.) n'ont pas été examinés pour `sellers` ; le tableau de bord web écrit seulement des **candidatures** (`driver_applications`, `partner_applications`). [F pour ces deux formulaires]

## 3. Inventaire des modifications de téléphone

Acteurs : **T** titulaire, **A** administrateur (super ou sous-admin), **S** fonction serveur.

| Profil | Chemin | Acteur | Contrôle | OTP | Audit |
|---|---|---|---|---|---|
| `clients` | création (`client_auth_page.dart`, `profil_client.dart`) et `set merge` du profil | T | règle propriétaire ; création : liste fermée de champs (`phone` libre) | non | non |
| `clients` | `AuthService.updatePhone` (réauthentification mot de passe côté appli) | T | **client seulement** ; la règle autorise le `update` direct | non | non |
| `livreurs` | `AuthService.updatePhone` (`driver_profil.dart`) ; création par super ou `fleetDriverCreation.js` | T / A / S | règle ; fonction avec motif de téléphone `PHONE_PATTERN` | non | non / non |
| `sellers` | `manageSellerAccountCF` | A (sous-admin ou super) | permission, débit | non | **oui** (booléen) |
| `sellers` | règle directe | A (sous-admin, super) / T | cf. §2 | non | **non** |
| `sellers` | création | A via serveur (`manageAdminPartnerAccount`) ; règle directe super | MFA conditionnel | non | oui / non |
| `restaurant_owners`, `restaurants` | création/mise à jour | A (super, `write: isAdmin()`) ; `assignOwner` serveur | règle ; serveur | non | partiel |
| `boulangeries` | création/mise à jour | A (super) ; propriétaire (`phone` non gardé) | règle | non | non |
| `pharmacies` | écran `admin_pharmacies_page.dart` (mise à jour directe), inscriptions | A / T | règle (non relue en détail) | non | non |
| `fleet_owners` | inscription (`phone` dans la liste fermée) ; mise à jour propriétaire ; `fleet_dashboard.dart` (fonction pour les chauffeurs) | T / A | règle | non | non |
| `ekbine_agents` | inscription (`phone`) ; mise à jour propriétaire | T | règle | non | non |
| `real_estate_agents` | création `realestate.js` (`phone` fourni) | S | contrôle serveur | non | non |
| `service_providers` | `serviceProviderApplication.js`, `artisanAccounts.js` | T / S / A | serveur | non | non |
| `admins` | champ `phone` fixé à la création (`createSubAdmin`) ; le propriétaire ne peut écrire que `fcmToken`/`photoUrl` | S / A | serveur | non | oui (création) |
| Numéros de paiement | `ekbine_agents.depositAccounts[].phoneNumber` (fonction `index.js` ~2073), `feexpayPhone` | S / T | validations de forme | non | partiel |
| Liaison Auth | **aucun** champ de liaison : pas de `linkWithCredential`/`updatePhoneNumber` côté client ni Admin SDK dans `lib/` et `functions/` (recherche) ; `request.auth.token.phone_number` n'est lu que par `passwordReset.js` et le bloc legacy commenté d'`index.js` | — | — | — | — |

Phases non vérifiées : règles `pharmacies`, `service_providers`, `real_estate_agents` en détail, `livreurs` au-delà du commentaire de suspension ; `storage.rules` non concerné. [NE]

## 4. Permissions et acteurs (synthèse)

- **Sous-admin « demandes_vendeurs »** : peut changer `phone` par règle (sans trace) ou par fonction (trace partielle) pour **tous les vendeurs**. **Risque confirmé** (combiné à `resetAccountPassword`).
- **Super-admin** : toute collection de profils, création avec uid arbitraire sur `sellers`/`boulangeries`/`restaurant_owners` ; aucun MFA exigé par règle.
- **Titulaire** : change son `phone` sans OTP sur `clients`, `livreurs`, `sellers`, `boulangeries`, `fleet_owners`, `ekbine_agents`.
- **Fonctions serveur** : sont la seule couche capable de lier un numéro à un compte de façon vérifiable.

## 5. Analyse de `account_phone_bindings`

**Rôle.** Registre serveur, d'origine contrôlée, qui dit « le numéro vérifié N peut réinitialiser le compte C ». Le profil `phone` ne fait que confirmer.

**Contrainte de conception [F/H].** Un numéro ivoirien compte 8–10 chiffres : l'espace est minuscule. Une empreinte **salée par enregistrement** est inutilisable (aucune recherche par numéro) et un SHA-256 simple est cassable par énumération. [R] Utiliser un **HMAC-SHA256 à clé serveur** (poivre) : recherche exacte possible, résistance à l'énumération si la clé reste secrète ; identifiant de clé (`keyId`) stocké pour la rotation (double calcul pendant la transition). La clé suit la règle du projet (secrets dans `functions/.env`, jamais dans le code/rapports) ; elle n'est ni générée ni lue ici. Note [F, mémoire projet] : Secret Manager est désactivé sur la préproduction.

**Arbitrage A vs B (révision de L4.10.1).** Lier le numéro au compte Auth (A) fait de ce numéro un moyen de connexion par SMS : si l'opérateur réattribue le numéro, le nouveau détenteur peut se connecter **au compte existant** [H, comportement général de Phone Auth]. Avec B seul (téléphone = facteur de **récupération**, pas de connexion), le recyclage ne donne que la possibilité de réinitialiser, atténuée par ancienneté du lien, notification, revalidation périodique et refus pour les profils à risque. **Recommandation révisée [R] : B comme cible pour tous les rôles, A seulement si le produit veut aussi la connexion par SMS.** À soumettre en décision.

**Champs nécessaires [R]** (document `account_phone_bindings/{bindingId}`) :
`schemaVersion`; `subjectKind` (`auth_user` | `profile_only`); `uid` (rôles Auth) ou `profileCollection+profileId` (pharmacie, artisan, comptes sans Auth) ; `phoneHmac`; `keyId`; `status` (`pending_confirmation` | `active` | `revoked` | `superseded`); `origin` (`legacy_backfill` | `admin_creation` | `holder_verified`); `verifiedAuthTimeMs` (vérification OTP, absent pour `legacy_backfill`); `createdBy` (fonction), `createdAtMs`; `version`; `previousBindingId`; `revokedAtMs`, `revokedReason`; `lastConfirmedAtMs`; drapeaux d'anomalie. Aucun numéro en clair, aucun contenu personnel.

**Unicité.** Firestore n'a pas de contrainte d'unicité hors identifiant de document : créer, **dans la même transaction**, `account_phone_binding_index/{phoneHmac}` → `{bindingId}` (`create` échoue si existant). Un numéro ⇒ au plus un lien actif ; un compte ⇒ au plus un lien actif (identifiant de lien = clé du sujet). Les doublons détectés au backfill ne produisent **aucune** liaison automatique.

**Liaison UID / numéro.** Rôles Auth : le lien est créé par une fonction qui exige (i) session authentifiée du compte cible (mot de passe récent, `request.auth.uid == uid`) **et** (ii) preuve OTP du nouveau numéro (jeton Phone Auth récent, `auth_time` ≤ 5 min, issu d'une seconde session ou d'un lien éphémère) ; la fonction relit les profils/`admins` en transaction. Comptes sans Auth (pharmacie, artisan, comptes partenaires créés par l'administration à la première connexion) : preuve du secret existant (mot de passe/PIN) + OTP.

**Révocation et remplacement.** Remplacer un numéro = nouvelle preuve OTP du **nouveau** numéro **et** preuve de l'ancien (OTP de l'ancien, ou mot de passe + délai de sécurité 72 h avec notification sur l'ancien canal) ; l'ancien lien passe `superseded`. Remplacement assisté par l'administration = action serveur à double approbation (N2) et audit, jamais par écriture de profil. Révocation sur suppression/anonymisation de compte (tombstone) et sur incident.

**Contrôles d'intégrité.** Règle Firestore `allow read, write: if false` pour les deux collections (hors lecture super-admin éventuelle sans empreinte) ; recalcul périodique de cohérence (lien ↔ profil ↔ Auth ↔ e-mail technique) ; événements `security_events` sur divergence ; version et `previousBindingId` pour détecter une réécriture.

**Accès serveur uniquement.** Le client ne lit jamais ces collections ; la résolution se fait dans `resetAccountPassword`.

## 6. Modèle de données proposé

```
account_phone_bindings/{bindingId}
  bindingId = uid                         (subjectKind: auth_user)
            = "<collection>:<profileId>"  (subjectKind: profile_only)
  schemaVersion, subjectKind, uid | profileCollection+profileId,
  phoneHmac, keyId, status, origin,
  verifiedAuthTimeMs?, createdBy, createdAtMs, version,
  previousBindingId?, revokedAtMs?, revokedReason?, lastConfirmedAtMs?, flags[]
account_phone_binding_index/{phoneHmac}   → { bindingId }          (create-only, unicité)
account_phone_binding_events/{eventId}    → { bindingId, kind, byFn, atMs, reasonCode }   (append-only)
```

[R] `write: false` sur les trois ; création par transaction qui crée lien + index + événement.

## 7. Plan de migration à blanc

Quatre étapes (aucune écriture, aucune suppression, aucun compte désactivé) :

1. **Inventaire à blanc.** Lecture seule (script hors dépôt ou fonction d'inventaire, **après autorisation distincte** pour toute lecture de production/préproduction) de : les collections de profils, `admins`, les utilisateurs Auth (fournisseurs, e-mail technique, `phoneNumber` éventuel), `account_tombstones`, `audit_logs` (`seller_profile_update` avec `phoneChanged`). Sortie : rapport JSON **hors du dépôt**, numéros remplacés par empreinte HMAC locale temporaire, sans données personnelles.
2. **Détection** (codes de classification) : `OK_UNIQUE`, `DUP_PHONE_MULTI_UID`, `MULTI_PROFILE_UID`, `ADMIN_OVERLAP`, `EMAIL_TECH_MISMATCH` (partie locale de l'e-mail technique ≠ `phone`), `THIRD_PARTY_PHONE_CHANGE` (audit `phoneChanged`), `NO_AUTH`, `CLOSED_OR_TOMBSTONE`, `ANONYMIZED`, `PHONE_MISSING_OR_INVALID`, `RECENT_CHANGE`, `RECYCLE_SUSPECT` (numéros sans activité récente).
3. **Revue humaine** des classes ≠ `OK_UNIQUE` : décisions écrites par cas (confirmer, geler, remplacer via procédure support) ; journal de décision hors production ; aucun traitement automatique des cas ambigus ; ceux-ci restent **sans lien** (la réinitialisation par SMS leur est fermée, le support reste disponible).
4. **Liaison vérifiée** uniquement après autorisation distincte : les liens `origin: legacy_backfill` sont créés `pending_confirmation` et passent `active` à la **première confirmation par le titulaire** (mot de passe + OTP) lors d'une connexion normale — la migration se fait par l'usage, sans bloquer personne. Les comptes sans activité restent `pending_confirmation` et soumis à des contrôles renforcés (délai, notification) à la réinitialisation.

Cas traités : même UID dans plusieurs collections (ADMIN_OVERLAP → refus total, sinon exemption documentée) ; même numéro sur plusieurs UID (aucun lien, revue) ; numéro modifiable par un tiers (marque `THIRD_PARTY_PHONE_CHANGE`, lien `pending_confirmation` obligatoire) ; non vérifié (idem) ; recyclé (revalidation à la prochaine connexion, ancienneté) ; sans Auth (lien `profile_only`) ; fermé/anonymisé (aucun lien, aucun profil réactivé) ; administrateur avec profil ordinaire (aucun lien, refus).

## 8. Matrice de sécurité

| Cas | Risque | Protection existante [F] | Protection recommandée [R] |
|---|---|---|---|
| Sous-admin change le numéro d'un vendeur | Prise du mot de passe du vendeur via le reset | Règle (pas de protection) ; fonction auditée **optionnelle** | Retirer `phone` des champs directs du sous-admin (la fonction reste) ; le reset ignore `profile.phone` ; gel du reset après changement tiers ; audit avec empreinte HMAC |
| Vendeur change son numéro sans OTP | Détournement du recouvrement de son propre compte (peu) ; préparation à une fraude (numéro d'un tiers) | `updatePhone` exige le mot de passe côté appli seulement | Le profil n'établit rien ; changement de lien exige OTP du nouveau numéro + preuve ancienne |
| Super-admin crée un profil avec un uid existant | Prise de compte via reset | Aucune (règle `create: isAdmin()`) | Refuser les créations directes (passage serveur) ; le reset exige un lien existant pour ce numéro ; refus si l'uid est dans `admins` ou a un autre profil |
| Utilisateur avec plusieurs profils | Mauvaise cible, escalade | Gardes de suppression ; aucun contrôle au reset | Détection en transaction ; exemption à double approbation |
| Deux uid, même numéro | Déni / ambiguïté | `Plusieurs comptes` (révèle) | Index d'unicité ; refus uniforme ; anomalie |
| Numéro réattribué par l'opérateur | Prise du reset (ou de la connexion avec A) | Aucune | B seul (pas de connexion SMS) ; ancienneté et revalidation ; notification du titulaire ; délai |
| Numéro modifié entre vérification et reset | Course | Aucune | Le reset relit le lien et son `version` en transaction ; jeton usage unique |
| Administrateur utilise le parcours ordinaire | Prise du compte | Aucune | Lecture `admins/{uid}` obligatoire, refus uniforme |

## 9. Impacts applicatifs

- **Flutter** : écrans de récupération (`reset_password_page`, `generic_forgot_password_page`) conservent leur interface ; nouveau message d'erreur uniforme ; nouvel écran de confirmation de numéro à la connexion (demande OTP, une fois). Écrans `updatePhone` (clients, livreurs) à remplacer par un appel fonction avec OTP. Sans ces changements, la liaison progressive ne démarre pas.
- **Web** : formulaires de candidature inchangés ; tableau de bord admin web non examiné pour `sellers` [NE].
- **Firebase Auth** : option B n'ajoute aucun fournisseur ; option A ajouterait le fournisseur téléphone (impacts de connexion).
- **Firestore** : trois collections `write:false` ; règle `sellers` : retrait de `phone` du sous-admin (autorisation distincte) ; créations directes de profils par le super fermées au profit du serveur.
- **Cloud Functions** : `passwordReset.js` (protégé), `manageSellerAccount.js` (audit HMAC), nouvelle fonction de liaison/remplacement, éventuellement inventaire en lecture.
- **SMS** : envoi d'OTP par Firebase Phone Auth (coût, quotas, **panne signalée** `INTERNAL (13)/39`, état actuel inconnu [H]) ; aucun SMS applicatif supplémentaire sauf décision d'alerte au titulaire.
- **Comptes sans Auth** (pharmacie, artisan) : liaison par secret + OTP ; chemin support conservé.
- **Utilisateurs légitimes** : pendant `pending_confirmation`, la voie SMS reste utilisable avec contrôles renforcés ; en cas de refus, support via l'action administrative existante. Aucun compte supprimé ni désactivé.

## 10. Tests nécessaires

Règles : sous-admin refusé sur `phone` (après fermeture) ; titulaire ne modifie plus `phone` en direct (si adopté) ; création directe par super refusée ; collections de liens `write:false` pour tous ; non-régression de la fiche vendeur par la fonction. Fonctions : liaison (OTP récent, mot de passe récent, `auth_time`), unicité (course entre deux comptes), remplacement avec/ sans ancien facteur, délai de 72 h, révocation, audit à empreinte HMAC, rotation de `keyId`, usage unique, `profile.phone` ≠ lien ⇒ refus, doublon ⇒ refus uniforme, admin ⇒ refus, compte fermé/anonymisé. Migration : inventaire à blanc déterministe sur jeu synthétique (aucune donnée réelle), classes de §7, idempotence, aucune écriture (espion sur Firestore/Auth). Intégration (émulateur Auth `demo-*`) : sessions après changement, comportement Phone Auth/liaison, unicité de numéro entre comptes. Mutations sur chaque garde. **Aucun test sur production.**

## 11. Risques résiduels

Données historiques de `phone` potentiellement falsifiées avant tout lien ; recyclage de numéros ; dépendance à Phone Auth et à sa disponibilité/coût ; poivre HMAC : gestion et rotation ; sous-admins gardent la possibilité de **gêner** (changement de numéro via fonction) même sans pouvoir détourner ; propriétaires GCP et super-admins compromis gardent un pouvoir de contournement (limite incompressible) ; périmètre d'écrans non audités (web admin, `service_providers`, `pharmacies`, `real_estate_agents`) ; l'audit actuel de `manageSellerAccountCF` ne porte pas l'empreinte du nouveau numéro.

## 12. Conditions préalables à l'implémentation

1. Autorisation de modifier `passwordReset.js`, `index.js` (protégés), `manageSellerAccount.js` et les règles Firestore.
2. Décision A / B / mixte (§5) et politique « un uid = un rôle » (L4.10/L4.10.1).
3. Gestion du poivre HMAC (stockage, rotation) conforme à la politique de secrets ; état de Secret Manager.
4. Autorisation de lecture (préproduction/production) pour l'inventaire à blanc, définition du format du rapport hors dépôt, revue humaine désignée.
5. Vérification de l'état réel de Phone Auth (panne) et du comportement Firebase (émulateur Auth).
6. Décision sur le changement de `phone` par le titulaire (OTP obligatoire ?) et sur le canal de notification.
7. Fermeture des écritures directes de profils par un super (lié à L4.11) ; deux super-admins joignables.
8. Calendrier de déploiement distinct, sans déploiement non demandé.

## 13. Compte rendu final

- **Fichiers inspectés** : `firestore.rules` (blocs `sellers`, `clients`, `fleet_owners`, `boulangeries`, `ekbine_agents`, `restaurant_owners`, recherche des champs `phone`), `functions/manageSellerAccount.js` (en-tête, validation, mise à jour, audit), `functions/adminPartnerAccounts.js` (profils autorisés), `functions/fleetDriverCreation.js`, `realestate.js`, `pharmacyOwnerIdentity.js`, `partnerFirstLogin.js` (recherches), `lib/services/auth_service.dart` (`updatePhone`), `lib/screens/client/profil_client.dart`, `driver/driver_profil.dart`, `admin/admin_sellers_page.dart`, `admin_partner_account_service.dart`, `admin_boulangeries_page.dart`, `admin_restaurants_page.dart`, `admin_pharmacies_page.dart`, `web/pages/drivers_page.dart`, `merchants_page.dart`, `rules-tests/sub-admin-s1-s3.rules.test.js`, recherches transversales `phone`/`phoneNumber`/`phone_number`.
- **Risques confirmés** : écriture directe de `phone` par un sous-admin sans trace ; changement de `phone` par le titulaire sans OTP ; absence d'unicité ; absence de lien serveur numéro↔compte ; audit sans empreinte.
- **Non vérifiables** : données réelles (doublons, double rôle), état de Phone Auth, comportement Firebase (liaison, recyclage, sessions), règles `pharmacies`/`service_providers`/`real_estate_agents`/`livreurs` en détail, écrans web d'administration, configuration MFA de production.
- **État Git final** : voir vérification ci-après : HEAD `d65c8f0`, index vide, stash 0, 35 suivis modifiés, 166 non suivis (165 + ce rapport).
- **Disque** : aucun nettoyage ; `C:` ≈ 7,98 Go libres au début de la mission.
- Aucun code, test, règle ou configuration modifié ; aucun accès Firebase ; aucun build ; L4.11 non commencée ; `account_phone_bindings` non implémentée.

Arrêt : en attente d'une nouvelle autorisation explicite.
