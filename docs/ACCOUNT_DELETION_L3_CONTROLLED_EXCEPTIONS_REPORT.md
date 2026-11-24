# Mission L3 — Exceptions contrôlées pour les opérations déjà engagées

Statut : terminée, arrêt avant toute autorisation. Aucun commit, push ni déploiement ; aucun accès à `az-express-b0469` ; L4 à L7 non lancées ; webhook FeexPay et `feexpayPayments.js` non modifiés ; les retraits et les 12 autres writers de règlement ne sont **pas** protégés par cette mission.

## 1. Fonctions protégées (liste fermée de cinq)

| Fonction | Acteur autorisé en quarantaine | Catégorie | Bénéficiaires contrôlés |
|---|---|---|---|
| `payOrderFromWalletCF` | client propriétaire | B | livreur crédité (sauf `settlementHold`), pharmacie si `medicineAmount > 0` |
| `cancelOrderCF` | client propriétaire | C | payeur de la commission remboursée, vendeur marketplace débité |
| `deliverOrderCF` | livreur lié à la commande | B | partenaire crédité (wallet, `isPaid`, v2) |
| `confirmOrderDeliveryWithProof` | livreur lié à la commande | B | idem (même corps que `deliverOrderCF`, `requireProof`) |
| `ekClientConfirmOrder` | client propriétaire de la commande E-Kbine | B | agent E-Kbine |

`adminConfirmDeliveryCF` (mode `adminConfirm` du même constructeur) n'est **pas** concernée : la garde n'est appliquée que si `!adminInfo`, et son export reste sur `onCall` (test dédié).

## 2. Mécanisme

Nouveau module `functions/accountClosureActor.js` :
- `CLOSURE_EXCEPTIONS` : table gelée `{fonction → collection du rôle}` des cinq fonctions. Toute autre fonction → `TypeError`.
- `buildOnCallClosing({rawOnCall, db, HttpsError})` → `onCallClosing(nom, options, handler)` : même enveloppe que `onCall` **sans** le refus global du wrapper. Refuse de se créer pour un nom hors liste (échec au chargement). Contrôle préalable hors transaction : pas de tombstone, ou quarantaine simple (`phase` absente/`closing`, ni `deleting` ni `authDeletedAtMs`) → passe ; sinon `permission-denied / ACCOUNT_DELETION_IN_PROGRESS`. Ce contrôle est indicatif ; le contrôle décisif est refait **dans la transaction**.
- `assertClosureActor(tx, …)` : lit le **tombstone, puis** le profil (ordre L0-F/C2), applique `closureRefusal` catégorie B, refuse si le tombstone existe sans profil (DR3/C5), si `deleting` / `authDeletedAtMs`, et exige, en quarantaine, que l'opération soit **strictement antérieure** à `tombstone.createdAt` (horodatage absent, invalide ou postérieur → `failed-precondition / ACCOUNT_CLOSING_OPERATION_NOT_ENGAGED`). Écrit `epoch + 1` dans la même transaction (via `applyTo`).
- `closureGuard(…)` : acteur + bénéficiaires par `assertFinancialLock` (L1, inchangé). Bénéficiaire anonymisé, absent, scellé ou illisible → `failed-precondition / BENEFICIARY_ACCOUNT_CLOSED` sans écriture (D6-a), sauf `onClosed:'skip'` (annulation, DR1).

Le tombstone n'est jamais supprimé, rouvert ni levé : le module n'écrit que `epoch` et `updatedAtMs` (test de source).

## 3. Conditions d'autorisation et contrôles par fonction

Communs : tombstone lu avant profil dans la transaction ; compte scellé / anonymisé / avec suppression Auth commencée / tombstone illisible / tombstone sans profil → refus sans écriture ; compte actif ou `deletionRequested` sans tombstone → comportement normal inchangé, sans epoch.

- **Pay** : propriétaire (`clientId`), statuts `cancelled/expired/refunded/failed/rejected` refusés (`PAYMENT_ORDER_NOT_PAYABLE`), `isPaid` déjà vrai refusé, engagement = `order.createdAt < tombstone.createdAt`. Bénéficiaire fermé → paiement refusé en entier : ni débit client, ni crédit, ni nouvelle commande.
- **Cancel** : propriétaire ; l'acteur est contrôlé **avant** toute autre issue, y compris la demande de litige « après récupération » (qui écrit la commande) ; statut encore annulable (règles existantes `ORDER_NOT_CANCELLABLE`, `ORDER_PICKED_UP`, `ORDER_IN_PREPARATION` inchangées). Paramètre additif `closure` de `cancelOrderTx` (seul `cancelOrderCF` le fournit ; AZ IA, expiration et administration inchangés). **DR1** : payeur de commission ou vendeur anonymisé/absent → le client est quand même remboursé, le crédit/débit du bénéficiaire fermé est omis, `commissionStatus` reste `charged`, signalement `reconciliation_flags/{orderId}_beneficiary_closed` (`needsReview`) écrit dans la même transaction.
- **Deliver / proof** : `order.driverId === uid`, statuts `accepted`/`picked_up` (règles existantes), engagement = `order.acceptedAt < tombstone.createdAt`. Partenaire à créditer anonymisé ou scellé → livraison refusée sans écriture (DR2). Partenaire **jamais fermé mais introuvable** : comportement historique conservé (livraison + signalement), voir §7. La confirmation par preuve reste soumise à toutes les vérifications QR/PIN existantes.
- **E-Kbine** (C1–C13) : C1 `assignedAt` doit être un vrai Timestamp (un nombre, un texte ou `{seconds}` est refusé) strictement antérieur au tombstone ; C3 aucun document dans les neuf autres collections de rôle ; C4 `clientId === uid` ; C5 tombstone en quarantaine simple, profil client présent ; C6 `proof_sent` seulement ; C7/C8 agent relu par `assertNewAccountActivity` (anonymisé, supprimé, en quarantaine, absent → confirmation entière refusée) ; C9 en quarantaine un paiement wallet exige `provenDebit` **et** le journal `clients/{uid}/wallet_transactions/ekorder_{orderId}` (`type payment`, `orderId`, `amount === −debitedAmount`) ; débit non prouvé → refus `EK_DEBIT_UNPROVEN_DURING_CLOSURE`, **aucun signalement créé** ; C10 `epoch + 1` ; C11 ligne `audit_logs` avec `closureDuringQuarantine:true` (aucune donnée personnelle ajoutée) ; C12 aucune écriture sur `clients/{uid}` ; C13 test de câblage. Hors quarantaine, `ekClientConfirmOrder` garde son comportement historique (crédit 0 + signalement si débit non prouvé).

## 4. Fichiers modifiés ou créés

| Fichier | Nature |
|---|---|
| `functions/accountClosureActor.js` | **nouveau** (113 lignes) |
| `functions/orderActions.js` | modifié (+62 / −4) : pay, `cancelOrderTx` (paramètre additif), `buildCancelOrder`, `buildDeliverOrder` |
| `functions/ekbineOrders.js` (**sensible**) | modifié (+31 de L3 ; hunks préexistants +8 intacts) |
| `functions/index.js` (**sensible**) | modifié (+7 / −5 : création de `onCallClosing`, cinq exports réécrits ; options `maxInstances`/`capInstances`/`pilotOnlyInstanceOptions` identiques, vérifiées par test ; hunks préexistants intacts) |
| `functions/accountClosureRegistry.js` | type de garde `closure_exception` ; quatre writers passent de `none` à garde réelle ; note E-Kbine mise à jour |
| `test/accountClosureExceptions.test.js` | **nouveau** (101 tests) |
| `test/accountClosureExceptions.emulator.test.js` | **nouveau** (5 tests, émulateur) |
| `test/accountClosureRegistry.test.js`, `test/accountClosureLock.test.js`, `test/ekbineQuarantineGuards.test.js` | adaptés (voir §5) |

Aucun autre module financier, aucun autre writer, ni `feexpayPayments.js`, ni le moteur de suppression, ni `accountClosureLock.js`/`State.js`/`Protocol.js`, ni les règles Firestore.

## 5. Tests existants adaptés (légitimement, rien d'affaibli)

1. `accountClosureLock.test.js` : « le socle n'est branché sur aucun writer » devient « branché uniquement sur `orderActions.js` et `ekbineOrders.js` » (liste exacte vérifiée).
2. `accountClosureRegistry.test.js` : `accountClosureActor.js` ajouté au moteur ; liste des writers sans garde 16 → 12 (les quatre writers de L3 en sortent) ; liste des gardes « copie de travail » complétée.
3. `ekbineQuarantineGuards.test.js` : le test « le client en quarantaine peut clôturer une commande engagée » encodait l'ancien comportement (aucune preuve) ; il fournit maintenant `assignedAt`, le journal du débit et un tombstone horodaté, ce qu'exige X-2. Les cas négatifs correspondants sont dans le nouveau fichier.

Une première exécution a révélé que la garde refusait un acteur dont le profil est **absent sans tombstone** : plusieurs tests existants (solde client absent → `SOLDE_INSUFFISANT`, livraison avec partenaire introuvable signalé, preuves de livraison) en dépendent. Plutôt que de modifier ces tests, j'ai préservé le comportement historique pour ce cas non lié à une fermeture (voir §7).

## 6. Tests et résultats (Node 22.23.4, garde de sortie réseau active)

Nouveau fichier unitaire (101 tests), pour **chacune des cinq fonctions** : compte actif ; suppression demandée ; quarantaine autorisée (epoch+1, `createdAt`/`state` intacts) ; quarantaine explicite `closing` epoch 4 → 5 ; scellé ; `deleting` / `authDeletedAtMs` ; anonymisé (avec/sans tombstone) ; tombstone sans profil ; tombstone illisible ; mauvais acteur ; mauvais propriétaire ; mauvais statut ; non engagé (postérieur, absent, invalide) ; répétition (soldes et epoch inchangés) ; aucune commande créée, tombstone jamais supprimé. Chaque refus compare **tout le magasin** avant/après (aucune écriture). S'y ajoutent : bénéficiaires fermés par fonction (pay : livreur/pharmacie anonymisé, absent, scellé ; cancel : DR1 anonymisé/absent/scellé/en quarantaine ; deliver et proof : partenaire anonymisé/scellé ; E-Kbine : C3, C7/C8, C9 et journal incohérent, hors-wallet T16, C1 types d'horodatage, égalité d'horodatage), `adminConfirmDeliveryCF` non concernée, liste fermée, enveloppe `onCallClosing`, câblage de `index.js` (exactement cinq usages, un par export, options conservées), absence de création de commande.

- Contrôle par mutation (refus de fermeture et refus `deleting` neutralisés) : 21 tests sur 101 échouent ; fichier restauré (identique).
- Fichiers ciblés : 101/101.
- **Suite pure complète : 2775 tests, 2602 réussis, 0 échec, 0 annulé, 173 ignorés** (référence L2.3 : 2673/2500/0/173 ; les cinq tests d'émulateur sont absents de la suite pure).
- **Émulateur local** `demo-l3-emu` (config dédiée, port 28080), fichier L3 exécuté trois fois (15 rondes × 5 fonctions × 3) : **5/5 à chaque exécution**, jamais « les deux », jamais « aucun », `emulatorRejects: 0`. Exemple de répartition : pay 13 opérations / 2 scellements, cancel 11/4, deliver 12/3, proof 8/7, ek 10/5 ; les deux issues ont été observées. Quand l'opération réussit : `epoch = 1`, le scellement est refusé (`closure_epoch_changed`) et l'argent exact (débit et crédit une fois) ; quand le compte est scellé : soldes inchangés.
- Fichier L2 existant (`accountClosureProtocol.emulator.test.js`) rejoué : **8/8**.
- Émulateur arrêté (uniquement le processus qui écoutait sur 28080) ; ports préexistants 5001, 8080, 9099, 9199, 4000 intacts (mêmes PID).

## 7. Invariants financiers

Vérifiés par tests : pas de double débit ni de double crédit (répétition ; deux appels concurrents côté émulateur) ; pas de crédit perdu (bénéficiaire fermé → refus global pour pay/deliver/E-Kbine, ou client remboursé + signalement pour l'annulation) ; pas de remboursement indu (annulation après récupération refusée, statuts non payables refusés, débit E-Kbine non prouvé refusé) ; aucune nouvelle commande ; tombstone jamais levé ni supprimé ; un compte scellé ou anonymisé n'a aucune exception.

## 8. Écarts de conception assumés et réserves restantes

1. **Acteur sans profil et sans tombstone** : laissé aux contrôles historiques du writer (DR3 ne vise que la fermeture). Un compte anonymisé (`isDeleted`) ou avec tombstone reste refusé.
2. **Partenaire introuvable (jamais fermé) à la livraison** : comportement historique conservé (livraison + signalement) ; seul un partenaire anonymisé ou scellé bloque (DR2).
3. **Annulation avec bénéficiaire scellé** : refus complet (DR1 ne prévoit que l'anonymisé) ; le client peut réessayer une fois le bénéficiaire anonymisé. Le débit du vendeur marketplace anonymisé est omis de la même façon (extension de DR1, à valider).
4. **Trace D6-a pour pay/deliver refusés** : non écrite (un refus n'écrit rien) ; la trace idempotente `…_beneficiary_closed` n'existe que pour l'annulation. À décider avant L4/L5.
5. **Journaux de `payOrderFromWalletCF`** (`wallet_transactions`, `logAudit`) restent écrits **après** la transaction (comportement existant, non atomique) ; la spec 7E-97 §6.2 les voulait déterministes dans la transaction. Non traité (hors du périmètre strict des exceptions).
6. **Échec de preuve QR/PIN** : l'incrément du compteur d'essais est écrit sans epoch (aucun argent) ; un livreur en quarantaine peut donc user ses essais.
7. **Réserves explicites de la mission** : les writers de retrait (`initiateWithdrawal`, `checkPendingWithdrawals`, `adminApproveWithdrawalCF`) et les autres writers de règlement sans garde de fermeture **ne sont pas protégés**. Le registre en liste encore 12 (dont `checkPendingWithdrawals` et `adminApproveWithdrawalCF`) : `adminApproveWithdrawalCF`, `adminBillingCF`, `adminConfirmDeliveryCF`, `adminOrderDisputeCF`, `autoExpireOrders`, `checkPendingWithdrawals`, `ekCancelOrderCF`, `ekbineAgentDepositAction`, `partnerOrderActionCF#adminDecision`, `partnerOrderActionCF#cashRemittance`, `refundExpiredBoutiqueOrderCF`, `settleTransferEarningsCF`. Rien dans L3 ne prétend le contraire.
8. Un faux retrait « réglé » écrit par un administrateur reste indétectable (L2.3).
9. Preuve sur émulateur uniquement ; rien sur Firestore de production ; aucun test appareil.

## 9. Statut de C2

Le chemin de quarantaine utilisé par C2 (T1 de `buildAccountDeletion`, inspection, webhook FeexPay) n'est pas modifié : `accountDeletion.js`, `accountClosureLock.js`, `accountClosureState.js`, `accountClosureProtocol.js`, `feexpayPayments.js` et leurs lectures sont inchangés. Les modifications portent sur les cinq writers et le wrapper. J'ai donc **jugé le protocole L0-F inutile à rejouer** et ne l'ai pas rejoué ; seul le fichier d'émulateur L2 (8/8) a été relancé. C2 reste **intermittent sur émulateur** (dernier relevé L2.2 : 17/20, échecs `INVALID_ARGUMENT: Transaction is invalid or closed`) et **n'est pas déclaré corrigé**. Aucun rejet d'émulateur n'a été observé sur les nouveaux écrivains (0 sur 225 rondes).

## 10. Préservation

HEAD `d65c8f0` ; branche `finalisation/az-express` ; index vide ; stash 0. Fichiers suivis modifiés : **27** (26 + `orderActions.js`). Non suivis : **135** avant ce rapport (132 + `accountClosureActor.js` + deux fichiers de test) ; le rapport s'ajoute → 136. Cinq fichiers sensibles : `professionalSubscriptions.js` (`976c2396`), `adminPartnerAccounts.js` (`1a5cde55`), `passwordReset.js` (`26975f60`) **inchangés** ; `index.js` (`9f00f1c1` → `a9ba2c0d`) et `ekbineOrders.js` (`21a9cc9a` → `ff24d2c8`) **changent**, inévitablement, car les câblages et le garde E-Kbine y vivent ; leurs modifications locales préexistantes sont intactes. `feexpayPayments.js` inchangé. Aucune opération Git destructive.

## 11. Prérequis pour L4, L5, L6, L7

- **L4 (16 → 12 writers B/C/D restants + retraits)** : décider du verrou de chaque writer (le socle `assertFinancialLock` est prêt) ; commencer par `ekCancelOrderCF`, `refundExpiredBoutiqueOrderCF` et les retraits ; décider la trace D6-a et les journaux déterministes de `payOrderFromWalletCF` (§8.4–8.5).
- **L5 (preuve de règlement des retraits)** : modèle de preuve indépendant (rapprochement journal wallet / `audit_logs`) pour fermer la limite du faux « réglé » administrateur.
- **L6 (reprise et récupération)** : définir la sortie administrative d'une quarantaine bloquée (aucune levée automatique, D-11) ; décision sur le sort d'un client dont le remboursement a été omis (signalements `beneficiary_closed`).
- **L7 (registre de décisions)** : traitement des signalements `…_beneficiary_closed` et `ekconfirm_*`.
- Avant tout déploiement : revue du câblage `onCallClosing` (cinq exports), puis déploiement par lot ciblé sur demande explicite ; C2 à rejouer si le chemin T1 est touché un jour.

Arrêt : en attente de votre autorisation explicite.
