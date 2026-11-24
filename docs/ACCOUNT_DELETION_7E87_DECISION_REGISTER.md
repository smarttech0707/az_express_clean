# Mission 7E-87 — Registre décisionnel et complément d'audit financier

Date : 2026-11-08 · HEAD `294332e`, index vide, aucun fichier de code modifié, aucun `git add`/commit/push, aucun déploiement, aucune commande distante, FeexPay non activé, `operations_control/account_deletion` non créé, production `az-express-b0469` non touchée, aucun secret lu. Seules exécutions : lectures de fichiers et recherches. Ce rapport est non suivi. Preuves : **[V]** lu dans le code · **[T]** couvert par un test nommé · **[ND]** non déterminé.

> **Correction de 7E-86.** La relecture intégrale montre que `payOrderFromWalletCF` règle une commande **déjà engagée** (livreur assigné, parfois livrée). Le classer « débit à bloquer sous quarantaine » (7E-86 §3.3, lot 2B) était **erroné** : le bloquer laisserait livreur et pharmacie impayés. Il sort de 2B et entre dans la politique 2C (§6).

## 1. Registre des décisions D1 à D5
Les cinq décisions sont celles de `ACCOUNT_DELETION_7E86_FINANCIAL_GUARD_AUDIT.md` §9 (aucune n'est inventée). Attention : la mission 7E-67 avait aussi des « D1-D5 » (webhook, fenêtre de jeton, comptes admin, `artisanLogin`, redéploiement) : **numérotation distincte** ; la D1 de 7E-67 (webhook sur compte en suppression) est résolue dans le code par `held_for_review`.

### D1 — Compensation d'un retrait en échec sur un profil anonymisé
- **Question exacte** : quand un retrait FeexPay échoue (`FAILED`) ou est refusé sans référence et que le profil du demandeur est déjà `isDeleted:true`, faut-il (a) mettre l'opération en revue sans aucun crédit, (b) créditer quand même, (c) autre ?
- **Problème métier** : l'argent a été débité à la demande de l'utilisateur ; la compensation doit lui revenir, mais le compte n'a plus de propriétaire joignable.
- **Technique** [V] : `applyPayoutStatus` (`feexpayPayments.js` l.427-457) et `compensateFailedWithdrawal` (l.715-754) créditent `wallet + montant` dès que le profil existe ; seul `user_not_found` est traité (`needsReview`). Aucun test sur `isDeleted`.
- **Risque financier** : crédit silencieux sur un compte anonymisé (argent immobilisé, aucune trace de revue) ; à l'inverse, un compte en simple quarantaine doit pouvoir récupérer son argent.
- **Options** : (a) revue (`needsReview`, `anomaly:'profile_anonymized'`, aucun crédit) ; (b) crédit tracé ; (c) crédit vers une cible alternative décidée par l'administration.
- **Recommandation** : **(a)** pour `isDeleted`, **compensation normale** pour tombstone seul (restitution) avec événement de sécurité. Conforme à la consigne « ne jamais créditer automatiquement un profil anonymisé sans décision métier ».
- **Sans décision** : 2C-1 ne peut pas être codé ; le comportement actuel (crédit silencieux) subsiste.

### D2 — Crédits administratifs vers un compte `isDeleted`
- **Question exacte** : pour `adminBilling`, `adminOrderDisputes`, `adminOrderRefunds` et `transferSettlement`, faut-il refuser explicitement, mettre en revue, ou créditer et tracer lorsque le compte cible est anonymisé ?
- **Métier** : l'administrateur décide un remboursement ou un partage de gains ; la cible peut avoir été anonymisée entre-temps.
- **Technique** [V] : aucune de ces fonctions ne teste tombstone, `isSuspended` ni `isDeleted` ; `transferSettlement` (l.115-118) ne vérifie que l'existence du livreur.
- **Risque** : crédit sur un compte sans propriétaire, sans signalement.
- **Options** : refus avec code explicite (+ drapeau de rapprochement) ; mise en revue ; crédit tracé.
- **Recommandation** : **refus explicite** pour `isDeleted` (l'humain choisit un remboursement hors système), **crédit permis** pour tombstone seul ; message d'erreur distinct pour l'interface d'administration.
- **Sans décision** : 2C-2 reporté ; crédits administratifs possibles sur comptes anonymisés.

### D3 — Confirmation E-Kbine quand l'agent est en quarantaine
- **Question exacte** : pour une commande déjà engagée (`proof_sent`), `ekClientConfirmOrder` doit-il créditer l'agent en quarantaine, refuser (comportement local actuel) ou mettre en revue ?
- **Métier** : le client a déjà payé ; l'agent a fourni le service.
- **Technique** [V] : la garde locale (non committée) refuse et laisse la commande `proof_sent`. Le moteur bloque la suppression d'un agent tant qu'une commande `ekbine_orders` est non terminale (`accountDeletionScope.js` l.42-44), donc le dossier reste `blocked` avec tombstone ; **aucune suppression de tombstone n'existe dans le code** (recherche) ni de levée de quarantaine : client et agent restent bloqués.
- **Risque** : argent client immobilisé, agent non payé.
- **Options** : (a) refuser (actuel) ; (b) créditer si le profil n'est pas `isDeleted` ; (c) revue.
- **Recommandation** : **(b)** — clôturer une opération engagée est une restitution ; refuser uniquement les **nouvelles** acceptations (garde de `ekbineAcceptOrder` conservée) et mettre en revue si `isDeleted`. Cela **modifie** la garde de `ekClientConfirmOrder` : à traiter dans le commit E-Kbine (commit 3), pas dans 2.
- **Sans décision** : le commit 3 ne peut pas être finalisé ; risque de blocage mutuel.

### D4 — Calendrier de l'outil `held_for_review`
- **Question exacte** : l'outil de consultation et de résolution est-il une condition **bloquante** de l'activation de la suppression de compte avec FeexPay actif, et quand est-il développé ?
- **Métier / technique** : voir §7. Aujourd'hui aucun outil de liste ni de résolution ; console Firebase seulement.
- **Risque** : paiement réel prélevé chez l'opérateur, retenu sans issue ; écart comptable non clos.
- **Options** : (a) bloquant, mission dédiée avant toute activation (recommandé) ; (b) pilote avec résolution manuelle documentée (volumes très faibles, jamais en production ouverte) ; (c) différer.
- **Recommandation** : **(a)** ; FeexPay reste désactivé tant que l'outil n'existe pas.
- **Sans décision** : l'activation reste interdite ; aucune planification possible.

### D5 — Modules non lus
- **Question exacte** : `partnerOrderActions`, `cashPayment`, `earningsSettlement`, `settleTerminalOrder` peuvent-ils être classés sans lecture ligne à ligne ?
- **Statut** : **résolue par cette mission** (lecture intégrale, §2) ; aucune décision humaine n'est plus requise. La lecture produit des points nouveaux (N1-N5, §4), **distincts** de D1-D5.

## 2. Audit détaillé des quatre modules
### 2.1 `cashPayment.js` — logique pure [V]
Aucun accès Firestore, aucun wallet. Fonctions : `initialCashPayment`, `declareNonPayment`, `reviewNonPayment`. Idempotence : rejeu sur statut déjà déclaré, `requestId` (16-128 car.) pour l'examen. Les protections de compte et la concurrence relèvent de l'appelant (`deliverOrderCF`, `partnerOrderActions`). **Classe : non financier direct, aucune garde à ajouter.**

### 2.2 `earningsSettlement.js` — calcul pur [V]
`buildProposal`, `settlementDocument`, `allocate`, `captureHandoverPoint` : aucun accès base, aucun effet de bord ; le document créé est toujours `pending_review`, aucun gain versé sans validation administrative. Parts entières, somme exacte. Le seul exécuteur des crédits est `transferSettlement.js` (ci-dessous). **Classe : non financier direct.**

### 2.3 Exécuteur lié : `transferSettlement.js` (nécessaire pour classer 2.2)
| Chemin | Mouvement | Tombstone / quarantaine | Transaction | Idempotence | Concurrence / reprise |
|---|---|---|---|---|---|
| `approve` (wallet) | **crédite** chaque livreur de la chaîne | **aucun** contrôle (ni tombstone, ni `isSuspended`, ni `isDeleted`) ; seulement existence du profil | oui, lectures avant écritures | identifiant déterministe `transfer_settlement_<order>_<driver>` + statut + refus si déjà enregistré | transaction sérialisée, `runLifecycleTransaction` |
| `approve` (cash) | aucun wallet | n/a | oui | statut `cash_pending` | idem |
| `confirmCashReceipt` | aucun wallet | aucun | oui | confirmation par uid | idem |
| `closeCash` | aucun wallet | n/a | oui | statut `settled` | idem |
Super-admin sauf `confirmCashReceipt`. **Classe : PA (protection absente) pour un livreur `isDeleted`** ; tests 0 référence suppression.

### 2.4 `partnerOrderActions.js` (action `partnerOrderActionCF`)
| Action | Mouvement de fonds | Contrôle de compte | Transaction | Idempotence | Concurrence |
|---|---|---|---|---|---|
| `acceptPartnerOrder`, `startPreparation`, `markReady` | aucun ; mais `sellerStatus` conditionne le droit au remboursement client | partenaire `isActive` seulement (pas de tombstone) | oui (`runLifecycleTransaction`, relit la commande) | rejeux explicites | sérialisée sur le document de commande |
| `refusePartnerOrder` | **oui, indirect** via `cancelOrderTx` : remboursement client (wallet), commission rendue au livreur payeur, reprise sur le vendeur | aucun contrôle tombstone/`isDeleted` ; remboursement = restitution | oui | `status:'cancelled'` + `partnerRefusal` ⇒ rejeu sans second remboursement | sérialisée ; journaux d'affichage `cancelOrderPostTx` **hors transaction** |
| `declareCashHandover`, `confirmCashRemittance`, `disputeCashRemittance`, `resolveCashRemittance` | **aucun wallet** ; écrit `cashRemittance`, `merchantCashSettled`, `reconciliation_flags` | acteur `isActive` seulement ; `resolve` super-admin | oui | montants cumulés, rejeu à montant égal, `requestId` pour `resolve` | sérialisée |
| `declareCashNonPayment`, `reviewCashNonPayment` | aucun wallet ; écrit `cashPayment` + drapeau | idem | oui | rejeu, `requestId` | sérialisée |
| `setPartnerOrdersConfig` | aucun fonds | super-admin | — | version | — |
Exposition réduite : création de commandes v2 `PARTNER_ORDERS_V2` désactivée par défaut [V, en-tête du fichier]. **Classe** : cash et préparation = **non financier direct** et **à ne pas bloquer** (clôture d'opérations engagées) ; `refusePartnerOrder` = **restitution** : à laisser passer, sauf client `isDeleted` (2C). Tests : 38, **0 référence suppression**.

### 2.5 `settleTerminalOrder` (`driverLifecycle.js`) [V]
En-tête : « Never touch money here ». Met à jour uniquement `isOnDelivery`, `currentOrderId`, `pendingOrderId` après une commande `delivered`/`cancelled` ; relit la commande dans la transaction et ignore un événement tardif ; idempotente ; `runLifecycleTransaction` rejoue une transaction fermée ; un livreur absent ne produit aucune écriture. **Classe : non financier ; ne jamais le garder** (il doit pouvoir libérer un livreur en quarantaine). Aucune fonction des quatre modules ne confirme une commande ni ne déclenche un paiement externe.

## 3. Protection transactionnelle : ce que l'on peut prouver
- **Wrapper ≠ transaction** : `assertAccountEnabled` lit hors transaction ; seule `assertNewAccountActivity(tx,…)` est atomique.
- **Test E de l'émulateur** [T] : lire un tombstone **absent** ne produit **aucun conflit** ; lire le **profil existant** (modifié par la quarantaine) en produit un, la transaction est rejouée et le tombstone désormais présent bloque. L'atomicité repose donc sur la lecture d'un **profil existant** dans la même transaction.
- **Limites [ND]** : (i) comportement des verrous Firestore en production non démontré (l'émulateur n'est pas une preuve) ; (ii) un acteur sans profil lu (ex. confirmation AZ IA d'un UID non client, la garde ne lit que `clients/{uid}`) n'a pas de conflit garanti ; (iii) la quarantaine ne pose pas `deletionRequested` sur un client : les contrôles fondés sur ce drapeau seul sont inopérants.

## 4. Points nouveaux (distincts de D1-D5)
- **N1 (élevé)** Un règlement de gains en attente (`transfer_settlements` / `orders.settlementHold`) **ne bloque pas** la suppression du livreur : l'inspection ne lit que statut terminal, `refundPending`, `needsReview`, `paymentStatus` [V : aucune référence à `settlementHold` dans `accountDeletion*.js`]. Une approbation ultérieure crédite alors un profil anonymisé (voir §2.3).
- **N2 (moyen)** Une commande wallet **livrée mais non payée** (`isPaid:false`, ex. pharmacie, réglée après livraison) est « terminale » pour le moteur : le client peut être supprimé avant de payer ; livreur et pharmacie restent impayés. À confirmer par un test dédié.
- **N3 (moyen)** `cashRemittance` non final et `reconciliation_flags` ouverts (dettes en espèces) ne sont pas vus par l'inspection ; les décisions administratives restent possibles sur le document de commande.
- **N4 (faible)** `cancelOrderPostTx` écrit les journaux d'affichage **après** la transaction et peut recréer des sous-collections sur un profil déjà nettoyé.
- **N5 (information)** Les acteurs partenaires/livreurs sont contrôlés par `isActive`, jamais par tombstone : une quarantaine ne les empêche pas de clôturer leurs opérations (souhaitable) mais ne les empêche pas non plus d'accepter une commande déjà en attente.
N1-N3 concernent l'inspection du moteur (fichiers du commit 1) : à traiter par un lot distinct **2D** (§8), après décision.

## 5. Matrice de protection (mise à jour)
Classes : **PT** présente et testée · **PI** présente, insuffisamment testée · **PA** absente · **ND** non déterminé · **NF** non financier / ne pas garder.
| Chemin | Garde transactionnelle | Classe | Action prévue |
|---|---|---|---|
| `initiateFeexPayPayment`, `initiateWithdrawal`, `feexPayWebhook`, `aiConfirmAction` | oui (AT) | **PT** | 2A |
| Compensation de retrait FAILED | non | **PA** (profil `isDeleted`) | 2C-1 (D1) |
| `createOrderFromQuoteCF` | non (drapeaux `deletionRequested`/`isDeleted` inopérants) | **PA** | 2B |
| `payBoutiqueOrderCF` (débit client + crédit vendeur, nouvelle commande) | non | **PA** | 2B |
| `payBoutiqueOrderCashCF` (nouvelle commande sans fonds) | non | **PA** (cohérence) | 2B |
| `payOrderFromWalletCF` (règlement d'une commande engagée) | non, **à ne pas bloquer** | restitution ; **PA** pour payeur/payés `isDeleted` | 2C-2 |
| `cancelOrderCF`, `refusePartnerOrder`, `autoExpireOrders`, `rateLimitCancelTx` (remboursements) | non, à ne pas bloquer | restitution ; **PA** pour client `isDeleted` | 2C-2 |
| `transferSettlement` (approve wallet) | non | **PA** (`isDeleted`) ; N1 | 2C-1 + 2D |
| `adminBilling`, `adminOrderDisputes`, `adminOrderRefunds` | non | **PA** (`isDeleted`) | 2C-2 (D2) |
| `adminWalletRequests`, `adminDriverRecharge`, catalogue, partenaire, événements | oui (HEAD) | **PT** | — |
| E-Kbine création / acceptation | oui (AT) | **PT** / **PI** | commit 3 |
| E-Kbine confirmation | oui (AT), sens à revoir | à modifier (D3) | commit 3 |
| `cashPayment`, `earningsSettlement`, `settleTerminalOrder`, actions cash et préparation de `partnerOrderActions` | n/a | **NF** | ne pas garder |
| Gardes P3 (mots de passe, abonnements) | oui (AT) | **PI** | commit 3b |

## 6. Politique de restitution (2C) : quarantaine, anonymisation, suppression, engagé, suspect
| État du compte | Nouvelle activité (création de commande, recharge, retrait, confirmation AZ IA, acceptation) | Clôture d'une opération **déjà engagée** (livraison, annulation, remboursement, compensation, règlement) | Opération **suspecte** |
|---|---|---|---|
| Actif | permis | permis | revue selon règles existantes |
| **Quarantaine** (tombstone, profil non anonymisé) | **refusée** (fail-closed) | **permise** : restitution, crédit/débit normaux, événement de sécurité | mise en `held_for_review` / `needsReview` (paiement créé **après** le tombstone, date illisible) |
| **Anonymisé** (`isDeleted`) | refusée | **aucun crédit automatique** : `needsReview` + raison `profile_anonymized`, solde inchangé, décision métier requise | `held_for_review` |
| **Supprimé** (Auth supprimé, nettoyage en cours) | refusée | idem anonymisé | idem |
| **Déjà engagée avant la demande** | n/a | termine normalement (le moteur bloque la suppression tant qu'elle existe, `inspect`) | — |
Mise en œuvre proposée (non réalisée) : fonction pure `accountCreditState(profile, tombstone) → 'active' | 'closing' | 'anonymized'`, appelée **dans** la transaction sur les chemins de crédit ; `anonymized` ⇒ écriture de revue sans toucher au wallet. Jamais de suppression d'opération réelle, jamais de modification de solde pour résoudre un conflit.

## 7. `held_for_review` : exigences de l'outil futur (non développé)
1. **Liste** (`listHeldPayments`, lecture seule) : filtre `needsReview==true` / `status=='held_for_review'`, pagination, motif (`reviewReason`), montant, opérateur, références, dates ; **super-administrateurs actifs seulement**.
2. **Historique d'audit** : chaque consultation sensible et chaque décision dans `audit_logs` et `support_events`, sans secret ni donnée personnelle brute.
3. **Résolution contrôlée** : machine d'états additive (`held_for_review → resolution_proposed → credited_after_review | rejected_after_review | refund_requested → refund_confirmed`), un seul passage par état, **double validation** (proposeur ≠ validateur), justification obligatoire.
4. **Prévention des doubles crédits** : transaction avec lecture avant écriture, clé d'idempotence `txId + action`, exclusion mutuelle crédit / remboursement / rejet, plafond au montant vérifié, solde jamais négatif.
5. **Rapprochement fournisseur** : revérification serveur auprès de FeexPay avant toute action ; montant et devise (XOF) identiques ; référence opérateur enregistrée pour un remboursement effectué hors système ; aucun appel d'API de remboursement.
6. **Traçabilité** : décision, auteurs, dates, références, état avant/après ; événement de sécurité en cas de refus.
7. **Garde de compte** : crédit interdit si profil `isDeleted` ou tombstone ; seules les voies rejet/remboursement enregistré restent ouvertes. Aucune action déclenchée par AZ IA.
**Pourquoi son absence bloque l'activation avec FeexPay actif** : (a) un paiement réel arrivé après la quarantaine est retenu sans issue (aucun chemin sûr de crédit, de remboursement ni de rejet) ; (b) la saisie manuelle dans la console contournerait transaction, audit et garde de double crédit ; (c) aucun état « résolu » ne permet de clore l'écart avec le relevé opérateur ; (d) l'application affiche un statut inconnu comme « en attente » sans explication ; (e) après anonymisation plus aucun dossier ne signale la retenue (le moteur ne lit `needsReview` que pour les comptes non encore anonymisés). **Activation de la suppression avec FeexPay désactivé : non bloquée par cet outil** (l'état n'est alors atteignable que par essai simulé).

## 8. Découpage définitif du commit 2
| Lot | Contenu | Fichiers | État | Dépend de |
|---|---|---|---|---|
| **2A** | gardes P2 existantes : `assertTargetNotClosing`, hold du webhook, garde AZ IA, garde in-tx recharge/retrait, `pilotLightOptions` | `accountAdmission.js`, `feexpayPayments.js`, `azia/index.js`, `azia/pendingActions.js`, `pilotCap.js`, `index.js` (hunks = `index_p2.patch`, 7 hunks), tests `accountQuarantineGuards`, `accountQuarantineIndex`, `accountQuarantineConcurrency.emulator`, `pilotCap.test.js` | **prêt** : patchs P2+P3 = exactement les 8 hunks actuels de `index.js` (lignes ajoutées identiques) ; 374/374 tests unitaires PASS (Node 22) ; scénarios émulateur à relancer avant commit | commit 1 (fait) ; aucune décision |
| **2B** | gardes in-tx sur **nouvelles** commandes payées : `createOrderFromQuoteCF` (après `assertActiveClient`, comme `catalogQuote.js` l.189 ; le rejeu `used` revient avant la garde), `payBoutiqueOrderCF` (client + vendeur `sellers`, après la lecture du client et avant la première écriture), `payBoutiqueOrderCashCF` (client) | `deliveryQuote.js`, `orderActions.js` (insertions limitées à `buildPayBoutiqueOrder`/`Cash`), nouveau `walletDebitQuarantineGuards.test.js` + cas émulateur | à implémenter | 2A (même helper HEAD) ; aucune décision |
| **2C-1** | restitution : compensation de retrait FAILED, approbation `transferSettlement`, `accountCreditState` | `feexpayPayments.js`, `transferSettlement.js`, `accountAdmission.js` (helper), tests | après D1 (et D2 pour `transferSettlement`) | 2A |
| **2C-2** | remboursements et crédits admin : `cancelOrderTx`, `payOrderFromWalletCF` (payés), `expireOrderTx`, `adminBilling`, `adminOrderDisputes`, `adminOrderRefunds` | `orderActions.js`, `orderRefunds.js`, modules admin, tests | après D2 ; lecture complète de `cancelOrderTx`/`deliverOrder` [ND] | 2C-1 |
| **2D (hors commit 2)** | inspection complémentaire du moteur (N1-N3) | `accountDeletion.js`, `accountDeletionScope.js` (fichiers du commit 1) | à décider | — |
| **Hors commit 2** | E-Kbine (commit 3, D3), gardes P3 (3b), outil `held_for_review` (D4), correctif de test, script de déploiement, documentation | — | — | — |
Ordre : 2A → 2B → (D1, D2) → 2C-1 → 2C-2 ; 2D avant toute activation.

## 9. Tests : inventaire et manques
| Chemin | Existant | Manquant |
|---|---|---|
| Recharge / retrait / AZ IA / webhook (2A) | 11 + 11 + 17 tests unitaires [T] ; émulateur A, A2, B, B2, C1-C3, D, E | rejeu du webhook après erreur transitoire |
| `createOrderFromQuoteCF`, `payBoutique*` (2B) | 2 références (`deliveryQuote`) | refus tombstone, zéro écriture (solde, stock, commande), fail-closed, quarantaine entre garde d'entrée et écriture, rejeu de devis `used`, émulateur (conflit via lecture du profil) |
| Compensation de retrait (2C-1) | `feexpayPayout`, `feexpayPayoutScheduler` : 0 réf. suppression | anonymisé / quarantaine / actif / rejeu |
| `transferSettlement` | 10 + 7 émulateur, idempotence couverte ; 0 réf. suppression | livreur `isDeleted`, quarantaine, rejeu après quarantaine |
| `partnerOrderActions` | 38 tests, rejeux couverts ; 0 réf. suppression | remboursement `refusePartnerOrder` vers client `isDeleted` ; cash sous quarantaine (comportement attendu : permis) |
| `cashPayment`, `earningsSettlement`, `settleTerminalOrder` | 20 / 8 / 11 (`driverLifecycle`) | aucun ajout indispensable (non financiers) |
| Remboursements | `orderRefunds` 18, `adminOrderRefunds` 28 ; 0 réf. suppression | quarantaine vs remboursement concurrent ; client `isDeleted` |
**Scénarios de concurrence** : suppression×paiement (émulateur A + unitaire, partiel) · suppression×retrait (A2, partiel) · **quarantaine×remboursement (manquant)** · tombstone×webhook (C2 + unitaires, présent) · double callback (C1 + unitaires, présent) · confirmation de commande×débit wallet (E-Kbine simulé, AZ IA B2 ; **livraison/boutique manquants**). Les émulateurs ne prouvent pas la sécurité en production ; le cas « 8 appels » E-Kbine reste intermittent. Aucune suite longue lancée dans cette mission.

## 10. Conditions avant activation
1. D1, D2, D3, D4 tranchées par écrit ; 2A, 2B, 2C-1, 2C-2 validés ; lot 2D décidé et, si retenu, livré.
2. Outil `held_for_review` livré et testé **avant** toute activation avec FeexPay actif.
3. `npm test` complet sous Node 22 comparé à la référence (2328 : 2280 OK, 1 échec `dispatchRetry` pré-existant, 47 ignorés) ; suite émulateur relancée, échecs documentés.
4. Tests de rôle réels sur comptes synthétiques en préproduction ; pas de preuve par émulateur seul.
5. **Quota Cloud Run non confirmé** : aucun déploiement ; vérification humaine de `Σ(cpu × maxInstances)` en `europe-west1`.
6. Lecture de `cancelOrderTx` et `deliverOrderCF` intégrale (non faite) avant 2C-2.
7. Passerelle fermée par défaut ; `operations_control/account_deletion` jamais créé sans décision explicite.

## 11. Limites
Lecture intégrale des quatre modules et de `transferSettlement`/`driverLifecycle` ; `cancelOrderTx`, `deliverOrderCF`, `adminBilling`, `adminOrderDisputes`, `expireOrderTx` lus **partiellement** ([ND] pour leurs détails internes) ; aucun test exécuté dans cette mission (374/374 provient de 7E-86) ; aucun accès réseau ni donnée de production.

## Verdict
**COMMIT 2 SOUS CONDITIONS**
2A est prêt (code, patchs et tests unitaires) ; 2B est spécifié (périmètre corrigé : `payOrderFromWalletCF` retiré) ; 2C dépend de D1/D2 ; l'activation dépend de D4, du lot 2D et du quota. Aucun code modifié, aucun commit, aucun push, aucun déploiement. En attente d'une décision humaine distincte.
