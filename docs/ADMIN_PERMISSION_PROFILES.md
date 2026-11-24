# Trois profils de sous-administrateurs : matrice des droits (proposition)

**Définitions seulement.** Rien n'est appliqué en production ; aucun sous-admin n'existe aujourd'hui (relevé du 2026-10-30 : 1 admin, rôle `super`). Définies dans `functions/adminPermissions.js` (`PROFILES`), testées (clés officielles, pas de recouvrement, aucune clé financière).

## 1. Contenu des profils

| Profil | Permissions | Finalité |
|---|---|---|
| **PARTENAIRES** | `demandes`, `demandes_resto`, `demandes_vendeurs`, `demandes_boulangeries`, `demandes_pharmacies`, `restaurants`, `boulangeries`, `pharmacies`, `boutique`, `flottes`, `ekbine`, `services`, `eventiel`, `locations`, `residences` | Demandes d'inscription et gestion des partenaires |
| **OPÉRATIONS** | `livreurs`, `commandes`, `carte`, `classement`, `zones`, `tricycle` | Commandes, livreurs, livraisons en cours |
| **SUPPORT** | `support`, `sos` | Réclamations, assistance, incidents |

**Réservé au super-administrateur (jamais dans un profil)** : `gains`, `recharges`, `cash_marchand`, `purger`, `anti_fraude`, `ai_dashboard`, `auto_moto`, et tout ce qui n'a pas de clé : retraits, wallets, commissions, tarifs, règlements, suppression de comptes, QR, facturation, gestion des admins, `app_config`, journaux d'audit et de sécurité.

## 2. Ce qui fonctionne réellement aujourd'hui, côté serveur

Une permission ouvre une entrée de menu (confort) ; la **protection** est dans les règles et les fonctions. Constat par permission (voir `ADMIN_PERMISSIONS_AUDIT.md` §4) :

| Profil | Fonctionne de bout en bout | Écran visible mais données / actions refusées par les règles |
|---|---|---|
| PARTENAIRES | création et gestion de comptes partenaires (`manageAdminPartnerAccount`), fiche et activation vendeur (`manageSellerAccountCF`, journalisée), abonnements / VIP (`manageProfessionalSubscription`, voir point 3), mots de passe pharmacie, comptes services | listes de demandes, boutique, flottes, événementiel, E-Kbine (commandes), restaurants / pharmacies / boulangeries (écritures) |
| OPÉRATIONS | `tricycle` complet ; annulation de commande (`commandes`) | liste des commandes, carte live, classement, zones (écritures), suspension de livreur |
| SUPPORT | — | tickets, signalements, SOS (lecture et résolution refusées) |

**Conséquence** : tant que la phase « lecture par permission » n'est pas faite (étape 3 de `ADMIN_PERMISSIONS_AUDIT.md` §5), ces profils sont **sûrs mais partiellement inopérants**. C'est volontaire : fermé par défaut.

## 3. Abonnements et VIP : décision appliquée (locale, non déployée)

Dans `manageProfessionalSubscription` :
- **Super-admin seul** : `activateStandard`, `activateVip`, `activateTrial` (gratuits ou payants) et le **renouvellement du compte d'un tiers** (débit du wallet d'autrui).
- **Sous-admin de la catégorie** (clé `demandes_vendeurs`, `restaurants`, `boulangeries`, `ekbine`, `flottes`) : `suspend` et `deactivateVip` seulement (protection, aucun avantage payant).
- **Propriétaire** : renouvelle son propre compte (débit de son wallet), comme avant.
Tests : `functions/test/professionalSubscriptions.test.js` (aucune activation ni débit par un sous-admin, suspension permise, super-admin intact).
Effet côté écrans : un sous-admin qui toucherait un bouton d'activation reçoit un refus serveur ; les écrans d'abonnement ne sont de toute façon pas rattachés au profil via des règles ouvertes.

## 4. Matrice des droits (cible)

L = lecture, E = écriture de champs de fiche / statut, F = fonction serveur journalisée, — = refusé, S = super-admin seul.

| Domaine | PARTENAIRES | OPÉRATIONS | SUPPORT |
|---|---|---|---|
| Demandes d'inscription (livreurs, restos, vendeurs, boulangeries, pharmacies) | L + décision (F) | — | — |
| Comptes partenaires (fiche, activation) | L + E limité (F) | — | — |
| Création de compte partenaire | F | — | — |
| Abonnement / VIP | suspension (F) ; activation gratuite : S | — | — |
| Commandes | — | L ; annulation (F) | L ciblée (à décider) |
| Livreurs (liste, statut) | — | L ; suspension avec motif (F) | — |
| Carte live / suivi | — | L | — |
| Réclamations, signalements, SOS | — | — | L + résolution (statut, note) |
| Wallets, recharges, retraits, commissions, gains, cash | S | S | S |
| Tarifs, `app_config`, zones tarifaires | S | S | S |
| Suppression de compte, purge, QR | S | S | S |
| Gestion des admins, journaux d'audit / sécurité | S | S | S |

## 5. Pour appliquer un profil (plus tard, avec votre validation)

1. Valider §3 (abonnements).
2. Implémenter la lecture par permission dans les règles (collections de chaque profil), avec tests générés depuis la table.
3. `createSubAdmin` / écran « Gestion des admins » : présélection d'un profil (cases cochables ensuite). Aucun compte existant n'est modifié.
4. Activer `ADMIN_MFA_MODE=enforce` avant de créer le premier sous-admin.
