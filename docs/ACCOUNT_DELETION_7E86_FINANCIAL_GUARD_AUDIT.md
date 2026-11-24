# Mission 7E-86 — Audit des gardes financières et préparation du commit 2

Date : 2026-11-08 · HEAD `294332e` (commit 1B), parents `65e738b` (commit 1) puis `aa3d1b0`. **Audit en lecture seule** : aucun code modifié, aucun `git add`/commit/push, aucun déploiement, aucune commande distante, aucun secret lu ni affiché, `operations_control/account_deletion` non créé, production `az-express-b0469` non touchée. Seule exécution : 374 tests unitaires existants sous Node 22 (sans émulateur, lecture seule). Ce rapport est non suivi.

Légende des preuves : **[V]** vérifié dans le code actuel · **[T]** couvert par un test nommé · **[N]** non déterminé (non lu ligne à ligne). L'état « HEAD » = commits déjà créés ; « AT » = arbre de travail non committé.

## 1. Mécanisme de quarantaine (rappel vérifié)
- Dans **une seule transaction** (`accountDeletion.js` l.87-90) le moteur crée `account_tombstones/{uid}` **et** pose `isSuspended:true` (+ `isOnline/isAvailable:false`) sur le profil. `deletionRequested:true` n'est posé **que pour les livreurs** (l.179/182) ; `isDeleted:true` seulement à l'anonymisation finale. **[V]**
- Conséquence : pour un **client**, seuls le tombstone et `isSuspended` signalent la quarantaine. Un flux qui ne teste que `deletionRequested`/`isDeleted` ne voit **pas** un client en quarantaine. **[V]**
- Garde générale HEAD : le wrapper `onCall` de `functions/index.js` (l.83-88) appelle `assertAccountEnabled` (lecture du tombstone de l'appelant, **hors transaction**, échec de lecture propagé = fermé) avant 59 callables. **Ne protège pas** : `rawOnCall` (Partner QR, suppression de compte), les modules qui importent `onCall` directement (`adminGuards`, `adminPartnerAccounts`, `artisanAccounts`, `artisanCredentials`, `marketplacePublishing`, `partnerActivationGuard`, `partnerFirstLogin`, `passwordReset`, `professionalSubscriptions`, `serviceProviderApplication`), ni webhooks/planifiés/triggers (volontaire). **[V]**
- `assertNewAccountActivity(tx,…)` (HEAD) relit tombstone + profil(s) **dans** la transaction ; `assertTargetNotClosing` (AT) vérifie un compte **cible** hors transaction. **[V]**
- `inspect()` du moteur (avant et après la quiet period) bloque la suppression si une opération non terminale, `refundPending`, `needsReview` ou `paymentStatus:'pending'` existe sur `orders`, 4 collections de commandes, `wallet_transactions` (top-level) et `withdrawal_requests` (l.44-55). Il ne voit pas ce qui naît **après** la 2ᵉ inspection. **[V]**

## 2. Ce qui est déjà dans HEAD et ce qui ne l'est pas
| Élément | HEAD | AT (non committé) |
|---|---|---|
| `assertAccountEnabled` + wrapper `onCall` | oui | — |
| `assertNewAccountActivity` dans E-Kbine | **non** (0 occurrence dans `ekbineOrders.js` HEAD) | oui (3 points) |
| Garde dans `pendingActions.js` (aiConfirmAction) | non | oui |
| Garde in-tx dans `initiateFeexPayPayment` / `initiateWithdrawal` | non | oui |
| `shouldHoldPayment` / `held_for_review` (webhook) | non | oui |
| `assertTargetNotClosing`, gardes P3 (mots de passe, abonnements) | non | oui |
| `pilotLightOptions` (plafonds préproduction) | non | oui |
| Tests `accountQuarantineGuards`, `accountQuarantineIndex`, `accountQuarantineConcurrency.emulator`, `ekbineQuarantineGuards` | — | **non suivis (nouveaux fichiers)** |
Gardes déjà en HEAD dans d'autres flux (via `assertNewAccountActivity`) : `catalogQuote`, `partnerOrderQuote`, `eventReservations`, `adminWalletRequests`, `adminDriverRecharge`, outils AZ IA (delivery, marketplace, pharmacies, restaurants). **[V]**

Base de test exécutée : `accountQuarantineGuards`, `accountQuarantineIndex`, `ekbineQuarantineGuards`, `pilotCap`, `passwordReset`, `adminPartnerAccounts`, `professionalSubscriptions`, `feexpayPayments`, `pendingActions`, `accountDeletionHardening` → **374/374 PASS, Node 22.23.4, 24 s**.

## 3. Inventaire des fonctions qui lisent, écrivent ou déplacent des fonds
Classes de protection : **PT** présente et testée · **PI** présente mais insuffisamment testée · **PA** absente · **ND** non déterminé. « Tx » = relue dans la transaction financière.

### 3.1 Paiements, retraits (FeexPay) et AZ IA
| Fonction | Mouvement | Garde AT (HEAD) | Tx | Tests | Classe |
|---|---|---|---|---|---|
| `initiateFeexPayPayment` | crée une demande de collect `pending` (pas de solde) | oui (wrapper seul) | oui (AT) | 5 unitaires + emulateur A | **PT** (après commit) |
| `feexPayWebhook` → `processFeexPayWebhookEvent` | crédite le wallet si collect vérifié | oui, mise en attente (aucune) | oui (profil + tombstone lus ensemble) | 6 unitaires + emulateur C1-C3 | **PT** |
| `initiateWithdrawal` | débite + payout | oui (wrapper seul) | oui (AT) | 5 unitaires + emulateur A2 | **PT** (après commit) |
| `checkWithdrawalStatus` (propriétaire ou super-admin) / `feexpayPayoutScheduler` → `applyPayoutStatus` | règle un retrait ; **FAILED = crédit de compensation** | aucune | non | 0 réf. suppression | **PA** pour profil `isDeleted` (voir R2) |
| `compensateFailedWithdrawal` (refus sans référence) | crédit de compensation | aucune | non | 0 réf. suppression | **PA** pour profil `isDeleted` |
| `aiConfirmAction` (confirm) | exécute le `confirmHandler` (commande, débit, recharge) | oui, **centrale** avant tout handler | oui | 6 unitaires + emulateur B/B2 | **PT** (après commit) |
| `aiConfirmAction` (cancel) | aucun fonds | volontairement non gardée | — | — | OK |
| `azIaChat` | crée actions/mémoire, **aucun fonds** | wrapper seul | — | — | hors périmètre financier (R8) |
| `initiate_wallet_recharge` (outil AZ IA) | `wallet_transactions` pending dans la tx de confirmation, appel FeexPay en `afterConfirm` | couvert par la garde centrale | oui | idem | **PT**, `afterConfirm` hors tx par conception |

### 3.2 E-Kbine
| Fonction | Mouvement | Garde AT | Tests | Classe |
|---|---|---|---|---|
| `ekCreateOrderCF` | débit wallet client | oui (tx) | 3 + idempotence | **PT** (après commit) |
| `ekClientConfirmOrder` | crédit `walletBalance` agent | oui (tx, sur l'agent) | 5 | **PT** (après commit) |
| `ekbineAcceptOrder` | débit/avance agent | oui (tx) | oui | **PI** (pas de test de concurrence émulateur dédié) |
| `ekCancelOrderCF` | remboursement client | aucune (volontaire) | — | à confirmer **ND** |
| `ekbineAgentDepositAction`, `ekbineSubmitDepositProof`, `ekbineUpdateDepositAccounts` | transactions de statut, pas d'écriture de solde dans `index.js` | aucune | — | non financier direct **[V]** (argent réel hors plateforme) |
| `ekbineReconciliation` | lecture | — | — | OK |

### 3.3 Débits wallet client à la création/au paiement d'une commande
| Fonction | Garde dans la transaction | Tests suppression | Classe |
|---|---|---|---|
| `createCatalogOrderFromQuoteCF` | `assertNewAccountActivity` (HEAD) | 4 réf. | **PT** |
| `createPartnerOrderFromQuoteCF` | idem (HEAD) | 2 | **PT** |
| `createEventReservationCF` | idem (HEAD) | 3 | **PT** |
| `createOrderFromQuoteCF` (livraison, `deliveryQuote.js`) | **seulement** `deletionRequested`/`isDeleted` (l.106, jamais posés sur un client en quarantaine) ; ni tombstone ni `isSuspended` | 2 | **PA transactionnelle** (wrapper seul) — **écart G1** |
| `payOrderFromWalletCF` (`orderActions.js` l.47) | aucune ; wrapper seul | 0 | **PA** — **écart G1** |
| `payBoutiqueOrderCF` (`orderActions.js` l.1271) | contrôle du vendeur seulement | 0 | **PA** — **écart G1** |
| `manageProfessionalSubscription` | `closing` relu (l.106, AT) ; module hors wrapper | 1 | **PI** |

### 3.4 Cycle de vie des commandes, remboursements, règlements
| Fonction | Mouvement | Garde | Tests suppression | Classe |
|---|---|---|---|---|
| `acceptOrderCF` | débit commission livreur | `deletionRequested`/`isSuspended` dans la tx (effectif : la quarantaine pose `isSuspended`) | 1 | **PI** |
| `deliverOrderCF`, `cancelOrderCF`, `refundExpiredBoutiqueOrder`, `autoExpireOrders` (`expireOrderTx`), `rateLimitCancelTx` | clôture d'opérations engagées, **crédits/remboursements** | aucune, **à ne pas bloquer** | 0 | **PA par conception** ; risque seulement si le profil est `isDeleted` (R3) |
| `driverRelease`, `driverTransfer`, `transferSettlement`, `earningsSettlement` | crédits livreurs | `driverTransfer` teste `isSuspended`/`deletionRequested` ; les autres aucune | 0 | **ND/PA** |
| `adminBilling`, `adminOrderDisputes`, `adminOrderRefunds` | crédits admin vers client/livreur/vendeur | aucune | 0 | **PA** (R3) |
| `adminWalletRequests`, `adminDriverRecharge` | crédits admin | `assertNewAccountActivity` | 1 / 4 | **PT** |
| `partnerOrderActions`, `partnerOrderReconciliation`, `cashPayment`, `settleTerminalOrder` (trigger) | règlement vendeur/espèces | non lus ligne à ligne | 0 | **ND** |
| `walletReconciliationCheck` | lecture seule | — | — | OK |

## 4. Risques identifiés
- **R1 (élevé)** Trois débits wallet client sans garde transactionnelle (`createOrderFromQuoteCF`, `payOrderFromWalletCF`, `payBoutiqueOrderCF`) : seul le wrapper (lecture hors tx) protège. Un client mis en quarantaine entre le wrapper et le commit peut voir son wallet débité et une commande créée ; la transaction de quarantaine met à jour le même profil, donc le conflit est détecté, **mais au rejeu la transaction financière ne teste ni le tombstone ni `isSuspended`** et continue. La fenêtre est courte mais réelle. Aucune de ces trois fonctions n'a de test de quarantaine (sauf deux références pour `deliveryQuote`).
- **R2 (moyen)** Compensation de retrait en échec (`applyPayoutStatus`, `compensateFailedWithdrawal`) : crédite le wallet sans tester `isDeleted`. Sur profil anonymisé, l'argent est crédité à un compte sans propriétaire, sans `needsReview`. Seul `user_not_found` est traité. Le moteur (`inspect`) bloque en principe tant qu'un retrait est `processing` : risque limité à une course après la 2ᵉ inspection.
- **R3 (moyen)** Crédits administratifs et remboursements automatiques sur un profil `isDeleted` : aucune détection. À ne pas bloquer pour un compte seulement en quarantaine (il s'agit de rendre son argent).
- **R4 (élevé pour l'activation)** `held_for_review` n'a **aucun** outil de consultation ni de résolution (section 6).
- **R5 (moyen)** `ekClientConfirmOrder` : si l'agent est en quarantaine, la confirmation est refusée et la commande reste `proof_sent` « pour le support ». Le client a déjà payé ; aucun outil de reprise n'a été trouvé. À traiter avec la revue métier E-Kbine.
- **R6 (moyen)** Écriture des traces secondaires après la transaction du webhook (`logSecurityEvent`, `logAudit`) : un arrêt entre les deux perd la trace, le statut `held_for_review` reste la source de vérité (déjà noté en 7E-71).
- **R7 (faible)** Webhook FeexPay authentifié par secret dans l'URL (`?wh_secret=`), pratique préexistante ; vérification indépendante du paiement et du montant auprès de l'opérateur en plus.
- **R8 (faible)** `azIaChat`, `clearAiHistory`, rappels : peuvent recréer des données personnelles après effacement ; non financier, hors du commit 2.
- **R9 (information)** Le wrapper ne couvre pas les callables importés directement : en HEAD, `professionalSubscriptions`, `passwordReset`, `adminPartnerAccounts` n'ont aucune garde (corrigé seulement en AT / commit 3b).
- **R10 (information)** La garde de `pendingActions` est placée **avant** le contrôle d'expiration : sous quarantaine, une action expirée est refusée sans passer au statut `expired` (inoffensif, le nettoyage planifié s'en charge).
- **R11 (quota)** `pilotLightOptions` (1 instance, 0,25 vCPU) pour 4 fonctions ; quota régional non confirmé : aucun déploiement autorisé.

## 5. Cas FeexPay
| Étape | Constat |
|---|---|
| Initiation (collect) | crée `wallet_transactions` `pending` ; garde in-tx (AT) ; échec de lecture du tombstone = refus ; l'appel opérateur a lieu après la transaction |
| Authentification du webhook | secret configuré obligatoire, comparaison côté serveur, refus 401 + événement de sécurité si invalide **[V]** |
| Vérification | statut vérifié auprès de l'opérateur (`createStatusVerifier`) et montant comparé avant tout crédit **[V]** |
| Idempotence | `credited`, `completed` ou `held_for_review` ⇒ « déjà traité » à deux niveaux (lecture initiale puis dans la transaction) ; tests de double webhook (unitaire + émulateur C1) |
| Compte en quarantaine | motifs : `profile_anonymized`, `payment_created_after_quarantine`, `tombstone_date_unreadable`. Collect **antérieur** au tombstone et profil intact : **crédité** (solde non nul ⇒ bloque la suppression via `inspect`) |
| Opération suspecte | `status:'held_for_review'`, `needsReview:true`, `reviewReason`, `credited:false`, solde **inchangé**, réponse 200, événement de sécurité `high` + audit |
| Payout | initiation gardée (AT) ; règlement `SUCCESS` sans écriture de solde ; `FAILED` ⇒ compensation unique, **sans test `isDeleted`** (R2) ; états ambigus ⇒ `needsReview` |
| Conservation | aucune transaction supprimée ni solde modifié pour résoudre un conflit **[V]** |

## 6. État de `held_for_review`
- **Producteur** : présent (AT). **Lecteurs** : le moteur lit seulement `needsReview===true` pour bloquer une suppression **non encore anonymisée** (`financial_regularization_required`) ; l'application Flutter classe tout statut inconnu en « pending » (sans explication, 7E-71).
- **Aucun** `listHeldPayments`, `resolveHeldPayment`, écran ou requête d'administration dans le code ; seul moyen : console Firebase (`needsReview == true`). Aucun état « résolu » n'existe.
- Cas aggravant : un paiement `held_for_review` arrivé **après l'anonymisation** n'a plus de dossier de suppression ouvert qui le signale.
- **Mécanisme nécessaire (conforme à la proposition 7E-71, à ne pas développer ici)** : lecture super-admin (`listHeldPayments`) ; machine d'états additive sur `wallet_transactions` (`held_for_review → resolution_proposed → credited_after_review | rejected_after_review | refund_requested → refund_confirmed`) ; double validation par deux super-administrateurs ; revérification opérateur du montant ; crédit **interdit** si profil anonymisé ou tombstone (seulement rejet/remboursement enregistré hors système) ; idempotence par `txId`+action ; audit complet ; aucun appel d'API de remboursement ; aucune action par AZ IA.
- **Décision recommandée** : cet outil ne fait **pas** partie du commit 2 (fonction financière nouvelle, +CPU dans un quota non confirmé, revue dédiée). Il reste une **condition bloquante d'activation** de la suppression avec FeexPay actif ; FeexPay reste désactivé et non activé par cette mission.

## 7. Matrice des tests manquants
Existant [T] : webhook après quarantaine, webhook dupliqué, profil anonymisé, erreur de lecture (fail-closed), recharge/retrait entre garde d'entrée et transaction (simulé), AZ IA double confirmation et action antérieure, E-Kbine création/confirmation avec course simulée, 9 scénarios émulateur (A, A2, B, B2, C1-C3, D, E).

| # | Cas demandé | État | Test à créer |
|---|---|---|---|
| 1 | Paiement concurrent avec suppression | partiel (émulateur A + fake) | extension aux 3 débits wallet manquants |
| 2 | Retrait concurrent avec tombstone | partiel (A2 émulateur) | aucun ajout indispensable |
| 3 | Webhook après quarantaine | **présent** | — |
| 4 | Double webhook | **présent** (unitaire + C1) | — |
| 5 | Remboursement concurrent | **manquant** | cancel/expire/rateLimit vs quarantaine ; crédit refusé/mis en revue seulement si `isDeleted` |
| 6 | Confirmation E-Kbine concurrente | partiel (fake) | scénario émulateur dédié ; le cas « 8 appels » de `financialConcurrency.emulator` reste intermittent |
| 7 | Opération engagée avant la demande | partiel (`inspect` bloquant, dossier `blocked`) | test bout en bout wallet/commande engagée |
| 8 | Échec transactionnel puis nouvelle tentative | partiel (fail-closed) | rejeu du webhook après erreur de lecture |
| 9 | Compensation de retrait FAILED sur profil `isDeleted` / tombstone seul | **manquant** | 4 cas (anonymisé, quarantaine, normal, rejeu) |
| 10 | `payOrderFromWallet`, `payBoutique`, `createOrderFromQuote` sous tombstone / `isSuspended` / course | **manquant** | 3 × (refus, aucune écriture, course) |
| 11 | Crédits admin vers cible `isDeleted` | **manquant** | `adminBilling`, `adminOrderDisputes`, `transferSettlement` |
| 12 | Résolution de `held_for_review` | **impossible** (outil absent) | avec l'outil |
Les émulateurs ne sont **pas** une preuve de sécurité en production ; verrouillage de plage de requêtes Admin SDK : **ND**.

## 8. Plan du commit 2
### 8.1 Découpage
- **2A — gardes P2 déjà écrites (indispensable)** : `functions/accountAdmission.js` (`assertTargetNotClosing`), `functions/feexpayPayments.js`, `functions/azia/index.js`, `functions/azia/pendingActions.js`, `functions/pilotCap.js`, `functions/index.js` (hunks pilotCap, import accountAdmission, options `pilotLightOptions` ×3, garde in-tx collect, garde in-tx retrait : patch `index_p2.patch`) ; tests `accountQuarantineGuards`, `accountQuarantineIndex`, `accountQuarantineConcurrency.emulator` (nouveaux), `pilotCap.test.js`. Le hunk `setPharmaciePassword` reste dans 3b.
- **2B — combler l'écart G1 (indispensable avant activation)** : `functions/deliveryQuote.js` (`assertNewAccountActivity` dans la transaction de `createOrderFromQuoteCF`, comme `catalogQuote.js` l.189), `functions/orderActions.js` (`buildPayOrderFromWallet`, `buildPayBoutiqueOrder`) ; trois fichiers de test (ou un fichier `walletDebitQuarantineGuards.test.js`).
- **2C — crédits sur profil anonymisé (recommandé, secondaire)** : `feexpayPayments.js` (`applyPayoutStatus`, `compensateFailedWithdrawal` : si `isDeleted===true` ⇒ `needsReview` + anomalie, aucun crédit ; tombstone seul ⇒ compensation normale + événement de sécurité) ; crédits admin : refus explicite si cible `isDeleted` (décision D2).
- **Hors commit 2** : E-Kbine (commit 3, revue métier non signée), gardes P3 (commit 3b), correctif de test Node 22, script de déploiement, documentation, **outil `held_for_review`** (mission dédiée), gardes non financières (AZ IA mémoire, immobilier, administration).

### 8.2 Dépendances et ordre recommandé
1. 2A en premier (2B et 2C réutilisent `assertNewAccountActivity` déjà en HEAD ; 3b dépend de `assertTargetNotClosing` de 2A).
2. 2B (3 insertions d'une ligne dans des transactions existantes ; régression : ordre des lectures avant écritures, nombre de lectures +1 à +2 par débit).
3. 2C seulement après décision D1/D2.
4. Aucun nouveau déploiement de fonction dans 2A-2C hors modification des 4 existantes plafonnées (quota non confirmé).

### 8.3 Risques de régression
Chemins d'argent actifs (wallets, commandes) : toute lecture ajoutée doit précéder les écritures de la transaction (règle « lecture avant écriture ») ; compteur de lectures ; messages d'erreur inchangés pour les comptes actifs ; `acceptOrder`, `deliverOrder`, `cancelOrder`, webhooks et planifiés **non bloqués** ; suites à relancer : paiements/wallet (~178), AZ IA (~174), règles Firestore principales (470), E-Kbine (54), concurrence émulateur.

### 8.4 Conditions de validation
- Tests d'unité des sections 7 (1, 9, 10, 11) créés **avant** le code (rouge puis vert) ; assertions existantes inchangées.
- `npm test` complet sous Node 22 : comparaison avec la référence 2328/2280/1 échec `dispatchRetry` (pré-existant)/47 ignorés, aucune régression nouvelle.
- Suite émulateur de concurrence (9 scénarios) relancée ; échecs intermittents documentés, jamais masqués.
- Revue humaine des diffs de `index.js` (patchs `index_p2` seul) et SHA-256 des fichiers avant/après.
- Décisions humaines D1-D4 (section 9) prises par écrit.
- Aucun déploiement tant que le quota Cloud Run n'est pas confirmé humainement.

## 9. Décisions nécessaires
- **D1** compensation d'un retrait en échec sur profil anonymisé : mise en revue (recommandé) ou crédit tel quel.
- **D2** crédits administratifs vers un compte `isDeleted` : refus explicite (recommandé) ou crédit tracé.
- **D3** `ekClientConfirmOrder` quand l'agent est en quarantaine : outil de reprise support (revue métier E-Kbine).
- **D4** `held_for_review` : calendrier de l'outil (bloquant l'activation production avec FeexPay actif).
- **D5** classement des modules non lus (`partnerOrderActions`, `cashPayment`, `earningsSettlement`, `settleTerminalOrder`) : lecture dédiée avant 2B.

## 10. Limites de l'audit
Lecture ciblée (≈35 fichiers repérés par recherche de mouvements de solde) ; fonctions classées **ND** non lues ligne à ligne ; aucune lecture de données de production ni appel réseau ; comportement du verrouillage Firestore en production non démontré ; secrets non lus.

## 11. Contrôles
HEAD `294332e`, index vide, commits 1 et 1B inchangés, aucun fichier de code modifié, aucun accès distant, aucun déploiement, aucun secret exposé. `git status` : 87 entrées avant ce rapport (+ ce rapport).

## Verdict
**COMMIT 2 SPÉCIFIÉ SOUS CONDITIONS**
Conditions : décisions D1-D5 ; écart G1 (2B) à combler avant toute activation ; `held_for_review` sans outil de résolution (bloquant l'activation production) ; modules ND à lire ; quota non confirmé (aucun déploiement). Aucun code modifié ni commit créé. En attente d'une autorisation humaine distincte.
