# Sécurité financière — Phase A (local, NON déployé, NON commité)

Branche `finalisation/az-express`. Rien n'est déployé : fonctions, règles et application restent à décider (voir « Dépendances »).

## Corrigé localement

| Réf. | Faille | Correction |
|---|---|---|
| F2 | Annulation client par écriture directe `status: cancelled` (`order_wait_screen.dart`) : aucun remboursement d'une commande payée par wallet. | L'écran appelle `FirestoreService.cancelOrder` → `cancelOrderCF` (propriétaire, livrée/annulée/récupérée refusées, remboursement `budget + shoppingBudget` si wallet payé, statut posé dans la même transaction). Garde anti double-tap `_cancelling`. |
| F3 | `approveRecharge` : batch sans lecture du statut (double crédit, demande rejetée approuvable), écriture wallet cross-user depuis Flutter. | `adminApproveRechargeCF` (`functions/adminWalletRequests.js`) : transaction, statut `pending` requis, montant et compte lus dans la demande (jamais fournis par l'appelant), preuve `recharge_request_<id>`, audit. Super-admin seul. |
| F4 | `approveWithdrawal` débitait une seconde fois : `initiateWithdrawal` (`index.js`, transaction de création) a déjà fait `wallet: balance - amount`. L'onglet admin « à traiter » ne contient que des `pending_manual`. | `adminApproveWithdrawalCF` : `pending_manual → processed`, **aucun solde touché**, refuse un retrait remboursé ou non en attente. Sens des statuts inchangé. |
| F5 | Journaux `clients/*` et `sellers/*/wallet_transactions` créables avec type, montant et identifiant libres. | Clients : `purchase` seulement, identifiant automatique (20 car.), champs historiques, montant entier 0..1 000 000 (forme exacte des 4 écrans blanchisserie/colis/eau/restaurant). Vendeurs : création réservée au super-admin (aucun écrivain dans le code). |
| F8 | Collision d'identifiants avec les `wallet_transactions` FeexPay. | Aucun crédit possible (voir tests) ; règles inchangées pour le niveau supérieur (4 champs `ekbine_payment`). |

## Non modifié (décision ou information manquante)

- **F1 prix libre / F6 baisse du solde côté client** : fermés seulement quand les anciens parcours auront un remplacement serveur.
- **Ekbine** (`ek_service.cancelOrder`) et **réservations d'événements** (`event_service.cancelReservation`) : annulation directe autorisée par les règles, politique de remboursement non établie dans le code → à décider avant de toucher.
- `rejectWithdrawal` / `rejectRecharge` restent côté Flutter (super-admin ; `rejectWithdrawal` est déjà transactionnel et idempotent).
- Bouton « Réessayer » de `order_wait_screen.dart` (réécrit `status: pending` en direct) : probablement refusé par les règles ; hors périmètre financier.

## Dépendances avant déploiement

1. Fonctions avant règles : `adminApproveRechargeCF`, `adminApproveWithdrawalCF` (0,5 CPU × 1 chacune), plus `quoteDeliveryCF` / `createOrderFromQuoteCF` (0,5 × 2). Quota Cloud Run à libérer.
2. Nouvelle version de l'application avant de s'appuyer sur les nouvelles fonctions d'administration (l'ancienne appelait Firestore directement).
3. Règles F5 : une ancienne version qui écrirait le journal client avec d'autres champs (`provider`, `txId`) ou un autre type ne pourrait plus le faire (la commande, elle, est créée avant).

## Tests

`functions/test/adminWalletRequests.test.js` (12), `orderActions.test.js` (+4 « F2 »), `feexpayPayments.test.js` (+3 « F8 »), `financialConcurrency.emulator.test.js` (4, concurrence réelle), `rules-tests/wallet-ledger.rules.test.js` (10, dans `npm run test:rules`).

## Complément (avant commit)

- Une seconde voie d'approbation de recharge existait dans `admin_boutique_page.dart` (onglet « Recharges »), avec la même faille F3 : la transaction ne relisait pas le statut de la demande. Elle appelle désormais `adminApproveRechargeCF`.
- Les demandes existantes portent `userId` (écran client) ou `clientId` (cet ancien onglet) : la fonction lit `userId ?? clientId`.
- Aucun appelant Flutter de `createRechargeRequest` n'existe dans le code actuel : les demandes viennent de documents déjà présents ou d'une version plus ancienne.
