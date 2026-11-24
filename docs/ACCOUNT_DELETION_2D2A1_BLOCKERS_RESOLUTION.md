# 2D-2A.1 — Levée des bloquants avant le writer de décisions

Spécification uniquement. HEAD `d65c8f0`, index vide. Aucun code, test, règle Firestore, writer ni inspecteur modifié ; aucun émulateur, accès distant ni accès production (`az-express-b0469`). Compléments : `ACCOUNT_DELETION_2D2A_TECHNICAL_CONTRACT.md`, `ACCOUNT_DELETION_2D2A_FIRESTORE_READ_MATRIX.md`, `ACCOUNT_DELETION_2D2A1_WRITER_SECURITY_MATRIX.md`.

Légende : **[C]** démontré par une source citée ; **[M]** décision métier fournie ; **[P]** proposition ; **[R]** risque ; **[H]** validation humaine encore nécessaire.

## Décisions de référence reprises [M]

Le moteur reste la référence des obligations ; il s'ajoute aux protections existantes sans les remplacer ; N3 bloquant ; N2/N3 = deux responsables indépendants, en attente avec un seul super-admin ; `paid_by_client_out_of_system` indisponible ; délai de 24 h non approuvé, non implémenté ; production interdite ; agents Ekbine, immobilier et flotte conservent leurs protections actuelles.

## Synthèse

| Question | Statut | Ce qui reste à décider par un humain |
|---|---|---|
| Q2 `driverIds` | **Résolue** (démontrée) | rien d'obligatoire ; valider l'omission résiduelle |
| Q4 schéma décisions/preuves | Schéma proposé | validation du schéma, des chemins et des règles |
| Q5 origine Ekbine | Faits démontrés, conception proposée | accepter la modification future du writer Ekbine ; sort des anciens flags |
| Q10 writers financiers | **Audit rendu** (statique) | autoriser les corrections P1/P2 comme prérequis de 2D-2B |
| Q16 paiement client hors système | Maintenu indisponible ; prérequis listés | définition métier complète |
| Q17 séquence avant suppression Auth | Séquence proposée ; **correction** d'une erreur de 2D-2A | validation de la séquence ; test de concurrence |

---

## Q2 — Requête sur `driverIds`

**Réponse technique démontrée [C]** :

| Point | Constat | Source |
|---|---|---|
| Collection | `transfer_settlements`, identifiant de document = `orderId` | `orderActions.js:136, 1030` |
| Champ | `driverIds` | `earningsSettlement.js:184` |
| Type réel | tableau issu de `proposal.chain` = `[...driverHistory.map(h => h.driverId), order.driverId]` | `earningsSettlement.js:102-105` |
| Cardinalité | 1 à plusieurs éléments : un livreur par maillon de transfert ; doublon marqué `driver_appears_twice`, maillon vide `driver_chain_incomplete` (le tableau peut alors contenir un élément non conforme) | `earningsSettlement.js:105-108` |
| Opérateur existant | `where('driverIds', arrayContains: driverId)` dans l'application | `lib/screens/driver/driver_transfer_page.dart:133` |
| Règle de lecture | `request.auth.uid in resource.data.driverIds` | `firestore.rules:1703` |
| Champ complémentaire | `holderDriverId` = `order.driverId` au moment de la création : égalité simple | `earningsSettlement.js:185` |
| Usage du moteur | un règlement est « lié » au livreur si `driverIds` contient l'un de ses ids **ou** si `holderDriverId` en fait partie | `accountObligations.js:478-480` |

**Opérateur requis : `array-contains` sur `driverIds`, `==` sur `holderDriverId`** [C]. Les deux requêtes sont nécessaires et ne sont pas redondantes : `orders.driverId` ne contient que le **dernier** livreur ; un livreur situé plus tôt dans la chaîne n'apparaît dans aucune commande par `driverId`, mais seulement dans `driverIds` d'un règlement (`earningsSettlement.js:102-105`).

**Index [C]** : `firestore.indexes.json` ne contient aucune entrée pour `transfer_settlements` ni `reconciliation_flags` et `fieldOverrides` est vide (`firestore.indexes.json:822`). Une requête à un seul filtre (`==` ou `array-contains`) s'appuie sur l'index mono-champ automatique : **aucun index composite n'est requis** si la requête ne contient ni tri ni second filtre. Ne pas ajouter `orderBy` : un tri exigerait un index composite.

**Risques d'omission [R]** :
1. Un règlement dont `driverIds` est absent ou n'est pas un tableau échappe à `array-contains` ; `holderDriverId` le rattrape seulement pour le dernier livreur. Le moteur signale déjà un `driverIds` non tableau quand il le lit, mais il ne le lit que s'il a été retourné par une requête.
2. Un règlement dont `holderDriverId` est nul (`order.driverId || null`, `earningsSettlement.js:185`) n'est trouvé que par `driverIds`.
3. Les commandes non livrées n'ont pas de règlement : sans objet.
4. Le champ est écrit à la création du règlement ; une valeur ultérieurement modifiée par un autre writer n'est pas vérifiée dans cette mission **[non confirmé]**.

**Décision métier** : aucune nécessaire. **Proposition [P]** : la requête de règlement du livreur est `array-contains` sur `driverIds` **et** `==` sur `holderDriverId`, chacune `limit(201)`, reçu de couverture pour les deux clés (c'est exactement ce que `requiredQueries` attend). **[H]** : confirmer qu'une omission résiduelle (risque 1) est tolérée, ou demander un contrôle complémentaire par les commandes terminées.

---

## Q4 — Collections `decisions` et `evidence`

Aucune collection n'est créée et aucune règle modifiée. Noms et schéma ci-dessous sont des **propositions** [P], conçus pour satisfaire exactement `verifyDecision` (`accountObligations.js:507-565`).

### Chemins et identifiants

| Collection | Chemin | Identifiant du document |
|---|---|---|
| Décisions | `account_deletion_decisions/{decisionId}` | `dec_<requestId>` : dérive du `requestId` ; `create` échoue si le document existe, ce qui garantit l'unicité du `requestId` au niveau global, pas seulement dans le registre fourni au moteur |
| Événements d'une décision | `account_deletion_decisions/{decisionId}/events/{seq}` | `seq` entier croissant sur 6 chiffres (`000001`) |
| Preuves | `account_deletion_evidence/{evidenceId}` | `ev_<requestId>` (une preuve par décision) |
| Annulations | `account_deletion_supersessions/{decisionId}` | identifiant de la décision annulée |

Contraintes de forme : `decisionId` et `evidenceId` respectent `^[A-Za-z0-9_.:-]{1,128}$` (`ID_PATTERN`) ; `requestId` respecte `^[A-Za-z0-9_.:-]{16,128}$` (`REQUEST_ID_PATTERN`), donc `dec_` + `requestId` ≤ 132 caractères : **limiter `requestId` à 124 caractères** dans le writer [P].

### Champs d'une décision

Champs lus par le moteur [C] : `status` ('executed' seulement), `subjectKind`, `subjectId`, `subjectType`, `resolution`, `requestId`, `requestedBy`, `tier`, `remaining`, `approvedBy`, `requestedAtMs`, `approvedAtMs`, `evidenceRef`.

Champs ajoutés pour la traçabilité, ignorés par le moteur [P] : `schemaVersion`, `orderId`, `claim:{amount,currency:'XOF',beneficiaryId}` (copie figée de la créance telle que calculée par le serveur), `origin:{uid,role,action,eventRef,atMs}`, `createdAtMs`, `executedAtMs`, `contentHash` (SHA-256 hex 64 du contenu canonique JSON trié), `previousHash` (chaînage avec l'événement précédent de la même décision), `accountUid` (compte en cours de suppression).

Valeurs temporelles : horodatages en millisecondes issus de l'horloge serveur du writer, jamais d'une entrée client. `approvedAtMs ≥ requestedAtMs > 0` [C].

### Propriétaires des écritures et permissions

| Opération | Qui | Source ou règle |
|---|---|---|
| Création, approbation, exécution | uniquement la Cloud Function du writer (Admin SDK) | **[P]** conforme à CLAUDE.md : collections sensibles `allow write: if false` |
| Lecture | super-admin uniquement | **[P]** |
| Lecture client, livreur, partenaire | interdite | **[P]** |
| Écriture client | interdite (`allow write: if false`, y compris sous-collections) | **[P]** |
| Mise à jour/suppression, y compris par le writer | interdites hors l'unique transition `pending → executed` | **[P]** ; l'immutabilité est une règle de code du writer : l'Admin SDK ignore les règles Firestore **[C]**, donc aucune règle ne peut empêcher le writer de réécrire |

Limite **[R]** : l'immutabilité n'est applicable ni par les règles Firestore ni par le moteur. Elle repose sur (a) un code de writer qui n'expose aucun chemin de modification, (b) le chaînage `previousHash`/`contentHash` qui rend toute altération détectable à la relecture, (c) une copie dans `audit_logs` (également écrite par Cloud Function). Un administrateur ayant accès à la console peut malgré tout modifier un document.

À noter pour la suite : CLAUDE.md énumère les collections en écriture serveur seule ; ajouter ces collections à cette liste serait une modification de la charte, à faire explicitement lors de 2D-2B **[H]**.

### Champs d'une preuve

Champs lus par le moteur [C] : `status:'verified'`, `decisionId`, `subjectKind`, `subjectId`, `resolution`, `verifiedBy`, `verifiedAtMs`, et pour les règlements hors système : `amount`, `currency:'XOF'`, `beneficiaryId`, `orderId`, `paymentRef`, `contentHash` (hex 64), `immutable:true`.

Propositions [P] : `storagePath`, `sizeBytes`, `mimeType` (le serveur relit les octets du fichier, recalcule `contentHash`, ne copie jamais un hash fourni), `capturedAtMs`, `requestId`, `accountUid`, `createdBy`. L'accès au fichier est limité par les règles Storage actuelles (non modifiées).

### Liens

`requestId` → `decisionId` (`dec_<requestId>`) → `evidenceRef` (`ev_<requestId>`) ; la décision porte `subjectId` (identifiant du flag, par exemple `<orderId>_partner_credit_missing`) et `orderId` ; le flag porte `resolutionDecisionId` et `resolutionRequestId` (`accountObligations.js:559-563`). Le lecteur d'inspecteur charge pour chaque flag `resolved` : le flag, `account_deletion_decisions/{resolutionDecisionId}`, puis `account_deletion_evidence/{evidenceRef}` ; tout échec de lecture ⇒ blocage (matrice de lecture §5).

### Correction d'une décision erronée

Une décision exécutée n'est jamais modifiée [P] :
1. Une nouvelle écriture `account_deletion_supersessions/{decisionId}` (`create` seulement) enregistre : qui, quand, motif, nouvelle décision éventuelle, empreinte.
2. Le **chargeur** de l'inspecteur, avant d'appeler le moteur, remplace le `status` de toute décision annulée par `'revoked'` : le moteur n'accepte que `'executed'` et traite tout autre statut comme non vérifié (`accountObligations.js:515`) **[C]**. La transformation est un contrat de l'appelant **[P]**.
3. Annuler une décision rouvre le flag : celui-ci ne devient pas `resolved` par la seule annulation. Le writer remet son statut à `open` via une écriture serveur tracée **[P, H]**.
4. L'annulation exige les mêmes niveaux de validation que la décision (deux responsables pour N2) **[P]**.
5. Si la suppression du compte est déjà terminée, la correction est historisée uniquement (pas de réouverture possible) **[P]**.

**Risques [R]** : collisions de `requestId` (traitées par la création unique), preuve falsifiée par un administrateur Storage, correction tardive après suppression. **Validation humaine [H]** : noms de collections, mise à jour de la liste CLAUDE.md, règles Firestore/Storage à rédiger en 2D-2B, politique de conservation.

---

## Q5 — Origine des flags Ekbine

### Faits démontrés [C]

| Flag | Création | Champs écrits | Auteur réel | Atomicité |
|---|---|---|---|---|
| `ekbine_cancel_unproven_debit` (`ekcancel_<orderId>`) | `ekCancelOrderCF`, `ekbineOrders.js:264-268` | `kind, orderId, clientId, status:'open', createdAt` | le **client** appelant (`uid = request.auth.uid`, `ekbineOrders.js:201`) | **hors transaction**, après le commit de l'annulation ; écriture précédée d'un `logAudit` qui avale ses erreurs (`index.js:300-312`) |
| `ekbine_confirm_unproven_debit` (`ekconfirm_<orderId>`) | `ekClientConfirmOrder`, `ekbineOrders.js:318-322` | `kind, orderId, clientId, agentId, amount, status:'open', createdAt` | le **client** confirmant (`uid`, `ekbineOrders.js:285`) | **dans** la transaction, avec une ligne `audit_logs` (`action:'ekbine_confirm_order'`, `userId`, `targetId`, `creditReason`) |

Autres constats [C] : aucun champ `decidedBy`, `actor`, `role` ni référence d'événement n'est écrit ; l'identifiant du flag est dérivé de la commande ; le champ de type est `kind` (le moteur accepte `type` ou `kind`, `accountObligations.js:174`) ; l'annulation inscrit `cancelledBy: uid` et `cancelledAt` sur la commande **dans la transaction** (`ekbineOrders.js:244-248`).

### Ce que signifie « origine » ici

Pour `cash_shortfall`, `seller_review`, etc., l'origine est un **administrateur** qui a pris la première décision (`decidedBy`, `adminOrderDisputes.js:511, 520` ; `partnerOrderActions.js:363`). Pour les flags Ekbine, personne n'a « décidé » : le flag est une conséquence automatique de l'action du **client** sur une commande dont le débit n'est pas prouvé. L'origine est donc l'**acteur déclencheur** (le client) et l'événement, pas un décideur humain. **[H]** : confirmer que cette lecture satisfait l'exigence « approbateur ≠ décideur initial » (l'indépendance vis-à-vis du client est alors triviale, l'indépendance réelle venant de la règle demandeur ≠ approbateur).

### Conception proposée [P] (aucune modification de code dans cette mission)

Le futur writer de flags Ekbine, **côté serveur uniquement**, inscrit sur tout nouveau flag :

```
origin: { uid, role: 'client', action: 'ek_cancel_order' | 'ekbine_confirm_order',
          eventRef: 'ekbine_orders/<orderId>' | 'audit_logs/<id>', atMs, orderStatusAtCreation }
decidedBy: <uid>   // alias lu par le moteur (`f.decidedBy`) pour ne pas changer le moteur
```

Vérifiabilité côté serveur au moment de la résolution [P] :
1. `origin.uid` doit être égal à `clientId` du flag **et** à `ekbine_orders/{orderId}.cancelledBy` (annulation) ou au `userId` de la ligne `audit_logs` référencée (confirmation).
2. `origin.atMs` doit égaler `cancelledAt` (annulation) ou `createdAt` de la ligne d'audit (confirmation), à la tolérance près d'une conversion de type.
3. `origin.role` est écrit par le serveur d'après la collection du profil (`clients`), jamais d'après une entrée.
4. L'écriture du flag est déplacée **dans la même transaction** que le fait générateur pour supprimer le risque de flag perdu lors d'un arrêt entre commit et écriture (`ekbineOrders.js:249-268`) **[R]**.

Anciens flags (sans `origin`) : leur résolution N2 reste **impossible** (`ORIGIN_DECIDER_REQUIRED`, `accountObligations.js:243`) **[C]**. Option de reconstitution depuis `ekbine_orders.cancelledBy`/`audit_logs` par un outil administratif traçable : **[H]**, non décidé.

**Risque [R]** : les anciens flags `ekcancel_*` créés puis perdus (arrêt avant écriture) n'ont jamais existé : une commande annulée avec `refunded:false` et `paymentMethod:'wallet'` sans flag correspondant est une obligation silencieuse que le moteur ne voit pas **[non quantifié]**.

**Conclusion** : tant que le writer n'écrit pas `origin`/`decidedBy` de façon vérifiable, aucune résolution N2 Ekbine n'est possible. C'est déjà le comportement du moteur (7E-107) [C].

---

## Q10 — Protection des writers financiers

Matrice complète : `ACCOUNT_DELETION_2D2A1_WRITER_SECURITY_MATRIX.md`. Points essentiels :

1. **Dotés d'une garde** : création de commandes par devis, boutique, recharge et retrait FeexPay, webhook FeexPay, recharges administratives, Ekbine création/acceptation/confirmation (pour l'agent), réservations d'événements [C].
2. **Sans garde de suppression trouvée** : `cancelOrderCF`, `deliverOrderCF`/`adminConfirmDeliveryCF`, `payOrderFromWalletCF`, `refundExpiredBoutiqueOrderCF`, `releaseOrderBeforePickupCF`, `settleTransferEarningsCF`, `adminBillingCF`, `adminOrderDisputeCF`, `partnerOrderActionCF`, `ekCancelOrderCF`, `autoExpireOrders` [C par recherche statique].
3. **Capables de créer une obligation pendant la suppression** : tous ceux qui posent un flag (`commission_untraced`, `partner_credit_missing`, `cash_payment_review`, `cash_shortfall`, `seller_review`, `driver_advance_unreimbursed`) ou un règlement `pending_review`.
4. **Capables de créditer un bénéficiaire anonymisé** : `settleTransferEarningsCF` (chaîne de livreurs), `adminBillingCF`, `adminOrderDisputeCF`, remboursements de `cancelOrderCF`/`autoExpireOrders`.
5. **Capables d'agir après l'inspection sur une commande terminée** : les quatre fonctions d'administration (litiges, facturation, actions partenaire, règlement des gains) [C].

**Conséquence [R]** : même avec le moteur et la relecture de Q17, ces writers peuvent créer une obligation après la dernière inspection, car ils ne consultent pas le marqueur de suppression. La séquence de Q17 ne ferme donc pas la fenêtre tant que ces gardes ne sont pas posées. **Décision proposée [P, H]** : poser les gardes P1/P2 de la matrice §4 **avant** d'activer l'intégration du moteur (condition d'entrée de 2D-2B).

---

## Q16 — Paiement client hors système

`paid_by_client_out_of_system` reste **indisponible** [M] ; le moteur l'exclut aujourd'hui (aucune créance n'est définie, `clientCashCaseClosed` ne fournit pas de `claim`, `accountObligations.js:615`) [C]. Aucune dette n'est créée, aucune clôture automatique proposée.

Informations à définir par le métier avant tout déblocage [H] :

| Information | Question à trancher |
|---|---|
| Créancier | Qui est créancier d'un paiement espèces non réglé : le partenaire, le livreur, la plateforme ? Le flag actuel (`cash_payment_review`) ne le dit pas. |
| Montant | Quelle source fait foi : `theoreticalTotal` de la commande (`cashPayment.js`), montant confirmé par le partenaire, ou montant arbitré ? |
| Commande | Identifiant unique du litige et de la commande ; traitement d'une commande à paiements partiels. |
| Preuve | Quelle preuve fait foi pour « le client a payé hors système » ? Qui la fournit ? Comment le serveur la vérifie (relecture réelle d'un justificatif, par exemple un reçu du créancier) ? |
| Autorité de validation | Deux responsables indépendants ? Le créancier doit-il confirmer lui-même (consentement) ? |

Tant que ces cinq points ne sont pas définis, la décision reste en attente et le dossier bloqué.

---

## Q17 — Relecture avant suppression Auth

### Correction préalable [C]

Mon rapport 2D-2A affirmait qu'aucune relecture n'existe entre la quarantaine et l'étape irréversible. C'est **inexact** : à la reprise, `process()` ré-exécute `inspect()` dans la transaction de bail (`accountDeletion.js:85`), après `QUIET_MS` (15 min, `accountDeletion.js:83`), **avant** tout appel Auth. Ce que le code actuel ne couvre pas est la fenêtre entre le commit de ce bail et `auth.deleteUser` (`accountDeletion.js:98-110` : `inspectCleanup` non transactionnel, `auditStrict`, `updateUser`/`revokeRefreshTokens`/`deleteUser`).

### Séquence actuelle [C]

1. **T1** : transaction d'inspection (identité, `inspect()`), création du tombstone, `isSuspended:true`, état `quarantined` (`accountDeletion.js:85-90`).
2. Attente `QUIET_MS`.
3. **T2** : transaction de bail : `inspect()` à nouveau, bail de 180 s (`accountDeletion.js:85-92`).
4. Hors transaction : `inspectCleanup`, `auditStrict`, `updateUser({disabled:true})`, `revokeRefreshTokens`, `deleteUser`, contrôle de disparition (`accountDeletion.js:98-110`).
5. **T3** : après suppression Auth, nettoyage puis transaction finale avec `inspect()` (`accountDeletion.js:124-133`). **Aucune protection** : l'opération irréversible a eu lieu. Un blocage ici laisse l'état `cleanup_pending`.

### Séquence cible proposée [P]

1. **T1** (inchangée en structure) : identité, `inspect()` **étendu par le moteur** (lectures de la matrice), tombstone, suspension, quarantaine. Toute obligation, lecture incomplète (`*_truncated`) ou erreur ⇒ `blocked`, aucun tombstone.
2. **Attente** `QUIET_MS`.
3. **T2** (bail) : `inspect()` + moteur à nouveau ; écriture du snapshot financier et d'un jeton de bail.
4. Contrôles non transactionnels existants (`inspectCleanup`, `auditStrict`) : **avant** la désactivation Auth, de sorte qu'il ne reste plus d'opération longue entre la dernière relecture et l'étape irréversible.
5. **Désactivation réversible** : `auth.updateUser(uid,{disabled:true})` + `revokeRefreshTokens` (code actuel `accountDeletion.js:106`), **sans** `deleteUser`. Un compte désactivé ne peut plus ouvrir de session ni obtenir de nouveau jeton ; les jetons d'identité déjà émis restent toutefois valides jusqu'à leur expiration tant que les callables ne vérifient pas la révocation, ce que je n'ai pas contrôlé **[H]**. L'état est réversible par `updateUser(uid,{disabled:false})`. Le tombstone, lui, bloque immédiatement les écritures client via `isAuth()` (`firestore.rules:7-11`) **[C]**.
6. **T2b — relecture financière finale** : transaction `inspect()` + moteur, avec vérification du bail et du tombstone, comparaison des empreintes de snapshot avec T2 (tout écart = nouvelle obligation ou changement d'état). 
   - Obligation nouvelle, lecture incomplète, erreur de lecture, bail expiré ou écart de snapshot : **arrêt immédiat** ; `updateUser(uid,{disabled:false})` si le compte doit être rendu ; état `blocked`, `reviewRequired:true` ; aucun appel à `deleteUser`.
   - Sinon : T2b écrit `authDeleteAuthorizedAtMs` et la durée de validité (par exemple 60 s).
7. **`auth.deleteUser`** immédiatement après T2b, puis contrôle d'absence (code actuel). Si le délai de validité est dépassé, retour à l'étape 6.
8. T3 (nettoyage et anonymisation) : conserve son `inspect()` comme contrôle de cohérence, **jamais comme protection**.

### Fenêtres de concurrence [C/R]

| Fenêtre | Écrivains concernés | Protection actuelle | Protection de la séquence cible |
|---|---|---|---|
| Entre T1 et tombstone | writers à garde (sérialisés sur le document tombstone) | oui | idem |
| Entre T1 et T2b | writers à garde : refusés par le tombstone. Writers **sans** garde (voir matrice) : non refusés | non | T2/T2b détectent leurs effets **s'ils sont visibles dans les lectures** |
| Entre T2b et `deleteUser` | writers sans garde | non | **non fermée par la relecture** : résiduelle, fermée uniquement par les gardes P1/P2 des writers |
| Après `deleteUser` | tous | sans objet | aucune : ne jamais compter la relecture T3 comme protection |

La fenêtre T2b → `deleteUser` ne peut pas être fermée par la seule relecture : Firestore et Auth ne partagent aucune transaction. Les deux protections réelles sont (1) le tombstone (règles client) et la désactivation du compte (nouvelles sessions), (2) des gardes dans chaque writer qui lit le tombstone **dans sa propre transaction** (`assertNewAccountActivity`). La séquence réduit la fenêtre à quelques secondes mais ne la supprime pas **[R]**.

**Question non résolue [H, Q11]** : la façon dont Firestore traite l'insertion concurrente d'un document correspondant à une requête déjà lue dans une transaction n'a pas été démontrée ici. La conception ne repose donc pas sur cette propriété : elle repose sur le tombstone, les gardes des writers et la relecture T2b. Un test de concurrence en préproduction est requis (plan ci-dessous).

Rappel : T3 ne doit jamais être présentée comme une protection.

---

## Plan d'exécution des tests et de l'environnement

Rien n'est exécuté dans cette mission (aucun émulateur).

| Étape | Contenu | Prérequis | État |
|---|---|---|---|
| 1. Node 22.23.4 | exécuter `npm test` dans `functions/` sous Node 22.23.4 en CI ou sur une machine équipée ; ne pas installer de gestionnaire de versions ici ; ne pas assimiler Node 24 | environnement | **non fait** |
| 2. Tests unitaires | 2 241 réussis, 0 échec sous Node 24.22.1 (référence, rapports 7E-108 et 2D-2A) ; à rejouer sous Node 22 | étape 1 | partiel |
| 3. 169 tests ignorés | tous « skipped » pour cause d'émulateur Firestore/Auth/Storage (motifs : 7E-108 §0 et 2D-2A §6) ; à exécuter en environnement autorisé avec émulateurs | autorisation humaine explicite | **non fait** |
| 4. Règles Firestore | `npm run test:rules` (Java requis) ; couvrir les futures collections de décisions et de preuves, y compris l'interdiction d'écriture client | règles rédigées en 2D-2B | non fait |
| 5. Tests de concurrence | (a) writer sans garde vs quarantaine ; (b) writer à garde vs quarantaine ; (c) insertion d'un flag entre T2 et T2b ; (d) deux demandes de décision avec le même `requestId` ; (e) lecture à 201 documents | émulateurs | non fait |
| 6. Tests synthétiques en préproduction | jeu `synthetic-*` (S0 à S6 de 2D-2A §5.4) sur un environnement **distinct de la production** ; aucune donnée réelle | environnement désigné **[H]** | non fait |
| 7. Budget de lectures | compteur de `snapshot.size` + relevé de lectures facturées avant/après ; comparer aux bornes de 2D-2A §5.1 | étape 6 | non fait |

---

## Conditions exactes d'entrée dans 2D-2B

Dépendantes d'une décision humaine :
1. Valider le schéma des décisions et des preuves (Q4), y compris les noms de collections et la mise à jour de la liste des collections serveur-seul de la charte.
2. Valider l'interprétation de l'origine Ekbine (Q5) et décider du sort des anciens flags sans `origin`.
3. Décider de poser les gardes P1/P2 de la matrice des writers **avant** l'intégration du moteur (Q10).
4. Valider la séquence T1/T2/T2b de Q17 et la désactivation réversible avant `deleteUser`.
5. Définir les cinq informations de Q16, ou confirmer que `paid_by_client_out_of_system` reste indisponible pour 2D-2B.
6. Désigner l'environnement de préproduction et autoriser l'exécution des émulateurs pour les 169 tests et la concurrence.
7. Confirmer que le délai de 24 h reste hors de 2D-2B.

Dépendantes d'une exécution :
8. Tests sous Node 22.23.4.
9. Plan de tests de concurrence et mesure de budget acceptés.

Autorisation humaine explicite de démarrer 2D-2B : **non donnée**. 2D-2B n'est pas commencé.
