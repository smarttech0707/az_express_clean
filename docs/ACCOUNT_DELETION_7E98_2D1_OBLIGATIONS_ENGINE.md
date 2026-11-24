# Mission 7E-98 — Lot 2D-1 : module `accountObligations.js`

Date : 2026-11-09 · HEAD `d65c8f00bdcedba570a66a5633913db46127be3d`, branche `finalisation/az-express`, index vide. Mission locale : **deux fichiers créés** (module + tests) et ce rapport ; aucun `git add`/staging/commit/amend/push/pull/merge/rebase/reset, aucun déploiement, aucune commande distante, aucun secret, FeexPay non activé, aucune suppression. **Aucun des trois inspecteurs, ni `index.js`, ni 2C, ni P3, ni `professionalSubscriptions.js` n'est modifié.** Production `az-express-b0469` intouchée ; émulateurs de l'utilisateur non touchés (aucun émulateur nécessaire).

## 1. Structures financières réellement trouvées (lues dans le code, aucune invention)
| Donnée | Où elle est écrite | Valeurs / forme réelles |
|---|---|---|
| `orders.status` | state machine | actifs `pending, broadcast, assigned, accepted, picked_up` ; terminaux `delivered, cancelled, expired, completed, refunded, failed_refunded, failed, rejected, closed` (union des deux ensembles `TERMINAL` des inspecteurs) |
| `orders.isPaid`, `paymentMethod` | `buildPayOrderFromWallet`, `deliverOrderCF` | `paymentMethod` : `'wallet'` ou `'cash'` ; pharmacie wallet : `isPaid:false` jusqu'au règlement post-livraison ; `boutique` : `isPaid` reste `false` (le paiement vit sur `boutique_orders`) ; `amountsVersion:2` : réglée à la création |
| `orders.settlementHold` (bool) / `settlementStatus` | `driverTransfer.js:487`, `deliverOrderCF`, `transferSettlement` | `settlementStatus` ∈ `pending_admin_review`, `cash_pending`, `settled` |
| `orders.heldDriverEarning` (entier) | `buildPayOrderFromWallet:130`, `deliverOrderCF` | montant retenu ; sans autre champ de statut : réglé quand `settlementStatus === 'settled'` |
| `orders.deliveryFeeHold` | `cancelOrderTx:451`, `adminBilling:192` | `{amount, status}` ; `status` ∈ `pending_admin_review`, `resolved` |
| `orders.cancelRequestAfterPickup` | `recordPickedUpCancelRequest`, `adminOrderDisputes:362`, `orderActions:810` | `status` ∈ `pending_admin_review`, `resolved_delivery_confirmed`, `resolved_without_closure`, `resolved_cancelled`, `resolved_partial_refund` |
| `orders.cashRemittance` | `deliverOrderCF:1006`, `partnerOrderActions` | `status` ∈ `pending`, `declared`, `confirmed`, `disputed`, `resolved` ; `amountDue`, `amountConfirmed`, `resolution.finalAmount` ; vue `describeCash` : `confirmed` réglé seulement si `amountConfirmed ≥ amountDue` |
| `orders.merchantCashSettled` (bool) | `deliverOrderCF:995`, `partnerOrderActions` | `false` posé à la livraison cash avec marchand non boutique ; `true` après confirmation / régularisation |
| `orders.cashPayment` | `cashPayment.js` | `status` ∈ `confirmed`, `non_payment_declared`, `unknown` ; `verification` ∈ `not_required`, `pending_review`, `confirmed_unpaid`, `refuted` |
| `orders.refundPending`, `needsReview`, `paymentStatus` | inspecteurs existants | repris tels quels (`paymentStatus === 'pending'`) |
| `transfer_settlements/{orderId}` | `settlementDocument`, `transferSettlement.js` | `status` ∈ `pending_review` (création), `cash_pending`, `settled` ; `driverIds[]`, `holderDriverId`, `clientId`, `totalPaid`, `method`, `cash.status` |
| `reconciliation_flags/{id}` | `orderActions`, `partnerOrderActions`, `adminOrderDisputes`, `driverRelease`, `ekbineOrders` | `status` ∈ `open`, `recorded` (reliquat arrêté par décision), `reviewed` (revue de `cash_payment_review`), `resolved` (testé par `partnerOrderReconciliation`) ; champs partie : `clientId`, `driverId`, `partnerId`, `sellerId` (`pharmacieId` toléré) ; montant `amount` / `theoreticalAmount` / `amountDueToPartner` |
| Commissions | `acceptOrderCF` / `cancelOrderTx` | `commissionStatus` `charged`/`refunded` : aucune obligation propre ; seule trace d'un défaut = flag `commission_untraced` (repris par la règle générique des flags) |

**Corrections à ma spécification 7E-97** (constatées en lisant les écrivains réels) : `transfer_settlements.status` n'a **pas** de valeur `rejected` ni `approved` (seulement `pending_review`, `cash_pending`, `settled`) ; le critère « statut ∉ {settled, rejected} » est donc remplacé par « statut ∈ {pending_review, cash_pending} = ouvert, `settled` = clos, tout autre = ambigu ». Les flags `recorded` ne sont **pas** une obligation ouverte (voir §3). Rien d'autre du §4.2 de 7E-97 n'est modifié.
**Divergence signalée** : `partnerOrderReconciliation.hasFlag` considère ouvert tout flag `status !== 'resolved'` (donc aussi `recorded` et `reviewed`) ; ce module est volontairement moins strict pour ces deux statuts décidés, faute de quoi `cash_shortfall` (« jamais débité automatiquement ») bloquerait l'anonymisation **à vie**.

## 2. Conception
`functions/accountObligations.js` (424 lignes ; tests : 335 lignes) : **prédicat pur**. Aucun `require`, aucune horloge (`Date.now`, `new Date`), aucun accès Firestore/réseau/`process`, aucune écriture, entrées jamais mutées (testé avec entrées gelées), sortie déterministe et triée.
Interface :
```js
evaluateAccountObligations({
  role,        // 'client' | 'livreur'|'driver' | 'pharmacie'|'seller'|'boulangerie'|'restaurant'|'partner'
  ids,         // identifiants du compte tels qu'ils figurent sur les documents (uid, identifiant d'établissement)
  orders,      // [{id, data}] — collection orders, DÉJÀ lus par l'appelant
  settlements, // [{id, data}] — transfer_settlements (client ou livreur de la chaîne) ; non requis pour un partenaire
  flags,       // [{id, data}] — reconciliation_flags
  truncated,   // { orders, settlements, flags } — true si la lecture a atteint sa limite
  legacyAbsentIsPaid, // 'block' (défaut) | 'ignore'
}) → { version, blocking, code, obligations[], retained[], summary:{open,review,ambiguous,retained,byType} }
```
Autres exports : `buildFinancialSnapshot(result, {atMs})`, `normalizeRole`, constantes `TYPES`, `STATE`, `CODE`, `TERMINAL_STATUSES`, `ACTIVE_STATUSES`, `MAX_SNAPSHOT_ITEMS`. Aucune requête supplémentaire n'est imposée à l'appelant au-delà de ce que les inspecteurs lisent déjà (+ `transfer_settlements` et `reconciliation_flags` plafonnés, prévus en 2D-2).
Chaque élément : `{type, state, blocking, source, refId, orderId, party, amount, currency:'XOF', status, reason}`.

## 3. Statuts et règles de décision
États : `open` (à régler) · `review` (retenu pour revue humaine) · `ambiguous` (indéterminé, fail-closed) · `retained` (décision finale conservée, **non bloquant**). `blocking = state ≠ retained`. `code` : `none` / `financial_obligation_pending` / `financial_state_ambiguous` (si au moins un ambigu).
| Type | Condition d'ouverture | Rôles | Clos / non bloquant |
|---|---|---|---|
| `operation_open` | statut actif (`pending…picked_up`) | tous | statut terminal |
| `refund_pending`, `review_open`, `payment_pending` | `refundPending === true`, `needsReview === true` (revue), `paymentStatus === 'pending'` | tous | faux / absent |
| `unpaid_delivered_wallet` | `delivered` ∧ wallet ∧ `isPaid === false` ∧ ni boutique ni v2 (montant = `budget`) | tous | `isPaid === true`, cash, boutique, v2, annulée |
| `settlement_held` | `settlementHold === true` ou `settlementStatus ∈ {pending_admin_review, cash_pending}` | client, livreur | `settled` |
| `held_driver_earning` | `heldDriverEarning > 0` ∧ `settlementStatus !== 'settled'` | client, livreur | 0 ou `settled` |
| `delivery_fee_held` | `deliveryFeeHold.status === 'pending_admin_review'` | client, livreur | `resolved` |
| `post_pickup_cancel_open` | `cancelRequestAfterPickup.status === 'pending_admin_review'` (revue) | client, livreur | 4 statuts `resolved_*` |
| `cash_remittance_open` | `pending`/`declared` (ouvert), `disputed` (revue), `confirmed` avec `amountConfirmed < amountDue` (reliquat) | livreur, partenaire | `confirmed` complet, `resolved` valide |
| `merchant_cash_unsettled` | livrée cash + `sellerId` non boutique + `merchantCashSettled === false` sans `cashRemittance` | livreur, partenaire | `true` |
| `cash_payment_review` | `cashPayment.verification === 'pending_review'` (revue) | tous | `confirmed_unpaid`, `refuted`, `not_required` |
| `transfer_settlement_open` | `pending_review` (revue), `cash_pending` (ouvert) ; le compte est livreur de la chaîne / détenteur / client | client, livreur | `settled` |
| `reconciliation_flag_open` | `status === 'open'` ∧ compte partie au flag (revue) | tous | `reviewed`, `resolved` |
| `reconciliation_recorded` | `status === 'recorded'` — **conservé, non bloquant** (`retained`) | tous | — |
Les identifiants et montants (entiers sûrs, sinon `null`) sont repris dans l'élément ; la devise est toujours `XOF`.

## 4. Politique fail-closed (motifs documentés dans `reason`)
Sont **ambigus et bloquants** : entrée non objet ; rôle inconnu ; identifiants du compte absents ; liste absente (`orders`/`flags` toujours ; `settlements` pour client et livreur) ; liste non tableau ; liste déclarée tronquée (`*_truncated`) ; entrée sans `id` ; document sans lien avec le compte (`order_not_linked_to_account`, `settlement_not_linked_to_account`, `flag_not_linked_to_account` — un défaut d'appel ne doit jamais être lu comme « rien à régler ») ; statut de commande inconnu ou illisible ; drapeaux `refundPending`/`needsReview`/`paymentStatus`/`isPaid`/`settlementHold` de mauvais type ; `settlementStatus`, `deliveryFeeHold.status`, `cancelRequestAfterPickup.status`, `cashRemittance.status`, `cashPayment.status/verification`, statut de règlement ou de flag **inconnus** ; contradictions (`settled` + `settlementHold:true` ; `merchantCashSettled:true` sans remise confirmée ; remise confirmée au-dessus du dû ; résolution invalide ; non-paiement déclaré sans revue ; remise absente sur commande cash v2 livrée ; flag ouvert sans partie) ; `heldDriverEarning` invalide ; méthode de paiement inconnue sur commande livrée non payée ; exception inattendue (capturée par document, puis globalement). Le module **ne lève jamais** d'exception.
**Compromis assumé** : une commande wallet livrée **sans champ `isPaid`** est ambiguë par défaut (`deliverOrderCF` la traite comme non payée, `cancelOrderTx` comme payée). `legacyAbsentIsPaid: 'ignore'` existe pour que 2D-2 puisse la tolérer après mesure sur des données synthétiques de préproduction — **à ne pas activer sans cette mesure** (risque de faux positifs permanents inverse : faux négatifs).

## 5. Proposition de `financialSnapshot` (non écrite dans Firestore)
Cible proposée : champ additif `financialSnapshot` de `account_deletions/{uid}` (aucun changement de schéma existant, écrit par le moteur en 2D-2 à la décision de blocage et à l'anonymisation). `buildFinancialSnapshot(result, {atMs})` produit, sans donnée personnelle :
```
{ version:1, atMs, blocking, code, currency:'XOF',
  counts:{open, review, ambiguous, retained},
  items:[{type, state, source, refId, orderId, party, amount, currency, status, reason}],   // ≤ 50
  truncated, omitted }
```
Permet de retrouver : type d'obligation, identifiant de commande/règlement (`orderId`, `refId`), montant, devise, rôle du compte (`party`, sans nom ni uid de contrepartie), statut financier observé, motif du blocage, date de constat (`atMs`, fournie par l'appelant — le module ne lit pas l'horloge). Borné à 50 éléments avec `truncated`/`omitted` ; résultat illisible ⇒ snapshot bloquant ambigu. Testé : aucun nom, téléphone ni adresse ne se retrouve dans le JSON, même présents dans les commandes d'entrée.

## 6. Tests et résultats (Node v22.23.4)
`functions/test/accountObligations.test.js` : **24 tests, 24 réussis, 0 échec, 0 ignoré**. Couverture des 12 cas demandés (aucune obligation ; livrée non payée ; payée ; `settlementHold` ; `heldDriverEarning` ; remise de fonds ; `transfer_settlements` ; plusieurs obligations ; statut inconnu ; données incohérentes ; obligation résolue ; profil sans données financières avec la distinction « liste fournie vide » / « liste absente »), plus : frais retenus, annulation après récupération, cash legacy et v2, non-paiement déclaré, flags `open`/`recorded`/`reviewed`/`resolved`, entrées invalides, listes tronquées, drapeaux des inspecteurs repris, `isPaid` absent, déterminisme (ordre mélangé, entrées gelées, JSON identique), snapshot (structure, absence de données personnelles, borne), pureté du source (aucun `require`, horloge, Firestore…), non-branchement (aucun inspecteur, `index.js`, `orderActions.js`, `accountAdmission.js` ne mentionne le module).
Incident de mise au point : un test (n° 7) a d'abord échoué parce que je supposais qu'un règlement fourni à un **partenaire** serait ignoré ; le module le traite à juste titre comme défaut d'appel (ambigu). J'ai corrigé l'**attente du test**, pas le module, et documenté ce comportement.
**Non-régression** : fichiers voisins `accountDeletionHardening`, `manualAccountDeletion`, `accountDeletionSupport`, `accountQuarantineGuards`, `accountQuarantineIndex`, `orderActions`, `transferSettlement`, `partnerOrderFinancial` : **197 tests, 197 réussis, 0 échec**. Suite complète non relancée (aucun fichier existant modifié : elle n'apporterait aucune preuve supplémentaire). Aucun émulateur, aucun test de production.

## 7. Fichiers
Créés (non suivis) : `functions/accountObligations.js` ; `functions/test/accountObligations.test.js` ; ce rapport. Modifiés : **aucun**. Vérifications : `accountDeletion.js`, `accountDeletionScope.js`, `manualAccountDeletion.js`, `index.js` ne contiennent aucune occurrence de `accountObligations` ; le diff de `functions/index.js` reste le seul hunk P3 (2 lignes) ; Commits 1, 1B, 2 inchangés ; `git diff --check` propre sur les deux fichiers.

## 8. Limites
- Périmètre : collection `orders` uniquement ; `boutique_orders`, `blanchisserie_orders`, `eau_boissons_orders`, `ekbine_orders` gardent la règle existante des inspecteurs (statut non terminal, `needsReview`, …).
- Le module juge des documents qu'on lui donne : il ne garantit pas que l'appelant a lu **toutes** les commandes d'un compte (d'où `truncated`) ; un livreur de la chaîne d'un transfert n'apparaît pas dans les commandes lues par `driverId` : le contrôle passe par `settlements` (requête `driverIds array-contains`).
- Les statuts ont été relevés dans le code écrivant ; des documents historiques de production aux valeurs différentes sont traités comme ambigus (bloquants) : calibrage à mesurer en préproduction (faux positifs).
- `commissionStatus` n'est pas une obligation en soi (aucune représentation d'une commission « en attente » hors flags) ; non inventé.
- Aucune preuve de production ; le comportement avec de vraies données n'est pas démontré.

## 9. Points à intégrer en 2D-2
1. Appeler `evaluateAccountObligations` depuis `inspect()` (`accountDeletion.js`, client/livreur), `readDeletionScope()` (partenaires) et `financialBlocker()` (`manualAccountDeletion.js`) **sans refaire** les requêtes de commandes déjà exécutées ; passer `ids` (uid + identifiant d'établissement) et `truncated` (limite 201 déjà utilisée).
2. Ajouter deux lectures plafonnées : `transfer_settlements` (`driverIds array-contains uid` pour le livreur ; `clientId == uid` pour le client) et `reconciliation_flags` (par `clientId`, `driverId`, `partnerId`/`sellerId`) ; marquer `truncated` si la limite est atteinte.
3. Mapper `code` → raison de dossier (`financial_obligation_pending` / `financial_state_ambiguous`), conserver `reviewRequired:true`, `nextAttemptAt = now + RETRY_MS` (reprise horaire déjà en place) ; ne pas compter ces blocages dans `MAX_ATTEMPTS`.
4. Écrire `financialSnapshot` (via `buildFinancialSnapshot`, `atMs = clock()`) dans `account_deletions/{uid}` au blocage et à l'anonymisation, sans changer le schéma existant ; ajouter `blockedSince` (additif).
5. Décider `legacyAbsentIsPaid` après mesure sur données synthétiques ; conserver `'block'` par défaut.
6. Remplacer progressivement les trois copies de la règle `TERMINAL/refundPending/needsReview/paymentStatus` par le module (en gardant exactement les mêmes statuts de blocage pour les cas qui existaient déjà).
7. Tests 2D-2 : inspecteurs bloqués/repris pour chaque type, anonymisation refusée avec obligation apparue pendant la quarantaine, émulateur pour la reprise (matrice 7E-97 n° 21 et 22).
8. Ne pas mélanger avec 2C, P3, E-Kbine, `professionalSubscriptions.js`, `held_for_review`, scripts de déploiement. Quota Cloud Run non confirmé : aucun déploiement.

## 10. État Git
HEAD `d65c8f00bdcedba570a66a5633913db46127be3d` · index vide · aucun nouveau commit · aucun push · aucun déploiement · worktree : les 90 entrées d'avant préservées + `functions/accountObligations.js`, `functions/test/accountObligations.test.js` et ce rapport (non suivis).

## Verdict
**2D-1 IMPLÉMENTÉ ET TESTÉ — PRÊT POUR REVUE**
Le prédicat pur est écrit, ses 24 tests passent sous Node 22.23.4 et aucun comportement existant n'a changé (197 tests voisins verts, aucun inspecteur touché). Réserves : calibrage sur données réelles (faux positifs) et décision `legacyAbsentIsPaid` pour 2D-2 ; aucune preuve de production. Aucun staging, aucun commit, aucun push, aucun déploiement. En attente d'une nouvelle autorisation humaine.
