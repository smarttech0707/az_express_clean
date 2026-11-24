# Mission 7E-102 — Arbitrage métier des obligations financières (M-1 à M-6)

Date : 2026-11-09 · HEAD `d65c8f0`, index vide, 96 entrées de travail avant ce rapport (97 avec lui). **Aucun code, test, configuration ou fichier existant modifié.** Aucun staging, commit, push, déploiement, commande distante, émulateur ni secret. Production intouchée.
**Statut du document : tout ce qui suit est une PROPOSITION soumise à validation humaine. Aucune décision n'est approuvée tant que vous ne l'avez pas écrit.** Les faits observés dans le code sont marqués **[V]** ; les inférences **[I]** ; ce que je n'ai pas pu vérifier **[?]**.
Sources lues : registre 7E-87 (D1-D5), 7E-97 (D6-a/b/c, §4, §6), 7E-100, 7E-101 ; écrivains `cashPayment.js`, `partnerOrderActions.js` (l. 280-362), `orderActions.js` (l. 48-100, 420-425, 896-905, 1012-1020), `adminOrderDisputes.js` (l. 505-523), `ekbineOrders.js`, `earningsSettlement.js`, `accountDeletion.js`, `accountDeletionScope.js`, `firestore.rules`/`firestore.indexes.json` (collections concernées).

## 0. Constats transversaux qui structurent toutes les décisions
1. **Il n'existe aucun registre de dettes.** Aucun écrivain de `debt` ni de `commissionDebt` dans `functions/` [V] (seuls les inspecteurs lisent ces champs) ; un wallet ne peut pas être négatif (règle projet). Une « dette » n'existe donc que sous forme de **champs sur la commande** (`cashRemittance`, `cashPayment`, `settlementHold`…) ou de **flags de rapprochement**.
2. **Aucun flag n'a de chemin de fermeture générique** [V] : `cash_payment_review` a `reviewCashNonPayment` ; tous les autres sont `open` sans issue (`adminOrderDisputes.js` : « à traiter hors de cet outil »).
3. **Une même créance économique apparaît sous plusieurs symptômes** (commande non payée + `needsReview` + flag `beneficiary_account_closed`, ou `cashPayment` + `cashRemittance` + flag `cash_shortfall`). 7E-100 les évalue séparément. Pour respecter « ne jamais compter une dette deux fois », il faut une **clé économique par commande** (`orderId`) dans le moteur et le snapshot (voir M-4 et M-6).
4. **Qui est créancier ?** Seul `cash_shortfall` porte `owedTo`. Pour les autres flags, le sens de la créance est implicite. Or l'autorité qui peut renoncer dépend du créancier (M-1).
5. Les actions sensibles existantes exigent déjà : `requireSuperAdmin`, `requestId` idempotent (16-128 car.), justification 10-500 car., `logAudit`, `checkRateLimit`. L'outil futur doit réutiliser ce socle, pas en inventer un second [V].

---

## M-1 — Fermeture des flags ouverts

### 1. Problème exact
Le moteur (7E-100) laisse bloquer tout flag `open` ; seul `reviewed` (pour `cash_payment_review`) et `resolved` (jamais écrit) ferment. Sans outil, des comptes restent bloqués à vie ; avec un outil mal contraint, un simple changement de statut pourrait effacer une créance.

### 2. Éléments observés
| Type de flag | Écrivain | États écrits | Parties | Sens de la créance | Issue existante |
|---|---|---|---|---|---|
| `cash_payment_review` | `orderActions.js:1018` (livraison), `partnerOrderActions.js:271` (déclaration tardive) | `open` → `reviewed` | partnerId, driverId | aucune créance propre ; sert à **examiner** une déclaration de non-paiement | `reviewCashNonPayment` (super-admin) pose `reviewed`+`decision`+`verification` [V] |
| `cash_shortfall` | `resolveCashRemittance` (`partnerOrderActions.js:362`) | naît `recorded` (jamais `open`) | partnerId, driverId | `owedTo:'partner'`, montant = `outstanding` | aucune (voir M-2) |
| `commission_untraced` | `orderActions.js:422`, `driverRelease.js:134` | `open` | driverId | **incertain [I]** : une commission a peut-être été prélevée sans trace ; le livreur a peut-être droit à un remboursement non prouvable | aucune |
| `partner_credit_missing` | `orderActions.js:898` | `open` | sellerId, sellerType | AZ/livreur doit `productAmount` au partenaire introuvable | aucune |
| `seller_review` | `adminOrderDisputes.js:509` | `open` | sellerId | revue d'une décision de litige ; `reason`, `decidedBy` | aucune |
| `driver_advance_unreimbursed` | `adminOrderDisputes.js:518` | `open` | driverId | le livreur a avancé des achats, le client a été remboursé : **créance du livreur** (`amount`) | aucune |
| `ekbine_cancel_unproven_debit`, `ekbine_confirm_unproven_debit` (champ `kind`, pas `type`) | `ekbineOrders.js:265,319` | `open` | clientId (+ agentId) | débit wallet non prouvé : possible dû au client ou à l'agent | aucune |
| `beneficiary_account_closed` | **prévu** par 7E-97 §6.2, non codé | `open` | à définir | paiement refusé (D6-a) : créance de la commande vs bénéficiaire | `clearBeneficiaryReview` prévu (voir M-3) |

### 3. Options
- **A.** Un seul outil générique `resolveReconciliationFlag` avec liste globale de résolutions (proposition 7E-100). *Risque :* un super-admin peut clore n'importe quoi avec une justification libre.
- **B.** Outil à **matrice stricte** : chaque type n'accepte que ses résolutions, avec preuve vérifiée par le serveur, deux niveaux de validation, décision immuable. *Coût :* plus de code et de décisions préalables.
- **C.** Pas d'outil : procédure console manuelle documentée. *Risque :* aucune garde technique ; contraire au principe « jamais par simple changement de statut ».

### 4. Avantages / risques
B est la seule option qui rende impossible la clôture par simple écriture de statut **si** les inspecteurs ne se fient pas au seul champ `status` mais exigent la trace de décision. A est trop permissive ; C est inacceptable pour l'argent.

### 5. Décision recommandée — B (matrice ci-dessous), à valider
**Principes communs de l'outil (tous types) :**
- Action Cloud Function réservée au **super-admin** (`requireSuperAdmin`), `checkRateLimit`, `requestId` idempotent, enveloppe `{success,error,message,data,code}`.
- Transition **unique** `open → resolved` ; `resolved` est irréversible ; une réouverture est une **nouvelle décision** (append-only), jamais une écriture sur l'ancienne.
- **Registre de décisions append-only** `reconciliation_decisions/{decisionId}` (écriture Admin SDK seulement, `allow write: if false`) : `decisionId = sha256(flagId + ':' + requestId)` tronqué (déterministe → rejeu idempotent, unique). Champs : `flagId, orderId, flagType, tier, resolution, amountBefore, amountResolved, remaining, evidence[{kind,ref}], justification, requestedBy, requestedAtMs, approvedBy, approvedAtMs, previousFlagStatus, createdAtMs`. Jamais mis à jour ni supprimé.
- Le flag reçoit : `status:'resolved'`, `resolvedBy`, `resolvedAtMs`, `resolutionRequestId`, `resolutionDecisionId`, `resolution`. **Le moteur n'accepte `resolved` que si ces cinq champs existent** (et, pour les niveaux 2/3, que `approvedBy` ≠ `resolvedBy`). Pour limiter la fraude par écriture directe en console, les inspecteurs **relisent le document de décision** des flags `resolved` (rares) et vérifient `flagId`, `orderId`, `resolution`, `approvedBy` ; sinon blocage.
- Aucun mouvement de wallet dans l'outil : il **constate** (la régularisation financière a lieu ailleurs, par les circuits existants).
- Audit : `logAudit` dans la même transaction que la décision (et non « best effort » après coup, contrairement à `payOrder`).
- **Pas de clôture automatique** : même quand la preuve est vérifiable par le serveur (ex. commande payée), l'outil exige l'action humaine ; il pré-remplit la preuve.

**Niveaux de validation :**
| Niveau | Quand | Exigence |
|---|---|---|
| **N1 — constat** | résolution **démontrée par les données** (commande payée, journal wallet présent) ou absence de dette prouvée | un super-admin, justification 20-500 car., preuve vérifiée par le serveur |
| **N2 — règlement hors système / prise en charge** | la créance est éteinte par un paiement hors ledger ou absorbée par AZ | **deux super-admins distincts** (demandeur ≠ approbateur ; aussi ≠ `decidedBy` d'origine du flag), justification, références de preuve |
| **N3 — renonciation à une créance** | `waived_by_decision` | N2 **et** autorisation du **créancier** (voir ci-dessous) |

**Matrice type → résolutions → preuve → autorité :**
| Type | Résolutions admises | Preuve obligatoire (vérifiée par le serveur) | Niveau |
|---|---|---|---|
| `cash_payment_review` | **aucune via l'outil générique** : uniquement `reviewCashNonPayment` (refuted / confirm_unpaid) | `cashPayment.verification` ≠ `pending_review` ; `reviewed` posé par l'action | existant (super-admin) |
| `cash_shortfall` | voir M-2 (jamais ouvert) | voir M-2 | N2/N3 |
| `commission_untraced` | `verified_no_debit` ; `refunded_by_ledger` ; `waived_platform_claim` | `verified_no_debit` : absence de ligne de débit de commission pour `orderId` dans `wallet_transactions` du livreur **[?** format d'identifiant des journaux de commission à confirmer] + attestation ; `refunded_by_ledger` : ligne de crédit référencée | N1 / N1 / N3 (le créancier est AZ si la commission est due à AZ) |
| `partner_credit_missing` | `paid_to_partner_ledger` ; `paid_out_of_system` ; `partner_unreachable_held` | crédit wallet du partenaire lié à `orderId` pour ≥ `amount` ; sinon référence de paiement externe (mobile money) | N1 / N2 / (reste ouvert) — **pas de renonciation** (créance d'un tiers) |
| `seller_review` | `reviewed_no_action` ; `adjusted_by_ledger` | décision de litige référencée (`decisionKey` du flag) ; l'approbateur ≠ `decidedBy` | N2 |
| `driver_advance_unreimbursed` | `reimbursed_by_ledger` ; `reimbursed_out_of_system` ; `waived_by_driver` | crédit livreur lié à la commande pour ≥ `amount` ; sinon référence ; renonciation seulement avec consentement écrit du livreur | N1 / N2 / N3 |
| `ekbine_cancel_unproven_debit`, `ekbine_confirm_unproven_debit` | `debit_proven_and_settled` ; `debit_disproved` ; `refunded_by_ledger` | journal de débit prouvé ou preuve d'absence ; sinon remboursement journalisé | N1 / N2 |
| `beneficiary_account_closed` | voir M-3 | voir M-3 | N2/N3 |
| type inconnu | **aucune** (le moteur le laisse bloquant) | — | — |

**`waived_by_decision` — évaluation et règles :**
- **Quelle autorité ?** AZ ne peut renoncer qu'à **ses propres créances** (commission, frais de plateforme). Pour la créance d'un tiers (partenaire, livreur, client), le super-admin **ne peut pas renoncer au nom du créancier** : il faut le **consentement écrit du créancier**, référencé (identifiant d'un justificatif stocké, sans donnée personnelle dans le registre).
- **Justification :** catégorie fermée (`creditor_consent`, `uncollectable_after_attempts`, `de_minimis_below_threshold`, `legal_decision`) + texte 20-500 car. ; le seuil `de_minimis` est **fixé par vous** (non proposé ici : décision de gestion).
- **Empêcher une renonciation sans décision documentée :** N3 impose deux super-admins distincts, le consentement référencé, un délai de réflexion (proposé 24 h entre demande et approbation), et le registre immuable. Le moteur n'accepte pas `resolution:'waived_*'` sans `approvedBy`, `creditorConsentRef` et `decisionId` valides.
- **Historique :** le flag reste en base avec `resolved`, le registre garde la demande, l'approbation et le montant renoncé (`amountBefore`, `remaining`) — le montant abandonné reste donc **reconstituable**.

### 6. Conséquences
- **2D-1 (module)** — correctif « 2D-1 ter » nécessaire : `resolved` exige les 5 champs (+ `approvedBy` ≠ `resolvedBy` pour les niveaux 2/3) ; `FLAG_TYPES` + `beneficiary_account_closed` ; clé économique ; D-6 (comptage du snapshot).
- **2D-2** — les inspecteurs lisent en plus `reconciliation_decisions` pour les flags `resolved` (1 lecture par flag clos, plafonnée).
- **Outil super-admin** — nouvelle Cloud Function + règles `reconciliation_decisions` (`write:false`) + tests (double résolution, replay, maker-checker, preuve absente, concurrence). Dépendance : les décisions ci-dessous.

### 7. Validation humaine impérative
(a) Existe-t-il **au moins deux super-admins distincts** ? (sinon, quelle alternative au maker-checker : délai + justification renforcée ?) (b) Seuil `de_minimis` et seuil de montant déclenchant N2. (c) Les résolutions listées sont-elles exhaustives pour votre métier ? (d) `waived_by_decision` est-il autorisé du tout, et pour quelles catégories ? (e) Qui est le créancier de `commission_untraced` (AZ ou livreur) ? (f) Forme du justificatif de consentement (où est-il stocké, qui le vérifie) ?

---

## M-2 — Reliquat `cash_shortfall` (état `recorded`)

### 1. Problème exact
7E-100 conserve un flag `recorded` avec trace (`decidedBy`, `requestId`, `amount`) comme **non bloquant**. Votre consigne : ne pas le traiter comme une dette abandonnée par défaut.

### 2. Éléments observés
- `resolveCashRemittance` fixe `finalAmount ≤ amountDue` ; `outstanding = amountDue − finalAmount` ; si `outstanding > 0` il crée le flag `recorded` avec `owedTo:'partner'` et le commentaire du code : « reliquat arrêté par décision, tracé pour le rapprochement, **jamais débité automatiquement** » [V].
- Après `resolved`, toute action est refusée (`CASH_ALREADY_FINAL`) : **il n'existe aucun chemin pour enregistrer un recouvrement ultérieur** [V].
- Le code ne dit pas **qui supporte** le reliquat : le livreur (il a gardé l'argent ?), AZ (elle indemnise le partenaire ?) ou le partenaire (il accepte la perte) [I]. Ni `debtor` ni `bearer` n'est écrit.
- Aucun registre de dette ni de recouvrement (constat 0.1).

### 3. Options
- **A.** `recorded` reste bloquant tant qu'aucune décision de clôture n'est enregistrée (clôture explicite).
- **B.** `recorded` = dette définitivement arrêtée (7E-100) : non bloquant.
- **C.** `recorded` bloque seulement le **livreur débiteur**, pas le partenaire.

### 4. Avantages / risques
A respecte votre principe mais bloque des livreurs tant que l'outil n'existe pas. B laisse un débiteur potentiel s'effacer et rend le partenaire impayé silencieux. C suppose de connaître le débiteur, ce que le code n'écrit pas.

### 5. Décision recommandée — A, avec les règles suivantes (à valider)
- **`recorded` n'est pas une dette abandonnée.** Il est bloquant (revue) pour le **livreur** et le **partenaire** concernés, jusqu'à une décision de clôture.
- Résolutions de clôture : `recovered_in_full` (preuve : confirmation du partenaire référencée, montant = `outstanding`, N2) ; `absorbed_by_platform` (AZ indemnise : preuve = crédit wallet partenaire ou paiement hors système référencé, N2) ; `waived_by_partner` (consentement écrit du partenaire, N3) ; `waived_platform_claim` **non applicable** (la créance n'est pas à AZ).
- **Paiement partiel :** enregistré comme décision `partial_recovery` (montant) ; le flag garde `remaining = outstanding − Σ recoveries` ; **tant que `remaining > 0` l'obligation reste ouverte** ; `remaining = 0` permet la clôture (une décision de clôture reste exigée, pas d'effet automatique).
- **Dette contestée :** un état `contested` (nouveau, additif) passe le flag en **revue administrative** (`review`), bloquant ; tout litige se règle par une décision N2.
- **Solde nul :** seul un `remaining = 0` **établi par des décisions enregistrées** ferme ; jamais un `outstanding = 0` déclaré sur le flag.
- Sans la décision « qui supporte le reliquat », un `recorded` historique est traité **ambigu bloquant**.

### 6. Conséquences
- **2D-1 ter :** `recorded` passe de `retained` à `review` bloquant ; la rétention n'est possible qu'avec une décision de clôture (`resolved` + registre). **Cela inverse le comportement 7E-100 et 7E-99.** Tests à refaire (C5).
- **2D-2 :** les livreurs/partenaires avec reliquat restent bloqués jusqu'à l'outil.
- **Outil :** actions `partial_recovery`, `recovered_in_full`, `absorbed_by_platform`, `waived_by_partner`, `contest`.

### 7. Validation humaine impérative
(a) **Qui supporte un reliquat décidé par `resolveCashRemittance` ?** (b) Quand le super-admin fixe `finalAmount < amountDue`, le partenaire est-il indemnisé ou perd-il la différence ? (c) Un livreur peut-il être anonymisé alors qu'il doit un reliquat s'il est insolvable (renonciation autorisée) ? (d) Existe-t-il un circuit de recouvrement hors système ?

---

## M-3 — `beneficiary_account_closed` et `clearBeneficiaryReview`

### 1. Problème exact
7E-97 §6.2 prévoit que `clearBeneficiaryReview` (action de `adminBillingCF`) « remet `needsReview:false` **et ferme le flag** ». Cette fusion mélange deux opérations aux effets différents.

### 2. Éléments observés
- Ces éléments n'existent **pas encore dans le code** [V] (spécification 2C-B).
- D6-a : bénéficiaire `isDeleted` ⇒ **paiement entier refusé**, rien d'écrit, trace séparée : `reconciliation_flags/<orderId>_beneficiary_closed` (`status:'open'`) + `orders.needsReview:true, reviewReason:'beneficiary_account_closed'` ; nouvelle tentative seulement après résolution administrative.
- Un bénéficiaire anonymisé **ne redevient jamais actif** (`isDeleted`). « Rétablir le bénéficiaire » n'a donc de sens que si (i) la quarantaine du bénéficiaire était temporaire (alors le refus D6-a ne s'applique pas : seul `anonymized` est refusé), ou (ii) l'administration **change de bénéficiaire** (autre livreur/pharmacie).
- La commande reste `delivered` et `isPaid:false` : pour le **client**, c'est l'obligation `unpaid_delivered_wallet` ; pour le moteur, trois symptômes d'une même créance (constat 0.3).
- L'identifiant du flag est **déterministe** (`<orderId>_beneficiary_closed`) : un nouveau refus écrirait sur le même document et **écraserait un état `resolved`** et sa trace [I].

### 3. Options
- **A.** Fusion (7E-97) : `clearBeneficiaryReview` lève la revue **et** ferme le flag.
- **B.** Deux opérations : `clearBeneficiaryReview` ne fait que **réautoriser une tentative** ; la fermeture du flag est une résolution distincte, tracée.
- **C.** Pas de levée : toute régularisation passe par un administrateur qui paie à la main.

### 4. Avantages / risques
A ferme le flag alors que la commande reste impayée : un deuxième refus le rouvre ou, pire, l'écrase. B garde la traçabilité et aligne la fermeture sur la réalité financière. C est sûre mais bloque le client sans procédure.

### 5. Décision recommandée — B (deux opérations distinctes)
1. **`clearBeneficiaryReview` = réautoriser une tentative** (retirer le verrou `needsReview` après vérification que le bénéficiaire est désormais `active`/`closing`, ou après remplacement du bénéficiaire). Effet : aucun flag fermé, aucun solde modifié, décision `retry_authorised` dans le registre. Si le bénéficiaire est toujours `anonymized`/`absent`, l'action est **refusée**.
2. **Fermeture du flag** par résolution N1/N2 uniquement :
   - `payment_completed` : preuve auto-vérifiable (`orders.isPaid === true`, `paidAt`, journaux `pay_order_<orderId>` présents) → N1 ;
   - `beneficiary_substituted` : l'administration a désigné un autre bénéficiaire, avec preuve du crédit → N2 ;
   - `order_payment_waived_by_platform` : AZ renonce à facturer le client (le livreur/partenaire non payé n'est pas lésé uniquement si AZ les indemnise) → N3 avec consentement/indemnisation référencée.
3. **Identifiant du flag** : ne plus l'écraser ; un nouveau refus après résolution crée `<orderId>_beneficiary_closed_<n>` ou une entrée de registre, jamais une réécriture.
4. Un bénéficiaire **anonymisé** ne se « rétablit » pas : il n'y a que des substitutions ou une prise en charge décidées.

### 6. Conséquences
- **2D-1 ter :** ajouter le type au moteur ; **ne pas** traiter la levée de `needsReview` comme fermeture du flag.
- **Lot 2C-B :** modifier la spécification (`clearBeneficiaryReview` ne ferme pas le flag) **avant** de coder ; c'est un changement de 7E-97 §6.2 (autorisé : « sauf décision explicitement justifiée »).
- **Outil :** deux actions séparées (levée de verrou / résolution du flag).
- **Paiements en attente :** pendant la revue, le paiement reste refusé (D6-a inchangée).

### 7. Validation humaine impérative
(a) Approuvez-vous la **séparation** levée de verrou / fermeture du flag (modification de 7E-97 §6.2) ? (b) Que doit-il advenir de la commande impayée lorsque le bénéficiaire est définitivement anonymisé : substitution, paiement par AZ, renonciation ? (c) Le client peut-il être « libéré » avant que le bénéficiaire soit payé ?

---

## M-4 — Non-paiement espèces du client (`confirmed_unpaid`)

### 1. Problème exact
Un client dont le non-paiement espèces a été confirmé n'est pas bloqué aujourd'hui, et sa dette n'est enregistrée nulle part.

### 2. Éléments observés
- `cashPayment` n'existe que sur les commandes **v2** (`cashPayment.js` : « les commandes historiques n'ont jamais de cashPayment ») [V].
- `reviewNonPayment` : « **aucune conséquence financière automatique** » ; ni `cashRemittance` ni montant modifié ; le dû au partenaire (`productAmount`) reste intact ; seul `resolveCashRemittance` peut arrêter un montant [V].
- Conséquence réelle : c'est le **livreur** qui reste débiteur du partenaire (`cashRemittance.amountDue`). **Le client n'est débiteur de personne dans le système** : aucun champ, aucune collection, aucun solde négatif possible (constat 0.1).
- `partnerOrderReconciliation` signale `V2_CASH_UNPAID_CONFIRMED_UNSETTLED` tant que `cashRemittance` n'est pas `resolved` [V].
- Aucun chemin de contestation du **client** : `reviewNonPayment` est un examen administratif unique (`PAYMENT_ALREADY_REVIEWED`) [V].

### 3. Options
- **A.** Ne rien faire (statu quo) : le client n'est jamais bloqué.
- **B.** Bloquer le client tant qu'une **décision de clôture** n'existe pas, **sans nouvelle collection** : la créance est portée par la commande (`cashPayment` + clé économique `orderId`), la clôture par le registre de décisions (M-1).
- **C.** Créer une structure de dette client (collection `client_claims`, solde négatif, ou prélèvement futur sur recharge).

### 4. Avantages / risques
A permet à un client ayant « confirmé impayé » de s'effacer ; la perte est supportée par le livreur/partenaire, sans recours. C crée un système financier nouveau (règles Firestore, UI, prélèvements, contestation, droit) et violerait « wallet jamais négatif » ; il faut une mission dédiée, pas un effet de bord. B est minimal et réversible.

### 5. Décision recommandée — B, restreint, à valider
- `cashPayment.verification === 'confirmed_unpaid'` ⇒ obligation **`review`** (bloquante) pour le **client** de la commande, **tant qu'aucune décision de clôture n'existe pour cette commande** dans le registre.
- Clôtures possibles : `paid_by_client_out_of_system` (référence de paiement, N2) ; `written_off_by_platform` (AZ efface la créance, N3 car elle indemnise livreur/partenaire par ailleurs) ; `refuted_after_contest` (le client prouve le paiement ; N2, entraîne la réouverture par une nouvelle revue — décision append-only).
- **Où enregistrer :** dans le registre `reconciliation_decisions` avec `subject:{kind:'order', id}` ; **aucun champ nouveau sur `orders`** n'est nécessaire (le moteur lit les décisions du client, comme pour les flags `resolved`). Option additive plus simple pour les inspecteurs : `orders.cashPayment.clientClaim:{status,decisionId}` écrit par le serveur seulement ; non recommandée avant analyse de tous les consommateurs d'`OrderModel`.
- **Rapprochement avec la commande :** clé = `orderId` ; montant = `cashPayment.theoreticalTotal` (ou `productAmount`+frais selon la définition retenue — **à fixer**).
- **Paiement ultérieur :** aucun flux n'existe aujourd'hui pour qu'un client règle une commande espèces non payée. Tant qu'il n'existe pas, la clôture se fait par décision humaine (référence du paiement hors système).
- **Contestation :** le client contacte le support ; le super-admin enregistre `contested` (revue) puis une décision. Pas de nouvelle UI dans ce lot.
- **Éviter la double comptabilisation :** les trois lectures d'une même commande (`cashPayment` du client, `cashRemittance`/flag `cash_shortfall` du livreur et du partenaire) sont **trois positions d'une chaîne** (client → livreur → partenaire) pour **le même argent**. Règle : chaque compte ne voit que **sa propre position** ; le snapshot d'un compte porte **un seul montant par `orderId`** ; aucune somme inter-rôles. La clôture de la créance client réduit la position du livreur seulement par décision explicite.
- **Limite connue :** les commandes espèces historiques (non v2) n'ont pas de `cashPayment` : aucun blocage possible.

### 6. Conséquences
- **2D-1 ter :** nouvelle règle client `cashPayment.confirmed_unpaid` + lecture du registre (donc paramètre `decisions` ou prédicat appelant) ; clé `economicKey = orderId`.
- **2D-2 :** lecture des décisions pour le client.
- **Outil :** actions `paid_by_client_out_of_system`, `written_off_by_platform`, `contest`.
- Si vous retenez A (statu quo), documenter explicitement que le recours contre le client est abandonné à l'anonymisation.

### 7. Validation humaine impérative
(a) La créance sur le client existe-t-elle en droit/contrat (CGU) et qui en est titulaire : AZ, livreur, partenaire ? (b) Doit-on bloquer la suppression d'un client pour une dette espèces, ou accepter l'abandon ? (c) Montant de référence ; (d) autorisez-vous `written_off_by_platform` et à quel niveau d'approbation ? (e) Souhaitez-vous une mission dédiée pour un vrai flux de règlement client (hors périmètre ici) ?

---

## M-5 — Exclusion des commandes wallet v2

### 1. Problème exact
7E-97 excluait les v2 (« réglées à la création ») ; 7E-100 les traite comme obligation si livrées avec `isPaid !== true`.

### 2. Éléments observés [V]
- Les trois fonctions de devis v2 écrivent `isPaid: paymentMethod === 'wallet'` à la création (`partnerOrderQuote.js:320`, `catalogQuote.js:209`, `deliveryQuote.js:222`) : une commande v2 wallet conforme vaut **toujours** `isPaid:true`.
- `partnerOrderReconciliation.js:78` : `isPaid !== true` sur v2 wallet ⇒ anomalie **haute** `V2_WALLET_NOT_MARKED_PAID` ; `V2_CLIENT_DEBIT_MISSING` (critique) si aucun journal de débit.
- `buildPayOrderFromWallet` refuse les v2 : « **Cette commande ne se règle pas après livraison** » (`orderActions.js:~78`) : **aucun chemin client** ne peut payer une v2 non marquée payée.
- D1 à D6 : aucune ne concerne l'exclusion v2 ; D6-b (paiement d'une commande engagée) vise `payOrderFromWallet` (non v2).

### 3. Options
- **A.** Maintenir 7E-100 (v2 wallet livrée non payée = bloquant).
- **B.** Revenir à 7E-97 (v2 exclue).
- **C.** Maintenir, **et** exiger en plus la preuve d'un journal de débit (comparaison avec `V2_CLIENT_DEBIT_MISSING`).

### 4. Avantages / risques
- A : aucun faux positif sur les données conformes (le cas ne se produit que sur une anomalie). Risque : un client en anomalie reste bloqué sans voie de sortie client (nécessite correction administrative).
- B : masque précisément l'anomalie « haute » et autorise l'anonymisation d'un client dont le débit n'est pas prouvé : risque d'anonymisation prématurée avec perte de la créance.
- C : plus sûr mais exige la lecture du journal wallet dans la transaction d'inspection (coût, plafond de lectures).

### 5. Décision recommandée — A (maintenir), C en réserve
Les preuves des écrivains justifient A. B n'est justifiée par aucune donnée. C est une amélioration ultérieure si vous jugez le risque `isPaid:true` sans débit inacceptable (il est couvert aujourd'hui par le rapport de rapprochement, pas par le moteur).
- **Voie de sortie à prévoir** (pas d'automatisme) : une action administrative de réparation `repair_v2_wallet_payment` (vérifie le journal de débit, pose `isPaid:true`) **ou** une résolution N2 « commande v2 réconciliée » dans l'outil M-1. Sans elle, le client en anomalie est bloqué.
- Documenter que la spécification 7E-97 §4.2 est amendée sur ce point.

### 6. Conséquences
- **2D-1 :** aucun changement. **2D-2 :** aucun. **Outil :** ajouter la résolution `order_flag_reconciled` ou l'action de réparation.

### 7. Validation humaine impérative
(a) Confirmez-vous le maintien de la règle actuelle ? (b) Acceptez-vous qu'un client en anomalie soit bloqué jusqu'à correction administrative ? (c) Voulez-vous la preuve de débit (option C) avant 2D-2 ?

---

## M-6 — Contrat de lecture des données

### 1. Problème exact
7E-101 D-1 : `limit` déclaré librement ; D-2 : une seule paire `{limit,size}` par liste alors que certains rôles nécessitent plusieurs requêtes.

### 2. Éléments observés [V]
- Les inspecteurs lisent avec `limit(201)` par requête et bloquent à `size >= 201` (`history_requires_manual_review`) ; cumul `related ≥ 200` (toutes collections confondues) ⇒ blocage.
- `inspect()` : une requête `orders` (`clientId` ou `driverId`) ; `readDeletionScope` : pour chaque profil, `orders` par `sellerId` **et** `restaurantId`/`pharmacieId`/`boulangerieId` selon le rôle (jusqu'à 2 requêtes par profil, identifiant d'établissement ou personnel) ; `financialBlocker` : requêtes `orders` par `pharmacieId`.
- Champs des documents à lire : `transfer_settlements` : `clientId`, `driverIds[]`, `holderDriverId` ; `reconciliation_flags` : `clientId`, `driverId`, `partnerId`, `sellerId`, `pharmacieId` (+ `agentId` Ekbine). Lecture des règlements réservée côté client aux `driverIds` (règles) ; Admin SDK pour les inspecteurs.
- Aucun index composite listé pour ces collections ; des requêtes d'égalité ou `array-contains` mono-champ utilisent les index automatiques [V `firestore.indexes.json`].

### 3. Options
- **A.** Format `reads.<liste> = { queries:[{key,limit,size}] }` + table des requêtes **exigées** par le module selon le rôle.
- **B.** L'appelant ne fournit qu'un booléen « complet » (déjà rejeté).
- **C.** Requêtes ciblées par état (index composites) pour réduire les volumes.

### 4. Avantages / risques
A permet de prouver qu'**aucune requête n'a été omise** ; la table doit rester synchronisée avec les inspecteurs (test de contrat). C réduit la volumétrie mais exige de nouveaux index (déploiement) et rate des formes historiques : à garder pour plus tard.

### 5. Décision recommandée — A
**Constante** `READ_LIMIT = 201` (le module refuse toute autre valeur de `limit`).
**Requêtes exigées (clés) par rôle et liste :**
| Rôle | `orders` | `settlements` | `flags` |
|---|---|---|---|
| client | `clientId` | `clientId` | `clientId` |
| livreur | `driverId` | `driverIds` (array-contains) **et** `holderDriverId` | `driverId` |
| pharmacie / seller / restaurant / boulangerie | `sellerId` **et** le champ spécifique (`pharmacieId` / `restaurantId` / `boulangerieId`) pour chaque identifiant (personnel + établissement) | — | `partnerId`, `sellerId`, `pharmacieId` |
**Preuve de couverture :** `reads.<liste> = { queries:[{ key, id, limit:201, size }, …] }` où `id` est l'identifiant interrogé. Le module vérifie : (1) l'ensemble des couples `(key,id)` fournis est **exactement** celui exigé pour le rôle et les `ids` ; (2) chaque `size < 201` ; (3) `max(size) ≤ longueur ≤ Σ size` (union entre bornes) ; (4) chaque document correspond à au moins un couple. Toute omission, clé inconnue ou duplicata de clé ⇒ ambigu bloquant.
**Pagination :** **aucune** dans l'inspection transactionnelle (cohérence). Une requête qui atteint 201 bloque pour revue manuelle (inchangé). *Limitation connue :* un compte à plus de 200 documents d'un type n'est jamais supprimable automatiquement ; un traitement par support (outil paginé hors transaction) est possible mais **hors périmètre** — question ci-dessous.
**Doublons :** union dédoublonnée par chemin de document **avant** appel (Map) ; le module bloque encore sur identifiant répété dans une liste (défaut d'appelant).
**Fail-closed :** erreur de lecture ⇒ la transaction échoue (aucune anonymisation, `failurePatch`) ; `financialBlocker` (hors transaction) doit propager l'erreur et **relire** dans l'étape destructive ou être migré dans une transaction.
**Budget :** ≈ 8 requêtes × 201 documents par inspection (≈ 1 600 lectures au pire), exécutées deux fois (avant tombstone, avant anonymisation) ; à mesurer en préproduction avant tout déploiement.
**Prouver l'examen complet :** `financialSnapshot.coverage` = reçu des requêtes (clés, `limit`, `size`) + `evaluated:{orders,settlements,flags}` + indicateur de plafond, recalculé à l'anonymisation ; deux reçus identiques = même périmètre.
**Séparation des collections :** n'envoyer au module que les documents de `orders` (`doc.ref.parent.id === 'orders'`) ; les autres collections de commandes restent aux inspecteurs.

### 6. Conséquences
- **2D-1 ter :** `reads.queries`, table de requêtes, `READ_LIMIT`, tests de contrat (la table est comparée aux requêtes réelles des inspecteurs, comme C6b).
- **2D-2 :** chaque inspecteur construit son reçu ; tests d'omission de requête.
- **Outil :** aucune.

### 7. Validation humaine impérative
(a) Acceptez-vous qu'un compte à plus de 200 documents d'un type reste bloqué (revue manuelle) ou demandez-vous un traitement paginé par le support ? (b) Un budget de ~1 600 lectures par inspection est-il acceptable (coût / durée) ? (c) Faut-il unifier `financialBlocker` dans une transaction ?

---

## Récapitulatif des décisions à approuver
| # | Décision proposée | Impact |
|---|---|---|
| M-1 | Outil à matrice stricte, registre de décisions append-only, 3 niveaux, maker-checker, renonciation seulement pour créances d'AZ ou avec consentement du créancier | nouvelle Cloud Function + collection + règles ; module 2D-1 ter |
| M-2 | `recorded` **bloquant** jusqu'à décision de clôture ; paiement partiel laisse ouvert ; contestation = revue | **inverse 7E-100** ; actions de recouvrement |
| M-3 | Séparer « réautoriser une tentative » et « fermer le flag » ; ne plus écraser les flags | amende 7E-97 §6.2 |
| M-4 | Bloquer le client sur `confirmed_unpaid` jusqu'à décision, sans nouvelle structure de dette | règle moteur + registre ; limite : commandes espèces non v2 |
| M-5 | Maintenir v2 wallet non payée = bloquant ; prévoir une voie administrative de réparation | aucun changement du module |
| M-6 | `reads.queries` avec requêtes exigées par rôle, `READ_LIMIT=201`, aucune pagination | module + tests de contrat |

## Séquence proposée (non approuvée)
1. Vous tranchez les questions des sections « Validation humaine » (en priorité : maker-checker, qui supporte `cash_shortfall`, séparation M-3, dette client).
2. Mission « 2D-1 ter » : module et tests seulement (M-1 `resolved` strict, M-2, M-4, M-6, D-1, D-2, D-6, trous de tests de 7E-101).
3. Mission de spécification détaillée + code de l'outil de résolution (Cloud Function, règles, tests ; **sans déploiement**).
4. Seulement ensuite 2D-2 (intégration des trois inspecteurs). Une intégration fail-closed sans l'outil est techniquement possible mais laisserait bloqués tous les comptes concernés par un flag `open` ou un reliquat `recorded`.

## Questions de validation, regroupées (réponse requise avant toute implémentation)
1. Combien de super-admins distincts existent-ils (maker-checker possible) ? 2. `waived_by_decision` : autorisé ? catégories ? seuil `de_minimis` ? 3. Qui supporte un reliquat `cash_shortfall` ? 4. Le client doit-il être bloqué pour dette espèces confirmée ? 5. Approuvez-vous la séparation levée de verrou / fermeture de flag (M-3) ? 6. Maintien de la règle v2 (M-5) et voulez-vous la preuve de débit ? 7. Comptes à plus de 200 documents : revue manuelle ou traitement paginé ? 8. Où est stocké le consentement écrit d'un créancier ?

## Limites de ce rapport
Aucune donnée de production consultée ; aucun test exécuté (aucun code modifié) ; format des journaux de commission (`commission_untraced`) à confirmer **[?]** ; la définition du créancier de `commission_untraced` et de `seller_review` est une inférence **[I]** ; les seuils (délai 24 h, montants) sont des paramètres que vous devez fixer.

## État Git
HEAD `d65c8f0` ; index vide ; aucun commit/push/déploiement ; seuls changements de cette mission : ce rapport (97 entrées de travail au total, les 96 existantes préservées).
