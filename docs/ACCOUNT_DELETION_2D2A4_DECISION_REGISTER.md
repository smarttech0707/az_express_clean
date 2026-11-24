# 2D-2A.4 — Registre final des décisions (suppression de compte, fermeture financière)

Document de registre uniquement. Branche `finalisation/az-express`, HEAD `d65c8f0`. Aucun code, test, règle, writer ni inspecteur modifié ; aucun lot L0–L8 commencé ; aucun émulateur, commande distante, opération Firebase, commit, push ni déploiement. Aucun document existant modifié. FeexPay et la suppression de compte ne sont pas activés.

Sources : `ACCOUNT_DELETION_2D2A3_FINAL_PROTOCOL.md` (désigné **P3**), 2D-2A (**P0**), 2D-2A.1 (**P1**), 2D-2A.2 (**P2**), décisions 7E-73 (`EKBINE_SCOPE_DECISION`), 7E-87 (`DECISION_REGISTER`), 7E-97 (`SPECIFICATION_2C_2D`), rapports 7E-98 à 7E-108. Aucune décision n'est créée ici : un sujet dont la source ne contient pas de décision est classé « proposé », « à confirmer » ou « bloquant ».

## 0. Légende et règles de lecture

| Statut | Sens dans ce registre |
|---|---|
| **APPROUVÉ** | la source cite une décision explicite (consigne 2D-2A.3 §1, décision 7E-73, 7E-97 §1 « confirmées », décisions 7E-102/105/107) |
| **PROPOSÉ** | conception de P3 sans décision humaine en source ; peut être adoptée telle quelle ou amendée |
| **À CONFIRMER** | une décision humaine est requise sur le fond ; la proposition de P3 n'est qu'un point de départ, ou la source est ambiguë |
| **BLOQUANT** | empêche le démarrage d'une étape nommée tant qu'il n'est pas levé |

« Responsable de validation » : les sources n'attribuent aucun nom. Rôles utilisés : **PO** = propriétaire du projet qui donne les autorisations dans cette série de missions ; **SA** = super-admin de l'application ; **TECH** = relecteur technique indépendant à désigner. Qui occupe ces rôles n'est pas établi par les sources **[à désigner par le PO]**.

Rappel de portée des preuves : toutes les validations de concurrence connues (7E-89) ont eu lieu **en émulateur**. Elles ne prouvent pas le fonctionnement en production (7E-89 §6, 7E-97 R1).

---

## 1. Décisions approuvées (rappel, avec sources)

| Id | Décision | Source | Justification | Risque associé | Validation |
|---|---|---|---|---|---|
| AP-01 | Le tombstone `account_tombstones/{uid}` est le document faisant autorité | consigne 2D-2A.3 §1 ; P3 D-1 | existe déjà, lu par toutes les gardes et par les règles (`accountAdmission.js:6`, `firestore.rules:10-12`) | un champ additif mal lu par un code existant (voir PR-01) | PO (déjà donnée) |
| AP-02 | `phase`, `epoch` et les informations de scellement sont additifs | idem ; P3 D-2 | compatibilité avec les tombstones existants | idem | PO (déjà donnée) |
| AP-03 | Tous les writers concernés lisent et modifient le même document dans leur transaction | idem ; P3 D-3 | sérialisation par un document unique | contention (hypothèse H2) | PO (déjà donnée) |
| AP-04 | Aucune nouvelle activité pendant la fermeture | idem ; D6 de 7E-97 | cohérence avec 2A/2B | — | PO (déjà donnée) |
| AP-05 | Règlements engagés possibles sous contrôles D6 (D6-a, D6-b, D6-c) | 7E-97 §1 « confirmées » | ne pas bloquer l'argent des clients | DR1–DR3 sont des règles dérivées (voir TC-04) | PO (déjà donnée) |
| AP-06 | Remboursements et compensations autorisés sous conditions | consigne 2D-2A.3 §1 | restitution | crédit en quarantaine immobilise le compte (7E-97 R6) | PO (déjà donnée) |
| AP-07 | N2 et N3 exigent deux responsables indépendants ; avec un seul super-admin ils restent en attente ; aucune auto-validation | 7E-102, 7E-105 ; consigne | contrôle à deux personnes | blocage durable tant qu'un second responsable n'existe pas | PO (déjà donnée) |
| AP-08 | N3 bloquant tant que le consentement du créancier n'est pas vérifiable | 7E-107 C1 ; 7E-108 | aucun contrat de consentement | — | PO (déjà donnée) |
| AP-09 | Anciens flags Ekbine sans origine fiable : bloquants | 7E-107 ; `ORIGIN_DECIDER_REQUIRED` (`accountObligations.js:243`) | origine inconnue | blocage permanent de certains clients | PO (déjà donnée) |
| AP-10 | Délai de réflexion de 24 h exclu | consigne 2D-2A.3 §1 | non approuvé en 7E-106 | — | PO (déjà donnée) |
| AP-11 | `held_for_review` obligatoire avant l'activation réelle de FeexPay | 7E-87 D4 (recommandation), 7E-97 R10 ; confirmé consigne 2D-2A.3 §1 | paiement réel retenu sans issue | outil de résolution absent aujourd'hui | PO (déjà donnée) |
| AP-12 | Aucun déverrouillage automatique fondé sur un délai | consigne 2D-2A.3 §2 | éviter la réouverture silencieuse | `sealed` bloqué suspend les règlements | PO (déjà donnée) |
| AP-13 | Agent Ekbine en quarantaine : pas de validation de confirmation ; client en quarantaine : pas de création de commande Ekbine ; commandes terminées/engagées inchangées | 7E-73 §1 | sécurité | commande laissée `proof_sent` (support) | PO (déjà donnée) |
| AP-14 | Le moteur s'ajoute aux contrôles existants ; `paid_by_client_out_of_system` indisponible ; production intouchable | 2D-2A.2 ; 7E-108 | prudence | — | PO (déjà donnée) |
| AP-15 | Registre proposé : `account_deletion_decisions`, `account_deletion_evidence`, `account_deletion_supersessions` | consigne 2D-2A.2 « Décisions acquises » | schéma 2D-2A.1 Q4 | détails du schéma encore à valider (PR-08) | PO (déjà donnée pour les noms) |

---

## 2. Registre des décisions du §10 de P3

Statuts : **P** proposé, **C** à confirmer, **B** bloquant (pour l'étape nommée).

### REG-01 — Schéma du tombstone, helper unique, sérialisation par `epoch` (P3 §10.1)

| Élément | Contenu |
|---|---|
| Statut | **PROPOSÉ** (principes AP-01 à AP-03 approuvés ; champs exacts et nom du helper : propositions) |
| Source | P3 §1.1, §1.3, §1.4, §1.5 ; faits : `accountDeletion.js:88`, `accountAdmission.js:2-13`, `firestore.rules:7-12`, 7E-89 #5 |
| Examen | (a) **Schéma** : conservation de `createdAt`, `state:'deleting'`; ajout de `phase`, `epoch`, `updatedAtMs`, `sealToken`, `sealEpoch`, `sealedAtMs`, `snapshotDigest`, `deleting`, `deleteStartedAtMs`, `authDeletedAtMs`, `lastRecovery`. Les gardes existantes testent `exists` seulement : compatibles. Un tombstone sans `phase` est lu comme `closing`, `epoch` 0. Pas de phase `deleted` (le tombstone reste scellé après suppression). (b) **Helper** : `assertFinancialLock(tx, db, HttpsError, parties, opClass)`, seul point d'implémentation ; il lit tombstone et profil de chaque partie, refuse en `sealed`, refuse A en `closing`, écrit `epoch+1` pour B/C/D. (c) **Sérialisation** : chaque writer B/C/D et T2b lisent puis écrivent le même document ; l'`epoch` observé à T2 doit être identique à T2b |
| Justification | ne dépend pas du comportement des requêtes de transaction face à une insertion (Q11 non démontrée) ; document unique par compte |
| Risques | **[F]** en émulateur seulement ; **[H]** H1 (conflit identique en production), H2 (contention du document), H4 (jetons) ; un writer hors protocole (script, console) n'est pas couvert ; un helper mal appliqué crée un trou ; sur un compte actif, le helper ne doit rien écrire |
| Point à examiner de plus près | les gardes existantes (`assertNewAccountActivity`) ne font que lire ; les convertir en écritures `epoch+1` change leur nature : elles sont aujourd'hui dans des flux A (refus) qui n'ont pas besoin de bump ; seuls les flux B/C/D bumpent |
| Prérequis | lecture complète des writers non lus (voir REG-03), tests purs du helper (L1), E1 en émulateur |
| Responsable | PO pour le schéma ; TECH pour la sérialisation |
| Bloque | L1 (nom et emplacement du helper) ; pas L0 |

### REG-02 — Récupération administrative (P3 §10.2)

| Élément | Contenu |
|---|---|
| Statut | **À CONFIRMER** (aucune source n'approuve une procédure de réouverture) ; principe « jamais sans nouvelle vérification » approuvé par la consigne 2D-2A.3 §2 |
| Source | P3 §1.6, §3.4–§3.6 ; consigne ; AP-07, AP-12 |
| Conditions proposées | voir tableau ci-dessous |
| Justification | éviter un `sealed` irréversible tout en interdisant l'automatisme |
| Risques | un seul super-admin ⇒ les cas N2 restent en attente et peuvent figer un compte ; une récupération mal vérifiée rouvre des écritures financières ; Auth indécidable |
| Prérequis | existence du helper (L1), des inspecteurs modifiés (L2), de la fonction (L2R) ; règle d'autorisation (SA) ; liste fermée de codes de motif |
| Responsable | PO (principe et motifs) ; SA (exécution) ; TECH |
| Bloque | L2R ; pas L0, pas L1 |

Conditions de récupération administrative (proposition P3 §1.6) :

| Situation | Condition requise pour passer `sealed → closing` | Statut |
|---|---|---|
| `sealed`, `deleting` absent ou faux, bail libre, Auth présent | SA + motif + `requestId` + inspection complète lisible enregistrée + audit strict | PROPOSÉ |
| `deleting:true` (un `deleteUser` a pu partir) | idem **+ seconde approbation d'un responsable différent (N2)** ; avec un seul SA : en attente | PROPOSÉ (N2 dérivé d'AP-07 ; application à la récupération non décidée) |
| Auth **incertain** (lecture Auth en erreur, résultat d'appel indéterminé) | **refus** : aucune réouverture tant que `getUser` ne tranche pas ; pas de bascule par défaut | PROPOSÉ |
| Auth **absent** (`user-not-found`) | récupération **refusée** : la suppression a eu lieu ; on complète par T3 | PROPOSÉ |
| Bail actif sur `account_deletions/{uid}` | refus | PROPOSÉ |
| Après récupération | `epoch+1`, sceau effacé, dossier `blocked`+`reviewRequired`, toute reprise repasse par T2 et T2b complets | PROPOSÉ |
| Réactivation Auth | décision distincte, après la réouverture, jamais en `sealed` | PROPOSÉ |

Approbations N2 : le moteur impose déjà approbateur ≠ demandeur ≠ décideur initial pour les décisions de résolution (`accountObligations.js:507-565`). L'extension de ce principe à la récupération administrative est une **proposition**, non une règle du moteur. Qui est le second responsable n'est pas défini dans les sources **[bloquant pour les cas N2]**.

### REG-03 — Classification A/B/C/D des writers (P3 §10.3)

| Élément | Contenu |
|---|---|
| Statut | **À CONFIRMER** pour les lignes « analogie » ; **APPROUVÉ** pour les lignes ancrées sur une décision (voir §3) |
| Source | P3 §4 ; 7E-97 §1–§3 ; 7E-87 ; 7E-73 |
| Justification | chaque writer est classé selon son effet sur l'argent et sa nature |
| Risques | analyse **statique** : aucun writer n'a été exécuté ; trois n'ont pas été lus intégralement (`checkPendingWithdrawals`, `adminApproveWithdrawalCF`, `ekbineAgentDepositAction`, P2 §7.1) |
| Prérequis | lecture complète de ces writers (inventaire) |
| Responsable | PO ; TECH |
| Bloque | L4, L5 pour les lignes à confirmer ; pas L0 ni L1 |

### REG-04 — Seuils d'alerte (P3 §10.4)

| Élément | Contenu |
|---|---|
| Statut | **PROPOSÉ** (aucun seuil n'existe en source ; aucun n'est approuvé) |
| Source | P3 §2 |
| Propositions | `sealed` depuis plus de 1 heure ; `deleting:true` sans `authDeletedAtMs` depuis plus de 15 minutes ; `epoch` incrémenté après T2 ; `blocked` après `MAX_ATTEMPTS` (6, `accountDeletion.js:139`) |
| Justification | le temps sert à alerter, jamais à déverrouiller (AP-12) |
| Risques | trop sensibles ⇒ bruit ; trop lâches ⇒ comptes figés ; canal d'alerte non défini ; dépend de la disponibilité du support |
| Prérequis | choix du canal (écran support `manageAccountDeletionCF` ou notification), propriétaire de l'alerte |
| Responsable | PO |
| Bloque | activation seulement (pas L0–L8) |

### REG-05 — Cinq fichiers non commités et moteur (P3 §10.5)

| Élément | Contenu |
|---|---|
| Statut | **À CONFIRMER** ; le non-suivi du moteur est **BLOQUANT** pour L2 |
| Source | P3 §6 ; 7E-68, 7E-72, 7E-73, 7E-93 à 7E-95 ; `git diff` du 2D-2A.3 |
| Faits | `ekbineOrders.js` +8 (7E-72/7E-68, « commit 3 E-Kbine ») ; `index.js` +2 (hunk P3 `setPharmaciePassword`) ; `professionalSubscriptions.js` +3/−1 ; `adminPartnerAccounts.js` +3 ; `passwordReset.js` +3 (commit 3b) ; tests : `passwordReset.test.js` +2, `restaurantV2Preprod.test.js` +1/−1 (commit indépendant), `ekbineQuarantineGuards.test.js` non suivi ; moteur et son test non suivis |
| Traitement documenté | aucune modification ; préservation par patch local daté hors dépôt avant tout lot concerné ; indexation par chemins explicites seulement ; jamais `git add .`, `stash`, `checkout --`, `reset` ; fins de ligne : avertissement CRLF sur `ekbineOrders.js` à traiter dans un commit séparé |
| Justification | éviter d'écraser ou de mélanger des travaux de missions différentes |
| Risques | chevauchement L3/L6 avec `index.js` et `ekbineOrders.js` ; perte de travail non commité ; le moteur absent de HEAD empêche toute activation reproductible |
| Prérequis | décision du PO sur : commiter ou non, dans quel ordre (3b, 3 E-Kbine, test indépendant, moteur), et quand |
| Responsable | PO |
| Bloque | **L2** (moteur à intégrer dans HEAD), **L3** et **L6** (chevauchement) ; pas L0, pas L1 |

### REG-06 — Anciens flags Ekbine et annulation d'une demande de suppression (P3 §10.6–§10.7)

| Sujet | Statut | Contenu |
|---|---|---|
| Anciens flags Ekbine sans origine | **APPROUVÉ** : restent bloquants (AP-09) | aucune reconstitution automatique |
| Voies de sortie des anciens flags | **À CONFIRMER** | (a) aucun traitement, blocage durable ; (b) clôture hors système par décision N2 avec preuve ; (c) outil futur de reconstitution `originProof:'reconstructed'`, validé par deux responsables. Aucune n'est approuvée |
| Origine serveur des nouveaux flags | **PROPOSÉ** | `origin{uid,role,action,eventRef,atMs,flagRef,originProof}` et `decidedBy` ; écriture dans la même transaction ; sans modification du moteur (alias `decidedBy`, `accountObligations.js:559`) |
| Flags d'annulation déjà perdus | **À CONFIRMER** | indétectables par le moteur (ne lit pas `ekbine_orders`) ; contrôle de rapprochement proposé (L8) ; extension de périmètre non décidée |
| Annulation d'une demande de suppression (levée de tombstone) | **À CONFIRMER** ; absente du code (7E-87 D3 : « aucune suppression de tombstone n'existe ») | ce serait un writer de catégorie D ; tant que non décidé, un tombstone n'est jamais levé et la réactivation Auth ne le lève pas |
| Source | P3 §3.5, §5 ; 7E-73 ; 7E-87 ; 7E-107 |
| Justification | éviter un faux positif durable ou une levée de quarantaine sans contrôle |
| Risques | clients Ekbine durablement bloqués ; utilisateur ne pouvant pas annuler sa demande ; origine reconstruite non fiable |
| Prérequis | L6 pour les nouveaux flags ; décision du PO pour le reste |
| Responsable | PO ; SA pour toute clôture N2 |
| Bloque | L6 (conception de `origin`) ; L8 (extension) ; activation pour les clients Ekbine concernés |

### REG-07 — Critères de validation en préproduction (P3 §10.8)

| Élément | Contenu |
|---|---|
| Statut | **PROPOSÉ** (critères) ; l'environnement est **BLOQUANT** |
| Source | P3 §8 (C1–C10) ; 2D-2A §5.4 ; 7E-89 §6 |
| Prérequis | un environnement **distinct de la production**, désigné par le PO ; données `synthetic-*` ; autorisation explicite ; E1 réussi en émulateur |
| Responsable | PO ; TECH |
| Bloque | P1 ; toute activation |

Critères proposés (non approuvés). Aucune validation en émulateur ne les remplace :

| Domaine | Critère de réussite | Scénarios |
|---|---|---|
| Concurrence | zéro effet financier validé après `sealed` ; zéro `deleteUser` sans T2b réussi ; zéro crédit vers un profil `isDeleted` ; un refus laisse l'état identique | C1 (writer vs T2b), C2 (A vs T1/closing), C3 (doubles appels), C4 (webhook/planificateur vs sealed), C5 (multi-livreurs), C7 (deux T2b) ; au moins 25 rondes avec délais aléatoires par scénario |
| Transactions conflictuelles | tout rejet de transaction est rejoué sans double effet ; nombre de rejouements et durées mesurés ; aucune erreur `Transaction is invalid or closed` non rejouée n'aboutit à une écriture partielle (7E-97 R1) | C1, C3, C7 |
| Reprise après incident | arrêt simulé entre T2b et `deleteUser` : `sealed` intact, reprise par `drain` sans déverrouillage, alerte ; échec de `deleteUser` : état déterminé par `getUser` ; récupération administrative selon REG-02 ; N2 en attente avec un seul SA | C8, C9, C10 |
| Ekbine | flag présent après arrêt simulé entre écritures (écriture atomique) | C6 |
| Budget de lectures | lectures par scénario conformes à 2D-2A §5.1 (écart ≤ 5 %), durée de transaction mesurée (seuil à fixer par le PO) | S0–S6 de 2D-2A §5.4 |
| Données | aucune donnée réelle, comptes `synthetic-*`, jamais la production | tous |

### REG-08 — Préproduction, émulateurs, Node 22 (P3 §10.8, §10.9)

| Élément | Contenu |
|---|---|
| Statut | **BLOQUANT** pour L0 (Node 22.23.4, émulateurs) et pour P1 (environnement) |
| Source | P3 §7 (L0, E1, P1), 2D-2A §6 ; 7E-71 `NODE22_VALIDATION`, 7E-72 `NODE22_FINAL_TESTS` pour la pratique antérieure |
| Faits | Node disponible ici : 24.22.1 seul ; Node 22.23.4 non validé (CI ou machine équipée) ; 169 tests « skipped » faute d'émulateur (motifs comptés en 2D-2A §6) ; aucun test ignoré n'a été exécuté dans cette série |
| Risques | confondre Node 24 et Node 22 ; compter les ignorés comme réussis |
| Prérequis | machine équipée Node 22.23.4 ; autorisation d'exécuter des émulateurs isolés (ports et projet `demo-*` dédiés, sans toucher aux émulateurs de l'utilisateur) ; environnement de préproduction désigné |
| Responsable | PO |
| Bloque | **L0** (Node 22 + émulateurs) ; **P1** |

### REG-09 — Délai de 24 h (P3 §10.9)

| Statut | **APPROUVÉ** : exclu (AP-10). Aucune implémentation, aucune dépendance. |

---

## 3. Classifications A/B/C/D : ancrage ou analogie

« Ancré » = une décision citée couvre le comportement. « Analogie » = P3 l'a déduit de D1–D6 par cohérence, sans décision nommant ce writer. Ces lignes sont **à confirmer**.

| Writer ou action | Cat. | Ancrage | Statut |
|---|---|---|---|
| `payOrderFromWalletCF` | B | D6-a, D6-b (7E-97 §1) | **Ancré** |
| `cancelOrderCF` | C | D6-c, DR1 (DR1 = règle dérivée) | Ancré (D6-c) ; **DR1 à confirmer** |
| `deliverOrderCF`, `confirmOrderDeliveryWithProof` | B | D6-c, DR2 ; exception de 7E-97 §3 pour la preuve | Ancré (D6-c) ; **DR2 à confirmer** |
| `releaseOrderBeforePickupCF`, progression de mission | A | 7E-97 §3 « inchangés » (progression = nouvelle mission) | **Ancré** |
| `settleTransferEarningsCF`, `adminBillingCF`, `adminOrderDisputeCF` | D | D2 (7E-87 : recommandation ; appliquée comme règle dérivée en 7E-97 §1) | **À confirmer** (D1/D2/D3 non confirmés individuellement, P2 §0.1.5) |
| `adminConfirmDeliveryCF` | D | 7E-97 §3 « inchangé » (appelant super-admin) ; contrôle des cibles par D2 | Partiellement ancré ; cibles **à confirmer** |
| `refundExpiredBoutiqueOrderCF` | C | aucun ; analogie D1/D2 | **Analogie — à confirmer** |
| `autoExpireOrders` (planificateur) | C | aucun ; 7E-97 §7 sur l'atomicité seulement | **Analogie — à confirmer** |
| `declareCashNonPayment` | A | aucun | **Analogie — à confirmer** (alternative : l'autoriser avec bump d'`epoch`) |
| `declareCashHandover`, `confirmCashRemittance`, `disputeCashRemittance` | B | aucun ; analogie D6-b | **Analogie — à confirmer** |
| `resolveCashRemittance`, `reviewCashNonPayment` | D | `requireSuperAdmin` dans le code ; 7E-102 pour l'origine | Ancré (code) ; contrôles de cible **à confirmer** |
| `acceptPartnerOrder`, `startPreparation`, `markReady`, `refusePartnerOrder` | A | aucun nommé ; analogie « progression exclue » (7E-97 §3) | **Analogie — à confirmer** |
| `ekCancelOrderCF` | C | 7E-73 : « commandes engagées : comportement inchangé » ; client en quarantaine peut clôturer | Ancré (7E-73) ; flag atomique **proposé** |
| `ekClientConfirmOrder` | B | 7E-73 : agent en quarantaine ⇒ échec sûr | **Ancré** (agent) ; relecture du client **proposée** |
| `ekCreateOrderCF`, `ekbineAcceptOrder` | A | 7E-73, 7E-68 | **Ancré** |
| `manageProfessionalSubscription` | A (renouvellement) | 7E-68 (garde existante non commitée) ; actions `suspend`/`deactivateVip` permises | Ancré dans le code, **classement P3 à confirmer** |
| Créations de commande, `initiateFeexPayPayment`, `initiateWithdrawal` | A | gardes en HEAD (lot 2A/2B) | **Ancré** |
| `feexPayWebhook` crédit | B | `held_for_review` existant ; AP-11 | Ancré ; comportement en `sealed` **proposé** |
| Recharges administratives | D | garde en HEAD | **Ancré** |
| `checkPendingWithdrawals`, `adminApproveWithdrawalCF`, `ekbineAgentDepositAction` | non classés | lecture incomplète | **Non classés — inventaire requis** |

Signalement : **cinq** lignes reposent sur une analogie pure (boutique expirée, `autoExpireOrders`, `declareCashNonPayment`, remises d'espèces, actions de préparation partenaire) ; **six** autres reposent sur des règles dérivées ou des contrôles de cible non confirmés (DR1, DR2, D2, cibles de `adminConfirmDeliveryCF`, `resolveCashRemittance`/`reviewCashNonPayment`, `manageProfessionalSubscription`) ; **trois** writers ne sont pas classés. Ils bloquent **L4/L5** pour leur périmètre, pas L0/L1.

---

## 4. Autres sujets ouverts

| Id | Sujet | Statut | Source | Justification | Risques | Responsable | Prérequis | Bloque |
|---|---|---|---|---|---|---|---|---|
| TC-01 | Validation formelle de D1, D2, D3 | **À CONFIRMER** | 7E-87 (recommandations) ; 7E-97 §1 (appliquées comme règles dérivées) | D3 est contredite par 7E-73 pour Ekbine | confusion sur la source faisant foi | PO | relecture 7E-87/97 | L5 |
| TC-02 | Interprétation « origine » des flags Ekbine (acteur déclencheur = client) | **À CONFIRMER** | P1 Q5 ; P3 §5 | pas de décideur humain à la création | indépendance triviale vis-à-vis du client | PO ; SA | — | L6 |
| TC-03 | Outil `held_for_review` | **BLOQUANT** pour toute activation FeexPay | 7E-87 D4 ; AP-11 | paiement retenu sans issue | écart comptable non clos | PO | mission dédiée (hors 2D-2) | activation FeexPay |
| TC-04 | Règles dérivées DR1–DR3 | **À CONFIRMER** | 7E-97 R5 : « à relire à l'autorisation d'implémentation » | cohérence D6 | crédit omis + flag peut surprendre | PO | relecture | L4 |
| TC-05 | Contrôle de révocation des jetons dans les callables | **À CONFIRMER** (non établi) | P2 §3.3, P3 H4 | seule hypothèse | jeton valide ~1 h pour fonctions non gardées | TECH | lecture ciblée | activation |
| TC-06 | Contrat de consentement du créancier (N3) | **À CONFIRMER** ; N3 reste bloquant (AP-08) | 7E-106 §4 | pas de contrat | — | PO | spécification dédiée | N3 seulement |
| TC-07 | Cas client « payé hors système » : créancier, montant, commande, preuve, autorité | **BLOQUANT** pour la résolution de ce cas ; reste indisponible (AP-14) | P1 Q16 | aucune créance définie | — | PO | décisions métier | ce cas seulement |
| TC-08 | Hypothèses H1–H4 (conflit en production, contention, `deleteUser` interrompu, jetons) | **À CONFIRMER** par E1 puis P1 | P3 §9 | non prouvées | tous les protocoles reposent sur H1 | TECH | E1, P1 | activation |
| TC-09 | Intégration du moteur : commit préalable dans HEAD, drapeau de déploiement progressif | **À CONFIRMER** | `accountDeletion.js:68-71` (`operations_control`) | patron existant pour activer par étapes | activation sans retour arrière | PO | décision REG-05 | L2, activation |

---

## 5. Blocages

### 5.1 Avant L0

| # | Blocage | Source |
|---|---|---|
| B0-1 | Machine ou CI avec **Node 22.23.4** (non installable ici ; aucun gestionnaire de versions) | P3 §7 L0, REG-08 |
| B0-2 | **Autorisation explicite** d'exécuter des émulateurs isolés pour les 169 tests ignorés | consigne ; P3 §8 |
| B0-3 | Désignation d'un responsable de la relecture technique (TECH) et confirmation des rôles PO/SA | §0 |

Aucune autre décision de P3 §10 n'est nécessaire pour démarrer L0 : L0 ne change aucun code.

### 5.2 Avant L1 (pas avant L0)

Nom et emplacement du helper, champ exact du verrou (REG-01) ; confirmation du statut des tombstones sans `phase`.

### 5.3 Avant toute activation (suppression de compte ou FeexPay)

| # | Blocage |
|---|---|
| BA-1 | Moteur et test **dans HEAD** (aujourd'hui non suivis) |
| BA-2 | Lots de protection des writers L1, L3, L4, L5, L6 réalisés, revus et testés |
| BA-3 | Intégration des inspecteurs L2, avec scellé et récupération administrative (L2R) |
| BA-4 | Writer de décisions et règles Firestore/Storage (L7) |
| BA-5 | E1 réussi (concurrence en émulateurs isolés) **et** P1 réussi (préproduction distincte de la production) |
| BA-6 | Suite complète sous Node 22.23.4 sans échec |
| BA-7 | `held_for_review` livré (AP-11) avant FeexPay |
| BA-8 | Décisions REG-02, REG-03, REG-05, REG-06, TC-01, TC-04 prises |
| BA-9 | Autorisation d'activation écrite du PO ; aucune activation avant |

---

## 6. Ordre proposé des prochaines autorisations

Séparées volontairement : un lot d'une famille n'autorise pas la suivante. Proposition **non approuvée**.

| Étape | Famille | Contenu | Autorisation requise | Remarques |
|---|---|---|---|---|
| **1** | Inventaire | lecture complète des writers non lus ; dénombrement des exports financiers ; relevé des fins de ligne et du diff des cinq fichiers ; état exact du worktree | autorisation de lecture seule | aucune écriture dans le dépôt |
| **2** | Décisions | confirmation de REG-02, REG-03, REG-05, REG-06, REG-04, TC-01, TC-04 | décision écrite du PO | peut précéder ou suivre l'étape 1 |
| **3** | Tests | **L0** : base Node 22.23.4 ; exécution des 169 tests en émulateurs isolés | autorisation émulateurs + machine Node 22 | aucun code modifié |
| **4** | Préservation | patch local daté des fichiers non commités ; décision de commit (hors lots L) | autorisation de commit local, par chemins explicites | séparée du développement |
| **5** | Développement | **L1** (helper pur), puis L3, L2, L2R, L4, L5, L6, L7, L8 un par un | autorisation par lot, après revue du précédent | chaque lot = un commit local distinct |
| **6** | Tests | **E1** : concurrence C1 à C10 en émulateurs isolés | autorisation émulateurs | valide en émulateur seulement |
| **7** | Préproduction | **P1** : données synthétiques, budget de lectures, concurrence réelle | environnement désigné + autorisation | jamais la production |
| **8** | Activation | pilotage par `operations_control/account_deletion`, FeexPay après `held_for_review` | autorisation distincte et écrite | hors de ce registre |

---

## 7. Récapitulatif

| Statut | Éléments |
|---|---|
| Déjà établis | AP-01 à AP-15 ; REG-09 ; anciens flags Ekbine bloquants (REG-06) |
| Proposés | REG-01 (schéma, helper, `epoch`), REG-04 (seuils), origine Ekbine, critères de préproduction REG-07 |
| À confirmer | REG-02 (récupération), REG-03 (cinq lignes par analogie pure, six sur règles dérivées), REG-05 (cinq fichiers, moteur), voies de sortie des anciens flags, annulation de demande de suppression, TC-01, TC-02, TC-04, TC-05, TC-06, TC-08, TC-09 |
| Bloquants | avant L0 : Node 22.23.4, autorisation d'émulateurs, TECH ; avant L2 : moteur dans HEAD ; avant P1 : environnement de préproduction ; avant FeexPay : `held_for_review` ; avant toute activation : BA-1 à BA-9 ; cas client hors système : TC-07 |

Je m'arrête ici. Aucun lot L0–L8 n'est commencé. J'attends une nouvelle autorisation explicite.
