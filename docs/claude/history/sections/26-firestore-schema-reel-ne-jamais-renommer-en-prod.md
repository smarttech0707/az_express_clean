## Firestore — schéma réel (ne jamais renommer en prod)

Le schéma effectivement en production diffère d'un schéma "manuel" idéal — c'est le schéma qui fait foi, pas une liste de collections théorique :
- Pas de collection `users` unique : le rôle est déterminé par la collection qui contient le document (`clients/{uid}`, `livreurs/{uid}`, `sellers/{uid}`, `restaurants/{uid}`, `pharmacies/{uid}`, `boulangeries/{uid}`, `ekbine_agents/{uid}`, `admins/{uid}` avec un champ `role: 'super'|'sub'`).
- Commandes livraison/courses/restaurant/pharmacie/marketplace partagent toutes la collection `orders` (polymorphe via `type`/`sellerType`) — pas de `shopping_orders` séparée.
- Ekbine a ses propres collections (`ekbine_orders`, `ekbine_agents`, `ekbine_chats/{orderId}/messages`).
- Le solde wallet est un champ (`wallet`) sur le document du rôle lui-même, pas une collection `wallet_accounts` séparée. `wallet_transactions` (top-level) + sous-collections par utilisateur existent déjà pour l'historique.
- `marketplace_products`, `support_tickets`, `audit_logs`, `security_events`, `rate_limits`, `zones_livraison`, `commissions` existent déjà et sont audités (voir mémoire projet `project_firestore_audit_fixes`, `project_security_audit`).
- Immobilier (`properties`) n'existe pas encore — voir le plan `real_estate_listings`/`real_estate_agents` déjà défini dans la mémoire `project_az_ia_integration`.

**Renommer/réorganiser ce schéma pour coller à un modèle "propre" théorique casserait toutes les Cloud Functions, règles Firestore, index et écrans existants — à ne jamais faire sans une décision explicite et un plan de migration dédié.** Les nouvelles collections doivent avoir un nom clair et cohérent avec l'existant, sans obligation de suivre une liste figée.

