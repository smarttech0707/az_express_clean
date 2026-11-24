# 2D-2A.2 — Protocole de concurrence entre suppression de compte et writers financiers

Spécification uniquement. Branche `finalisation/az-express`, HEAD `d65c8f0`, index vide. Aucun code, test, règle, writer ni inspecteur modifié. Ni émulateur, ni commande distante, ni accès production (`az-express-b0469`). Ce rapport est le seul fichier créé par la mission ; les rapports précédents ne sont donc pas réécrits, et leurs corrections figurent au §0.2.

Légende : **[F]** fait prouvé par une source citée (code, rapport, sortie d'outil) ; **[H]** hypothèse, non prouvée ; **[D]** décision métier acquise ; **[P]** proposition ; **[A]** validation humaine requise.

Sources principales : `functions/index.js:76-90` (wrapper `onCall`), `accountAdmission.js`, `accountDeletion.js:62-140`, `earningsSettlement.js`, `ekbineOrders.js`, `orderActions.js`, `partnerOrderActions.js`, `feexpayPayments.js`, `firestore.rules:3-12` ; rapports 7E-86 (audit des gardes), 7E-87 (registre D1–D5), 7E-89 (concurrence du lot 2A, émulateur), 7E-97 (spécification 2C/2D, décisions D6), 2D-2A et 2D-2A.1.

---

## 0. Faits de départ et corrections de mes rapports précédents

### 0.1 Ce qui existe déjà **[F]**

1. **Wrapper d'appelant.** Toute Cloud Function déclarée avec l'`onCall` local de `index.js` appelle `assertAccountEnabled(db, request.auth?.uid)` : refus `ACCOUNT_DELETION_IN_PROGRESS` si `account_tombstones/{uid}` existe. La lecture est **hors transaction** et ne concerne que **l'appelant** (`index.js:83-90`, `accountDeletion.js:16-19`). Les webhooks et planificateurs ne sont volontairement pas enveloppés (`index.js:76-77`). Seules `requestAccountDeletionCF`, `getAccountDeletionStatusCF`, `getPartnerQr`, `resolvePartnerQr` et `listPartnerQrEstablishments` utilisent `rawOnCall` (7E-97 §3).
2. **Garde transactionnelle.** `assertNewAccountActivity(tx, …, uid, partners)` relit `account_tombstones/{uid}` puis les profils **dans la transaction du writer** (`accountAdmission.js:2-13`). Elle est posée dans les créations de commande par devis, les paiements boutique, FeexPay (initiation et crédit), les recharges administratives (HEAD) et dans trois points Ekbine (arbre de travail non commité, §0.2).
3. **Preuve de concurrence en émulateur (lot 2A).** 7E-89 : 9 scénarios sur 9 réussis ; le scénario 5 montre qu'une lecture du tombstone **absent** par un writer entre en conflit avec la création du tombstone et est rejouée ; recharge, retrait et webhook ne produisent aucun effet validé après le tombstone. Limites de ce rapport : émulateur seulement, entrelacements tirés au hasard, pas de production (7E-89 §6).
4. **Décisions D6 [D]** (7E-97 §1) : D6-a bénéficiaire `isDeleted` ⇒ paiement entier refusé, sans écriture partielle, avec revue ; D6-b une commande déjà engagée reste payable par un payeur en quarantaine simple, nouvelle commande interdite ; D6-c `cancelOrderCF` et `deliverOrderCF` autorisés à un acteur en quarantaine simple, sous contrôles de rôle, d'association et de statut. Règles dérivées DR1–DR3 (7E-97 §1) : à relire à l'autorisation d'implémentation.
5. **D1 à D3** sont des *recommandations* du registre 7E-87 (D1 : retrait en échec sur profil anonymisé ⇒ revue sans crédit ; D2 : crédit administratif vers un compte `isDeleted` ⇒ refus explicite, crédit permis en quarantaine simple ; D3 : confirmation Ekbine avec agent en quarantaine ⇒ créditer sauf `isDeleted`). 7E-97 §1 les applique comme règles dérivées ; leur validation formelle individuelle n'est pas rappelée dans les sources que j'ai relues **[A]**.
6. **Non implémenté [F]** : `onCallClosing`, `assertClosureActor`, `accountCreditState`, `assertBeneficiaryCreditable` (recherche dans `functions/*.js` : aucune occurrence). Les lots 2C/2D de 7E-97 §9 restent à faire.
7. **Comportement de l'inspecteur [F]** : `inspect()` est exécuté avant le tombstone (`accountDeletion.js:85`, T1), de nouveau au bail après `QUIET_MS` (T2, même ligne, 2ᵉ passage) et enfin après la suppression Auth (`accountDeletion.js:124`, T3). Aucun contrôle ne précède `deleteUser` après le bail hors `inspectCleanup` non transactionnel (`accountDeletion.js:98-110`).
8. **Sous quarantaine** : `isSuspended:true`, tombstone, règles `isAuth()` qui refusent le client (`firestore.rules:7-11`). Une opération de crédit reçue pendant la quarantaine rend `wallet ≠ 0` et bloque l'anonymisation (7E-97 §4.4, réserve R6).

### 0.2 Corrections à mes rapports 2D-2A.1 **[F]**

1. **Matrice des writers : le wrapper d'appelant manquait.** J'ai écrit « aucun contrôle de suppression trouvé » pour `cancelOrderCF`, `deliverOrderCF`, `payOrderFromWalletCF`, etc. C'est inexact pour l'appelant : ces fonctions sont enveloppées par `onCall` local (`index.js:2435-2440, 2491, 2539, 2800-2812, 2845`) et refusent donc déjà un appelant sous tombstone, hors transaction. Ce qui manque réellement : (i) la lecture **dans la transaction** ; (ii) le contrôle des **bénéficiaires** (livreur, vendeur, partenaire) ; (iii) les chemins non enveloppés : `autoExpireOrders` (planificateur), webhooks.
2. **Ma correction P1 « garde sur client » pour `cancelOrderCF`/`deliverOrderCF`/`payOrderFromWalletCF` contredit D6-b/D6-c** : ces opérations doivent rester permises à un acteur en quarantaine simple. Elle est remplacée par la classification du §1 (catégorie B).
3. **Gardes Ekbine.** Les trois gardes Ekbine que je rangeais parmi les gardes existantes (`ekbineOrders.js:148, 309, 354`) sont des modifications **non commitées** de l'arbre de travail (`git diff` : 8 lignes ajoutées dans `ekbineOrders.js`, commentaires « Mission 7E-72 » et « 7E-68 »). Elles ne sont pas dans HEAD.
4. **Le plan 2C/2D de 7E-97 existait déjà** et couvre une grande partie de mes corrections P1/P2 (sous-lots 2C-A à 2C-D). Ce rapport le complète par un protocole de verrouillage commun et par la séquence de suppression Auth.

---

## 1. Classification des writers Q10

Catégories : **A** nouvelle activité (interdite pendant la fermeture) ; **B** règlement d'une obligation déjà engagée (conditionnel, acteurs et bénéficiaires vérifiés en transaction) ; **C** compensation ou remboursement (conditionnel, traçabilité) ; **D** opération administrative (contrôle renforcé, preuve obligatoire). « Fermeture » = du tombstone à la suppression ou à l'abandon.

Règle transversale **[P]**, issue de 7E-97 §2 et des décisions d'aujourd'hui : *aucun writer ne crédite automatiquement un bénéficiaire `isDeleted` ou dont le profil est absent* (DR3) ; un crédit en quarantaine simple est permis (D1/D2) et, par 7E-97 §4.4, immobilise le compte jusqu'à régularisation.

| Writer | Catégorie | Pourquoi (source) | Conditions transactionnelles proposées | Comparaison D1–D6 / 7E-87, 7E-97 |
|---|---|---|---|---|
| `payOrderFromWalletCF` (`orderActions.js:48`) | **B** | paie une commande déjà créée ; le journal client est écrit **après** la transaction (`orderActions.js:142`) | acteur = client propriétaire ; statut payable ; bénéficiaires non anonymisés ; journal `order_<id>` dans la transaction ; refus D6-a si bénéficiaire fermé, avec flag `beneficiary_account_closed` posé hors transaction de façon idempotente | D6-a, D6-b ; 7E-97 §6.2 (journaux déterministes en transaction) |
| `cancelOrderCF` (`orderActions.js:494`) | **C** (annulation = remboursement du client ; remboursement de commission au livreur) | permise à un client en quarantaine tant que le statut le permet | `assertClosureActor` (propriétaire, statut) ; crédit au livreur omis s'il est `isDeleted` + flag (DR1) ; jamais de refus du remboursement client | D6-c, DR1, DR3 |
| `deliverOrderCF` (`orderActions.js:569`) | **B** | clôture d'une mission engagée ; crée règlement `pending_review` et flags (`orderActions.js:898, 1017, 1030`) | livreur = `order.driverId` ; statut `accepted`/`picked_up` ; partenaire non anonymisé (DR2) ; livreur non anonymisé | D6-c, DR2 |
| `confirmOrderDeliveryWithProof` (même module) | **B** | même clôture avec preuve QR/PIN | idem `deliverOrderCF` | 7E-97 §3 (même exception) |
| `adminConfirmDeliveryCF` (`orderActions.js`, builder partagé) | **D** (+B) | appelant super-admin | cibles (client, livreur, partenaire) non anonymisées ; motif et preuve tracés (`audit_logs`) ; réalisation par un administrateur, jamais par le compte supprimé | D2 |
| `refundExpiredBoutiqueOrderCF` (`orderActions.js:1657`) | **C** | rembourse une commande boutique expirée | client non `isDeleted` ; sinon aucun crédit + `needsReview` ; statut de la commande revérifié | D1/D2 par analogie **[A]** (non couvert nommément par 7E-97) |
| `autoExpireOrders` (`index.js:2174`) | **C** (planificateur, **non enveloppé**) | expire des commandes et rembourse (`index.js:2256`) | pour chaque commande : lire le verrou des deux parties ; `isDeleted` ⇒ pas de crédit + revue ; verrou « scellé » ⇒ reporter | 7E-97 §7 ; non nommé dans 7E-97 ⇒ **[A]** |
| `releaseOrderBeforePickupCF` (`driverRelease.js`) | **A** | libération d'une mission = progression de mission (7E-97 §3 : « inchangé », wrapper conservé) ; crée un flag `commission_untraced_<uid>` (`driverRelease.js:134`) | appelant fermé ⇒ refus par le wrapper (comportement voulu, réserve R4 de 7E-97) | D6-c (exclu de l'exception) |
| `settleTransferEarningsCF` (`transferSettlement.js:100-140`) | **D** (+B) | approbation administrative qui crédite chaque livreur de la chaîne (`driverIds`) | chaque livreur crédité : profil présent et non `isDeleted` sinon **refus de toute l'approbation** (aucun crédit partiel) ; fermeture simple ⇒ permis | D2 ; 7E-97 §6.5 |
| `adminBillingCF` (`adminBilling.js:153-305`) | **D** (+C) | frais retenus, remboursements `admin_refund_*` | cible non anonymisée sinon refus explicite et tracé ; fermeture simple permise | D2 ; 7E-97 §6.5 |
| `adminOrderDisputeCF` (`adminOrderDisputes.js:473-525`) | **D** (+C) | litiges : crédits et flags `seller_review`, `driver_advance_unreimbursed` | idem ; décideur initial enregistré dans le flag (`decidedBy`) | D2 ; 7E-102 (origine) |
| `partnerOrderActionCF` — `acceptPartnerOrder`, `startPreparation`, `markReady`, `refusePartnerOrder` (`partnerOrderActions.js:380-404`) | **A** | progression d'une commande partenaire | appelant fermé ⇒ refus (wrapper) | D6-c (progression exclue) **[A]** |
| `partnerOrderActionCF` — `declareCashNonPayment` (l.260) | **A** | crée l'obligation `cash_payment_review` | refus si le client ou le partenaire est fermé **[A]** : alternative = permettre la déclaration avec epoch (§2) | à trancher |
| `partnerOrderActionCF` — `declareCashHandover`, `confirmCashRemittance`, `disputeCashRemittance` (l.300-329) | **B** | règlement d'une remise d'espèces engagée | livreur et partenaire non anonymisés ; statut de remise ; fermeture simple permise | D6-b par analogie **[A]** |
| `partnerOrderActionCF` — `resolveCashRemittance`, `reviewCashNonPayment` (l.126, 281) | **D** | super-admin obligatoire (`requireSuperAdmin`) | preuve et décideur enregistrés ; `reviewCashNonPayment` écrit `cashPayment.review.byUid` (source d'origine pour le moteur) | 7E-102 |
| `ekCancelOrderCF` (`ekbineOrders.js:199`) | **C** (annulation d'une commande engagée) | rembourse le client ; pose le flag Ekbine hors transaction (`ekbineOrders.js:264-268`) | client non anonymisé ; flag écrit dans la transaction (§4) | D3 par analogie **[A]** (D6 ne nomme pas Ekbine) |
| `ekClientConfirmOrder` (`ekbineOrders.js:283`) | **B** | clôture d'une commande engagée, crédite l'agent | agent non `isDeleted` (garde déjà ajoutée, non commitée) ; client lu aussi (aujourd'hui seul l'agent est relu) | D3 |

Autres writers déjà gardés (création de commande, boutique, recharge, retrait, FeexPay) : **A** pour leur flux d'ouverture, conservés. Le crédit FeexPay en attente passe en `held_for_review` : outil de résolution absent (D4, obligatoire avant l'activation de FeexPay).

Bilan **[P]** : aucun writer de la liste n'est de catégorie « refus total » sauf la progression de mission (A). La protection nécessaire n'est donc pas « refuser pendant la fermeture » mais « décider **dans la transaction**, sur le même verrou que la suppression ».

---

## 2. Verrou financier

### 2.1 Problème

Aujourd'hui l'inspection (T1, T2) lit des requêtes puis la suppression progresse. Un writer de catégorie B/C/D autorisé en fermeture peut créer un flag, un règlement ou un crédit **après** la dernière lecture. Pour que T2b détecte cet événement sans dépendre du comportement des requêtes de transaction face à une insertion (phantom), il faut un conflit sur **un document précis** que les deux côtés lisent et écrivent.

**Fait [F]** : la lecture d'un document absent ou présent dans une transaction est invalidée par une écriture concurrente de ce document, ce qui est caractérisé en émulateur par 7E-89 scénario 5.
**Hypothèse [H]** : le comportement équivalent pour une *requête* dont un nouveau document correspond au filtre n'est pas démontré (déjà question Q11). Le protocole ci-dessous ne s'appuie pas dessus.

### 2.2 Document faisant autorité

**Proposition [P]** : `account_tombstones/{uid}` devient le verrou financier par compte (champs additifs), un par UID de compte concerné (client, livreur, vendeur, partenaire, agent). Raisons : il existe déjà, est créé par T1 (`accountDeletion.js:88`), est lu par toutes les gardes (`assertNewAccountActivity`, wrapper, règles `isAuth()`), et ses règles interdisent toute lecture et écriture client (`firestore.rules:12`). L'ajout de champs ne modifie ni les gardes ni les règles existantes (celles-ci testent seulement l'existence).

Champs additifs **[P]** : `phase` (`closing` | `sealed`), `epoch` (entier ≥ 0), `sealedUntilMs`, `sealToken`, `updatedAtMs`. Le document du dossier `account_deletions/{uid}` garde l'état de flux (inchangé).

Alternative écartée : un document séparé `account_financial_locks/{uid}`. Elle ajoute une collection et une règle ; elle n'est utile que si l'on veut éviter de modifier `state:'deleting'` du tombstone. **[A]** : choisir.

### 2.3 États et transitions

| État | Signification | Entrée | Sortie |
|---|---|---|---|
| (absent) | compte actif | — | T1 |
| `closing` | quarantaine simple : D6 s'applique (catégories B/C/D permises, A refusée) | T1 (création, `epoch:0`) ; retour d'un `sealed` abandonné | T2b (→`sealed`) |
| `sealed` | scellé : plus aucune écriture financière sur ce compte, sauf la suppression elle-même | T2b réussi (`epoch` inchangé depuis T2, moteur non bloquant, lectures complètes) | `deleted` après suppression Auth confirmée ; ou retour à `closing` (abandon, expiration) |
| `deleted` | Auth supprimé | T3 après `auth/user-not-found` confirmé | terminal |

`epoch` est un compteur monotone : chaque transaction de writer de catégorie B/C/D qui **écrit** une obligation, un règlement ou un crédit pour la partie incrémente `epoch` (écriture du tombstone). T2 enregistre l'`epoch` observé dans `account_deletions/{uid}.financialSnapshot.epoch` ; T2b exige `epoch` identique.

### 2.4 Contrôles transactionnels des writers (protocole commun)

Pour chaque partie P du writer (appelant, client, livreur, vendeur, partenaire, bénéficiaire), le writer, **avant toute écriture** et dans sa transaction :
1. lit `account_tombstones/{P}` et le profil de P ;
2. profil absent ou `isDeleted` ⇒ interdit selon D6-a/D2/DR1–DR3 (refus, omission du crédit avec flag, ou mise en revue selon la ligne du §1) ;
3. tombstone absent ⇒ comportement actuel, aucune écriture supplémentaire (pas de coût pour les comptes actifs) ;
4. tombstone `phase:'sealed'` et non expiré ⇒ refus `ACCOUNT_SEALED` (catégorie A/B/C/D toutes) ;
5. tombstone `phase:'sealed'` expiré ⇒ le writer traite P comme `closing` et **écrit** `phase:'closing'`, `epoch+1` (abandon implicite du scellé) ;
6. tombstone `closing` ⇒ catégorie A : refus ; B/C/D : autorisé si les conditions de la ligne du §1 sont vérifiées, puis **`epoch + 1`** dans la même transaction.

Un *helper* unique **[P]** (extension de `accountAdmission.js`) applique les points 1–6 : `assertFinancialLock(tx, db, HttpsError, parties, opClass)` retourne les écritures à ajouter. Aucun writer ne réimplémente la logique.

**Garantie** : chaque writer de B/C/D lit puis écrit le même document que T2b lit puis écrit (le tombstone). Deux transactions concurrentes sur ce document se sérialisent : soit le writer valide avant T2b (T2b est rejeté et rejoué, voit l'`epoch` changé et bloque), soit T2b valide avant (le writer rejoué lit `sealed` et refuse). Cette garantie repose sur le fait documenté en émulateur (7E-89 #5) ; **en production elle reste [H]** jusqu'aux tests de préproduction.

### 2.5 Tous les writers utilisent le même protocole **[P]**

Contrôle d'exhaustivité proposé pour 2D-2B, sans l'implémenter ici :
1. Registre `FINANCIAL_WRITERS` (un tableau déclaratif : export, catégorie, parties) tenu dans un module de test ou de configuration.
2. Test unitaire exécutant chaque writer enregistré avec un tombstone `sealed` et vérifiant le refus, puis avec `closing` et vérifiant `epoch+1` pour B/C/D et le refus pour A.
3. Test de câblage lisant `index.js` pour interdire tout nouvel export appelant des collections de portefeuille sans passer par le registre (liste des exports ayant `wallet` dans leur module : à établir).
4. Recherche statique en CI : toute écriture de `reconciliation_flags`, `transfer_settlements` ou `wallet_transactions` hors des modules du registre échoue.

### 2.6 Doubles écritures

1. `epoch` ne remplace pas l'idempotence des writers : les identifiants déterministes de flags (`<orderId>_…`, `ekcancel_<orderId>`) et de journaux (`order_<id>`, `admin_refund_<orderId>`) restent la protection contre le rejeu.
2. Une écriture de flag ou de journal **hors transaction** est interdite pour les writers du registre : `payOrderFromWalletCF` (journal `.add()` après la transaction, `orderActions.js:142`) et `ekCancelOrderCF` (flag après la transaction) sont à migrer (§5).
3. `sealToken` : seul le détenteur du jeton (le bail de `accountDeletion.process`) peut passer `sealed → deleted`. Un second processus de suppression est refusé (bail déjà détenu).

### 2.7 Erreurs

| Erreur | Conséquence | Reprise |
|---|---|---|
| Lecture du verrou impossible dans un writer | le writer échoue entièrement (refus fermé) | retry du client |
| Transaction de writer rejouée par conflit | normal ; l'état relu décide | automatique |
| T2b ne peut pas lire/écrire le verrou | dossier `blocked`, Auth réactivé, aucun `deleteUser` | reprise horaire (`RETRY_MS`) |
| Écart d'`epoch` à T2b | dossier `blocked`, nouvelle inspection complète | idem |
| Verrou `sealed` jamais libéré (crash) | expiré à `sealedUntilMs` ; le prochain writer l'ouvre (point 5) ; le dossier refait T2b | automatique |

### 2.8 Webhooks et planificateurs

Non enveloppés par le wrapper (`index.js:76-77`). Règle **[P]** : même helper en transaction ; refus ⇒ mise en `held_for_review` (comportement FeexPay existant, 7E-89 #7) plutôt qu'échec perdu. L'outil de résolution de `held_for_review` est absent (D4) : prérequis pour toute activation de FeexPay **[A]**.

---

## 3. Séquence T1 → quarantaine → T2 → désactivation Auth → T2b → deleteUser

Le service Auth n'est pas une transaction Firestore ; aucune atomicité n'existe entre `deleteUser` et Firestore. **Aucune étape ne suppose le contraire.**

### 3.1 Séquence proposée **[P]**

1. **T1** (transaction) : identités, admin, rôles multiples, `inspect()` **étendu au moteur** ; création du tombstone `closing`, `epoch:0` ; `isSuspended:true`. Toute obligation ou lecture incomplète ⇒ `blocked`, **sans** tombstone.
2. Attente `QUIET_MS` (15 min).
3. **T2** (bail) : `inspect()` + moteur ; enregistrement du snapshot et de l'`epoch` observé ; bail de 180 s.
4. Contrôles non transactionnels (`inspectCleanup`, `auditStrict`) : **avant** la désactivation Auth.
5. **Désactivation réversible** : `auth.updateUser(uid,{disabled:true})`, `revokeRefreshTokens`.
   - **[F]** un compte désactivé ne peut plus ouvrir de session ni obtenir de nouveau jeton ;
   - **[H]** les jetons déjà émis restent valides jusqu'à expiration (environ une heure, 7E-97 R7) tant que les callables ne vérifient pas la révocation : le contrôle de révocation n'est pas établi ici. C'est pourquoi la protection repose sur le verrou et pas sur la désactivation.
6. **T2b** (transaction) : relecture complète (`inspect()` + moteur + journaux wallet + registre), vérification que le tombstone est `closing` avec `epoch` égal à T2, que le bail est valide, que le snapshot est équivalent. Puis écriture `phase:'sealed'`, `sealedUntilMs = now + 60 s`, `sealToken`.
   - Obligation nouvelle, lecture incomplète, erreur, bail expiré, écart d'`epoch` ou de snapshot ⇒ **arrêt** : voir §3.3.
7. **`deleteUser`** : immédiatement ; avant l'appel, le processus vérifie `now < sealedUntilMs − marge` (marge 15 s, dérive d'horloge incluse). Si la marge est insuffisante ⇒ pas d'appel, retour à l'étape 6.
8. Vérification d'absence Auth (code actuel), puis **T3** : `phase:'deleted'` (contrôle de cohérence uniquement ; **jamais** une protection).

### 3.2 Empêcher une écriture concurrente après T2b

- Après T2b, tout writer de B/C/D/A lit `sealed` non expiré et refuse (§2.4 point 4). Une transaction qui avait lu `closing` avant T2b est invalidée au commit par l'écriture de T2b sur le même document, puis rejouée **[H en production, F en émulateur #5]**.
- Une transaction déjà démarrée (lecture avant T2b, écriture après) : même mécanisme ; à tester en concurrence (§6).
- Écritures **non** transactionnelles sur les mêmes obligations (journaux, flags hors transaction, planificateurs sans helper) : **non couvertes** tant qu'elles ne sont pas migrées ; c'est la raison de leur présence dans les lots 1–3.
- **Résiduel [H]** : une écriture hors registre (script d'administration, console Firebase) n'est pas empêchée. Mitigation : T3 compare `epoch` et la présence de nouveaux documents ; l'écart déclenche la procédure §3.5.

### 3.3 Obligation découverte tardivement

| Moment | Constat | Action |
|---|---|---|
| T1 | obligation ouverte | `blocked`, aucun tombstone (7E-97 §4.3) : le compte reste utilisable et peut régler |
| Entre T1 et T2b | obligation nouvelle | dossier `blocked`/`cleanup_pending`, tombstone `closing` conservé, Auth **réactivé** (§3.4), reprise horaire |
| T2b | écart d'`epoch`/snapshot ou moteur bloquant | `phase` reste `closing` (jamais `sealed`), Auth réactivé, aucun `deleteUser` |
| Après `deleteUser` | `epoch` changé ou nouvel élément dans T3 | procédure « obligation tardive » §3.5 |

### 3.4 Échec de `deleteUser` et restauration d'un compte désactivé

1. `deleteUser` en échec transitoire : le dossier garde le bail et réessaie selon `failurePatch` (6 tentatives, `accountDeletion.js:139-141`). Pendant les reprises le verrou `sealed` expire (60 s) ; **chaque reprise refait T2b** avant un nouvel appel `deleteUser`.
2. Échec définitif ou abandon : `updateUser(uid,{disabled:false})` **sans** toucher au tombstone. Le compte redevient connectable mais reste sous `closing` : le wrapper et les règles `isAuth()` le bloquent, sauf les clôtures D6. La quarantaine financière n'est donc pas levée.
3. **Fait [F]** : aucune suppression de tombstone n'existe dans le code (7E-87 D3). Lever une quarantaine, c'est-à-dire annuler une demande de suppression, est une opération absente ; elle est hors périmètre. **[A]** : décider si elle est nécessaire (par exemple annulation à la demande de l'utilisateur) ; ce serait un nouveau writer administratif de catégorie D.
4. Restaurer l'accès ne doit jamais accepter de nouvelle activité (A) : c'est garanti tant que le tombstone existe.

### 3.5 Obligation « tardive » après `deleteUser`

L'argent n'est pas perdu : le profil anonymisé conserve `wallet` et l'historique (`accountDeletion.js:129-132`). Procédure **[P]** :
1. Création d'un flag `late_obligation_<uid>_<orderId>` (écriture serveur) avec `accountUid`, `epochAtDeletion`, référence de l'événement.
2. **Aucun crédit automatique** vers le profil anonymisé (décision acquise) ; résolution administrative hors système, décision N2 selon le moteur.
3. L'utilisateur supprimé ne peut plus se connecter : la compensation éventuelle se fait par décision administrative et preuve, jamais par le wallet.

---

## 4. Flags Ekbine

### 4.1 Faits **[F]**

| Flag | Écrit par | Quand | Champs |
|---|---|---|---|
| `ekcancel_<orderId>` (`ekbine_cancel_unproven_debit`) | `ekCancelOrderCF` (appelant = client) | **après** la transaction (`ekbineOrders.js:264-268`) ; `logAudit` précédent avale ses erreurs (`index.js:300-312`) | `kind, orderId, clientId, status, createdAt` |
| `ekconfirm_<orderId>` (`ekbine_confirm_unproven_debit`) | `ekClientConfirmOrder` (appelant = client) | **dans** la transaction, avec une ligne `audit_logs` (`ekbineOrders.js:318-326`) | `kind, orderId, clientId, agentId, amount, status, createdAt` |

La commande annulée porte `cancelledBy` et `cancelledAt` écrits dans la transaction d'annulation (`ekbineOrders.js:244-248`). Aucun flag ne porte d'acteur, de rôle ni de référence d'événement.

### 4.2 Protocole serveur proposé **[P]**

1. **Même transaction.** Le flag est créé avec `tx.create` (refus si déjà existant) dans la transaction de l'annulation ou de la confirmation, sous l'identifiant déterministe existant. Le chemin `alreadyDone` reste inchangé (rejeu sans second flag).
2. **Origine enregistrée par le serveur**, jamais par le client :
   `origin: { uid, role, action, eventRef, atMs, orderStatus }`
   - `uid` = `request.auth.uid` ; `role` = rôle déduit de la collection du profil lu dans la transaction ;
   - `action` ∈ {`ek_cancel_order`, `ekbine_confirm_order`} ;
   - `eventRef` = `ekbine_orders/<orderId>` pour l'annulation (les champs `cancelledBy`/`cancelledAt` sont dans la même transaction), référence de la ligne `audit_logs` créée dans la même transaction pour la confirmation (`tx.set` à identifiant connu) ;
   - `atMs` = horloge serveur de la transaction.
3. **Alias pour le moteur** : `decidedBy` = `origin.uid`, car `verifyDecision` reçoit `originBy` depuis `f.decidedBy` (`accountObligations.js:559`). Aucune modification du moteur n'est proposée.
4. **Vérifiabilité au moment de la résolution** (writer de décisions) : recalcul de `origin.uid` depuis la commande (`cancelledBy === clientId`, `cancelledAt`) ou la ligne d'audit référencée ; écart ⇒ résolution refusée.
5. **Verrou** : le flag est une écriture de catégorie B/C du protocole §2 (relit les parties, incrémente `epoch`).

### 4.3 Anciens flags sans origine **[D]**

Ils restent **bloquants** : `ORIGIN_DECIDER_REQUIRED` impose une origine pour les deux types Ekbine (`accountObligations.js:243`). Options de sortie, à décider **[A]** :
- (a) ne rien faire : blocage permanent tant qu'aucun outil n'existe (le plus sûr) ;
- (b) outil administratif futur reconstituant `origin` depuis `ekbine_orders` (`cancelledBy`, `cancelledAt`) ou `audit_logs`, marqué `originProof:'reconstructed'`, validé par deux responsables (N2) ;
- (c) clôture hors système par décision N2 avec preuve.

### 4.4 Flag perdu après une annulation

Aujourd'hui un arrêt entre le commit de l'annulation et l'écriture du flag perd le flag **[F]** (écriture hors transaction). Le moteur ne lit pas `ekbine_orders` et ne peut pas détecter cette perte. Mesures **[P]** :
1. écriture dans la même transaction (§4.2) pour toutes les annulations futures ;
2. un contrôle de rapprochement lecture seule des commandes `ekbine_orders` `status:'cancelled'`, `paymentMethod:'wallet'`, `refunded:false` sans flag correspondant (source de l'indice : `refunded`/`refundedAmount` écrits dans la transaction, `ekbineOrders.js:244-247`) ;
3. l'intégration de ce contrôle dans la décision de suppression d'un **client** nécessite d'étendre le périmètre du moteur ou de l'inspecteur : **[A]**, hors du périmètre actuel (les agents Ekbine conservent leurs protections).

---

## 5. Contrat d'implémentation : lots minimaux ordonnés

Aucun lot n'est commencé. Chaque lot = un commit local distinct, après revue, sans mélange (7E-97 §9). **Contrainte** : l'arbre de travail contient des modifications non commitées de `ekbineOrders.js`, `index.js`, `professionalSubscriptions.js`, `adminPartnerAccounts.js`, `passwordReset.js` ; tout lot touchant ces fichiers exige de trancher leur statut d'abord **[A]**.

| Lot | Contenu | Fichiers | Invariants financiers | Tests | Risques | Critères de validation | Autorisation humaine |
|---|---|---|---|---|---|---|---|
| **L0** | Base de référence : suite sous Node 22.23.4 ; émulateurs isolés pour les 169 tests ignorés | aucun | — | tests existants | environnement | 0 échec ; liste des ignorés exécutés | exécution des émulateurs, choix de l'environnement |
| **L1** | Helper pur `assertFinancialLock` + registre `FINANCIAL_WRITERS` ; aucun branchement | `accountAdmission.js` (ou module neuf), test neuf | aucune écriture supplémentaire pour un compte actif | tests purs avec transaction simulée : absent/closing/sealed/expiré/profil absent/`isDeleted` | complexité de l'API | tests purs verts ; pas de changement de comportement | validation du nom et du champ (`account_tombstones` ou document neuf) |
| **L2** | T1 crée le tombstone `phase:closing`, `epoch:0` ; lecture de `epoch` à T2 ; T2b et séquence Auth (§3) ; moteur intégré aux trois inspecteurs | `accountDeletion.js`, `accountDeletionScope.js`, `manualAccountDeletion.js` (+ tests) | jamais de `deleteUser` sans T2b réussi ; `epoch` inchangé | séquence complète avec simulations d'échec Auth | modifie les inspecteurs ; `manualAccountDeletion.js` lit hors transaction | tests voisins inchangés ; nouveaux cas T2b | autorisation de modifier les inspecteurs |
| **L3** | Helpers 7E-97 (`accountCreditState`, `assertClosureActor`, `assertBeneficiaryCreditable`) + `onCallClosing` limité à 4 fonctions | `index.js`, `accountAdmission.js` | acteur et bénéficiaires relus en transaction avant toute écriture | tests de câblage (liste fermée) | `index.js` modifié non commité | test : `onCallClosing` n'apparaît que pour la liste | arbitrage sur `index.js` |
| **L4** | `payOrderFromWalletCF`, `cancelOrderCF`, `deliverOrderCF`, `confirmOrderDeliveryWithProof` : D6-a/b/c, DR1–DR3, journaux dans la transaction, `epoch+1` | `orderActions.js`, `orderRefunds.js` | pas de solde négatif ; crédit omis ⇒ flag ; aucune écriture partielle ; transaction unique | 7E-97 §8 (#1–#16, #23, #24) + cas `sealed`/`closing` | tests existants modifiés (7E-97 R2) | rejeu idempotent, collisions d'identifiants exclues | oui (code d'argent) |
| **L5** | Chemins de crédit D1/D2 : compensation de retrait, `transferSettlement`, `adminBilling`, `adminOrderDisputes`, `refundExpiredBoutiqueOrderCF`, `autoExpireOrders`, FeexPay | `feexpayPayments.js`, `transferSettlement.js`, modules admin, `index.js` | aucun crédit vers `isDeleted` ; refus de toute l'approbation si un livreur est fermé | 7E-97 #17–#20 + tests de scellé | planificateur : exécution par lots, une commande en échec ne bloque pas les autres | idem | oui |
| **L6** | Protocole Ekbine (§4) : flag dans la transaction, `origin`/`decidedBy`, garde du client à la confirmation | `ekbineOrders.js` (+ tests) | flag créé exactement une fois ; aucun flag perdu | tests de rejeu, de refus, de cohérence `origin` | conflit avec les modifications non commitées (7E-72, 7E-68, commit 3 / D3) | tests Ekbine existants verts | oui (arbitrage du commit 3) |
| **L7** | Writer de décisions et de preuves (2D-2B) | module neuf, règles Firestore/Storage | N2 : deux responsables ; N3 : indisponible ; preuve relue côté serveur | règles + unité + concurrence sur `requestId` | immutabilité non imposable par les règles | conformité au schéma 2D-2A.1 Q4 | oui |
| **L8** | Contrôle de rapprochement Ekbine (flags perdus) | lecture seule | aucune écriture | tests purs | extension du périmètre du moteur | — | oui (extension du moteur) |

Ordre recommandé : L0 → L1 → L2 → L3 → L4 → L5 → L6 → L7 (L8 optionnel). L2 ne doit pas être activé tant que L4/L5 ne protègent pas les writers : **l'intégration du moteur sans verrou et sans gardes de bénéficiaires ne ferme pas la fenêtre** (§0.2, 7E-97 §9 étape 2 qui précède l'assouplissement du wrapper).

---

## 6. Plan de tests (aucun lancé dans cette mission)

| # | Test | Environnement | Pré-requis | État |
|---|---|---|---|---|
| 1 | Suite complète sous Node 22.23.4 (`npm test`) | CI ou machine équipée ; aucun gestionnaire de versions installé ici | machine adaptée | **non fait** (Node 24.22.1 seul disponible) |
| 2 | Tests unitaires et voisins | idem | idem | verts sous Node 24 (2 241 réussis, 0 échec, 169 ignorés) ; à rejouer sous Node 22 |
| 3 | Les 169 tests ignorés (Firestore, Auth, Storage, `AZ_E2E_RULES=1`) | émulateurs isolés (ports dédiés, projet `demo-*`) | autorisation d'exécuter des émulateurs | non fait |
| 4 | Règles Firestore (tombstone, futures collections de décisions) | émulateur + Java | règles rédigées en L7 | non fait |
| 5 | Concurrence : (a) writer B/C/D vs T2b ; (b) writer A vs T1 ; (c) deux T2b simultanés ; (d) expiration du scellé et writer pendant `deleteUser` simulé ; (e) deux demandes avec le même `requestId` ; (f) lecture à 201 | émulateurs isolés, 25 rondes minimum avec délais aléatoires comme 7E-89 | L1–L4 | non fait |
| 6 | Échec de suppression Auth et reprise : `updateUser` en échec, `deleteUser` en échec, `auth/user-not-found` inattendu, échec de la vérification d'absence, double processus | simulations dans les tests (faux Auth) puis émulateur Auth | L2 | non fait |
| 7 | Tests synthétiques en préproduction | environnement **distinct de la production**, comptes `synthetic-*`, aucune donnée réelle | environnement désigné **[A]** | non fait |
| 8 | Mesure du budget de lectures | compteur de `snapshot.size` + relevé des lectures facturées | étape 7 | non fait |
| 9 | Vérification que l'arbre de travail non commité n'est pas écrasé | revue de diff avant chaque lot | — | permanent |

Critères d'acceptation de la concurrence : zéro effet financier validé après `sealed` ; zéro `deleteUser` sans T2b réussi ; zéro crédit vers `isDeleted` ; toute écriture refusée laisse l'état identique. Ils prouvent l'absence de violation sur les entrelacements tirés, pas la sécurité en production (même limite que 7E-89 §6).

---

## 7. Hypothèses, risques et décisions

### 7.1 Hypothèses non prouvées **[H]**

1. L'invalidation par conflit sur un document lu puis écrit par une autre transaction s'applique en production comme en émulateur.
2. Le comportement d'une *requête* de transaction face à l'insertion d'un document correspondant n'est pas utilisé comme garantie.
3. La marge de 15 s et le délai de scellé de 60 s couvrent la durée d'un appel `deleteUser` et la dérive d'horloge.
4. Les jetons déjà émis ne sont pas révoqués immédiatement : aucun contrôle de révocation dans les callables n'a été établi.
5. L'analyse des writers est statique : aucune ligne n'a été exécutée, certaines fonctions (`checkPendingWithdrawals`, `adminApproveWithdrawalCF`, `ekbineAgentDepositAction`) n'ont pas été lues intégralement.

### 7.2 Risques **[F/H]**

1. Un écrivain hors registre (script, console) n'est pas empêché par le protocole.
2. Un crédit en quarantaine simple immobilise le compte (réserve R6 de 7E-97).
3. Contention sur le document tombstone : acceptable (un document par compte fermé, débit faible) mais à mesurer.
4. L'arbre de travail contient des modifications non commitées dans des fichiers que les lots L3 et L6 devront toucher.
5. Le flag Ekbine d'annulation peut déjà avoir été perdu pour des commandes passées ; aucun contrôle ne le détecte.
6. Les gardes Ekbine existantes dans l'arbre de travail ne sont pas dans HEAD.

### 7.3 Décisions humaines requises **[A]**

1. Choix du document de verrou : champs additifs du tombstone, ou document séparé.
2. Valider la classification du §1, notamment les lignes marquées « par analogie » (boutique expirée, `autoExpireOrders`, remises d'espèces, Ekbine).
3. Valider les règles dérivées DR1–DR3 et la formalisation de D1–D3 mentionnée au §0.1.
4. Valider la durée du scellé (60 s) et la marge (15 s).
5. Décider si l'annulation d'une demande de suppression (levée de tombstone) est nécessaire.
6. Décider du sort des anciens flags Ekbine (§4.3) et de l'extension du contrôle de flags perdus (§4.4).
7. Arbitrer les modifications non commitées (`ekbineOrders.js`, `index.js`, etc.) avant L3/L6.
8. Désigner l'environnement de préproduction et autoriser les émulateurs isolés pour L0 et les tests de concurrence.
9. Outil `held_for_review` : prérequis pour tout traitement de webhook en scellé (D4).

### 7.4 Conditions d'entrée de 2D-2B

2D-2B (writer de décisions, L7) dépend de : les décisions 1, 2, 4, 6 ci-dessus ; la validation du schéma de décisions et de preuves (2D-2A.1 Q4) ; au minimum L0 (base Node 22 et émulateurs) ; et, avant toute **activation** de l'intégration du moteur, les lots L1 à L5. Autorisation humaine explicite de démarrer : **non donnée**.

Je m'arrête ici. 2D-2B n'est pas commencé et aucun writer n'est modifié.
