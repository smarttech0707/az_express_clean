---
paths:
  - firestore.rules
  - storage.rules
  - firestore.indexes.json
  - rules-tests/**
  - FIRESTORE_RULES.md
  - FIRESTORE_SCHEMA.md
---

# Règles Firestore / Storage — invariants

Références : `FIRESTORE_RULES.md` (matrice), `FIRESTORE_SCHEMA.md` (champs), `docs/claude/INDEX.md` (prompts 22, 53, 57, 73, 74, 80). Ne jamais déployer sans demande explicite ; valider par `firebase deploy --only firestore:rules --dry-run`.

- `unchanged(field)` utilise `.get(field, null)` des deux côtés (un champ absent ne doit pas lever d'erreur d'évaluation). Ne pas revenir à l'accès direct `data[field]`.
- `orders` (état après le durcissement du Prompt 80) : pas de branche permettant au client d'assigner `driverId` ; le livreur ne modifie pas `isPaid` (seulement `deliverOrderCF` / `payOrderFromWalletCF`) ; la branche vendeur a `unchanged('status')`. Ne jamais rouvrir ces branches.
- Collections Cloud-Function-only (`allow write: if false`) : `audit_logs`, `security_events`, `rate_limits`, `ai_conversations`, `ai_pending_actions`, `ai_user_memory`, `ai_reminders`, `request_logs`, `wallet_reconciliation_findings` (lecture super-admin).
- Wallet : le propriétaire ne peut que diminuer son `wallet`. Aucune écriture cross-user.
- Le tableau `permissions` des sous-admins n'est PAS appliqué dans les règles (seul le filtrage d'écrans Flutter) : un sous-admin actif a l'accès `isAdmin()` complet. Ne pas supposer le contraire.
- Formulaires publics (site vitrine, utilisateur non authentifié) : `driver_applications`, `partner_applications`, `contact_messages`, `pharmacie_requests`, `account_deletion_requests` — création publique avec validation stricte de forme, lecture admin seulement. La connexion anonyme automatique n'existe pas sur le web.
- KYC Storage : `driver_selfies`, `driver_id_photos`, `fleet_selfies`, `fleet_id_photos` en lecture propriétaire/admin. `driver_photos/{id}` reste lisible par tout utilisateur authentifié (photo de profil vue par le client).
- Les pharmacies n'utilisent pas Firebase Auth (mot de passe haché via Cloud Function, `pharmacie_credentials`).
- `restaurants/{id}/menu` est la **seule** source des menus (sous-collection permissionnée). Ne pas utiliser la collection racine `menus` (aucune règle) ni `restaurants/{id}/menus` (obsolète, admin-only).
- Index composites : toute requête égalité + `orderBy` sur un autre champ exige un index dans `firestore.indexes.json` (échec silencieux sinon, ex. `boutique_orders` clientId + createdAt).
- Chat Marketplace : `chatId` de la forme `mp_<productId>_<uid>` ; la règle utilise `mp_.*_` + uid ; les messages portent `senderUid`.
- `rules-tests/` n'a pas été exécuté localement faute de Java ; le job CI `firestore-rules` les exécute.
