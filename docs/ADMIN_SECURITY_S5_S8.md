# Failles S5 à S8 : audit et corrections locales (2026-10-30)

**Statut : tout est local, rien n'est déployé.** Aucune donnée de production modifiée. Complète `docs/ADMIN_PERMISSIONS_AUDIT.md` (S1–S4).

Relevé de production (lecture seule, 2026-10-30) : collection `admins` = **1 compte, rôle `super`, 0 sous-admin**. Aucune permission de sous-admin n'est donc en circulation : les durcissements ci-dessous n'ont aucun effet sur un compte existant.

## S5 — Notifications aux administrateurs

**Constat** : 4 envois vers « tous les admins actifs », sous-admins compris : alerte de sécurité (`logSecurityEvent`), nouvelle demande livreur, nouveau prestataire de services, nouvelle inscription événementielle.

**Correction** : `functions/adminPermissions.js` → `adminNotificationTokens(admins, permission)` et table `NOTIFICATION_PERMISSION`.

| Événement | Reçu par |
|---|---|
| Alerte de sécurité | super-admin seul |
| Nouvelle demande livreur | super + sous-admins `demandes` |
| Nouveau prestataire de services | super + sous-admins `services` |
| Nouvelle inscription événementielle | super + sous-admins `eventiel` |

Le super-admin actif reçoit tout (comme avant). Inactif, rôle inconnu, `permissions` mal formé, jeton absent ou trop court : ignorés. Les jetons sont dédoublonnés.
**Tests** : `adminPermissions.test.js` (7 cas de routage + un test qui interdit les jetons admin « bruts » dans le code) et `eventNotifications.test.js` (sous-admin avec / sans `eventiel`).
**Limite** : les autres notifications (clients, livreurs, partenaires) ne sont pas concernées. Aucune notification admin n'existe hors de ces 4.

## S6 — Données des livreurs : audit, PAS de changement de règle

**Constat** : `livreurs/{id}` est lisible par tout utilisateur connecté, **anonymes inclus** (`main.dart` ouvre une session anonyme pour la carte). Le document contient `wallet` et d'autres champs privés ; Firestore ne sait pas masquer un champ : tout lecteur reçoit le document entier. Une requête `where isOnline == true` renvoie donc les portefeuilles de tous les livreurs en ligne.

**Inventaire des lectures** (25 requêtes dans 20 fichiers) :

| Usage | Fichiers | Champs réellement utilisés | Qui lit |
|---|---|---|---|
| A. Livreur assigné, par identifiant | `customer_tracking_screen`, `tracking_service`, `realtime_tracking_service`, tableaux de bord boulangerie / pharmacie / vendeur | nom, téléphone, photo, note, `lat`/`lng`, `isOnline` | client, partenaire concerné |
| B. Livreurs en ligne (liste) | `live_marker_cache.onlineDriversFeed`, `destination_picker` | `lat`, `lng`, `heading`, `isOnline` | client, **visiteur anonyme** |
| C. Son propre document | `driver_*`, `driver_location_service`, `auth_service`, `driver_login` | tout | le livreur |
| D. Administration | `admin_dashboard`, `drivers_page`, `admin_drivers_ranking`, `admin_recharge_page` | liste, compteurs, wallet | admin |
| Dispatch / attribution | Cloud Functions (Admin SDK) | tout | serveur, non concerné par les règles |

**Pourquoi je n'ai pas modifié la règle** : toute restriction de lecture casserait aujourd'hui B (carte des visiteurs et estimation de proximité) et, selon sa forme, A (suivi, contact du livreur). Les anciennes versions installées de l'application cesseraient aussi de fonctionner. Ce n'est pas un correctif de règle, c'est une migration.

**Plan sûr (à valider)** :
1. Nouveau document public `driver_public/{uid}` : prénom, photo, `lat`, `lng`, `heading`, `isOnline`, `isAvailable`, note, type de véhicule. Jamais `wallet`, téléphone, jetons, pièces KYC. Règle : lecture utilisateur connecté, écriture propriétaire sur ces seules clés. (Additif : aucun effet sur l'existant.)
2. Application livreur : double écriture `livreurs` + `driver_public` (pas de fonction déclenchée à chaque ping GPS : coût et quota Cloud Run). Rattrapage des livreurs existants par script serveur.
3. Application client / partenaire : usages A et B lisent `driver_public`. Le téléphone du livreur assigné, nécessaire au client, vient de la commande (copie posée à l'attribution par le serveur) : **à vérifier / ajouter**.
4. Attendre l'adoption de la nouvelle version (version minimale imposée).
5. Seulement ensuite : `livreurs` en lecture propriétaire + admin (permission `livreurs`) ; les anciennes versions échoueraient à ce moment-là.

Aucune règle, fonction ni écran n'a été modifié pour S6. Risque ouvert : tout utilisateur de l'application peut lire les portefeuilles des livreurs en ligne.

## S7 — OTP administrateur : l'audit corrige mon constat initial

**Constat corrigé** : mon audit précédent décrivait un OTP vérifié côté client. C'était l'ancien mécanisme. Le code actuel (`admin_login.dart`, `admin_otp_page.dart`) utilise l'**authentification multi-facteur native de Firebase** (TOTP en premier, SMS en repli) : le code est vérifié par Firebase (expiration, limitation des essais, usage unique), pas par l'application. Aucune fonction ni écran ne lit plus `otpHash`, `otpCode`, `otpExpiry` ni `otpAttempts`. Il n'y a donc pas de « vérification OTP maison » à remplacer.

**Défauts réels trouvés et corrigés (localement)** :
1. **Règle `admins`** : le propriétaire pouvait encore écrire ces 4 champs OTP sur son document. Surface morte mais inutile → retirée (seuls `fcmToken` et `photoUrl` restent permis).
2. **Aucun contrôle serveur du second facteur** : un compte admin pas encore enrôlé obtient un jeton valide avec le seul mot de passe, et les règles / fonctions ne regardent pas `firebase.sign_in_second_factor`. `adminGuards.js` : `enforceAdminSecondFactor`, variable `ADMIN_MFA_MODE` :
   - `off` : rien ; **`log` (défaut)** : journalise `admin_without_second_factor` (uid et rôle seulement, une fois par compte et par instance), ne bloque pas ; `enforce` : refuse toute opération admin sans second facteur.
   - Le système existant n'est **pas** désactivé et rien ne bloque aujourd'hui. Le passage en `enforce` demande : (a) de vérifier dans les journaux que le super-admin passe bien avec second facteur, (b) de définir `ADMIN_MFA_MODE=enforce` dans `functions/.env` (non fait).
   - Les règles Firestore n'ont pas été durcies de la même façon (un oubli d'enrôlement verrouillerait l'administration entière) : à envisager après la période d'observation (`isActiveAdmin()` + `sign_in_second_factor`).

Expiration, limitation des tentatives, anti-réutilisation, contrôle d'identité : fournis par Firebase MFA. Journalisation : les connexions admin et la mise en place du second facteur ne sont pas journalisées côté serveur aujourd'hui, seule l'absence de second facteur l'est désormais (point à décider : un `audit_logs` des connexions admin demande une fonction appelée après connexion).
**Tests** : `adminGuards.test.js` (modes off / log / enforce, aucune donnée sensible dans la trace, `requireSuperAdmin` / `requireAdminPermission` en enforce), `rules-tests/admin-doc-s7-s8.rules.test.js`.

## S8 — Permissions

- **Liste officielle** : `PERMISSION_KEYS` (30 clés) dans `functions/adminPermissions.js`, identique à `adminPermissionKeys` (Flutter) et à `adminPermissionsKnown()` (règles) : **test de parité** sur les trois.
- **Clés inconnues refusées** : `createSubAdmin` (avant toute création de compte), règle `admins` (création et changement de la liste ; un compte historique portant une clé obsolète reste désactivable).
- **Toutes les clés utilisées par les fonctions et les règles sont officielles** (test de balayage du code).
- **`auto_moto`** : exigée par `moderateVehicleEntity`, absente de l'interface et de la liste Flutter (un sous-admin qui l'aurait reçue serait **rejeté à la connexion** : `adminPermissionKeys` ne la contenait pas). Ajoutée à la liste officielle et à la liste Flutter. **Non** ajoutée à l'écran d'attribution et le menu « Auto & Moto » reste réservé au super-admin, car les règles de modération des véhicules ne sont pas ouvertes à une permission. Aucun profil ne la contient. Elle n'est attribuée à personne.
- Aucune permission n'est attribuée automatiquement à un sous-admin existant (il n'y en a d'ailleurs aucun en production).
- **Limite** : les profils (voir `docs/ADMIN_PERMISSION_PROFILES.md`) sont des définitions ; tant que les règles ne sont pas ouvertes par permission, une partie des écrans reste vide pour un sous-admin.
