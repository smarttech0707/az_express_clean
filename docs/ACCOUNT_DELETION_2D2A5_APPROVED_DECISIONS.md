# 2D-2A.5 — Consolidation des décisions humaines (suppression de compte, fermeture financière)

Date : 2026-11-10. Branche `finalisation/az-express`, HEAD `d65c8f0`. Document de consolidation uniquement. Aucun code, test, règle ni configuration modifié ; aucun émulateur, opération Firebase ou commande distante ; aucun commit, push ni déploiement ; aucun document existant modifié ; aucun lot L0–L8 commencé.

Sources documentaires : registre 2D-2A.4 (`ACCOUNT_DELETION_2D2A4_DECISION_REGISTER.md`, **R4**), protocole final 2D-2A.3 (**P3**), 2D-2A.2 (**P2**), 2D-2A.1 (**P1**), 2D-2A (**P0**), décisions 7E-73 (`EKBINE_SCOPE_DECISION`), 7E-87 (`DECISION_REGISTER`), 7E-97 (`SPECIFICATION_2C_2D`), rapports 7E-98 à 7E-108, et la **consigne de la mission 2D-2A.5** (message du propriétaire, désignée **C5**) qui énonce les onze décisions.

## 0. Règle de classification utilisée ici

| Statut | Critère appliqué |
|---|---|
| **APPROUVÉE** | la consigne C5 l'énonce comme décision à formaliser, sans réserve. Seul le **principe énoncé** est approuvé |
| **RECOMMANDÉE** | proposition de l'assistant (P3, R4) que C5 ne reprend pas comme décision, ou ajout de détail de mise en œuvre non validé explicitement |
| **À CONFIRMER** | C5 renvoie à une validation, ou une contradiction avec une source impose un arbitrage humain |

Règle de prudence : pour chaque décision, **ce qui est dit par C5 est APPROUVÉ ; tout ce que j'y ajoute pour la rendre exécutable est RECOMMANDÉ** tant que le propriétaire ne l'a pas validé explicitement. Rien n'est promu au-delà. C5 ne contient ni signature ni liste nominative : l'identité des approbateurs n'est pas établie par les sources (voir D-10).

Aucune des preuves de concurrence connues (7E-89, 9 scénarios sur 9) n'est une preuve de fonctionnement en production : elles ont eu lieu en émulateur (7E-89 §6, 7E-97 R1).

---

## D-1 — Tombstone comme document de référence, verrou transactionnel commun, `epoch`

| Rubrique | Contenu |
|---|---|
| Statut | **APPROUVÉE** pour : tombstone existant comme référence, verrou commun lu et modifié dans la transaction de chaque writer, présence d'`epoch`. **RECOMMANDÉE** pour : liste exacte des champs (`phase`, `epoch`, `updatedAtMs`, `sealToken`, `sealEpoch`, `sealedAtMs`, `snapshotDigest`, `deleting`, `deleteStartedAtMs`, `authDeletedAtMs`, `lastRecovery`), nom du helper `assertFinancialLock`, règle « le tombstone n'est jamais supprimé après suppression Auth » (voir D-7) |
| Justification | le document existe déjà, est créé par T1 (`accountDeletion.js:88`), est lu par le wrapper, par les gardes et par les règles `isAuth()` (`firestore.rules:7-12`) ; deux transactions qui lisent puis écrivent le même document se sérialisent, sans dépendre du comportement des requêtes face à une insertion (Q11 non démontrée) |
| Source | C5 §1 ; P3 §1.1–§1.5 ; décisions 2D-2A.3 §1 ; 7E-89 scénario 5 |
| Risques et limites | preuve **en émulateur** seulement ; hypothèses H1 (conflit identique en production), H2 (contention d'un document par compte) à vérifier en préproduction ; un writer hors protocole (script, console) n'est pas couvert ; les gardes actuelles ne font que **lire** : ce sont des flux de catégorie A qui n'ont pas besoin de bumper |
| Conditions de mise en œuvre | lot L1 (helper pur, tests), puis branchement par lots ; aucune écriture supplémentaire pour un compte actif ; un tombstone sans `phase` reste lu comme `closing`, `epoch` 0 |
| Autorité | propriétaire du projet (PO) pour le schéma ; relecteur technique indépendant (TECH) pour la sérialisation |

**Contradictions.** Aucune avec 7E-73 ni 7E-87. Écart d'extension avec 7E-97 : sa spécification n'utilise que des **lectures** (`accountCreditState`, `assertClosureActor`, `assertBeneficiaryCreditable`) et ne prévoit ni `epoch` ni écriture du tombstone par les writers. D-1 **étend** 7E-97 ; l'extension doit être revue avec ses lots 2C-A à 2C-D.

---

## D-2 — Récupération administrative stricte ; seconde approbation pour `deleting:true`

| Rubrique | Contenu |
|---|---|
| Statut | **APPROUVÉE** : récupération administrative stricte ; seconde approbation obligatoire quand `deleting:true`. **RECOMMANDÉE** : les autres conditions de P3 §1.6 et de R4 REG-02 (rappelées ci-dessous). **À CONFIRMER** : identité du second responsable, liste des codes de motif |
| Justification | le scellé ne se rouvre jamais par un délai (AP-12) ; `deleting:true` signifie qu'un `deleteUser` a pu partir : l'état est incertain, d'où deux responsables (principe N2, 7E-105) |
| Source | C5 §2 ; P3 §1.6, §3.4–§3.6 ; R4 REG-02 ; 7E-105 (deux responsables indépendants) |
| Risques et limites | avec un seul super-admin, les cas `deleting:true` restent en attente (conforme à D-6 de P3) ; Auth incertain ne doit jamais entraîner une réouverture ; une récupération mal vérifiée rouvre des écritures financières |
| Conditions de mise en œuvre | voir tableau ci-dessous ; fonction dédiée de catégorie D (L2R) ; audit strict (la transaction échoue si l'audit échoue) ; après récupération toute reprise repasse par T2 et T2b complets |
| Autorité | super-admin (SA) pour l'exécution ; second responsable pour `deleting:true` ; PO pour les motifs |

Conditions (recommandées sauf les deux lignes approuvées) :

| Situation | Condition pour passer `sealed → closing` | Statut |
|---|---|---|
| `sealed`, `deleting` faux, bail libre, utilisateur Auth présent | SA + motif + `requestId` + inspection complète lisible enregistrée + audit strict | Recommandée |
| `deleting:true` | **seconde approbation d'un responsable différent** (en plus des conditions ci-dessus) | **Approuvée** |
| Auth **incertain** (lecture Auth en erreur, issue d'appel indéterminée) | refus : aucune réouverture tant que l'état Auth n'est pas établi | Recommandée |
| Auth **absent** | récupération refusée : la suppression a eu lieu, le dossier se complète par T3 | Recommandée |
| Bail actif sur le dossier | refus | Recommandée |
| Après récupération | `epoch+1`, sceau effacé, dossier `blocked` + `reviewRequired`, réactivation Auth séparée et postérieure | Recommandée |

**Contradiction signalée.** Le commentaire de `accountDeletionSupport.js:4` énonce : « No support action can change consent, money, identity bindings or completion ». La récupération modifie l'état de complétion de la suppression. Elle doit donc être une **fonction administrative distincte** de `manageAccountDeletionCF`, pas une nouvelle action de support (cohérent avec L2R). Pas de contradiction avec 7E-73 ni 7E-97.

---

## D-3 — Classification A/B/C/D avec vérification individuelle des writers

| Rubrique | Contenu |
|---|---|
| Statut | **APPROUVÉE** : classification A/B/C/D appliquée avec **vérification individuelle** de chaque writer. **À CONFIRMER** : chaque ligne tant que sa vérification individuelle n'est pas faite (voir tableau). La classification de P3 §4 reste **RECOMMANDÉE** ligne par ligne |
| Justification | analyse de P2/P3 **statique** : aucun writer n'a été exécuté ; trois n'ont pas été lus intégralement (`checkPendingWithdrawals`, `adminApproveWithdrawalCF`, `ekbineAgentDepositAction`) |
| Source | C5 §3 ; P3 §4 ; R4 §3 ; 7E-97 §1–§3 (D6) ; 7E-73 |
| Risques et limites | classer par analogie peut ouvrir ou fermer à tort une opération d'argent ; un writer oublié reste hors protocole |
| Conditions de mise en œuvre | fiche de vérification par writer avant son lot : lecture complète ; parties concernées (appelant, client, livreur, vendeur, partenaire, agent, bénéficiaires) ; points de crédit/débit ; frontières de transaction ; présence du wrapper ; effet attendu en `closing` et en `sealed` ; décision ancrée ou par analogie ; test de concurrence associé |
| Autorité | PO (valide chaque ligne) ; TECH (relit la fiche) |

Statut ligne par ligne (reprise de R4 §3) :

| Writer ou action | Cat. | Statut au 2026-11-10 |
|---|---|---|
| `payOrderFromWalletCF` | B | Ancré D6-a/D6-b ; vérification individuelle à faire |
| `cancelOrderCF` | C | Ancré D6-c ; DR1 voir D-8 ; vérification à faire |
| `deliverOrderCF`, `confirmOrderDeliveryWithProof` | B | Ancré D6-c ; DR2 voir D-8 ; vérification à faire |
| `releaseOrderBeforePickupCF`, progression de mission | A | Ancré 7E-97 §3 ; vérification à faire |
| `settleTransferEarningsCF`, `adminBillingCF`, `adminOrderDisputeCF` | D | **À confirmer** (D2, voir D-8) |
| `adminConfirmDeliveryCF` | D (+B) | Partiellement ancré ; cibles **à confirmer** |
| `refundExpiredBoutiqueOrderCF` | C | **Analogie — à confirmer** |
| `autoExpireOrders` | C | **Analogie — à confirmer** |
| `declareCashNonPayment` | A | **Analogie — à confirmer** |
| `declareCashHandover`, `confirmCashRemittance`, `disputeCashRemittance` | B | **Analogie — à confirmer** |
| `resolveCashRemittance`, `reviewCashNonPayment` | D | Ancré dans le code (`requireSuperAdmin`) ; contrôles de cible **à confirmer** |
| `acceptPartnerOrder`, `startPreparation`, `markReady`, `refusePartnerOrder` | A | **Analogie — à confirmer** |
| `ekCancelOrderCF` | C | Ancré 7E-73 ; flag atomique **recommandé** |
| `ekClientConfirmOrder` | B | Ancré 7E-73 (agent) ; relecture du client **recommandée** |
| `ekCreateOrderCF`, `ekbineAcceptOrder` | A | Ancré 7E-73, 7E-68 |
| `manageProfessionalSubscription` | A | classement **à confirmer** |
| Créations de commande, `initiateFeexPayPayment`, `initiateWithdrawal` | A | Ancré (gardes en HEAD) |
| `feexPayWebhook` | B | Ancré `held_for_review` ; comportement en `sealed` **recommandé** |
| Recharges administratives | D | Ancré (garde en HEAD) |
| `checkPendingWithdrawals`, `adminApproveWithdrawalCF`, `ekbineAgentDepositAction` | non classés | **Inventaire requis** |

**Contradictions.** Aucune avec D6 de 7E-97. Écarts d'extension : 7E-97 §3 laisse `adminConfirmDeliveryCF` « inchangé » ; P3 y ajoute le contrôle des cibles (D2). 7E-73 laisse `ekCancelOrderCF` « inchangé » ; P3 déplace seulement l'écriture du flag dans la transaction (aucun changement de comportement visible), à valider.

---

## D-4 — Seuils d'alerte

| Rubrique | Contenu |
|---|---|
| Statut | **RECOMMANDÉE**, **à faire approuver formellement** (C5 le dit expressément). Aucun seuil n'est approuvé |
| Seuils proposés | (1) dossier `sealed` depuis plus de **1 heure** (`sealedAtMs`) ; (2) `deleting:true` sans `authDeletedAtMs` depuis plus de **15 minutes** ; (3) **modification d'`epoch` après T2** ; (4) complément : dossier `blocked` après `MAX_ATTEMPTS` (6, `accountDeletion.js:139`) |
| Justification | le temps sert à alerter, jamais à déverrouiller (AP-12) ; chaque seuil désigne un état qui ne devrait pas durer ou ne pas se produire |
| Source | C5 §4 ; P3 §2 ; R4 REG-04 |
| Risques et limites | trop sensibles ⇒ bruit ; trop lâches ⇒ comptes figés ; canal et destinataire non définis ; dépend de la disponibilité du support ; aucune alerte ne rouvre quoi que ce soit |
| Conditions de mise en œuvre | choix du canal (écran de support existant ou notification), du destinataire et d'une procédure de réponse ; mesures de durée en préproduction avant de fixer les valeurs définitives |
| Autorité | PO |

**Contradictions.** Aucune. Le seuil (3) est un événement, pas une durée.

---

## D-5 — Préservation des cinq fichiers non commités ; intégration séparée du moteur

| Rubrique | Contenu |
|---|---|
| Statut | **APPROUVÉE** : préserver les cinq fichiers ; intégrer le moteur `accountObligations.js` **séparément**. **RECOMMANDÉE** : modalités (patch local daté, indexation par chemins explicites). **À CONFIRMER** : ordre et moment des commits |
| Justification | ces fichiers contiennent des travaux de missions distinctes (7E-68, 7E-72) qui se chevauchent avec L3 et L6 ; le moteur est un autre périmètre et n'est pas dans HEAD |
| Source | C5 §5 ; P3 §6 ; R4 REG-05 ; 7E-68, 7E-72, 7E-73, 7E-93 à 7E-95 ; CLAUDE.md (ne jamais committer sans demande explicite) |
| Faits vérifiés | `ekbineOrders.js` +8 (gardes client/agent/accept Ekbine) ; `index.js` +2 (hunk `setPharmaciePassword`) ; `professionalSubscriptions.js` +3/−1 ; `adminPartnerAccounts.js` +3 ; `passwordReset.js` +3 ; tests : `passwordReset.test.js` +2, `restaurantV2Preprod.test.js` +1/−1 ; non suivis : `ekbineQuarantineGuards.test.js`, `accountObligations.js`, `accountObligations.test.js` ; avertissement Git LF→CRLF sur `ekbineOrders.js` |
| Risques et limites | chevauchement avec L6 (`ekbineOrders.js`) et L3 (`index.js`) ; perte de travail si le worktree est nettoyé ; le moteur absent de HEAD interdit une activation reproductible |
| Conditions de mise en œuvre | aucune modification de ces fichiers hors lot autorisé ; pas de `git add .`, `stash`, `checkout --`, `reset` ; patch de sauvegarde hors dépôt avant tout lot concerné ; moteur intégré dans un commit distinct, avant L2 |
| Autorité | PO (commits) ; TECH (revue des diffs) |

**Contradictions.** Aucune avec 7E-95 (qui range ces fichiers en « commit 3 E-Kbine » et « commit 3b »). Rappel : les gardes Ekbine dans l'arbre de travail ne sont pas dans HEAD.

---

## D-6 — Anciens flags Ekbine bloquants, sans suppression automatique

| Rubrique | Contenu |
|---|---|
| Statut | **APPROUVÉE** : bloquants, aucune suppression automatique. **À CONFIRMER** : voie de sortie éventuelle. **RECOMMANDÉE** : protocole d'origine serveur pour les **nouveaux** flags et écriture atomique |
| Justification | l'origine d'un flag ancien est inconnue : les deux flags Ekbine sont créés par le client sans champ d'acteur (`ekbineOrders.js:264-268, 318-326`) ; le moteur exige une origine (`ORIGIN_DECIDER_REQUIRED`, `accountObligations.js:243`) |
| Source | C5 §6 ; 7E-107 ; P3 §5 ; R4 REG-06 |
| Risques et limites | blocage durable de certains clients Ekbine ; flags d'annulation déjà perdus (écriture hors transaction) indétectables par le moteur, qui ne lit pas `ekbine_orders` |
| Conditions de mise en œuvre | nouveaux flags : `origin{uid,role,action,eventRef,atMs,flagRef,originProof}` et `decidedBy` écrits par le serveur dans la même transaction (lot L6) ; anciens flags : aucun traitement automatique ; sorties possibles (clôture hors système N2 avec preuve, outil de reconstitution validé par deux responsables) à décider |
| Autorité | PO ; SA pour toute clôture ; second responsable pour N2 |

**Contradictions.** Aucune avec 7E-73. Rappel : 7E-87 D3 recommandait de créditer l'agent en quarantaine ; 7E-73 l'a remplacé (voir D-8).

---

## D-7 — Annulation de demande uniquement avant `sealed`, sous nouvelle inspection

| Rubrique | Contenu |
|---|---|
| Statut | **APPROUVÉE** : l'annulation d'une demande de suppression n'est possible **qu'avant `sealed`** et **sous nouvelle inspection**. Tout le reste de sa conception est **RECOMMANDÉ** ou **À CONFIRMER** |
| Justification | un compte en fermeture ne doit pas rester prisonnier d'une demande ; une fois scellé, l'opération irréversible est engagée |
| Source | C5 §7 ; P3 §3.5, §10 (sujet resté ouvert) ; 7E-87 D3 (« aucune suppression de tombstone n'existe dans le code ») |
| Risques et limites | rouvrir un compte sans nouvelle vérification ; course entre annulation et T2b ; question de l'initiateur non tranchée |
| Conditions de mise en œuvre (recommandées) | fonction dédiée de catégorie D ; refus si `phase:'sealed'` ou `deleting:true` ; nouvelle inspection (`inspect()` et moteur) **enregistrée** (le résultat n'empêche pas l'annulation mais est tracé) ; vérification que l'utilisateur Auth existe et que le profil n'est pas `isDeleted` ; réactivation Auth et levée de `isSuspended` seulement après le succès ; audit strict ; même transaction et même document de verrou que D-1, pour que T2b et l'annulation se sérialisent |
| **À CONFIRMER** | (a) **qui** annule : l'utilisateur lui-même (ses callables sont bloqués par le tombstone, il faudrait une fonction hors wrapper comme `requestAccountDeletionCF`, qui est `rawOnCall`) ou le super-admin ; (b) **mécanisme** : suppression du tombstone ou autre état ; (c) sort de l'`epoch` et du dossier `account_deletions/{uid}` (`state:'cancelled'` ?) ; (d) conséquences si des obligations ont été créées en `closing` |
| Autorité | PO (règle) ; SA (exécution si initiée par l'administration) ; TECH |

**Contradictions à signaler.**
1. **Avec P3 §1.1** : P3 écrit que le tombstone n'est jamais supprimé après suppression Auth — compatible, car l'annulation n'a lieu qu'**avant** `sealed`. Mais P3 §3.5 écrivait que lever un tombstone n'existe pas : D-7 crée une capacité nouvelle.
2. **Avec 7E-87 D3** : « aucune suppression de tombstone n'existe » reste vrai dans le code ; D-7 ne le change pas tant que non implémenté.
3. **Avec `accountDeletionSupport.js:4`** : le support ne peut pas changer la complétion ; l'annulation exige donc une fonction distincte.
4. **Avec 7E-97 §4.3** : « avant la quarantaine, le compte reste utilisable et peut régler » ; l'annulation dans la fenêtre `closing` étend cette logique mais n'y figure pas.

---

## D-8 — Formalisation de D1–D3 et DR1–DR3

| Rubrique | Contenu |
|---|---|
| Statut | **APPROUVÉE** : formaliser ces règles « conformément aux règles exposées dans les décisions » (C5). **À CONFIRMER** : D3 (contradiction ci-dessous) ; chaque règle dérivée citée dans le rapport d'implémentation qui la reprendra. DR1–DR3 sont, selon 7E-97 R5, « à relire à l'autorisation d'implémentation » |
| Règles (texte des sources) | **D1** (7E-87) : retrait en échec sur profil anonymisé ⇒ revue `needsReview`, `anomaly:'profile_anonymized'`, aucun crédit ; compensation normale pour tombstone seul. **D2** (7E-87) : crédits administratifs (`adminBilling`, `adminOrderDisputes`, `adminOrderRefunds`, `transferSettlement`) vers `isDeleted` ⇒ refus explicite ; crédit permis pour tombstone seul. **D3** (7E-87) : confirmation Ekbine avec agent en quarantaine, recommandation (b) créditer sauf `isDeleted` ; voir contradiction. **DR1** (7E-97) : remboursement de commission vers un livreur `isDeleted` omis, `commissionStatus` reste `charged`, flag `beneficiary_account_closed` ; le client reste remboursé. **DR2** : partenaire `isDeleted` ⇒ livraison refusée sans écriture. **DR3** : profil absent traité comme anonymisé |
| Justification | éviter tout crédit automatique vers un compte sans propriétaire joignable ; ne pas faire perdre son argent au client |
| Source | C5 §8 ; 7E-87 §1 ; 7E-97 §1 |
| Risques et limites | statut formel de D1, D2, D3 : 7E-87 les présente comme **recommandations** (« Recommandation : … ») ; 7E-97 §1 les applique comme règles dérivées sans reproduire une validation nominative (P2 §0.1.5) ; un crédit sous quarantaine immobilise le compte (7E-97 R6) |
| Conditions de mise en œuvre | lots L4 (DR1, DR2, D6) et L5 (D1, D2) ; textes de refus et codes d'erreur explicites pour l'interface d'administration (7E-87 D2) ; tests 7E-97 #17–#20 |
| Autorité | PO |

**Contradiction signalée (obligatoire).** **D3 de 7E-87** recommande de **créditer** l'agent en quarantaine pour clôturer une opération engagée ; **7E-73 §1** décide qu'**un agent en quarantaine ne peut pas valider une confirmation** (échec sûr, commande laissée `proof_sent`). Le code non commité suit 7E-73 (`ekbineOrders.js`, garde agent). **Arbitrage proposé (à confirmer)** : 7E-73, décision postérieure et explicite du propriétaire, prévaut pour l'agent en quarantaine ; D3 ne subsiste que pour le cas profil `isDeleted`, où les deux sources convergent vers un refus/revue. L'état « argent client immobilisé, agent non payé » décrit par 7E-87 D3 persiste donc et passe par le support.

Autres écarts : 7E-97 §1 qualifie D6 de « définitives, non rouvertes » et DR1–DR3 de « dérivées » ; ils ne doivent pas être traités avec le même statut.

---

## D-9 — Tombstone comme contrôle serveur principal ; révocation Auth comme protection complémentaire

| Rubrique | Contenu |
|---|---|
| Statut | **APPROUVÉE** : le tombstone est le contrôle principal côté serveur ; la désactivation/révocation Auth est une protection **complémentaire**. **RECOMMANDÉE** : désactivation réversible avant T2b, réactivation séparée de la réouverture financière |
| Justification | le tombstone agit immédiatement, via le wrapper (lu à chaque appel), les règles `isAuth()` et les gardes transactionnelles, quel que soit le jeton ; la désactivation Auth n'empêche que de nouvelles sessions |
| Source | C5 §9 ; P3 §3.3 ; `index.js:83-90`, `firestore.rules:7-11`, `accountAdmission.js:2-13` ; 7E-97 R7 (jeton valide environ une heure) |
| Risques et limites | **non établi** : les callables ne vérifient pas la révocation des jetons ; un jeton déjà émis peut rester utilisable pour les fonctions non gardées par tombstone (H4) ; Firestore et Auth ne forment pas une transaction ; un échec de `deleteUser` ou un arrêt entre T2b et `deleteUser` laisse un état Auth à déterminer par lecture |
| Conditions de mise en œuvre | séquence T1 → quarantaine → T2 → désactivation → T2b → scellé → `deleteUser` (P3 §3.1) ; lecture ciblée du contrôle de révocation avant activation ; tests d'échec Auth en émulateur puis en préproduction |
| Autorité | PO ; TECH |

**Contradictions.** Aucune avec 7E-97 R7 : D-9 la confirme (la garde en transaction, non le jeton, protège).

---

## D-10 — Rôles : propriétaire du projet, super-admin, relecteur technique indépendant

| Rubrique | Contenu |
|---|---|
| Statut | **APPROUVÉE** : distinguer les trois rôles et leurs approbations (C5). **À CONFIRMER** : qui occupe chaque rôle (aucune source ne nomme de personne) ; la matrice ci-dessous est **RECOMMANDÉE** |
| Justification | l'indépendance exigée par N2 (7E-102, 7E-105) et par la revue de code suppose des rôles distincts |
| Source | C5 §10 ; R4 §0 ; 7E-102, 7E-105 ; moteur : approbateur ≠ demandeur ≠ décideur initial (`accountObligations.js:507-565`) |
| Risques et limites | si le PO et le SA sont la même personne, ils comptent pour **un seul** responsable : les décisions N2 restent en attente (conforme à D-6 de P3) ; une approbation donnée par l'assistant n'est jamais une approbation de rôle |
| Conditions de mise en œuvre | désigner nommément les trois rôles ; consigner la désignation dans un document ; l'assistant qui écrit un lot n'est **pas** le relecteur technique de ce lot |
| Autorité | PO |

Matrice recommandée :

| Acte | PO | SA | TECH | Second responsable |
|---|---|---|---|---|
| Autoriser une mission ou un lot (L0–L8, E1, P1) | **décide** | — | — | — |
| Valider un schéma, une règle de classification, un seuil | **décide** | consulté | avis | — |
| Relire le code d'un lot et ses tests | — | — | **valide** (indépendant de l'auteur) | — |
| Exécuter une récupération administrative | — | **exécute** | — | **requis si `deleting:true`** |
| Décision de résolution N2 | — | demandeur ou approbateur | — | **approbateur distinct** (≠ demandeur ≠ décideur initial) |
| Décision N3 | indisponible (N3 bloquant, AP-08) | | | |
| Autoriser un commit local | **décide** | — | revue | — |
| Autoriser l'activation (suppression, FeexPay) | **décide**, par écrit | — | avis | — |
| Autoriser tout accès à la préproduction | **décide**, spécifiquement | — | — | — |

**Contradictions.** Aucune avec les sources ; la matrice explicite ce que 7E-102/105 supposent.

---

## D-11 — Préproduction exclusivement sur `az-express-preprod`, après autorisation spécifique

| Rubrique | Contenu |
|---|---|
| Statut | **APPROUVÉE** : la préproduction est exclusivement `az-express-preprod`, accessible seulement après autorisation spécifique. La production `az-express-b0469` reste interdite |
| Justification | isolation de la production ; les documents 7E-70 désignent déjà ce projet comme « projet unique » de préproduction (n° 306761725053) |
| Source | C5 §11 ; `ACCOUNT_DELETION_7E70_PREPROD_DEPLOYMENT_PLAN.md` (lignes 3 et 7) ; `.firebaserc` |
| Faits vérifiés | `.firebaserc` désigne **la production** par défaut (`az-express-b0469`) et ne définit pas d'alias de préproduction ; le plan 7E-70 impose : toute commande porte `--project az-express-preprod`, jamais `firebase use`, ne pas se fier à `.firebaserc` ni à `gcloud config` ; un contrôle d'isolation (`verify-isolation.js`) doit retourner 0 avant toute action |
| Risques et limites | une commande sans `--project` explicite vise la production ; l'état actuel du projet de préproduction (déploiements, secrets, Secret Manager, index manquants, selon la mémoire du 05/11/2026) n'a pas été vérifié ici faute d'accès distant ; les émulateurs ne remplacent pas la préproduction |
| Conditions de mise en œuvre | autorisation spécifique, par phase, écrite par le PO ; projet explicite dans chaque commande ; contrôle d'isolation avant toute écriture ; jeux `synthetic-*` seulement ; aucune donnée de production ; critères de R4 REG-07 (concurrence, reprise après incident, transactions conflictuelles) |
| Autorité | PO (autorisation) ; TECH (contrôle d'isolation) |

**Contradictions.** Aucune. Précision : le registre R4 parlait d'un environnement « à désigner » ; C5 le désigne.

---

## 12. Tableau récapitulatif des statuts

| # | Décision | Principe énoncé | Détails de mise en œuvre | Validation encore nécessaire |
|---|---|---|---|---|
| D-1 | Tombstone, verrou commun, `epoch` | Approuvée | Recommandés | schéma exact, nom du helper |
| D-2 | Récupération stricte ; N2 pour `deleting:true` | Approuvée | Recommandés | identité du second responsable, motifs |
| D-3 | Classification A/B/C/D vérifiée individuellement | Approuvée | À confirmer par writer | inventaire et fiche de vérification de chaque writer |
| D-4 | Seuils 1 h / 15 min / `epoch` après T2 | **Recommandée** | — | **approbation formelle des seuils** |
| D-5 | Préservation des cinq fichiers ; moteur séparé | Approuvée | Recommandés | ordre et moment des commits |
| D-6 | Anciens flags Ekbine bloquants | Approuvée | Recommandés (nouveaux flags) | voie de sortie éventuelle |
| D-7 | Annulation avant `sealed`, sous nouvelle inspection | Approuvée (principe) | Recommandés / À confirmer | initiateur, mécanisme, sort du dossier |
| D-8 | Formalisation D1–D3, DR1–DR3 | Approuvée (formaliser) | À confirmer | **arbitrage D3 / 7E-73** ; relecture DR1–DR3 |
| D-9 | Tombstone principal, Auth complémentaire | Approuvée | Recommandés | contrôle de révocation des jetons |
| D-10 | Rôles distincts | Approuvée | Matrice recommandée | **désignation nominative** |
| D-11 | Préproduction `az-express-preprod` seule | Approuvée | Conditions recommandées | autorisation spécifique par phase |

## 13. Contradictions et écarts (liste consolidée)

| # | Sources | Nature | Traitement proposé |
|---|---|---|---|
| X-1 | 7E-87 D3 ↔ 7E-73 §1 | créditer l'agent en quarantaine (recommandation) ↔ échec sûr (décision) | 7E-73 prévaut ; **à confirmer** (D-8) |
| X-2 | 7E-87 D3 (« aucune suppression de tombstone n'existe ») ↔ D-7 | capacité d'annulation inexistante dans le code | D-7 la prévoit sans l'implémenter ; **à confirmer** |
| X-3 | `accountDeletionSupport.js:4` ↔ D-2, D-7 | le support ne peut pas changer la complétion | fonctions distinctes de `manageAccountDeletionCF` |
| X-4 | 7E-97 (lectures seules) ↔ D-1 (écriture d'`epoch`) | extension non prévue par 7E-97 | revue avec les lots 2C-A à 2C-D |
| X-5 | 7E-97 R5 (DR1–DR3 « à relire ») ↔ D-8 (formaliser) | statut des règles dérivées | relecture explicite à l'autorisation de L4 |
| X-6 | 7E-97 §3 et 7E-73 (« inchangés ») ↔ P3 (cibles, flag atomique) | contrôles ajoutés à deux writers | validation en D-3 |
| X-7 | 7E-87 (recommandations) ↔ 7E-97 §1 (règles dérivées) | statut formel de D1–D3 | validation en D-8 |

Aucune contradiction avec D6-a, D6-b, D6-c de 7E-97 ni avec les décisions N2/N3 de 7E-102 à 7E-107.

## 14. Prochaines autorisations (rappel, non approuvé)

1. Inventaire en lecture seule (fiches de vérification des writers, trois writers non lus).
2. Validation écrite des points « à confirmer » ci-dessus (D-2, D-3, D-4, D-6 sortie, D-7, D-8 X-1, D-10 désignation).
3. L0 : Node 22.23.4 et émulateurs isolés pour les 169 tests ignorés (autorisation distincte).
4. Préservation et commits des cinq fichiers et du moteur (autorisation distincte).
5. Développement lot par lot, puis E1, puis P1 sur `az-express-preprod` (autorisation spécifique), puis activation (autorisation écrite distincte).

Je m'arrête ici. Aucun lot L0–L8 n'est commencé.
