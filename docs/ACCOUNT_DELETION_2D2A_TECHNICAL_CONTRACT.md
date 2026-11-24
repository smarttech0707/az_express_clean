# 2D-2A — Contrat technique d'intégration du moteur `accountObligations.js`

Spécification uniquement. HEAD `d65c8f0`, index vide. Aucun code, test, inspecteur, writer, règle ni configuration n'a été modifié ; aucune commande distante ni émulateur n'a été utilisé ; la production `az-express-b0469` n'a pas été touchée. Complément : `docs/ACCOUNT_DELETION_2D2A_FIRESTORE_READ_MATRIX.md` (requêtes, reçus, journaux).

Légende : **[C]** confirmé par une source de code ou une décision métier citée ; **[P]** proposition à valider ; **[Q]** question sans réponse ; **[R]** risque.

Sources examinées : `functions/accountObligations.js` et son test ; `accountDeletion.js`, `accountDeletionScope.js`, `manualAccountDeletion.js`, `accountDeletionIdentity.js`, `accountCleanup.js` ; writers `partnerOrderQuote.js`, `catalogQuote.js`, `deliveryQuote.js`, `orderActions.js`, `partnerOrderActions.js`, `adminOrderDisputes.js`, `adminBilling.js`, `driverRelease.js`, `ekbineOrders.js`, `ekbineReconciliation.js` ; `firestore.rules` (journaux wallet, `account_tombstones`) ; `lib/services/delivery_order_service.dart` ; rapports 7E-97 à 7E-108 (en particulier 7E-102 décisions métier, 7E-105/106/107 durcissement, 7E-108 audit).

## 1. Principes confirmés

1. Le moteur est un prédicat pur, sans lecture ni écriture ; l'appelant lit tout et fournit les documents **[C]** (`accountObligations.js:765`).
2. Il est fail-closed : toute entrée absente, mal formée ou inconnue ⇒ résultat bloquant, jamais d'exception **[C]**.
3. Un seul état n'est pas bloquant en dehors de `retained` : `manual_review` (commandes wallet historiques) **[C]** (décision R10, 7E-108).
4. Niveau N3 : bloquant dans tous les cas **[C]** (`flag_level3_unavailable`, `accountObligations.js:511`).
5. `paid_by_client_out_of_system` reste indisponible : aucune créance (créancier, montant, preuve) n'est définie ; aucune ne doit être inventée **[C]** (décision du 7E-108).
6. Avec un seul super-admin, toute décision de niveau 2 reste en attente ; aucune auto-validation **[C]** (décision 7E-102, `verifyDecision` : approbateur ≠ demandeur ≠ décideur initial).
7. Une donnée fournie par le client n'est jamais une preuve ; les lignes `ekbine_payment` du client ne prouvent aucun débit **[C]** (`firestore.rules:853-865`, `ekbineReconciliation.js:7`).
8. N'écrire dans les collections `audit_logs`, `security_events`, `rate_limits`, `ai_*` que par Cloud Function, règles jamais assouplies **[C]** (CLAUDE.md).

## 2. Contrat de lecture Firestore

Détail complet : matrice de lecture. Points de décision :

### 2.1 Requêtes

- Les requêtes, clés et identifiants sont exactement ceux de `requiredQueries(role, ids)` ; l'appelant ne reconstruit pas la liste lui-même **[C]**. Les inspecteurs appellent `requiredQueries` et émettent exactement les requêtes retournées **[P]**.
- Limite exacte : `.limit(201)` pour chaque requête et `limit: 201` dans le reçu **[C]** (`READ_LIMIT`, `coverage`).
- `size = snapshot.size` ; `size = 201` ⇒ lecture tronquée ⇒ blocage **[C]**.
- Doublons : un document par identifiant dans la liste ; un couple (clé, id) une seule fois **[C]**.
- Chaque inspecteur fournit son propre ensemble de statuts terminaux (`INSPECTOR_TERMINAL_STATUSES`) : `accountDeletion` (8 statuts), `accountDeletionScope` (+ `closed`), `manualAccountDeletion` (+ `declined`, `closed`) **[C]**.
- Aucun document hors de ces listes n'est ajouté. Les collections que le moteur n'évalue pas (`boutique_orders`, `blanchisserie_orders`, `eau_boissons_orders`, `ekbine_orders`, `wallet_transactions` de niveau supérieur, `withdrawal_requests`, listings, responsabilités de flotte) conservent leurs contrôles actuels **[P]**.

### 2.2 Erreurs de lecture

Toute exception, tout délai ou refus de permission pendant une lecture ⇒ dossier bloqué (`state: 'blocked'`, raison technique non détaillée), moteur non appelé, aucune quarantaine ni suppression **[P]**. Les inspecteurs bloquent déjà ainsi leurs propres échecs (`accountDeletion.js:55-56`, `accountDeletionScope.js` : raison + retour) **[C]** ; le contrat étend ce comportement aux lectures nouvelles.

### 2.3 Journaux wallet

Les trois emplacements sont décrits en matrice §5. Résumé **[C]** :
- Preuve de débit client : uniquement `clients/{uid}/wallet_transactions/order_<orderId>` pour les générations « v2 » et « devis ».
- Absent, divergent ou illisible ⇒ blocage.
- Lignes `ekbine_payment` (niveau supérieur) : jamais utilisées.
- Génération historique : aucune lecture de journal ; revue manuelle non bloquante, sauf contradiction.

Limite reconnue **[R]** : un administrateur peut créer ou modifier un document `order_<id>` (`isAdmin()`), et le moteur ne peut pas l'identifier comme faux.

### 2.4 Revue manuelle et troncature

Trois notions distinctes, à ne jamais confondre **[C]** : obligations bloquantes (`obligations`, `blocking`), dossiers historiques (`manualReview`, `counts.manualReview`), lecture tronquée (`manualReviewRequired`). Détail et exemples : matrice §6.

## 3. Contrat du futur writer de décisions (non implémenté)

Le writer est une Cloud Function (callable, `europe-west1`) qui écrit seule dans le registre ; aucun client n'y écrit **[P]** (règle CLAUDE.md : collections sensibles `allow write: if false`). Le nom de collection est à fixer **[Q4]**.

### 3.1 Structure d'une décision

Champs lus par `verifyDecision` (`accountObligations.js:507-565`) **[C]** :

| Champ | Contrainte |
|---|---|
| id du document | `^[A-Za-z0-9_.:-]{1,128}$` (`ID_PATTERN`) ; clé de recherche `resolutionDecisionId` du flag |
| `status` | `'executed'` uniquement |
| `subjectKind` | `'flag'` (ou le genre du cas client) |
| `subjectId` | identifiant du flag ou de la commande |
| `subjectType` | type de créance, égal au libellé du flag (ex. `partner_credit_missing`) |
| `resolution` | une clé de la matrice `RESOLUTIONS` |
| `requestId` | `^[A-Za-z0-9_.:-]{16,128}$`, égal à celui du flag (`resolutionRequestId`), **unique dans le registre fourni** |
| `requestedBy` | `^[A-Za-z0-9_.:-]{1,128}$`, égal à `resolvedBy` du flag |
| `tier` | entier, ≥ niveau minimal de la résolution ; `3` ⇒ refusé |
| `remaining` | entier égal à 0 (aucune approbation restante) |
| `approvedBy`, `requestedAtMs`, `approvedAtMs` | exigés si `tier ≥ 2` ; `approvedBy` ≠ `requestedBy` ≠ décideur initial ; `approvedAtMs ≥ requestedAtMs > 0` |
| `evidenceRef` | exigé pour le niveau 1 et pour toute résolution hors système |

Champs de traçabilité proposés en plus, ignorés par le moteur **[P]** : `createdAtMs`, `executedAtMs`, `decisionHash` (SHA-256 du contenu canonique, hex 64), `previousDecisionHash` (chaînage), `schemaVersion`, `claimSnapshot` (montant, bénéficiaire, devise XOF figés au moment de la demande), `approvals[]` (historique, jamais réécrit).

### 3.2 Identifiants et unicité

1. `requestId` généré côté serveur, jamais fourni par le client ; unicité garantie par une écriture `create` (échec si le document existe) sur un document dont l'identifiant dérive du `requestId` **[P]**.
2. Le moteur ne peut vérifier l'unicité que dans le registre qu'on lui fournit **[C, limite]** ; la garantie globale appartient au writer **[P]**.
3. Un rejeu avec le même `requestId` retourne la décision existante, sans nouvelle écriture **[P]**.

### 3.3 Niveaux et origine

Matrice `RESOLUTIONS` (niveau minimal par résolution) **[C]**, alignée sur la décision 7E-102 :

| Créance | N1 | N2 | N3 |
|---|---|---|---|
| `commission_untraced` | `verified_no_debit`, `refunded_by_ledger` | — | `waived_platform_claim` |
| `partner_credit_missing` | `paid_to_partner_ledger` | `paid_out_of_system` | — |
| `seller_review` | — | `reviewed_no_action`, `adjusted_by_ledger` | — |
| `driver_advance_unreimbursed` | `reimbursed_by_ledger` | `reimbursed_out_of_system` | — |
| `ekbine_cancel_unproven_debit`, `ekbine_confirm_unproven_debit` | `debit_proven_and_settled` | `debit_disproved`, `refunded_by_ledger` | — |
| `cash_shortfall` | — | `recovered_in_full`, `absorbed_by_platform` | — |
| `beneficiary_account_closed` | `payment_completed` | `beneficiary_substituted` | — |
| `client_cash_nonpayment` | — | `refuted_after_contest`, `paid_by_client_out_of_system` (indisponible) | — |

Décideur initial exigé (`ORIGIN_DECIDER_REQUIRED`, `accountObligations.js:243`) : `cash_shortfall`, `seller_review`, `driver_advance_unreimbursed`, `client_cash_nonpayment`, et les deux types Ekbine ; origine absente ⇒ blocage **[C]**. Origine lue sur le flag (`decidedBy`) ou sur la commande (`cashPayment.review.byUid`) **[C]**.

Constat à traiter **[R]** : les signalements Ekbine ne portent aucun `decidedBy` (`ekbineOrders.js:265, 319`) ; le niveau 2 Ekbine est donc impossible tant que le writer n'impose pas une origine. Choix proposé : le writer inscrit l'origine dans la décision et dans un champ du flag ajouté par le writer de résolution, jamais par le client **[P]**, **[Q5]**.

Résolutions non autorisées, toutes bloquantes **[C]** (décision 7E-105) : `closed_by_contract`, `no_claim_established`, `waived_by_partner`, `waived_by_driver`, `written_off_by_platform`.

### 3.4 Preuves

Un document de preuve est lu par le serveur au moment de la décision **et** à nouveau lors de l'inspection ; il n'a de valeur que si `exists`, `status: 'verified'`, lié à la décision, au sujet et à la résolution **[C]** (`verifyDecision`). Pour les résolutions hors système (`paid_out_of_system`, `reimbursed_out_of_system`), champs exigés **[C]** :

`amount` égal à la créance calculée par le moteur ; `currency: 'XOF'` ; `beneficiaryId` (vendeur pour `partner_credit_missing`, livreur pour `driver_advance_unreimbursed`) ; `orderId` ; `paymentRef` ; `contentHash` hex 64 ; `immutable: true` ; `verifiedBy`, `verifiedAtMs`.

Contrôles serveur obligatoires du writer **[P]** :
1. La preuve est un document créé par le serveur depuis un fichier réellement lu dans Storage (octets relus, hachés en SHA-256) ; une URL, un texte ou un hash fournis par le client ne comptent jamais.
2. `contentHash` est recalculé par le serveur, pas copié de l'entrée.
3. `verifiedBy` ≠ `requestedBy` pour les preuves hors système **[Q6]**.
4. Le montant, le bénéficiaire et la commande sont relus depuis le flag et la commande ; la décision ne les porte pas comme source de vérité.
5. Une preuve ne sert qu'à une seule décision (`decisionId`) ; elle n'est jamais modifiée (`immutable: true`, règle Firestore sans `update`).
6. Un identifiant de preuve ne peut pas être réutilisé pour un autre flag.

### 3.5 N3 et consentement

N3 reste bloquant tant que le consentement du véritable créancier n'est pas vérifiable **[C]**. Aucun champ `creditorConsentRef` n'est lu par le moteur. Le contrat de consentement (vérification d'identité du créancier, preuve de consentement, immuabilité) n'est pas spécifié ici **[Q7]**.

### 3.6 Un seul super-admin

- Une décision N2 est créée en état `pending` avec `remaining ≥ 1` ; elle ne devient `executed` qu'après une approbation d'une personne différente **[C]**.
- Tant qu'aucun second responsable n'existe, la décision reste `pending` et le dossier bloqué ; aucune dérogation, aucun compte technique d'approbation **[C]** (décision du 7E-105).
- Le writer ne détermine pas le niveau à partir d'une entrée client ; il le déduit de la matrice `RESOLUTIONS` **[P]**.

### 3.7 Historique immuable

Chaque transition (demande, approbation, exécution, refus) ajoute un événement dans une sous-collection ou un tableau append-only avec empreinte chaînée ; aucun `update` ni `delete` n'est possible côté règles **[P]**. Un `audit_logs` est écrit par `logAudit` à chaque étape, avec `checkRateLimit` sur les demandes **[C]** (CLAUDE.md).

## 4. Intégration des trois inspecteurs

### 4.1 État actuel [C]

| Inspecteur | Rôles | Lectures actuelles | Limite | Gestion d'erreur |
|---|---|---|---|---|
| `accountDeletion.js` `inspect(tx, uid, role)` | client, livreur | profil, autres rôles (10 collections), `orders`, 4 collections `*_orders`/`ekbine_orders`, `wallet_transactions` (`userId`), `withdrawal_requests` | `LIMIT = 201`, `size ≥ 201` ⇒ `history_requires_manual_review` | raison renvoyée, dossier `blocked` |
| `accountDeletionScope.js` `readDeletionScope(tx, db, uid)` | partenaires (`config.partnerInventoryVersion === 1`) | identités, entreprises, propriétaires (limite 201), soldes, 5 collections de commandes, produits, `wallet_transactions`, `withdrawal_requests` | 201 ; `related` plafonné à 200 | raison renvoyée |
| `manualAccountDeletion.js` `financialBlocker(role, target)` | pharmacie, prestataire d'événements (administration) | `orders` par `pharmacieId`, `event_reservations` par `providerIds` | 201 | `throw HttpsError('failed-precondition', …)` |

Constats **[C]** :
- Aucun des trois ne lit aujourd'hui `transfer_settlements` ni `reconciliation_flags` ni les journaux wallet par document. Ces trois lectures sont nouvelles.
- Les trois utilisent des ensembles de statuts terminaux différents, que le moteur reprend nommément.
- `manualAccountDeletion.js` ne couvre `orders` que pour `pharmacie` ; l'artisan et le prestataire d'événements restent hors moteur (voir **[Q8]**).
- `manualAccountDeletion.js` lit hors transaction (`db.collection().get()`), contrairement aux deux autres (`tx.get`) **[R]** : il n'a aucune garantie de cohérence entre lecture et suppression.

### 4.2 Données à charger et ordre des opérations [P]

Pour un client ou un livreur (`accountDeletion.js`) :

1. Lectures existantes (profil, multi-rôles, collections) **dans la transaction**.
2. Requêtes `requiredQueries(role, ids)` pour `orders`, `transfer_settlements`, `reconciliation_flags`, chacune `limit(201)` ; reçu de couverture construit depuis `snapshot.size`.
3. `requiredWalletDebitIds('client', orders)` ⇒ lectures ponctuelles des journaux `order_<id>` du client.
4. Pour chaque flag `resolved` : lecture de `decisions/{resolutionDecisionId}`, puis de `evidence/{evidenceRef}` si la décision en porte un ; pour le cas client, la décision correspondante.
5. Appel de `evaluateAccountObligations({role, ids, terminalStatuses, orders, settlements, flags, reads, walletDebits, decisions, evidence})`.
6. Si `blocking` ⇒ raison `financial_obligation_pending` ou `financial_state_ambiguous` (les deux codes du moteur), dossier `blocked`, `reviewRequired: true`, snapshot enregistré ; sinon poursuite.
7. Les contrôles actuels de l'inspecteur restent appliqués **en plus** du moteur (aucun contrôle retiré) **[P]**. Justification : le moteur ne couvre pas toutes leurs collections.

Pour les partenaires (`readDeletionScope`) : même séquence avec `ids = [identifiant établissement]` ; le moteur reçoit `role = 'pharmacie' | 'restaurant' | 'boulangerie' | 'seller'` selon `p.role` **[P]**. Un profil à plusieurs rôles (multi-identités) ⇒ un appel par rôle, résultats cumulés, blocage si l'un bloque **[P, Q9]**.

Pour l'administration (`manualAccountDeletion.js`) : seul le rôle `pharmacie` est candidat. Les lectures doivent passer dans une transaction ; si ce n'est pas faisable, le blocage doit rester la valeur par défaut **[P]**.

### 4.3 Moment d'appel et concurrence

1. Appel obligatoire dans la transaction qui précède la quarantaine (`accountDeletion.js:85-90`) : c'est la seule qui peut encore **empêcher** la suppression **[C]**. La transaction de finalisation (`accountDeletion.js:124-133`) s'exécute **après** la suppression Auth (`accountDeletion.js:105-110`) : un blocage à ce stade ne peut plus annuler la suppression, il laisse seulement le dossier en `cleanup_pending` **[C]**.
2. **Correction (2D-2A.1)** : une relecture existe déjà entre la fin de quarantaine et la suppression Auth. À la reprise du dossier, la transaction de bail (`accountDeletion.js:85-92`) rappelle `inspect()` après `QUIET_MS`, avant tout appel Auth. Le trou restant est la fenêtre entre ce commit et `auth.deleteUser` (`inspectCleanup`, `auditStrict`, appels Auth, `accountDeletion.js:98-110`). La séquence proposée est dans `ACCOUNT_DELETION_2D2A1_BLOCKERS_RESOLUTION.md` §Q17 **[P]**. L'affirmation précédente « aucune relecture entre la fin de quarantaine et l'étape irréversible » était inexacte.
3. Garde de course : la quarantaine pose `account_tombstones/{uid}` et `isSuspended`, ce qui refuse les nouvelles opérations côté règles (`firestore.rules:10-12`) **[C]** ; les Cloud Functions vérifient `assertAccountEnabled` **[C]** (`accountDeletion.js:17`). Je n'ai pas vérifié que **chacun** des writers financiers appelle cette garde **[Q10]**.
4. Le comportement des requêtes dans une transaction Firestore face à l'insertion d'un nouveau document correspondant au filtre n'est pas garanti par la documentation que j'ai pu examiner ici ; je ne l'affirme pas **[Q11]**. La barrière de quarantaine plus la double exécution (1) sont les seules garanties retenues.
5. Aucun appel du moteur hors transaction pour la décision de suppression **[P]**.

### 4.4 Traitement des résultats

| Résultat du moteur | Action de l'inspecteur |
|---|---|
| `blocking: true`, code `financial_obligation_pending` | état `blocked`, `reviewRequired: true`, raison `financial_obligation_pending` **[P]** |
| `blocking: true`, code `financial_state_ambiguous` | état `blocked`, raison `financial_state_ambiguous` **[P]** |
| `manualReviewRequired: true` (troncature) | même blocage ; ne jamais ré-essayer en boucle sans changement **[P]** |
| `blocking: false` et `summary.manualReview > 0` | poursuite autorisée ; `counts.manualReview` conservé dans le snapshot et dans `audit_logs` ; jamais affiché comme « paiement confirmé » **[C/P]** |
| `blocking: false`, aucune entrée | poursuite |

### 4.5 Snapshot financier

`buildFinancialSnapshot(result, {atMs})` : forme `{version, atMs, blocking, code, manualReviewRequired, currency, counts, items, truncated, omitted}`, 50 éléments au plus, sans exception **[C]** (`accountObligations.js:887`). Il ne contient aucune donnée personnelle (identifiants techniques, montants, statuts, raisons) **[C]** (rapport 7E-108 §3).

Stockage proposé **[P]** : champ `financialSnapshot` du dossier `account_deletions/{uid}` écrit **dans la même transaction** que le changement d'état, avec `atMs` fourni par l'horloge de l'inspecteur (`clock()`), jamais par le client ; conservation après anonymisation pour la traçabilité (les références `orderId` restent valides puisque les commandes sont conservées, `accountDeletion.js:129-132`).

## 5. Budget de lectures

Hypothèses **non mesurées**, calculées à partir du contrat de lecture. Facturation : une requête compte au moins une lecture, puis une par document retourné ; un `get` ponctuel compte une lecture, même si le document n'existe pas.

### 5.1 Lectures nouvelles par rôle (en plus des lectures actuelles)

| Rôle | Requêtes nouvelles | Lectures maximales des requêtes (chaque requête à 201) | Journaux wallet | Registre (décisions + preuves) | Total maximal |
|---|---|---|---|---|---|
| Client | settlements `clientId`, flags `clientId` | 2 × 201 = 402 | ≤ 200 (commandes v2/devis wallet livrées ; au-delà de 200 commandes la lecture `orders` est tronquée donc bloquée) | ≤ 200 + 200 | ≈ 1 000 |
| Livreur | settlements `driverIds` et `holderDriverId`, flags `driverId` | 3 × 201 = 603 | 0 | ≤ 200 + 200 | ≈ 1 000 |
| Pharmacie / restaurant / boulangerie | flags `partnerId`, `sellerId`, `pharmacieId` | 3 × 201 = 603 (`orders` : une seconde requête `kind` = 201 déjà dans le périmètre actuel selon l'inspecteur ; recompter si elle est nouvelle) | 0 | ≤ 200 + 200 | ≈ 1 000 |

Remarque : le registre n'est lu que pour les flags `resolved` et les cas clients ; le plafond de 200 résulte de la limite de 201 par requête de flags **[C]**. Sans flag résolu, le coût du registre est 0.

### 5.2 Scénarios

| Scénario | Hypothèse | Lectures nouvelles |
|---|---|---|
| Moyen (client) | 30 commandes dont 20 v2 ou devis wallet livrées ; 2 règlements ; 1 flag non résolu | 2 (requêtes `settlements`) + 1 (requête `flags`, doc 1) + 20 journaux ≈ **25** |
| Moyen (livreur) | 50 commandes ; 3 règlements ; 1 flag | ≈ **8** |
| Maximal admissible | chaque requête à 200 documents (juste sous la limite), 200 flags résolus avec décisions et preuves | **≈ 1 000** (valeurs du tableau) |
| Dépassement | une requête retourne 201 documents | lectures facturées jusqu'à 201 pour cette requête ; moteur : `<liste>_truncated` ; dossier bloqué en revue manuelle ; aucune pagination dans la transaction **[C]** |

Les hypothèses (30 commandes, 20 journaux, etc.) sont des **estimations de travail**, pas des mesures. Les lectures actuelles des inspecteurs (profil, 10 collections de rôles, 5 collections de commandes, etc.) ne sont pas recomptées ici.

### 5.3 Capacité et dépassement

- Une lecture à 201 documents est déjà une limite fonctionnelle : au-delà, le dossier va en revue manuelle **[C]**.
- La taille maximale d'une transaction en lectures n'est pas une limite dure que j'aie vérifiée ; la durée et la contention d'une transaction lisant ≈ 1 000 documents sont à mesurer **[Q12]**.

### 5.4 Protocole de mesure synthétique en préproduction [P]

Non exécuté (aucun émulateur, aucun accès distant dans cette mission).

1. Projet cible : un environnement de préproduction distinct de `az-express-b0469`, jamais la production **[Q13 : désigner cet environnement ; l'état préproduction connu est du 05/11/2026]**.
2. Jeu de données synthétique : comptes `synthetic-*` avec identifiants reconnaissables ; scénarios S0 (aucune commande), S1 (30 commandes, 20 v2), S2 (200 commandes dont 200 v2), S3 (201 commandes, troncature), S4 (200 flags résolus avec décisions et preuves), S5 (livreur avec 200 règlements), S6 (partenaire avec 200 commandes et 200 flags).
3. Instrumentation : compteur d'appels `tx.get` et somme des `snapshot.size` ; relevé indépendant par les métriques Firestore (lectures facturées) avant et après chaque scénario.
4. Mesures : lectures par appel, durée de transaction, nombre de relances de transaction, taille du snapshot.
5. Critères d'acceptation proposés : lectures conformes au tableau 5.1 (écart ≤ 5 %), aucune relance en l'absence de concurrence, durée de transaction nettement sous le délai maximal (seuil à fixer **[Q12]**), troncature détectée en S3.
6. Résultats conservés dans un rapport daté ; aucune donnée de production copiée.

## 6. Tests et Node

Suite complète (`node --test test/*.test.js`, Node v24.22.1), rejouée dans cette mission : **2 410 tests, 2 241 réussis, 0 échec, 169 ignorés (skipped), 0 todo, 0 annulé**. Les 169 résultats non réussis sont donc **tous « skipped »**, et le journal du lanceur en donne le motif **[C, preuve : sortie du lanceur de tests]** :

| Motif affiché par le test | Nombre |
|---|---|
| émulateur Firestore requis (projet `demo-*`) | 67 |
| émulateur Firestore requis (projet `demo-az-t7e`) | 37 |
| émulateur Firestore requis | 35 |
| `FIRESTORE_EMULATOR_HOST` absent (émulateur Firestore requis) | 10 |
| émulateurs Auth/Firestore requis | 10 |
| émulateurs + `AZ_E2E_RULES=1` requis | 7 |
| émulateurs Storage et Firestore requis (projet `demo-az-t7e-st`) | 2 |
| émulateurs Auth/Firestore/Storage requis | 1 |
| **Total** | **169** |

Aucun test n'est « todo » ; aucun n'est non exécuté sans motif. Ces 169 tests n'ont **pas** été exécutés : leur résultat réel est inconnu, il ne faut pas les compter comme réussis **[C]**. Ils nécessitent des émulateurs, interdits dans cette mission.

Node : seul v24.22.1 est présent ; la version cible est 22 (`functions/package.json`, 22.23.4 demandé). Aucune validation sous Node 22.23.4 n'a eu lieu et Node 24 n'est pas présenté comme équivalent. À faire en CI ou sur une machine équipée, sans gestionnaire de versions installé ici **[Q14]**.

## 7. Questions sans réponse

| # | Question |
|---|---|
| Q1 | Étendre le moteur aux rôles `ekbine_agent`, `real_estate_agent`, `fleet_owner`, ou conserver leurs contrôles actuels ? |
| Q2 | Opérateur exact de la requête `driverIds` (supposé `array-contains`) : confirmer par `transferSettlement.js`. |
| Q3 | Un partenaire a-t-il une créance de règlement lisible dans `transfer_settlements` ? Le moteur ne l'interroge pas. |
| Q4 | Noms et chemins des collections `decisions` et `evidence` ; règles Firestore associées. |
| Q5 | Origine (« décideur initial ») des signalements Ekbine : qui l'écrit et où ? |
| Q6 | La preuve hors système doit-elle être vérifiée par une troisième personne ? |
| Q7 | Contrat de consentement du créancier pour le niveau 3. |
| Q8 | Prestataires d'événements et artisans : quelles créances le moteur doit-il couvrir ? |
| Q9 | Profil à plusieurs rôles : un appel par rôle, quels identifiants ? |
| Q10 | Tous les writers financiers appellent-ils la garde de compte supprimé ? |
| Q11 | Comportement exact des insertions concurrentes face à une requête de transaction. |
| Q12 | Seuils de durée et de contention d'une transaction de ≈ 1 000 lectures. |
| Q13 | Désignation de l'environnement de préproduction pour les mesures. |
| Q14 | Environnement d'exécution de Node 22.23.4. |
| Q15 | Délai de réflexion de 24 h : non approuvé ; décision métier requise avant toute implémentation. |
| Q17 | Fenêtre résiduelle entre la transaction de bail et `auth.deleteUser` : voir 2D-2A.1 §Q17. |
| Q16 | Créance, créancier et preuve du cas client « payé hors système » : à définir par le métier. |

## 8. Risques

1. Journal `order_<id>` modifiable par un administrateur : fausse preuve indétectable **[R]**.
2. `manualAccountDeletion.js` lit hors transaction **[R]**.
3. Signalements Ekbine sans origine : niveau 2 inatteignable tant que le writer n'est pas défini **[R]**.
4. Registre non authentifié par le moteur : il fait confiance à l'appelant **[C, limite reconnue]**.
5. Unicité de `requestId` limitée au registre fourni **[C]**.
6. Falsification cohérente avant le snapshot indétectable **[C]**.
7. Commandes historiques en revue manuelle : la suppression peut être autorisée alors qu'une dette ancienne existe sans trace ; décision métier R10, assumée, à journaliser **[C]**.
8. Concurrence : insertion tardive d'une opération financière entre lecture et finalisation (Q10, Q11) **[R]**.
9. 169 tests nécessitent des émulateurs et n'ont jamais été vus passer dans cette session **[C]**.

## 9. Conditions d'entrée de 2D-2B (à satisfaire avant tout code)

1. Réponses aux questions Q2, Q4, Q5, Q10, Q16 et Q17 au minimum ; Q1, Q3, Q8, Q9 si l'étendue de 2D-2B les inclut.
2. Validation humaine du contrat de lecture (matrice) et du schéma des décisions et preuves (§3).
3. Décision métier sur le délai de 24 h (Q15), ou confirmation qu'il est hors de 2D-2B.
4. Désignation d'un environnement de préproduction et accord sur le protocole de mesure (§5.4) ; aucune mesure n'est faite en production.
5. Exécution de la suite sous Node 22.23.4 (CI ou machine équipée) pour la base existante, avant d'ajouter du code.
6. Exécution, dans un environnement d'émulateurs autorisé, des 169 tests ignorés, ou accord écrit pour s'en passer.
7. Décision explicite d'intégrer le moteur en plus (non à la place) des contrôles actuels de chaque inspecteur (§4.2).
8. Autorisation humaine explicite de démarrer 2D-2B.

Je m'arrête ici. 2D-2B n'est pas commencé.
