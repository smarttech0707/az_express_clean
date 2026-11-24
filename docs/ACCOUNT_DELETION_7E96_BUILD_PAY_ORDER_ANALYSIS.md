# Mission 7E-96 — Analyse de `buildPayOrderFromWallet` (lot 2C)

Date : 2026-11-09 · HEAD `d65c8f00bdcedba570a66a5633913db46127be3d`, branche `finalisation/az-express`, index vide. **Analyse uniquement** : aucun code du dépôt modifié, aucun `git add`/staging/commit/amend/push/pull/merge/rebase/reset, aucun déploiement, aucune commande distante, aucun secret, FeexPay non activé, aucune suppression. Production `az-express-b0469` intouchée ; émulateurs 5001/8080/9099 non touchés. Seul artefact d'exécution : une **sonde jetable** de 10 tests unitaires sur une copie `git archive HEAD` dans le scratchpad (§8), hors dépôt.
Preuves : **[V]** lu dans le code · **[U]** test unitaire existant ou sonde (faux Firestore) · **[E]** émulateur · **[ND]** non déterminé.

## 0. Corrections de ma propre documentation
- Mes rapports 7E-90/92 situaient `buildPayOrderFromWallet` en « l. 48–493 ». **Faux** : la fonction occupe `functions/orderActions.js` **l. 48–170** ; les l. 172–493 sont `recordPickedUpCancelRequest`, `cancelOrderTx`, `cancelOrderPostTx` (annulation), hors périmètre de cette fonction mais voisins.
- Le registre 7E-87 (§6) postule qu'un client en quarantaine « peut clore une opération engagée » via `payOrderFromWalletCF`. **Le code actuel l'en empêche** (§4.2) : c'est la trouvaille principale de cette analyse.

## 1. Emplacement et fonctionnement [V]
- Définition : `functions/orderActions.js:48`, fabrique `buildPayOrderFromWallet({ db, admin, onCall, HttpsError, checkRateLimit, logAudit })`, exportée l. 1779.
- Câblage : `functions/index.js:2435` — `exports.payOrderFromWalletCF = buildPayOrderFromWallet({ …, onCall: (h) => onCall({ maxInstances: 3 }, h), … })`. Le `onCall` utilisé est le **wrapper local** de `index.js:83`, qui exécute `assertAccountEnabled(db, request.auth?.uid, HttpsError)` avant le handler (voir §4.2). `maxInstances: 3` n'est **pas** passé par `pilotLightOptions` (la fonction est hors pilote : `pilotCap.test.js:45`, `OUT_OF_PILOT`).
- Appelant unique côté application : `lib/screens/client/suivi_commande.dart:1068` (`_WalletPayButton`) → `FirestoreService.payOrderFromWallet` (`firestore_service.dart:256-268`) → `httpsCallable('payOrderFromWalletCF')` avec `{orderId, medicineAmount}` seulement (les autres paramètres sont ignorés côté serveur). Aucun appel par AZ IA (`azia/tools` : seul un commentaire dans `ekbine.js:137`), aucun appel serveur à serveur.
- Réponse : `{ success: true }` ; erreurs `HttpsError` (le client Flutter ne reconnaît que la sous-chaîne `SOLDE_INSUFFISANT`, sinon affiche `Erreur paiement : <message>`).

## 2. Parcours financier complet [V]
1. **Entrée** : `unauthenticated` si pas d'auth ; `orderId` requis ; `checkRateLimit(uid,'pay_order_wallet',20,60)` ; `medAmount = clamp(round(medicineAmount), 0, 500 000)` — **attesté par le client** (aucune autre source de vérité).
2. **Transaction unique** (`db.runTransaction`, l. 64-139). Lecture de `orders/{orderId}` ; refus si inexistante, `clientId !== uid`, `isPaid === true`, `amountsVersion === 2`, ou `driverId` absent. **Aucun contrôle du `status`** de la commande (une commande `cancelled` non payée est payable, §7-R9).
3. `deliveryAmount = order.budget`, `total = budget + medAmount`. Toutes les lectures **avant** les écritures : `clients/{uid}`, `livreurs/{driverId}`, `pharmacies/{pharmacieId}` (seulement si `medAmount > 0` et `pharmacieId`).
4. **Débiteur** : le client (`clientWallet < total` ⇒ `failed-precondition SOLDE_INSUFFISANT:solde:total` ; client sans document ⇒ solde 0 ⇒ même refus, test `orderActions.test.js:1628` [U]). Débit : `wallet - total` (jamais négatif par construction).
5. **Bénéficiaires** : (a) **livreur** `+deliveryAmount`, sauf `order.settlementHold === true` (course transférée) → aucun crédit, `heldDriverEarning` + `settlementStatus:'pending_admin_review'` sur la commande, et, si la commande est déjà `delivered`, création de `transfer_settlements/{orderId}` ; (b) **pharmacie** `+medAmount` si `pharmacieId && medAmount > 0`. Écritures par `tx.update` : si un document bénéficiaire n'existe pas, la transaction **échoue en entier** (sonde P6 [U] : client non débité, commande non marquée payée).
6. Marquage : `isPaid:true`, `paymentMethod:'wallet'`, `medicineAmount` si > 0.
7. **Après validation** (hors transaction, séquentiel) : `wallet_transactions` du client (`payment`), du livreur (`earning`, si non retenu), de la pharmacie (`earning`), puis `logAudit('pay_order_wallet')`. Un arrêt entre la validation et ces écritures laisse **argent déplacé sans journal** (non atomique, §7-R11).
- **Commission** : aucune dans cette fonction (prélevée à l'acceptation, `acceptOrderCF`). **Moment de l'affectation du livreur** : antérieur (`driverId` obligatoire). **Moment de la validation de commande** : `isPaid` seul ; le statut de livraison n'est ni lu ni modifié. **Opérations différées** : pharmacie wallet = paiement **après** livraison ; `deliverOrderCF` ne crédite pas livreur/pharmacie tant que `isPaid` n'est pas vrai (`orderActions.js` ~l. 925-975) ; `transferSettlement` ouvre/approuve le règlement du gain retenu. **Compensations/remboursements** : aucune dans cette fonction ; l'annulation d'une commande **payée** est faite par `cancelOrderTx` (client remboursé `clientSnap.exists`, vendeur « seller » débité, commission rendue).

## 3. Graphe des appels et des consommateurs
```
Flutter suivi_commande._WalletPayButton ──> FirestoreService.payOrderFromWallet ──> payOrderFromWalletCF
                                                                                       │ wrapper onCall: assertAccountEnabled(caller)
                                                                                       └─ buildPayOrderFromWallet : tx{orders, clients, livreurs, pharmacies}
écrit : clients.wallet(−), livreurs.wallet(+) | orders.heldDriverEarning, transfer_settlements/{id} (si retenu), pharmacies.wallet(+), orders.isPaid
lisent isPaid : deliverOrderCF (crédit livreur/marchand), cancelOrderTx (needsClientRefund si isPaid !== false),
                partnerOrderReconciliation (boulangerie standard), transferSettlement (gain retenu)
```
Tests existants : `orderActions.test.js` l. 170-296 (8 cas : nominal, pharmacie, solde, propriétaire, déjà payé, sans livreur, plafond 500 000, non authentifié) + l. 1396 et 1487 (course transférée, ordinaire/livrée) + l. 1628 (client sans document) ; `deliveryQuote.emulator.test.js:135,143` [E] (refus d'une commande déjà payée par devis ; cash puis wallet) ; `partnerOrderConcurrency.emulator.test.js:199` [E] ; `partnerOrderFinancial.test.js:155`. **Aucun test** ne couvre tombstone, `isSuspended` ni `isDeleted`, ni deux appels concurrents sur l'émulateur.

## 4. Matrice des statuts de compte
### 4.1 Faits sur le moteur de suppression [V]
- Quarantaine (`accountDeletion.js` ~l. 83-90) : `inspect()` impose `wallet === 0` (et `debt/pendingBalance/…` nuls), aucune mission en cours, puis **tombstone `account_tombstones/{uid}` + `isSuspended:true`** (pas de `deletionRequested`, pas de `isDeleted`). L'anonymisation (~l. 122-134) **relance `inspect`** (solde nul exigé de nouveau, sinon `cleanup_pending`), pose `isDeleted:true`, supprime les champs personnels, **conserve** `wallet` et `wallet_transactions`.
- Conséquence : un crédit reçu **pendant la quarantaine** rend `wallet ≠ 0` et **bloque l'anonymisation** (le dossier passe en `cleanup_pending` avec revue) — l'argent n'est pas perdu. Un crédit reçu **après** l'anonymisation atterrit sur un profil définitivement anonymisé, sans revue (N1/N2 du registre).
- `readDeletionScope` (`accountDeletionScope.js:3,61`) : statuts `delivered`, `cancelled`, … sont **terminaux** ; ni `isPaid`, ni `settlementHold` ne sont lus. Une commande **livrée mais non payée** n'empêche donc **ni la quarantaine ni l'anonymisation** du client, du livreur ou de la pharmacie (N2 confirmé en lecture).

### 4.2 Le wrapper `onCall` bloque déjà l'appelant en quarantaine [V + U]
`assertAccountEnabled` (`accountDeletion.js:16-19`) refuse tout appelant dont le tombstone existe : `permission-denied / ACCOUNT_DELETION_IN_PROGRESS`. `payOrderFromWalletCF`, `cancelOrderCF`, `deliverOrderCF`, `acceptOrderCF` passent par ce wrapper. Sonde P2 et P10 [U] : client en quarantaine ⇒ refus d'entrée, aucune écriture. **Il n'existe donc, aujourd'hui, aucun chemin par lequel un client (ou livreur) en quarantaine règle, annule ou livre une opération engagée** ; la « clôture légitime sous quarantaine » du registre 7E-87 n'est pas réalisable avec ce wrapper. Elle n'a de sens que pour des appels **serveur** ou **admin** non wrappés, ou si l'on exempte explicitement ces fonctions (décision D6, §10).

### 4.3 Matrice (payer = appelant ; bénéficiaires = livreur, pharmacie)
| Situation | Comportement actuel (preuve) | Autorisé selon règles métier | Écart |
|---|---|---|---|
| **A. Client actif** | paiement correct (sonde P1 [U], tests existants) | oui | aucun |
| **B1. Client en quarantaine (tombstone + `isSuspended`)** — règlement d'une commande livrée non payée | **refusé** par le wrapper (P2 [U]) | à décider (D6) : le registre l'autorise comme restitution, mais l'engine ne devrait pas l'avoir mis en quarantaine (N2) | contradiction registre/code |
| **B2. Client `deletionRequested` seul** | non lu par le wrapper ni par la fonction | n/a (la quarantaine ne pose pas ce drapeau) | contrôles fondés sur ce drapeau inopérants |
| **C. Client anonymisé (`isDeleted`)** | l'appelant n'a plus d'Auth ; si le profil est appelé, `wallet` = 0 ⇒ `SOLDE_INSUFFISANT` (P7 [U]) | refus | aucun risque de débit ; commande restée impayée (N2) |
| **D1. Livreur bénéficiaire en quarantaine (tombstone seul)** | **crédité** (P3 [U]) | oui : service rendu, restitution ; crédit **bloque l'anonymisation** (§4.1) | aucun |
| **D2. Livreur bénéficiaire anonymisé** | **crédité quand même** (P4 [U]) : `wallet` > 0 sur profil `isDeleted` | non automatique (D1/D2 du registre) | **protection absente** |
| **E1. Pharmacie/vendeur bénéficiaire en quarantaine** | créditée (même code) | oui (idem D1) | aucun |
| **E2. Pharmacie bénéficiaire anonymisée** | **créditée** (P5 [U]) | non automatique | **protection absente** |
| **F. Bénéficiaire sans document** | transaction annulée, client non débité (P6 [U]) | refus propre souhaitable | erreur interne opaque |
Distinctions : *nouvelle commande* (lots 2A/2B, bloquée) ≠ *règlement d'une commande engagée* (cette fonction) ≠ *règlement vendeur/livreur* (crédit des bénéficiaires, ici) ≠ *remboursement* (`cancelOrderTx`, `orderRefunds`) ≠ *compensation* (retrait FeexPay en échec, 2C-1).

## 5. Décisions du registre 7E-87 applicables
- **D1** (compensation de retrait) : quarantaine simple ⇒ compensation normale ; profil anonymisé ⇒ aucun crédit automatique, mise en attente. Non modifiée. Ne concerne pas `buildPayOrderFromWallet` (pas de compensation) mais **fixe le principe** à reprendre pour les bénéficiaires.
- **D2** (crédits administratifs) : quarantaine ⇒ crédit autorisé ; anonymisé ⇒ refus automatique, traçabilité, revue. Idem principe.
- **Applicable par analogie à ce lot** (aucune décision n'existe encore pour un *paiement client → bénéficiaire anonymisé*) : voir **D6** (§10).

## 6. Risques financiers (preuve)
| # | Risque | Verdict | Preuve |
|---|---|---|---|
| R1 | Double débit (appels simultanés) | **Protégé par la transaction Firestore réelle** (`isPaid` relu dans la tx) ; **non prouvé** sur émulateur | code l. 72-74 [V] ; test « déjà payé » [U] ; sonde P9 avec le **faux** Firestore : deux appels réussissent (le faux n'a pas de contention optimiste : écriture identique « perdue », un seul débit, deux réponses de succès et deux journaux) → **le faux ne prouve pas la concurrence** [ND] ; émulateur absent |
| R2 | Double crédit | même mécanisme que R1 | idem [ND émulateur] |
| R3 | Débit sans commande validée / commande validée sans débit | impossible : un seul `runTransaction` | [V] |
| R4 | Débit client sans crédit livreur | volontaire (`settlementHold`) ; sinon atomique | [V][U 1396] |
| R5 | Paiement vendeur/livreur bloqué par la quarantaine **du client** | **oui, aujourd'hui** (wrapper) | P2 [U] |
| R6 | Paiement bloqué par la quarantaine **du bénéficiaire** | non : crédité normalement | P3 [U] |
| R7 | Remboursement empêché pour client en quarantaine | **oui** (wrapper bloque `cancelOrderCF`) | P10 [U] |
| R8 | **Crédit sur profil anonymisé** (livreur ou pharmacie) | **présent** | P4, P5 [U] |
| R9 | Paiement d'une commande `cancelled` non payée | possible (aucun contrôle de statut) ; perte de l'appelant seulement | P8 [U] ; hors quarantaine |
| R10 | Paiement différé après anonymisation du bénéficiaire (N2) | **présent** : l'engine n'empêche pas l'anonymisation avec une commande livrée non payée | `accountDeletionScope.js:61` [V] ; P4/P5 [U] |
| R11 | Transaction partiellement exécutée (journaux) | **présent** : `wallet_transactions` et audit hors transaction | l. 141-166 [V] |
| R12 | Concurrence suppression × paiement | tombstone du **payeur** lu hors transaction par le wrapper (non atomique) ; tombstone du **bénéficiaire** jamais lu ; profil bénéficiaire lu en tx ⇒ une anonymisation concurrente provoque conflit/rejeu (la tx relit `isDeleted` si on l'ajoute) | [V] ; émulateur [ND] |
| R13 | Montant `medicineAmount` attesté par le client | existant, hors périmètre ; plafonné 500 000 ; ne crée pas de fonds (le client paie de sa poche) | [V][U] |

## 7. Concurrence et transactions [V sauf mention]
Lectures avant écritures respectées (commentaire l. 93-99, bug passé corrigé) ; idempotence : seulement `isPaid` (pas de clé d'idempotence par requête) ; retries : `runTransaction` rejoue en cas de contention ; tombstone : **non lu dans la transaction** (seulement le wrapper) ; suppression arrivant pendant le paiement : (i) quarantaine du payeur posée après le wrapper ⇒ **le paiement aboutit** (restitution, cohérent avec la politique), le wallet devient > 0 si crédit, mais ici il baisse (débit) ; (ii) anonymisation du bénéficiaire concurrente ⇒ la tx lit son profil, donc un conflit déclenche un rejeu ; **non démontré** (aucun test d'émulateur sur cette fonction). Conclusions tirées du code : R1-R3 ; des tests unitaires : R5-R8, R10 ; d'émulateur : **aucune** pour cette fonction.

## 8. Sonde jetable (preuves [U])
Copie `git archive HEAD functions` dans le scratchpad, `index.js` chargé avec `firebase-admin`/`axios` factices (même méthode que `accountQuarantineIndex.test.js`) : **10/10 tests réussis** (Node 22.23.4), P1…P10 ci-dessus. Données synthétiques ; fichier hors dépôt ; aucun test ajouté au dépôt.

## 9. Relations avec les autres modules
- `transferSettlement` : crédite le livreur du gain retenu sans contrôle `isDeleted` (`l.115-118`) ; `payOrderFromWalletCF` ouvre le dossier quand la commande est livrée → même profil de risque (R8/R10) ; à traiter avec 2C-1/2D.
- `adminBilling`, `adminOrderDisputes`, `adminOrderRefunds`, `partnerOrderActions.refusePartnerOrder` (via `cancelOrderTx`) : crédits/remboursements sans contrôle `isDeleted` ; `cancelOrderTx` crédite `clientSnap.exists` sans lire `isDeleted` (l. 413-415) et la commission au livreur payeur `payerSnap.exists` (l. 430-433).
- `held_for_review` : ne couvre que les paiements FeexPay ; **aucun** mécanisme de mise en attente pour un paiement wallet interne vers un bénéficiaire anonymisé n'existe, sauf le motif `settlementHold`/`pending_admin_review` (réutilisable pour le livreur, pas pour la pharmacie).
- Lots 2A/2B : aucune interaction directe ; ne pas réintroduire de garde « nouvelle activité » (`assertNewAccountActivity`) ici : elle refuserait justement la clôture légitime.

## 10. Proposition de lot 2C (non implémentée)
Principe : **pas de garde générale** sur le payeur ; **garde ciblée sur les bénéficiaires**, et correction de la cause à la source.
1. **Source (lot 2D, prioritaire)** : faire refuser à `readDeletionScope` la quarantaine/anonymisation d'un client, livreur ou partenaire ayant une commande `delivered` avec `paymentMethod:'wallet'` et `isPaid !== true` (ou `settlementHold`/`settlementStatus` non réglé) — fichiers du Commit 1 (`accountDeletionScope.js`), tests dédiés. Cela supprime R10 et rend la question B1 sans objet en pratique.
2. **Garde bénéficiaire dans `buildPayOrderFromWallet` (2C-2a)** : dans la transaction, après les lectures existantes et **avant la première écriture**, calculer pour livreur et pharmacie un état `accountCreditState(profile, tombstone)` → `active | closing | anonymized` (fonction pure dans `accountAdmission.js`, sans lecture supplémentaire hors le tombstone du bénéficiaire).
   - `active`, `closing` (tombstone seul) : crédit normal (D1/D2 : restitution autorisée).
   - `anonymized` (`isDeleted`) : **aucun crédit automatique** ; décision **D6** ci-dessous.
   - Profil absent : refus propre `failed-precondition` avant toute écriture (remplace l'erreur interne opaque).
3. **Payeur** : conserver le wrapper tel quel ; ajouter seulement, dans la tx, un refus fail-closed si `clients/{uid}.isDeleted === true` (défense en profondeur, déjà couvert de fait par le solde nul). **Ne pas** exempter `payOrderFromWalletCF` du wrapper tant que 2D n'est pas livré (D6-b).
4. **Journaux** (R11) : option additive hors périmètre financier — écrire les `wallet_transactions` avec des identifiants déterministes dans la transaction, ou documenter l'écart ; à traiter séparément.
5. **Fichiers concernés** : `functions/accountAdmission.js` (helper pur) ; `functions/orderActions.js` (`buildPayOrderFromWallet` seul, insertion avant l. 110) ; tests `functions/test/orderActions.test.js` + nouveau `payOrderQuarantine*.test.js` (+ émulateur) ; messages Flutter `suivi_commande.dart` si un nouveau code d'erreur est exposé ; 2D : `accountDeletionScope.js`, `test/accountDeletionHardening.test.js`. **Pas** `index.js` ni `pilotCap.js`.
6. **Refus** : bénéficiaire sans profil ; (selon D6) bénéficiaire `isDeleted`. **Mise en attente** : voir D6-a. **Autorisation** : tout autre cas, y compris tombstone seul.
7. **Risques résiduels** : R1/R2 (émulateur à écrire), R9 (statut `cancelled` payable), R11 (journaux), N1/N3 du moteur, comportement de production non démontré, quota Cloud Run non confirmé.

### Décisions humaines nécessaires
- **D6-a** — Paiement dont le **bénéficiaire est anonymisé** : (a1) **refuser le paiement entier** (aucun débit, commande marquée à revoir : le client reste redevable, l'administration tranche) ; (a2) **débiter le client et retenir la part** (réutiliser `heldDriverEarning` / `pending_admin_review` pour le livreur ; un champ additif équivalent pour la pharmacie) ; (a3) créditer quand même et tracer (non recommandé, contredit D1/D2). Recommandation : **(a1)** — plus simple, aucune immobilisation d'argent client, cohérent avec « solde inchangé » de D1/D2.
- **D6-b** — **Clôture sous quarantaine du payeur** : (b1) corriger à la source (2D) et laisser le wrapper bloquer (recommandé) ; (b2) exempter `payOrderFromWalletCF`/`cancelOrderCF` du wrapper pour les appelants en quarantaine (élargit la surface, nécessite des gardes de remplacement).
- **D6-c** — `cancelOrderCF`/`deliverOrderCF` appelés par un acteur en quarantaine : même question, hors de cette fonction.

## 11. Tests à prévoir
| # | Cas | Niveau |
|---|---|---|
| 1 | Client actif : paiement autorisé | unitaire (existant) + émulateur |
| 2 | Client en quarantaine : refus d'entrée (wrapper), aucune écriture | unitaire (sonde P2 → à intégrer) |
| 3 | Commande engagée (livrée non payée) + 2D : quarantaine/anonymisation refusée | unitaire moteur (2D) |
| 4 | Bénéficiaire `isDeleted` (livreur, pharmacie) : comportement D6-a, solde inchangé | unitaire + émulateur |
| 5 | Compensation sur compte en quarantaine : autorisée (2C-1) | unitaire |
| 6 | Compensation sur compte anonymisé : mise en attente (2C-1) | unitaire |
| 7 | Quarantaine/anonymisation du bénéficiaire **concurrente** du paiement : invariant « aucun crédit sur `isDeleted` » | **émulateur** (modèle des ordonnancements 2B) |
| 8 | Deux appels simultanés : un débit, un crédit | **émulateur** (le faux Firestore ne le prouve pas, P9) |
| 9 | Réessai après succès : refus `Commande déjà payée`, aucun second effet | unitaire (existant) + émulateur |
| 10 | Remboursement (`cancelOrderTx`) vers client en quarantaine / `isDeleted` | unitaire + émulateur (2C-2b) |
| 11 | Bénéficiaire sans document : refus propre avant écriture | unitaire |
| 12 | Journaux post-transaction absents après arrêt simulé | unitaire (R11) |
**Nécessitent un test réel (préproduction, comptes synthétiques)** : comportement des conflits de transaction en production, effet d'un crédit sur profil anonymisé réel, messages Flutter sur appareil.

## 12. Limites de l'analyse
Lecture intégrale de `buildPayOrderFromWallet`, `cancelOrderTx`/`cancelOrderPostTx`, du wrapper `onCall`, de `assertAccountEnabled`/`assertNewAccountActivity`, de `inspect`/`readDeletionScope` (extraits), de la partie `deliverOrderCF` citée (~l. 925-975), et de l'appelant Flutter. **Non lus ligne à ligne** : le reste de `buildDeliverOrder`, `adminBilling`, `adminOrderDisputes`, `adminOrderRefunds`, `orderRefunds.js`, `transferSettlement` (repris du registre 7E-87). Aucun test d'émulateur lancé pour cette fonction (R1/R2/R12 restent [ND]). La sonde utilise un faux Firestore qui **ne modélise pas la contention**. Rien n'a été exécuté contre la production. Le comportement de l'émulateur n'est pas une preuve de production. Quota Cloud Run non confirmé : aucun déploiement.

## 13. État Git
HEAD `d65c8f00bdcedba570a66a5633913db46127be3d` · index vide · aucun nouveau commit · aucun push · aucun déploiement · worktree préservé (les 87 entrées d'avant + ce rapport).

## Verdict
**LOT 2C ANALYSÉ — DÉCISIONS MÉTIER NÉCESSAIRES**
La fonction est comprise de bout en bout ; la protection du **payeur** existe déjà (wrapper), celle des **bénéficiaires** est absente (livreur et pharmacie `isDeleted` crédités, preuves P4/P5), et la cause racine est dans l'inspection du moteur (N2, lot 2D). Avant toute spécification, il faut trancher D6-a (refuser le paiement entier, retenir la part ou créditer-et-tracer) et D6-b (corriger à la source ou exempter le wrapper). Aucune modification de code, aucun staging, aucun commit, aucun push, aucun déploiement. En attente d'une nouvelle autorisation humaine.
