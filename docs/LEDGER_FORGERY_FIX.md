# Journal financier du livreur — correctif de la preuve de commission forgeable (local, NON déployé)

Statut : **appliqué dans le dépôt de travail, rien n'est déployé, aucun commit.** Contexte : audit du 31 octobre 2026
(`docs/PUBLICATION_1_0_10_PLAN.md`, rapport de préparation de mise en production).

## La faille

`livreurs/{id}/wallet_transactions` était créable par son propriétaire avec n'importe quel identifiant et des champs
`type` / `amount` / `orderId` libres. Les fonctions `cancelOrderTx` ([orderActions.js](../functions/orderActions.js)) et
`releaseOrderBeforePickupCF` ([driverRelease.js](../functions/driverRelease.js)) lisaient le document
`commission_<commande>_<livreur>` comme preuve d'un prélèvement réel pour toute commande sans `commissionStatus`, et créditaient
`amount` sans plafond. Un livreur pouvait donc fabriquer la preuve (montant arbitraire), accepter la course (branche directe
`assigned → accepted`, encore ouverte) puis faire annuler ou libérer la course : crédit de son propre wallet, argent créé.
Reproduit sur émulateur et faux Firestore avant correctif (crédit de 100 000 FCFA).

## Correctif (3 couches)

1. **Règles** — `livreurs/{id}/wallet_transactions`, création par le propriétaire (`firestore.rules`) : uniquement une ligne
   `type == 'commission'`, identifiant automatique du SDK (`[A-Za-z0-9]{20}`), montant entier 0..1000, champs
   `type, amount, description, orderId, createdAt` (plus `provider` ni `txId`), `description` ≤ 300 caractères, `orderId`
   ≤ 128 caractères ou `null`, `createdAt` de type timestamp. Les identifiants lus comme preuve (`commission_…`,
   `commission_refund_…`, `earning_…`, `fee_hold_commission_…`) et les types `earning` / `refund` / `recharge` / `withdrawal`
   deviennent impossibles à écrire côté client. `update` reste refusé, `delete` admin seul, lecture propriétaire / admin.
2. **Fonctions** — [commissionProof.js](../functions/commissionProof.js) (pur, testé) : une preuve ancienne n'est retenue que si
   type `commission`, même commande, montant entier > 0, sans champ `provider`/`txId`, et **montant ≤ commission du barème pour
   le budget de la commande**. Sinon aucun remboursement automatique : la course est annulée / libérée normalement et un
   signalement `reconciliation_flags/<commande>_commission_untraced…` est écrit avec `proofRejectReason`
   (`proof_missing`, `proof_type_invalid`, `proof_order_mismatch`, `proof_amount_invalid`, `proof_client_shape`,
   `proof_exceeds_policy`, `expected_unknown`) pour vérification par le super-admin. Les commandes tracées par `acceptOrderCF`
   (`commissionStatus: 'charged'`) n'utilisent jamais le journal : seul `commissionAmount` compte.
3. **Idempotence** (inchangée, verrouillée par test) : un remboursement pose `commissionStatus: 'refunded'` dans la même
   transaction ; un rejeu ne crédite pas deux fois.

Toutes les fonctions qui annulent passent par `cancelOrderTx` (`cancelOrderCF`, `autoExpireOrders`, AZ IA `cancel_order`,
`adminBilling`, `adminOrderDisputes`) : elles héritent du correctif sans autre changement.

## Compatibilité avec les anciennes versions

- Ancienne application livreur : sa seule écriture dans ce journal est `FirestoreService._logTransaction`
  (`.add({type:'commission', amount, description, orderId, createdAt})`) : identifiant automatique, type `commission` →
  **toujours acceptée** (test « ancien flux client conservé »). Aucune autre écriture client dans `livreurs/*/wallet_transactions`
  (vérifié dans `lib/`). Les écrans lisent le journal sans l'écrire.
- Commandes antérieures à `acceptOrderCF` : remboursement conservé si la preuve est cohérente (montant ≤ barème). Si la
  configuration `config/commission` a augmenté la commission depuis, une preuve plus petite reste remboursée à son montant ;
  si elle a été **réduite** depuis le prélèvement (preuve > barème actuel), le remboursement automatique est bloqué et signalé :
  c'est voulu (argent jamais créé).
- Documents forgés déjà présents en production (avant correctif) : non supprimés (aucune écriture de production) ; plafonnés au
  barème. Contrôle à faire avant déploiement : lecture seule des `commission_*` du journal sans `commissionStatus` sur la commande.

## Acceptation directe `assigned → accepted` (mission 3)

Non fermée. Le correctif est préparé et validé en test : [DRIVER_ACCEPT_CLOSED_RULES.diff](DRIVER_ACCEPT_CLOSED_RULES.diff)
(régénéré sur les règles actuelles : une branche remplacée par `false`), vérifié par
`rules-tests/driver-accept-closed.rules.test.js`. Plan, critères et conséquences : [DRIVER_ACCEPT_RULE_MIGRATION.md](DRIVER_ACCEPT_RULE_MIGRATION.md).

Conséquences d'une fermeture pour les anciennes versions : toute version qui accepte par écriture Firestore directe reçoit
`permission-denied` et ne peut plus accepter de course (aucun blocage possible par `config/app_versions`, lu seulement par les
versions récentes). Fermer seulement quand `legacyAcceptanceReport.js` rapporte 0 acceptation ancienne sur 14 jours.

Risque résiduel tant qu'elle est ouverte (après ce correctif) : un client livreur modifié peut accepter sans payer la commission
(manque à gagner AZ, **pas de création d'argent** : le remboursement sans preuve fiable est désormais bloqué).

## Risques résiduels

- `wallet_transactions` des **clients** et des **vendeurs** reste créable par le propriétaire (affichage seulement : aucune
  fonction ne l'utilise comme preuve de remboursement ; `walletReconciliation` signalerait l'écart). À durcir dans une passe séparée.
- Documents forgés antérieurs : plafonnés mais non purgés.
- `config/commission` modifiable par l'admin : un barème réduit bloque (et signale) un remboursement légitime ancien.

## Tests (régression)

- `rules-tests/driver-ledger.rules.test.js` (9) — dans `npm run test:rules`.
- `functions/test/commissionProof.test.js` (4), `functions/test/orderActions.test.js` (5 « RÉGRESSION »),
  `functions/test/driverRelease.test.js` (4 « RÉGRESSION »).
