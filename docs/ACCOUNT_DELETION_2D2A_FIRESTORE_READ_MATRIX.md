# 2D-2A — Matrice de lecture Firestore (spécification, aucun code)

HEAD `d65c8f0`, index vide. Document de spécification uniquement. Rien n'est implémenté, aucun inspecteur n'est modifié.

Légende : **[C]** règle confirmée par une source de code ou une décision métier citée ; **[P]** proposition à valider ; **[Q]** question sans réponse (voir le contrat, §10).

Sources de référence : `functions/accountObligations.js` (désigné « moteur »), `accountDeletion.js`, `accountDeletionScope.js`, `manualAccountDeletion.js`, `accountDeletionIdentity.js`, `firestore.rules`, rapports 7E-98 à 7E-108.

## 1. Rôles du moteur et rôles des inspecteurs

Le moteur reconnaît quatre rôles (`ROLE_ALIASES`, `accountObligations.js:90`) **[C]** :

| Rôle moteur | Alias d'entrée acceptés |
|---|---|
| `client` | client, clients |
| `driver` | livreur, driver, livreurs |
| `partner` | pharmacie, pharmacy, seller, vendeur, boulangerie, restaurant, partner, partenaire |

Les rôles `ekbine_agent`, `real_estate_agent` et `fleet_owner` de `accountDeletionIdentity.js` ne sont **pas** connus du moteur : un rôle inconnu produit un blocage global (`unknown_role`). Les inspecteurs doivent donc garder leurs contrôles actuels pour ces rôles **[C]** (le moteur ne les couvre pas) ; l'extension du moteur est hors périmètre **[Q1]**.

Le moteur n'évalue que trois collections : `orders`, `transfer_settlements` (liste « settlements ») et `reconciliation_flags` (liste « flags ») (`accountObligations.js:17`, `LISTS`, ligne 126) **[C]**. Les autres collections que lisent aujourd'hui les inspecteurs (`boutique_orders`, `blanchisserie_orders`, `eau_boissons_orders`, `ekbine_orders`, `wallet_transactions` de niveau supérieur, `withdrawal_requests`, `real_estate_*`, produits, `livreurs.ownerId`, `pharmacy_owners`/`restaurant_owners`) restent contrôlées par la logique existante des inspecteurs, inchangée **[P]**.

## 2. Requêtes obligatoires par rôle

Fonction de référence : `requiredQueries(role, ids)` (`accountObligations.js:705`) et `requiredKeys` (ligne 699). `ids` est dédupliqué avant le calcul **[C]**.

| Rôle | Liste | Collection | Clé(s) du moteur | Opérateur |
|---|---|---|---|---|
| client | orders | `orders` | `clientId` | `==` |
| client | settlements | `transfer_settlements` | `clientId` | `==` |
| client | flags | `reconciliation_flags` | `clientId` | `==` |
| livreur | orders | `orders` | `driverId` | `==` |
| livreur | settlements | `transfer_settlements` | `driverIds` | `array-contains` **[P]** |
| livreur | settlements | `transfer_settlements` | `holderDriverId` | `==` |
| livreur | flags | `reconciliation_flags` | `driverId` | `==` |
| pharmacie / restaurant / boulangerie | orders | `orders` | `sellerId` et `pharmacieId` / `restaurantId` / `boulangerieId` | `==` |
| seller (sans type particulier) | orders | `orders` | `sellerId` | `==` |
| tout partenaire | settlements | — | aucune requête (liste vide) | — |
| tout partenaire | flags | `reconciliation_flags` | `partnerId`, `sellerId`, `pharmacieId` | `==` |

Précisions :
1. L'opérateur de la clé `driverIds` n'est pas écrit dans le moteur. Le nom du champ au pluriel indique un tableau ; l'opérateur `array-contains` est une **proposition** à confirmer par la lecture de `transferSettlement.js` / `orderActions.js:136` **[Q2]**.
2. Pour un partenaire, l'identifiant à interroger est celui de l'établissement (`businessPath`), pas l'UID personnel, comme `readDeletionScope` (`accountDeletionScope.js:42-47`) **[C]**.
3. Pour un client ou un livreur, `ids` contient l'UID du compte **[C]**.
4. Les signalements Ekbine portent `clientId` (`ekbineOrders.js:265, 319`) : ils sont donc couverts par la requête flags `clientId` d'un client **[C]**. L'agent Ekbine n'a pas de requête dédiée, ce qui reste hors périmètre **[Q1]**.
5. Un partenaire n'a aucune requête sur `transfer_settlements`. C'est le comportement du moteur (`requiredKeys`, ligne 701) ; l'absence éventuelle d'une obligation de règlement côté partenaire n'est pas vérifiée dans cette mission **[Q3]**.

## 3. Forme du reçu de couverture

Pour chaque liste, l'appelant fournit exactement **[C]** (`coverage`, `accountObligations.js:715-751`) :

```
reads.<liste> = { queries: [ { key, id, limit, size } , ... ] }   // aucune autre propriété
```

Règles contrôlées par le moteur, donc à respecter à l'identique :

| Règle | Source |
|---|---|
| Un objet de requête a exactement quatre propriétés `key`, `id`, `limit`, `size` | `coverage` |
| `limit` vaut **exactement 201** (`READ_LIMIT`) ; ni 200, ni 202 | `coverage` |
| `size` entier, `0 ≤ size ≤ limit` | `coverage` |
| `key` ∈ clés requises du rôle ; `id` ∈ `ids` | `coverage` |
| Un couple (clé, id) en double ⇒ `<liste>_query_duplicate` (bloquant) | `coverage` |
| Un couple manquant ⇒ `<liste>_queries_incomplete` | `coverage` |
| Nombre de documents fournis `n` : `max(size) ≤ n ≤ Σ size` (union dédupliquée) sinon `<liste>_read_size_mismatch` | `coverage` |
| `size ≥ limit` ⇒ lecture potentiellement tronquée ⇒ `<liste>_truncated` + `manualReviewRequired` | `coverage` |
| `reads` absent ⇒ `reads_missing` ; liste sans reçu ⇒ `<liste>_coverage_unproven` | `coverage` |

Détail de la mise en œuvre à fixer en 2D-2B **[P]** : `size` doit être `snapshot.size` de la requête, jamais `docs.length` après filtrage côté code, et la requête doit être émise avec `.limit(201)` pour que `size = 201` signifie « tronqué ».

### Doublons

- Un même document peut revenir par deux requêtes (ex. `sellerId` et `pharmacieId`) : l'appelant fournit **un seul** document dans la liste par identifiant ; le moteur rejette `<liste>_duplicate_document_id` si un identifiant se répète **[C]**.
- Un reçu avec le même couple (clé, id) deux fois est un défaut de l'appelant et bloque **[C]**.

### Lectures incomplètes et erreurs

- Toute exception pendant une lecture (réseau, permission, délai) ⇒ l'inspecteur renvoie un blocage de dossier sans appeler le moteur, sans snapshot « propre » et sans suppression **[P]**. Justification : le moteur est fail-closed sur toute entrée absente (`reads_missing`, `*_not_provided`), mais une exception est avant le moteur.
- Aucune relance silencieuse qui masque une lecture partielle. Une relance éventuelle repart de zéro et refournit un reçu complet **[P]**.

## 4. Lectures par type de commande et de créance

| Cas | Lecture exigée | Source |
|---|---|---|
| Commande wallet v2 (`amountsVersion: 2`), client, livrée, `isPaid: true`, hors boutique | Document `clients/{uid}/wallet_transactions/order_<orderId>` | `walletGeneration`, `needsDebitProof`, `requiredWalletDebitIds` **[C]** |
| Commande créée par devis serveur (`tariffQuoteId`) | Même document `order_<orderId>` | `catalogQuote.js:198`, `deliveryQuote.js:207` **[C]** |
| Commande wallet historique (sans `amountsVersion`, sans `tariffQuoteId`) | Aucune lecture de journal (non garanti) ; le moteur émet une entrée `manual_review` | `accountObligations.js:355-358` **[C]** |
| Commande payée `cash` | Aucune lecture supplémentaire : couverte par `orders` et par les flags `cash_*` | moteur **[C]** |
| Règlement partenaire (`cash_payment_review`, `cash_shortfall`, `partner_credit_missing`) | Flags via la requête `flags` du rôle ; commande déjà lue | `orderActions.js:898, 1017`, `partnerOrderActions.js:361` **[C]** |
| Avance livreur (`driver_advance_unreimbursed`) | Flag (requête `flags` `driverId`) | `adminOrderDisputes.js:518` **[C]** |
| Retenue de règlement | Champs de la commande (`settlementHold`, `heldDriverEarning`, `deliveryFeeHold`) et `transfer_settlements` | moteur **[C]** |
| Signalements Ekbine | Flags `ekbine_cancel_unproven_debit`, `ekbine_confirm_unproven_debit` via `clientId` | `ekbineOrders.js:265, 319` **[C]** |

Le journal v2/devis n'est requis que pour le **rôle client** (`requiredWalletDebitIds` retourne `[]` sinon) **[C]**. Les ids sont triés et dédupliqués par le moteur ; l'appelant lit chacun par lecture ponctuelle (`get` d'un document), sans plafond de 201 puisqu'aucune requête n'est impliquée **[C]**.

### Éviter la double comptabilisation d'une même créance

Le moteur calcule une clé économique `orderId|claim` (`economicKey`) ; deux éléments qui portent la même clé comptent une seule créance, et les compteurs `orders`, `economic`, `flags`, `manualReview` sont indépendants de la déduplication **[C]**. Conséquences de contrat :

1. L'appelant ne fusionne, ne déduplique et ne filtre **aucun** document avant le moteur, sauf pour retirer les doublons d'identifiant issus de deux requêtes distinctes **[P]**.
2. Un même fait (ex. une commande `refundPending` avec un flag ouvert) peut apparaître dans `orders` et dans `flags` : les deux sont fournis ; le moteur détermine la créance unique **[C]**.
3. Les comptes servent à l'information (`summary.counts`), jamais à reconstituer un montant total côté inspecteur **[P]**.

## 5. Journaux wallet : les trois emplacements

| # | Chemin Firestore | Écrivains autorisés | Valeur comme preuve |
|---|---|---|---|
| A | `clients/{uid}/wallet_transactions/{txId}` | Cloud Functions (Admin SDK). Un client ne peut créer qu'une ligne `purchase` à identifiant automatique de 20 caractères, champs limités à `type, amount, description, orderId, createdAt` (`firestore.rules:326-340`) | Seul `order_<orderId>` est une preuve de débit : l'identifiant déterministe est refusé aux clients par la règle **[C]** |
| B | `{livreurs\|pharmacies\|sellers}/{uid}/wallet_transactions/{txId}` | Cloud Functions ; livreur : une ligne `commission` à identifiant automatique, 0 à 1000 (`firestore.rules:398-406`) ; vendeur : `isAdmin()` seulement (`firestore.rules:453-458`) | Hors périmètre du moteur (client uniquement). Les identifiants déterministes `commission_<commande>_<livreur>` servent de preuve aux fonctions (`driverRelease.js:98-103`) **[C]** |
| C | `wallet_transactions/{txId}` (niveau supérieur) | Cloud Functions pour FeexPay (`feexpayPayments.js`) ; **le client peut créer** `{uid, type:'ekbine_payment', amount, createdAt}` (`firestore.rules:853-865`) | **Jamais une preuve de débit wallet.** Les lignes `ekbine_payment` sont écrites par le client (`ekbineReconciliation.js:7`) **[C]** (décision de mission) |

Tableau des types et champs :

| Emplacement | Type | Champs utiles | Garantie transactionnelle |
|---|---|---|---|
| A, `order_<id>` v2 | `payment` | `amount`, `orderId`, `provider:'wallet'`, `txId`, `productAmount`, `deliveryFee` | Écrit dans la même transaction que le débit du solde et la création de commande (`partnerOrderQuote.js:294-302`) **[C]** |
| A, `order_<id>` devis | `payment` | `amount`, `orderId`, `provider`, `txId` | Idem (`catalogQuote.js:196-200`, `deliveryQuote.js:205-209`) **[C]** |
| A, historique `payOrderFromWalletCF` | `payment` | `amount`, `orderId` | Écrit **après** la transaction avec un identifiant automatique (`orderActions.js:142`) : non garanti, non lisible par `order_<id>` **[C]** |
| A, historique client Flutter | aucune ligne garantie | — | Débit côté client (`delivery_order_service.dart:71`), `lastPaidOrderId` seulement **[C]** |
| A, remboursement | `admin_refund_<orderId>` | `amount`, `orderId` | Écrit en transaction (`adminBilling.js:295`) — non utilisé par le moteur |

Risques de falsification :
1. Un administrateur (`isAdmin()`) peut créer n'importe quel document du chemin A : le moteur ne détecte pas une fausse ligne `order_<id>` créée par un admin **[C, limite reconnue]**.
2. Un client ne peut pas fabriquer `order_<id>` (règle) ; il peut fabriquer une ligne `purchase` à identifiant automatique, inutilisée comme preuve **[C]**.
3. Le document peut avoir été supprimé : le moteur traite l'absence d'un journal garanti comme un blocage (`*_wallet_debit_missing`) **[C]**.

### Règles de lecture et de résultat

| Situation | Résultat exigé | Source |
|---|---|---|
| Journal lu, existe, `type:'payment'`, `orderId` égal, `amount` égal au total attendu | Aucune obligation | moteur **[C]** |
| Document absent (`exists:false`) | Revue bloquante `*_wallet_debit_missing` | moteur **[C]** |
| Divergence (type, orderId ou montant, y compris montant sous forme de chaîne) | Revue bloquante `*_wallet_debit_mismatch` | moteur **[C]** |
| Journal non fourni dans `walletDebits` | Ambigu bloquant `*_wallet_debit_unverified` | moteur **[C]** |
| Erreur de lecture (exception) | Blocage de l'inspecteur, moteur non appelé | décision de mission **[C]** |
| Montants de la commande invalides | Ambigu bloquant `*_amounts_inconsistent` | moteur **[C]** |

## 6. Commandes historiques et revue manuelle

Distinction à respecter dans tout consommateur **[C]** (décision R10 de 7E-108 et sondes du rapport 7E-108 §3) :

| Notion | Où la lire | Effet |
|---|---|---|
| Obligation bloquante | `result.obligations` ; `result.blocking === true` ; `result.code` | Interrompt la suppression |
| Dossier historique `manual_review` | `result.manualReview` ; nombre dans `result.summary.manualReview` et, dans un snapshot, `counts.manualReview` | Non bloquant ; conservé dans l'audit |
| Lecture tronquée | `result.manualReviewRequired === true` (et obligations `*_truncated`) | Bloquant |

Règles :
1. `manualReviewRequired` signale **uniquement** une lecture tronquée (`isTruncationItem`, `accountObligations.js:666`) **[C]**. Ne jamais l'utiliser comme compteur de dossiers historiques.
2. Pour compter les dossiers historiques, utiliser `counts.manualReview` du snapshot **[C]**.
3. Un dossier historique n'est jamais présenté comme un paiement confirmé : état `manual_review`, montant nul, raison `legacy_wallet_payment_unproven` **[C]**.
4. Toute contradiction financière reste bloquante : `refundPending`, `needsReview`, `paymentStatus: pending`, retenue de règlement, gain livreur retenu, statut inconnu, `isPaid` faux ou absent, flag de réconciliation ouvert (sondes du rapport 7E-108 §3) **[C]**.

## 7. Résultats d'erreur d'appel du moteur

Le moteur ne lève jamais d'exception (`failClosed`) : toute entrée mal formée renvoie un résultat bloquant avec `code: financial_state_ambiguous` **[C]**. Le contrat côté appelant est donc : appeler, puis tester `blocking`. Une exception levée par l'appelant avant (lecture) est traitée comme un blocage **[P]**.
