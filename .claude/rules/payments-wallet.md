---
paths:
  - functions/orderActions.js
  - functions/dispatch.js
  - functions/tarifService.js
  - functions/walletReconciliation.js
  - functions/azia/tools/**
  - lib/services/tarif_service.dart
  - lib/services/delivery_service.dart
  - lib/services/firestore_service.dart
  - lib/services/feexpay_service.dart
  - lib/screens/client/*wallet*
  - lib/screens/client/suivi_commande.dart
  - lib/screens/client/boutique_page.dart
  - lib/screens/admin/admin_cash_settlement_page.dart
---

# Paiements, wallet, tarification, commissions — invariants

Sources détaillées : `docs/claude/INDEX.md` (prompts 22, 28, 46-49, 51-52, 54, 64, 75-77, 80). Les chiffres de l'archive sont datés.

## Principes
- Aucun crédit/débit cross-user depuis Flutter. `payOrderFromWalletCF`, `cancelOrderCF`, `deliverOrderCF`, `payBoutiqueOrderCF`, `payBoutiqueOrderCashCF`, `refundExpiredBoutiqueOrderCF` (`functions/orderActions.js`) font ces écritures côté serveur. Les méthodes `FirestoreService` correspondantes délèguent à ces CF.
- Un client peut seulement **diminuer** son propre `wallet` ; un livreur aussi (commission à l'acceptation). Toute augmentation passe par une Cloud Function.
- Toujours : transaction, lectures avant écritures, plafond anti-solde-négatif (`Math.min(montant, solde)`), `logAudit`.
- `wallet_transactions` est append-only pour les non-admins. Remboursement = crédit wallet interne, jamais un remboursement fournisseur.
- `feexPayWebhook` : secret dans l'URL (`wh_secret`), idempotent, statuts normalisés. FeexPay agrège Orange/MTN/Moov/Wave (`feexpayOperatorCode()`) : ne pas créer d'abstraction multi-fournisseurs. Le prestataire s'appelle **FeexPay** (jamais CinetPay).

## Commissions
- Commission livreur (`config/commission`, paliers 100/200 FCFA) : **prélevée uniquement à l'acceptation** (`acceptOrder`), remboursée à l'annulation. `deliverOrderCF` ne la prélève plus (décision Prompt 75).
- Marketplace et Boutique (`PREPAID_PARTNER_TYPES = seller, boutique`) : vendeur payé 100 % à la création ; `deliverOrderCF` ne crédite pas le partenaire pour ces types.
- Restaurant/pharmacie : partenaire crédité à la livraison, **seulement si `order.isPaid === true`**. Ekbine : `fee = 0`.
- Pharmacie wallet : le client n'est pas débité à la création ; règlement unique post-livraison via `payOrderFromWalletCF`. `deliverOrderCF` ne crédite pas le livreur d'une commande wallet non payée.
- Cash : le livreur garde le cash. Pour une commande cash avec `sellerId`, `merchantCashSettled:false` est posé et suivi dans `admin_cash_settlement_page.dart` (pas de wallet touché).

## Annulation
- Un seul code : `cancelOrderTx` / `cancelOrderPostTx` dans `functions/orderActions.js`, utilisé par `cancelOrderCF`, `autoExpireOrders` (logique équivalente) et l'outil AZ IA `cancel_order`. Ne jamais recréer une 6ᵉ implémentation.
- Marketplace (`sellerType:'seller'`) : le vendeur est débité à l'annulation (plafonné). Boutique : exclue (le vrai paiement est sur `boutique_orders`, document séparé).
- Boutique : `payBoutiqueOrderCF` crée `boutique_orders` + une course de livraison de 500 FCFA (`isPaid:false`, ne représente que le trajet). Depuis la facturation séparée (`docs/MARKETPLACE_BOUTIQUE_BILLING.md`) : le client paie produits + 500, le vendeur reçoit les produits, `budget` = frais de livraison (`amountsVersion:1`, `productAmount`, `deliveryFee`, `totalAmount`) et le livreur est crédité des frais à la livraison.

## Tarification livraison
- Source unique : `TarifService.compute()` (Dart) = `functions/tarifService.js` (Node). Modifier les deux + tests (`test/services/tarif_service_test.dart`, `functions/test/tarifService.test.js`).
- Zone centrale (≤ 8 km autour de 6.7273, -3.4961) : standard 500 jour / 1000 nuit ; **express 1000 jour / 1500 nuit**. Nuit à partir de 20 h, refus des commandes > 10 km après 21 h.
- `orders.budget` est écrit une seule fois à la création, lu partout ensuite : ne pas recalculer.
- AZ IA ne choisit jamais un prix : `create_delivery_order`/`create_pharmacie_order` le calculent via `tarifService.js`.
- `lib/services/delivery_service.dart` (ancien moteur) ne sert plus que pour `calculateDistance`/`calculateETA`.
- Le prix est toujours calculé côté client pour les écrans Flutter : une revalidation serveur n'existe pas (voir known-issues).

## Pièges déjà rencontrés
- Deux fonctions individuellement correctes qui doublent un débit/crédit quand on les combine : tracer le cycle de vie complet (création → acceptation → livraison → annulation) avant de modifier.
- Un double-tap crée deux commandes : garder le flag de chargement sur chaque bouton d'achat.
- Les tests de `orderActions` utilisent un faux Firestore ; un test qui valide un comportement erroné doit être corrigé, pas contourné.
