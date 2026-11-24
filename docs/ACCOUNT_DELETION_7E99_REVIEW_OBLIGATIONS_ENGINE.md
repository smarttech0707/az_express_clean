# Mission 7E-99 — Revue indépendante de `accountObligations.js` (avant 2D-2)

Date : 2026-11-09 · HEAD `d65c8f00bdcedba570a66a5633913db46127be3d`, branche `finalisation/az-express`, index vide. **Revue uniquement : aucun code modifié**, aucun `git add`/staging/commit/amend/push/pull/merge/rebase/reset, aucun déploiement, aucune commande distante, aucun secret, FeexPay non activé, aucune suppression ; production `az-express-b0469` intouchée ; émulateurs de l'utilisateur non touchés (aucun émulateur lancé). Artefacts d'exécution hors dépôt, dans le scratchpad : un script de sondes et une copie du module pour des mutations. Fichiers revus : `accountObligations.js` (sha256 `fc5674e7…`) et `test/accountObligations.test.js` (`d5d505c5…`), inchangés pendant la revue.
Preuves : **[V]** lu dans le code · **[P]** sonde exécutée contre le module · **[M]** mutation · **[T]** test.

## 1. Résumé exécutif
Le module est **bien conçu, pur, déterministe, et ses tests sont réels** (24/24, 197/197 voisins ; 16 mutations sur 16 détectées). La revue y trouve cependant **des défauts fail-open ou de fuite à corriger avant l'intégration 2D-2** :
| # | Gravité | Constat | Preuve |
|---|---|---|---|
| **C1** | **Haute** | `truncated` n'est pris en compte que s'il vaut exactement `{orders:true}` : `truncated:true`, `'true'`, `1`, `{orders:1}`, une faute de frappe de clé ⇒ lecture plafonnée traitée comme **absence d'obligation** | [P] 5 variantes ⇒ `blocking:false` |
| **C2** | **Haute** | Commande **v2 wallet livrée avec `isPaid !== true`** exclue sans condition ⇒ aucun blocage, alors que `partnerOrderReconciliation` la signale en `V2_WALLET_NOT_MARKED_PAID` (haute) | [P] ; [V] reconciliation l. 78 |
| **C3** | Moyenne | `reason` et `status` reprennent du **texte libre du document** (`needs_review:${reviewReason}`, `flag_open:${type}`, `status`) sans borne ni liste blanche : un téléphone ou un nom y atteint le `financialSnapshot` (3 037 caractères observés) | [P] |
| **C4** | Moyenne | `buildFinancialSnapshot` **lève une exception** si `summary` manque, et recopie `result.blocking` : un résultat altéré `blocking:false` avec des obligations produit un snapshot « non bloquant » | [P] |
| **C5** | Moyenne | Règles de flags trop larges : `recorded` toujours conservé sans trace de décision ; `reviewed` accepté pour **tout** type de flag alors que le code ne l'écrit que sur `cash_payment_review` ; **aucun code n'écrit jamais `resolved`** ni ne ferme les autres flags `open` ⇒ ces flags bloqueraient **à vie** | [V] [P] §5 |
| **C6** | Moyenne | Ensemble `TERMINAL` du module (avec `closed`) plus large que ceux de `inspect()` et `financialBlocker()` ⇒ l'intégration **relâcherait** silencieusement ces deux inspecteurs ; codes de raison à conserver | [V] §8 |
| **C7** | Basse | Champs typés à `null` traités comme absents ; documents en double comptés deux fois | [P] |
Verdict : **2D-1 VALIDÉ SOUS RÉSERVES — CORRECTIONS NÉCESSAIRES** (C1 à C6 avant 2D-2 ; C7 recommandé).

## 2. Audit des statuts financiers (écrivains réels)
| Donnée | Origine (écrivain) | Statuts réellement écrits | Sortie vers l'état final | Règle du module | Verdict |
|---|---|---|---|---|---|
| `orders.status` | rules + CF | `pending, broadcast, assigned, accepted, picked_up, delivered, cancelled, expired` (+ `completed/refunded/failed*/rejected` côté inspecteurs) | transitions de la state machine | actif ⇒ ouvert ; inconnu ⇒ ambigu | **OK** ; `closed` n'est écrit nulle part dans `orders` (C6) |
| `orders.isPaid` | `OrderModel.toMap` (toujours écrit depuis le commit `a7f8423`, 2026-06-17), CF de devis (`deliveryQuote:222`, `catalogQuote:209`, `partnerOrderQuote:320`), outils AZ IA (`isPaid: paymentMethod === 'wallet'`), `payBoutique*` (`false`, `type:'boutique'`), `payOrderFromWallet:127` (`true`), `deliverOrderCF:797` (`true` si `markCashPaid`) | booléen | `true` posé par le paiement | `false` + wallet + livrée ⇒ ouvert | **OK** hors C2 ; §7 |
| `settlementHold` / `settlementStatus` | `driverTransfer:487`, `deliverOrderCF` (l. 1035, 1085), `payOrder` (l. 130), `transferSettlement` (l. 132, 145, 185) | `pending_admin_review`, `cash_pending`, `settled` (aucune autre valeur écrite) | `transferSettlement` ⇒ `settled`, `settlementHold:false` | `hold` ou statut ouvert ⇒ ouvert ; `settled`+`hold:true` ⇒ ambigu | **OK** (états cohérents avec les écritures : en cash, `cash_pending` laisse `hold:true`) |
| `heldDriverEarning` | `payOrder:130`, `deliverOrderCF` (l. 866, 905, 947) | entier ; **jamais remis à zéro** | clos quand `settlementStatus === 'settled'` | `>0` ∧ non `settled` ⇒ ouvert | **OK** |
| `deliveryFeeHold` | `cancelOrderTx:451` | `status:'pending_admin_review'` ; `adminBilling:192` ⇒ `'resolved'` | `adminBilling` (super-admin) | idem | **OK** |
| `cancelRequestAfterPickup` | `recordPickedUpCancelRequest` (l. 206), `deliverOrderCF` (l. 810), `adminOrderDisputes` (l. 357-363) | `pending_admin_review`, `resolved_delivery_confirmed`, `resolved_without_closure`, `resolved_cancelled`, `resolved_partial_refund` | décision super-admin | `pending…` ⇒ revue | **OK** (les 5 valeurs sont exactement celles du code) |
| `cashRemittance` | `deliverOrderCF:1006` (`pending`), `partnerOrderActions` | `pending, declared, confirmed, disputed, resolved` ; montants cumulés `amountHandedOver/amountConfirmed` ≤ `amountDue` | confirmation intégrale du partenaire, ou `resolveCashRemittance` (super-admin) ⇒ `resolved` | voir règle | **OK** : `confirmed` partiel = ouvert (cohérent avec `describeCash`) |
| `merchantCashSettled` | `deliverOrderCF:995` (`false`), `partnerOrderActions` (`true`), **`admin_cash_settlement_page.dart:53` (écriture admin directe, commandes non v2)** | booléen | page admin / CF | `false` sans remise ⇒ ouvert | **OK** (voie de sortie existante) |
| `cashPayment` | `cashPayment.js`, `deliverOrderCF`, `partnerOrderActions` | `status` : `confirmed, non_payment_declared, unknown` ; `verification` : `not_required, pending_review, confirmed_unpaid, refuted` | `reviewCashNonPayment` (super-admin) | `pending_review` ⇒ revue | **OK** ; cas client : `confirmed_unpaid` non bloquant (§9-R4) |
| `transfer_settlements` | `settlementDocument` (via `deliverOrderCF` et `payOrder`) | **`pending_review`, `cash_pending`, `settled`** (actions `approve`, `confirmCashReceipt`, `closeCash` ; **pas de `reject`**) | `transferSettlement` | ouvert / clos / ambigu | **OK** ; la spécification 7E-97 (`rejected`, `approved`) était fausse, déjà corrigée par 7E-98 |
| `reconciliation_flags` | 8 écrivains (§5) | `open`, `recorded`, `reviewed` ; **`resolved` jamais écrit** | voir §5 | voir §5 | **À corriger (C5)** |

## 3. Cohérence avec les écrivains : points d'attention supplémentaires
- **Commande wallet non payée, non boutique, non v2** : source réelle de l'obligation = pharmacie et boulangerie *standard* (`isPaid:false` à la création même en wallet, règlement par `payOrderFromWalletCF`) ; `pharmacie_garde.dart:524` et `boulangerie_order_page.dart:248` écrivent bien `isPaid:false` **[V]** — le module les traite correctement.
- **Boulangerie standard** : `partnerOrderReconciliation` note que les articles ne sont « jamais encaissés » (seuls les frais le sont) : écart métier hors périmètre de ce module.
- **Chaîne de livreurs** : un livreur d'un transfert n'est pas `driverId` de la commande finale ; seul `transfer_settlements.driverIds` le relie ⇒ la lecture des règlements est indispensable en 2D-2 (§8).

## 4. Statuts non couverts
Aucun statut d'écriture non listé n'a été trouvé pour les champs ci-dessus. Les valeurs `pending_payment`, `in_progress`, `awaiting_transfer` existent dans le code mais appartiennent à d'autres collections ou à `transfer_settlements.cash.status` (sous-champ, couvert par le statut parent) ; elles sortent du périmètre `orders`.

## 5. Divergence `reconciliation_flags` : analyse et règle proposée
**Constat sur le code [V]** — qui écrit quoi :
| Type de flag | Écrivain | Statuts écrits | Chemin de fermeture |
|---|---|---|---|
| `cash_payment_review` | `deliverOrderCF:1017`, `partnerOrderActions:271` | `open` | `reviewCashNonPayment` (`partnerOrderActions:288`) pose `status:'reviewed'` + `decision` + `verification` (`confirmed_unpaid` ou `refuted`) |
| `cash_shortfall` | `partnerOrderActions:362` (`resolveCashRemittance`) | **`recorded`** + `amount`, `decidedBy`, `requestId` | aucun : « reliquat arrêté par décision, jamais débité automatiquement » |
| `commission_untraced` | `orderActions:422`, `driverRelease:134` | `open` | **aucun** |
| `partner_credit_missing` | `orderActions:898` | `open` | **aucun** |
| `seller_review`, `driver_advance_unreimbursed` | `adminOrderDisputes:509,518` | `open` | **aucun** (« à traiter hors de cet outil ») |
| `ekcancel_*`, `ekconfirm_*` | `ekbineOrders:265,319` | (non relu ici) | aucun relevé |
Aucune écriture de `status:'resolved'` n'existe dans `functions/` pour cette collection ; `lib/` et `firestore.rules` n'y touchent pas (collection non exposée, Admin SDK seulement). **`resolved` n'est donc qu'un jeton de convention** (testé par `partnerOrderReconciliation.hasFlag`), jamais produit par le code.
**Ce que `hasFlag` signifie réellement** : la divergence est **plus étroite qu'annoncée**. `hasFlag` n'est appelée qu'une fois (`partnerOrderReconciliation:141`, type `partner_credit_missing`) pour décider d'**atténuer une anomalie** quand un flag explicatif existe ; `!== 'resolved'` y signifie « un flag non clos existe ». Ce n'est pas une définition générale de « dû ouvert » : les deux modules n'ont pas à être alignés ligne à ligne.
**Signification de chaque état** : `open` = à traiter ; `recorded` = **décision administrative consignée**, le reliquat existe encore mais « arrêté » (la remise de fonds est passée en `resolved` et `merchantCashSettled:true`, donc réglée du point de vue du système) — **ce n'est pas seulement « enregistré »**, il porte l'auteur et le `requestId` de la décision ; `reviewed` = **revue terminée** pour `cash_payment_review` uniquement, mais `confirmed_unpaid` laisse un résiduel porté par `cashRemittance` (anomalie `V2_CASH_UNPAID_CONFIRMED_UNSETTLED` tant que la remise n'est pas `resolved`) ; `resolved` = jamais écrit.
**Règle cohérente proposée (fail-closed)** :
1. **Seuls clos sans condition** : `resolved` **avec trace** (`resolvedBy` chaîne ∧ `resolvedAtMs` entier). Sans trace ⇒ ambigu.
2. **`reviewed`** : clos **uniquement** pour `type === 'cash_payment_review'` ∧ `verification ∈ {refuted, confirmed_unpaid}` ∧ `decision` présente ; le résiduel de `confirmed_unpaid` est porté par l'évaluation de `cashRemittance` (déjà faite). Pour tout autre type ⇒ ambigu.
3. **`recorded`** : conservé **non bloquant (`retained`)** seulement si `decidedBy` (chaîne) ∧ `requestId` (chaîne) ∧ `amount` entier ≥ 0 ; sinon ambigu. Justification : la décision *est* la clôture voulue par le code ; bloquer à vie supprimerait toute voie de sortie.
4. **`open`** : bloquant. **Mais** pour tous les types sans chemin de fermeture (`commission_untraced`, `partner_credit_missing`, `seller_review`, `driver_advance_unreimbursed`, ekbine) l'anonymisation resterait bloquée tant qu'on n'a pas de moyen de les clore. Deux options : (a) **prérequis 2D-2 recommandé** : une action super-admin minimale `resolveReconciliationFlag` (`flagId`, `requestId` idempotent, justification ≥ 10 caractères, audit) qui pose `resolved`, `resolvedBy`, `resolvedAtMs` ; (b) à défaut, procédure support manuelle documentée (console, mêmes champs) — le compte reste utilisable, le blocage est sûr mais **non automatiquement levable**. Ne **pas** requalifier ces flags en non bloquants sans décision métier (ils peuvent représenter de l'argent dû au livreur ou au vendeur).
5. Statut inconnu, casse différente (`Open`), absence de statut ⇒ ambigu (déjà le cas : sonde `Open` ⇒ ambigu).
**Écarts actuels du module** : `recorded` retenu sans trace [P] ; `reviewed` accepté pour `commission_untraced` [P] ; `resolved` accepté sans trace. À corriger (C5).

## 6. Lectures tronquées (protocole pour 2D-2)
**Constat [P]** : le module ne détecte une troncature que si l'appelant passe `truncated:{orders:true}` strictement ; tout autre forme est silencieusement ignorée (C1) — c'est le défaut le plus grave de la revue car il transforme une lecture plafonnée en « aucune obligation ».
**Correction demandée** : (1) `truncated` doit être un objet dont les clés sont dans `{orders, settlements, flags}` et dont les valeurs sont des **booléens** ; toute autre forme ⇒ ambigu `truncated_invalid`. (2) Mieux : remplacer l'indicateur déclaratif par une **preuve de couverture** — `reads: { orders: {limit, size}, settlements: {limit, size}, flags: {limit, size} }` — et laisser le module calculer `size >= limit` ⇒ tronqué ; une liste sans `reads` correspondant ⇒ ambigu (l'appelant ne peut plus « oublier » de signaler).
**Protocole de lecture (conforme à l'existant des inspecteurs)** :
- Plafond **`LIMIT = 201`** par requête (`accountDeletion.js:6`), interprété comme « 200 + sentinelle » : `snap.size >= LIMIT` ⇒ lecture incomplète ⇒ blocage `history_requires_manual_review` (comportement actuel, à conserver) ; idem pour `related.length >= 200`.
- **Pas de pagination** dans l'inspection : elle s'exécute dans une transaction Firestore (`tx.get(query)`) dont la cohérence serait rompue par une pagination ; un compte à plus de 200 documents d'un type reste donc bloqué pour revue manuelle (déjà vrai aujourd'hui, non aggravé).
- **Erreur de lecture** : toute exception dans la transaction annule celle-ci (aucune anonymisation), remonte à `process()` qui applique `failurePatch` (compteur `attempts`, plafond `MAX_ATTEMPTS = 6` ⇒ `max_attempts_reached`, reprise par l'assistance) — fail-closed [V].
- **Prévention d'anonymisation** : `inspect()` est ré-exécuté **dans la transaction même** qui pose `isDeleted` (`accountDeletion.js:124-134`) ; la couverture est donc évaluée à cet instant. Pour la voie partenaire, `readDeletionScope` l'est aussi (`partnerAccountDeletion.js:62`). **Exception** : `financialBlocker` (voie manuelle, `manualAccountDeletion.js:77-98`) lit **hors transaction** — voir §8.
- Volume : 7 requêtes × 201 existantes + 2 ou 3 nouvelles × 201 ≈ 1 800 documents lus au pire par passage, deux passages (quarantaine, anonymisation) : acceptable, à mesurer en préproduction (durée de transaction).

## 7. Commandes historiques sans `isPaid`
- **Écritures actuelles** : le champ est **toujours écrit** — `OrderModel.toMap` (booléen non optionnel, introduit le 2026-06-17), toutes les CF de création, les outils AZ IA, `payBoutique*`, et les formulaires bruts `boulangerie_order_page`/`pharmacie_garde`. **La règle Firestore l'exige à la création** : `firestore.rules` l. 720-733 n'accepte que `isPaid == false` ou `isPaid == true` avec débit lié ; une valeur absente fait échouer la condition. Les écritures Admin SDK (CF) l'écrivent toutes.
- **Variantes qui peuvent légitimement l'omettre** : aucune dans le code actuel. Seules les commandes **antérieures à l'introduction du champ** (premier commit du champ dans `order_model.dart` : `a7f8423`, 2026-06-17), ou écrites hors code (console, jeux de test, `test-env/.snapshots`), peuvent en manquer.
- **Migration historique** : aucune (`scripts/` ne référence `isPaid` que pour `restaurant-v2-pilot` en lecture ; aucun backfill) [V].
- **Comportements divergents sur la valeur absente** : `deliverOrderCF` la traite comme **non payée** (aucun crédit livreur), `cancelOrderTx` comme **payée** (`isPaid !== false` ⇒ remboursement) ⇒ aucune interprétation unique n'est sûre.
- **Doit-elle toujours bloquer ?** Oui, **par défaut** (comportement actuel `'block'`). Une règle de compatibilité n'est justifiable que si une **preuve complémentaire** établit le paiement : par exemple, une ligne `payment`/`purchase` pour la commande dans `clients/{uid}/wallet_transactions` (les mêmes journaux que `partnerOrderReconciliation` utilise). **`legacyAbsentIsPaid:'ignore'` ne doit pas être activé** sans cette preuve ; recommandation : le **supprimer** de l'API (option dangereuse, sans usage justifié) ou le remplacer par un paramètre `paidOrderIds` (ensemble d'identifiants prouvés payés par le journal) fourni par l'appelant.
- **Protocole de mesure (préproduction, données synthétiques, jamais la production)** :
  1. Environnement : projet de préproduction ou émulateur `demo-*` isolé ; comptes et commandes **synthétiques** uniquement.
  2. Jeu de données : matrice `variante` (cash, wallet standard, pharmacie, boulangerie standard, boutique, v2 wallet, v2 cash, transfert) × `isPaid` (`true`, `false`, absent, `null`) × `status` (`delivered`, `cancelled`, actif) × journal wallet (présent/absent).
  3. Exécution : appliquer le prédicat à chaque jeu de documents sous Node 22.23.4.
  4. Mesures : nombre de blocages, de faux positifs (commande payée prouvée par journal mais bloquée) et de faux négatifs (impayée non bloquée) ; durée de lecture ; taille du snapshot.
  5. Acceptation : 0 faux négatif ; faux positifs documentés avec leur voie de sortie (régularisation manuelle journalisée) ; décision humaine consignée avant toute dérogation.
  6. Hors périmètre : aucune lecture de production.

## 8. Audit du `financialSnapshot`
| Point | Résultat |
|---|---|
| Limite 50 | exacte [M : passer à 60 est détecté] ; `items.length ≤ 50` |
| `truncated` / `omitted` | exacts [P] : 63 éléments ⇒ 50 affichés, `omitted:13`, `counts` portent le total (60 ouverts + 3 conservés) |
| Ordre | déterministe : `type`, puis `refId`, puis `reason` ; bloquants avant conservés ; les éléments conservés peuvent être entièrement omis au-delà de 50 (acceptable, ils sont comptés) |
| Montants / devise | entiers sûrs ou `null` ; devise constante `XOF` |
| Références | identifiants techniques de commande/règlement ; `party` = rôle du compte (pas d'uid de contrepartie) |
| Données personnelles | **non garanties** : `reason` et `status` reprennent du texte du document (C3) — la sonde y a fait passer un téléphone et 3 000 caractères |
| Traçabilité après anonymisation | oui pour l'obligation (ids de commande conservés, montants conservés, flags conservés) ; **manque** la preuve de couverture : nombre de documents évalués par liste (`evaluated`) et indicateur de plafond |
| Obligation non réglée requalifiée en réglée | **possible si le résultat est altéré** : le snapshot lit `result.blocking`/`summary` au lieu de les recalculer depuis `obligations`/`retained` (C4) ; avec un résultat issu du module, jamais |
| Robustesse | exception si `summary` manque (C4) |
**Corrections demandées (C3, C4)** : (a) tout `reason`, `status`, `type` issu d'un document passe par un nettoyeur : `^[a-z0-9_:.-]{1,64}$` sinon `invalid_label` ; (b) `buildFinancialSnapshot` recalcule `blocking`, `code` et `counts` à partir de `obligations`/`retained`, ne lève jamais (résultat illisible ⇒ snapshot ambigu bloquant, déjà prévu) ; (c) ajouter `evaluated:{orders, settlements, flags}` et l'état de couverture. Aucune écriture Firestore dans cette mission.

## 9. Audit des tests
**Rejeu (Node v22.23.4)** : `accountObligations.test.js` **24/24** ; fichiers voisins (`accountDeletionHardening`, `manualAccountDeletion`, `accountDeletionSupport`, `accountQuarantineGuards`, `accountQuarantineIndex`, `orderActions`, `transferSettlement`, `partnerOrderFinancial`) **197/197** ; 0 ignoré. Suite complète non relancée (aucun fichier existant modifié).
**Assertions réellement exécutées** : 114 appels `assert.*` ; **16 mutations du module sur 16 détectées** [M] (statuts ouverts vidés, `recorded` bloquant, troncature ignorée, `isPaid` absent ignoré, exclusion boutique/v2 retirée, tri désactivé, statut inconnu toléré, remise partielle non ouverte, impayé non bloquant, document étranger ignoré, limite 50→60, fuite de champ dans le snapshot, `heldDriverEarning` sans test de règlement, frais retenus `resolved` rouverts, `reviewed` rouvert). La suite est donc **sensible**, pas décorative.
**Scénarios manquants (à ajouter avec les corrections)** : `truncated` mal formé (`true`, `'true'`, `1`, clé inconnue) ; v2 wallet livrée non payée ; libellés libres et trop longs (`reviewReason`, `flag.type`, `status`) ; snapshot avec résultat incomplet ou altéré ; `recorded` sans `decidedBy`/`requestId` ; `reviewed` pour un autre type ; `resolved` sans trace ; champs typés à `null` ; documents en double ; rôle `partner` avec `ids` partiel (déjà ambigu) ; `terminalStatuses` fourni par l'appelant ; `reads` `{limit,size}` (si adopté).
**Cohérence tests/implémentation** : le test n°7 corrigé en 7E-98 (règlement fourni à un partenaire ⇒ ambigu) est cohérent avec la politique documentée. **Déterminisme** : ordre mélangé, entrées gelées, JSON identique ⇒ vérifié. **Pureté** : test du source (aucun `require`, aucune horloge, aucun Firestore). **Limite** : le test de pureté est textuel (liste de motifs) ; il n'empêcherait pas un `import()` dynamique — risque faible.

## 10. Manifeste 2D-2 (sans rien intégrer maintenant)
Les trois inspecteurs passent par `process()` ; chacun doit appeler le prédicat avec **les mêmes documents déjà lus** et préserver ses codes de raison existants.
| | `inspect()` — `accountDeletion.js:31-62` | `readDeletionScope()` — `accountDeletionScope.js` | `financialBlocker()` — `manualAccountDeletion.js:77-98` |
|---|---|---|---|
| Rôles | `client`, `livreur` (autres rôles : `role_obligations_review_required`) | partenaires, si `partnerInventoryVersion === 1` | `pharmacie`, `event_provider` |
| Transaction | oui (`tx.get`) ; exécuté **2 fois** (avant tombstone ; avant `isDeleted`) | oui ; exécuté à la demande puis avant `isDeleted` (`partnerAccountDeletion.js:19,62`) | **non** (lectures simples) |
| Déjà lu | `orders` (+4 collections de commandes, `wallet_transactions`, `withdrawal_requests`) par `clientId`/`driverId == uid`, `limit(201)` | `orders` & 4 collections par champ propriétaire (`clientId/driverId/sellerId/pharmacieId/restaurantId/boulangerieId`) | `orders` par `pharmacieId`, ou `event_reservations` |
| À ajouter | `transfer_settlements` : client `where clientId == uid` ; livreur `where driverIds array-contains uid` ; `reconciliation_flags` : `driverId == uid` (livreur) / `clientId == uid` (client) ; `limit(201)` chacune | `reconciliation_flags` par `partnerId`/`sellerId` == identifiant d'établissement ; **pas de règlements** | `reconciliation_flags` par `partnerId`/`sellerId` == `target.id` (pharmacie) ; pas applicable à `event_provider` |
| `ids` à passer | `[uid]` | `[uid, businessId]` | `[target.id]` |
| Filtrage | passer au module **seulement** les documents de la collection `orders` (`doc.ref.parent.id === 'orders'`) | idem | idem (pharmacie) |
| Plafond / tronqué | `size >= 201` ⇒ `history_requires_manual_review` (existant) ; nouvelles requêtes : même règle ; fournir `reads:{limit,size}` | idem | idem ; nouveau : si lecture incomplète ⇒ bloquer |
| Erreur de lecture | exception ⇒ transaction annulée ⇒ `failurePatch` | idem | exception ⇒ propager (déjà le cas) ; **ne jamais** traiter comme vide |
| Raison de dossier | conserver `active_or_unresolved_operation`, `financial_regularization_required`, `history_requires_manual_review` pour les cas existants ; ajouter `financial_obligation_pending` / `financial_state_ambiguous` pour les nouveaux | idem (`scope.reason`) | idem (`financialBlocker` renvoie une chaîne) |
| `financialSnapshot` | écrire dans `account_deletions/{uid}` au blocage et à l'anonymisation (additif) ; `blockedSince` | idem | n/a (pas de job `account_deletions` dans la voie manuelle ; consigner dans `support_events`) |
| Tests à ajouter | un blocage par type (matrice §2), reprise automatique horaire (`RETRY_MS`), anonymisation refusée si obligation apparue pendant la quarantaine, plafond atteint, lecture en erreur, non-régression des raisons existantes | idem + `businessesToFreeze`/`deletionRequested` inchangés | idem hors transaction |
**Risques d'intégration**
- **Double lecture** : les commandes sont déjà lues ; ne **pas** relancer de requête `orders` pour le prédicat ; seules `transfer_settlements` et `reconciliation_flags` sont nouvelles (2 passages ⇒ 2 lectures de chaque).
- **Dépendance circulaire** : aucune — le module n'a aucun `require` ; les inspecteurs peuvent l'importer ; garder le test de pureté.
- **Limites Firestore** : requêtes d'égalité / `array-contains` mono-champ ⇒ index automatiques (aucun composite requis ; `firestore.indexes.json` ne mentionne pas ces collections — à confirmer en préproduction) ; transaction : ≈ 1 800 documents au pire, à mesurer (durée, mémoire).
- **Relâchement involontaire (C6)** : ne pas substituer les `TERMINAL` locaux par ceux du module ; ajouter au module un paramètre `terminalStatuses` (défaut : l'ensemble de `inspect()`) pour que chaque inspecteur conserve **exactement** son comportement d'état actuel.
- **Voie manuelle non transactionnelle** : `financialBlocker` lit hors transaction ; recommander de relire dans l'étape destructive ou de documenter l'écart de cohérence.
- **Reprise** : les blocages d'inspection n'incrémentent pas `attempts` ; ils se rejouent chaque heure (`RETRY_MS`) jusqu'à levée — aucun plafond.

## 11. Réserves et risques
| # | Réserve |
|---|---|
| R1 | Corrections C1 à C6 à faire (et tests associés) **avant** 2D-2 ; C7 recommandé |
| R2 | Flags `open` sans chemin de fermeture ⇒ blocage permanent tant qu'aucune action `resolveReconciliationFlag` (ou procédure support) n'existe |
| R3 | `legacyAbsentIsPaid:'ignore'` : supprimer ou conditionner à une preuve par journal ; ne rien activer sans mesure |
| R4 | Un **client** dont le non-paiement espèces est `confirmed_unpaid` n'est pas bloqué (la dette éventuelle n'est portée que côté livreur/partenaire) : décision métier à confirmer |
| R5 | Valeurs historiques inconnues en production ⇒ blocages (fail-closed) : calibrage en préproduction |
| R6 | Aucun test sur données réelles ; aucun test d'émulateur pour l'intégration (non intégré) |
| R7 | `commissionStatus` ne représente pas une obligation propre ; seules les traces de rapprochement le font |
| R8 | Quota Cloud Run non confirmé ; `held_for_review` obligatoire avant activation FeexPay ; aucun déploiement |

## 12. Recommandation
1. **Ne pas intégrer 2D-2 avant** les corrections C1-C6 : mission suivante dédiée « 2D-1 bis » (modification du module et de ses tests seulement, sans toucher aux inspecteurs).
2. Priorités : C1 (`reads:{limit,size}` ou validation stricte de `truncated`), C2 (v2 wallet non payée ⇒ ambigu), C3 (liste blanche de libellés), C4 (snapshot recalculé, jamais d'exception, `evaluated`), C5 (règle de flags §5), C6 (`terminalStatuses`).
3. Décider du **mécanisme de fermeture des flags** (action super-admin ou procédure support) avant 2D-2.
4. Supprimer ou durcir `legacyAbsentIsPaid`.
5. Puis seulement 2D-2 selon le manifeste du §10, test par test.

## 13. État Git
HEAD `d65c8f00bdcedba570a66a5633913db46127be3d` · index vide · aucun nouveau commit · aucun push · aucun déploiement · aucun fichier de code modifié (les deux fichiers du module et ses tests sont inchangés, mêmes sha256) · `git status` : les 93 entrées d'avant + ce rapport.

## Verdict
**2D-1 VALIDÉ SOUS RÉSERVES — CORRECTIONS NÉCESSAIRES**
Le prédicat est sain dans son principe, bien testé et pur, mais trois défauts fail-open ou de fuite (C1 troncature, C2 v2 non payée, C3 libellés libres) et trois écarts de conception (snapshot, règles de flags, ensemble terminal) doivent être corrigés avant l'intégration. Aucune modification de code, aucun staging, aucun commit, aucun push, aucun déploiement. En attente d'une nouvelle autorisation humaine.
