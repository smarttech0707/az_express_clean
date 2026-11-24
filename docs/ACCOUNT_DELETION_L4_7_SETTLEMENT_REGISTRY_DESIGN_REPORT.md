# Mission L4.7 — Conception du registre de décisions et de la clôture des créances

Étude en **lecture seule**. Aucun fichier source ni test modifié, aucun accès Firebase, aucune écriture hors ce document. Notation : **[E]** existe et a été vérifié dans le dépôt ; **[H]** proposé ou décrit dans des documents historiques mais **non implémenté** ; **[P]** proposition de ce rapport.

## 0. État Git (vérifié avant l'étude)

HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, **35 suivis modifiés, 159 non suivis** (conforme à l'attendu). Hashes inchangés : `ekbineOrders.js` ff24d2c8, `index.js` a9ba2c0d, `professionalSubscriptions.js` 976c2396, `adminPartnerAccounts.js` 1a5cde55, `passwordReset.js` 26975f60, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a. État final : voir §14.

## 1. État réel de l'architecture actuelle

**Ce qui existe [E]**
- Un **signalement** L4 est écrit dans `reconciliation_flags` (collection serveur seule : aucune règle `match` dédiée dans `firestore.rules`, donc refus par défaut ; vérifié par `grep`, cohérent avec `FIRESTORE_SCHEMA.md`). Deux types : `beneficiary_closed` (crédit de commission non rendu à un livreur fermé ; `parties[]` avec `amountWithheld`, `sourceJournalId`, `currency:'XOF'`, `kind:'commission_refund_omitted'` ; id `<commande>_beneficiary_closed`, écrit dans `cancelOrderTx`) et `beneficiary_closed_refused` (opération refusée ; `beneficiary` ; id `<commande>_<pay|deliver|cancel>_beneficiary_refused` ; `completed:false`).
- Des **champs plats** additifs (`driverId`, `clientId`, `sellerId`, `pharmacieId`, `partnerId`) sont écrits depuis L4.6 ; les signalements écrits avant L4.6 n'en ont pas.
- Le **moteur** `accountObligations.js` (pur, 1 140 lignes) lit ces signalements (L4.6) : `open`/`cleared`/`contested` → revue bloquante ; `recorded`/`reviewed`/`resolved` → ambigu bloquant `flag_closure_unproven` ; jamais « conservé ».
- Le contrat de vérification d'une décision existe **dans le moteur** : `verifyDecision` (statut `executed`, `subjectKind/Id/Type`, `requestId` 16–128 caractères unique dans le registre fourni, `resolution` de la matrice `RESOLUTIONS`, `tier`, `remaining === 0`, `requestedBy`, `approvedBy ≠ requestedBy ≠ originBy`, `approvedAtMs ≥ requestedAtMs`, `evidenceRef` → preuve `verified` liée à la décision, avec pour le hors-système : `amount`, `currency`, `beneficiaryId`, `orderId`, `paymentRef`, `contentHash` SHA-256, `immutable:true`) ; niveau 3 refusé tant que le consentement du créancier n'existe pas.
- L'**inspecteur** `accountObligationsInspector.js` lit `orders`, `transfer_settlements`, `reconciliation_flags` par champ propriétaire (limite 201) et lui passe **`decisions: []` et `evidence: []`** (commentaire : « le writer de décisions est la mission L7 »).
- `clearBeneficiaryReview` (`adminBilling.js`) = levée de verrou uniquement : `needsReview:false` sur la commande et traces `lockLifted*` sur le signalement qui reste `open` ; vérifie l'état courant du bénéficiaire ; super-admin seul (`requireSuperAdmin`).
- Garde de crédit `assertBeneficiariesCreditable` / `isBeneficiaryCreditable` (`accountClosureActor.js`) ; états de fermeture (actif, suppression demandée, quarantaine, scellé, anonymisé, absent, illisible) ; `account_tombstones` jamais rouvert.
- Contrôles d'accès : `admins/{uid}` avec `role ∈ {super, sub}`, `isActive` ; `requireSuperAdmin` ; second facteur **`ADMIN_MFA_MODE` à `log` par défaut** (n'est pas imposé) ; `logAudit` → `audit_logs` (écriture serveur, lecture super-admin) ; `checkRateLimit`. Liste fermée de permissions (`adminPermissions.js`, miroirs règles + Dart, test de parité) : **aucune permission d'approbation financière**.
- Précédent d'idempotence : `order_dispute_decisions/<sha256(orderId|requestId)>` (litiges, serveur seul).

**Ce qui n'existe pas [vérifié par recherche dans `functions/`, `firestore.rules`, `storage.rules`]**
- Aucune collection `decisions` / `evidence` (ni équivalent), aucune règle, aucun writer, aucun chemin Storage de preuves de règlement ; aucun module exécutant ; aucun portefeuille ou grand livre de créances ; aucune sous-collection d'historique.
- Aucune permission ni registre d'approbateurs N2 ; aucun contrôle « deux personnes physiques distinctes » (seulement des chaînes d'identifiants).
- Aucune résolution de la matrice `RESOLUTIONS` pour les types `beneficiary_closed` / `beneficiary_closed_refused` (la matrice contient seulement l'ancien nom planifié `beneficiary_account_closed` : `payment_completed` N1, `beneficiary_substituted` N2 — **[H]**, jamais écrit par le code).
- Aucun mécanisme de conservation de la somme : la commission non rendue reste simplement côté AZ (compteurs `config/az_wallet`), le signalement la **trace** sans la **retenir**.
- Aucun script de rattrapage.

## 2. Inventaire des collections et fonctions

| Élément | Statut | Rôle / remarque |
|---|---|---|
| `reconciliation_flags/*` | [E] serveur seul | signalements ; ids déterministes par type ; aucun index dédié (`firestore.indexes.json` n'en contient aucun) |
| `orders.needsReview / reviewReason / reviewFlagId / reviewCleared*` | [E] | verrou opérationnel (`beneficiary_closed`, `beneficiary_credit_omitted`) |
| `account_tombstones/{uid}` | [E] règles `read, write: false` | fermeture, jamais supprimé |
| `audit_logs` | [E] | journal générique (add), lecture super-admin |
| `order_dispute_decisions/*` | [E] | décisions de litige, **sans lien** avec les créances de fermeture |
| `config/az_wallet` | [E] | compteurs AZ (commissions, frais retenus), pas un grand livre |
| `adminBillingCF.clearBeneficiaryReview` | [E] | levée de verrou |
| `evaluateAccountObligations` / `verifyDecision` / `RESOLUTIONS` | [E] | lecture seule, fail-closed |
| `decisions`, `evidence` (noms de contrat), writer de décisions | [H] | décrits dans `ACCOUNT_DELETION_2D2A_TECHNICAL_CONTRACT.md` §3 (« non implémenté ») ; noms de collections « à fixer [Q4] » |
| Module de règlement différé / exécutant | [H] | L4.4, Option 1 « recommandée », jamais codée |

## 3. Écarts entre l'existant et les besoins

1. **Aucune voie de clôture** : pas de registre, de writer, de preuves, d'approbateurs ; tout signalement L4 est donc bloquant à vie (voulu à ce stade).
2. **Matrice incomplète** : les types L4 n'ont pas de `RESOLUTIONS` ; le code L4.6 renvoie `flag_closure_unproven` sans appeler `verifyDecision`. Il faut ajouter une branche de vérification (voir §5-F) et choisir les résolutions autorisées.
3. **Désaccord de nommage** : `beneficiary_account_closed` (planifié, N1 `payment_completed`) vs `beneficiary_closed` (écrit). Le N1 « payment_completed » repose sur une preuve auto-vérifiable de paiement (`isPaid`, journaux `pay_order_*`), qui ne correspond **pas** à une commission non rendue à un livreur fermé : à redéfinir.
4. **Identité N2** : les contrôles du moteur portent sur des chaînes, pas sur des personnes ; second facteur non imposé ; pas de permission dédiée ; pas de registre d'approbateurs.
5. **Argent** : il n'existe aucun moyen *dans le système* de payer un compte fermé (la garde l'interdit, à raison) ; « payé » ne peut donc être aujourd'hui qu'un paiement **hors système prouvé**, ou un futur exécutant vers un représentant vérifié (hors périmètre, décision juridique).
6. **Unicité des `requestId`** : le moteur ne la vérifie que dans le registre fourni ; l'inspecteur devra charger toutes les décisions pertinentes.
7. **Identifiants** : un signalement par commande et par type ; deux obligations distinctes de la même commande (par exemple deux événements) ne peuvent pas coexister (voir §8).
8. **Historique** : signalements pré-L4.6 invisibles pour l'inspecteur (champs plats absents).
9. **Divergences de documentation** : le commentaire de `verifyDecision` (« un seul super-admin existe aujourd'hui ») est périmé par la décision N2 ; `7E-102` décrit `clearBeneficiaryReview` comme « prévu » alors qu'il existe (levée seule) ; le rapport L4.4 est resté sur l'Option 1 sans fixer de noms.

## 4. Architecture recommandée

Retenir l'**Option 1 du L4.4** (approuvée) : **pas de collection de dettes séparée** ; le signalement typé *est* la créance, étendu et verrouillé ; deux ou trois collections serveur seul pour la preuve et la décision ; un seul module exécutant plus tard. Distinction stricte des six objets :

| Objet | Où | Nature | Mutable ? |
|---|---|---|---|
| **Signalement** | `reconciliation_flags` (trace L4) | constat qu'une opération a été refusée ou qu'une somme n'a pas été créditée | écrit une fois ; champs `lockLifted*` ajoutables |
| **Créance** | même document, **seulement** pour `beneficiary_closed` (crédit omis, avec journal source) | somme due à un bénéficiaire identifié | montant, bénéficiaire, devise, journal : **figés** (`claimSnapshot` + empreinte) |
| **Décision administrative** | `obligation_decisions/{id}` [P] | demande N2, approbations, résultat | append-only par événements ; états contrôlés |
| **Preuve de règlement** | `obligation_evidence/{id}` [P] + octets en Storage | document vérifié par le serveur, lié à une décision | **immuable** (create-only) |
| **Règlement confirmé** | transition de la décision vers `settled_confirmed` | résultat d'une vérification serveur de la preuve | une fois |
| **Clôture définitive** | champs `closure` du signalement écrits par le seul writer | fermeture après règlement confirmé | une fois |

Important : **un refus d'opération (`beneficiary_closed_refused`) n'est pas une créance** : rien n'est dû tant que l'opération (paiement, livraison, annulation) n'a pas eu lieu ; il se clôt par la reprise réussie de l'opération (preuve = état de la commande + journaux) ou par décision de support, jamais par un paiement. Seule `beneficiary_closed` porte un montant dû.

**Noms proposés [P]** : `obligation_decisions`, `obligation_evidence`, `obligation_events` (historique append-only, une sous-collection `events` sous chaque décision suffit) ; mappées vers les paramètres `decisions` / `evidence` du moteur (tableaux `[{id,data}]`). Règles : `allow read: if isSuperAdmin(); allow write: if false;` pour les trois, comme `audit_logs`.

## 5. Modèle de données proposé [P]

**Signalement/créance** (`reconciliation_flags/{claimId}`, champs *ajoutés* à l'existant, aucun renommage) :
`claimId`, `schemaVersion`, `claimSnapshot { orderId, eventType, beneficiary { collection, id }, amount, currency:'XOF', sourceJournalId }`, `claimHash` (SHA-256 canonique du snapshot), `lock { state:'locked'|'lifted', liftedAtMs, liftedBy, justification }` (déjà `lockLifted*`), `decisionState: 'none'|'requested'|'approved_1'|'approved_2'|'rejected'|'revoked'|'expired'` (miroir en lecture, recalculé du registre), `settlementState: 'unpaid'|'evidence_submitted'|'evidence_verified'|'settled_confirmed'`, `closure { state:'open'|'closed', closedAtMs, decisionId, evidenceId, closureHash }`. Le moteur **ne se fie jamais à ces miroirs** : il relit décision et preuve.

**Décision** (`obligation_decisions/{decisionId}`) : champs lus par `verifyDecision` (`status`, `subjectKind:'flag'`, `subjectId`, `subjectType`, `resolution`, `requestId`, `requestedBy`, `tier`, `remaining`, `approvedBy`, `requestedAtMs`, `approvedAtMs`, `evidenceRef`) **plus** `claimSnapshot` copié, `claimHash`, `createdAtMs`, `executedAtMs`, `decisionHash`, `previousDecisionHash` (chaînage global), `schemaVersion`, `approvals[]` (uid, `personRef`, instant, `authTimeMs`, `secondFactor: true`, `sessionIdHash`), `revoked { by, atMs, reason }`. États : `requested → approved_1 → executed` ; terminaux : `rejected`, `revoked` (avant exécution seulement), `expired`.

**Preuve** (`obligation_evidence/{evidenceId}`) : champs lus par le moteur (`status:'verified'`, `decisionId`, `subjectKind`, `subjectId`, `resolution`, `verifiedBy`, `verifiedAtMs`, `amount`, `currency`, `beneficiaryId`, `orderId`, `paymentRef`, `contentHash`, `immutable:true`) plus `kind`, `storagePath`, `sizeBytes`, `mime`, `receivedAtMs`, `paymentRefHash`, `payeeKind` (`beneficiary|representative|heir`), `payeeVerificationRef`. Les octets sont dans un chemin Storage serveur seul `obligation_proofs/{claimId}/{evidenceId}` [P], **nouveau** (aucun chemin existant ne convient).

**Unicité de preuve de paiement** : `obligation_payment_refs/{sha256(paymentRef)}` créé en `create` (échec si déjà utilisé) — empêche qu'une même preuve solde deux créances [P].

## 6. Cycle de vie complet d'une créance [P]

0. **Création** (déjà [E]) dans la transaction qui omet le crédit ; état `locked`, `open`, `unpaid`, `none`.
1. **Levée éventuelle du verrou** ([E]) : `clearBeneficiaryReview` ; ne change ni `decisionState`, ni `settlementState`, ni `closure` ; le signalement reste bloquant pour le moteur.
2. **Ouverture d'une demande** (`requestObligationDecision`, super-admin désigné A, `requestId` serveur, résolution choisie dans la matrice, justification) : transaction qui relit signalement, commande, journal source, état courant du bénéficiaire ; fige `claimSnapshot` ; crée la décision `requested`, `remaining = 1` (N2).
3. **Première validation** : (si le flux exige d'abord une revue) le demandeur A n'approuve rien ; la décision attend B.
4. **Deuxième validation N2** (`approveObligationDecision`, super-admin B ≠ A, ≠ décideur initial, ≠ titulaire/bénéficiaire, désigné au registre des approbateurs, second facteur frais) : contrôles §7 ; passe à `approved_1` → `approved_2` ; `remaining = 0`. *Aucun effet financier à ce stade.*
5. **Dépôt et vérification des preuves** (`attachObligationEvidence` puis `verifyObligationEvidence` par un **troisième acteur ou B**, jamais A pour les règlements hors système) : le serveur relit les octets, calcule `contentHash`, compare montant, devise, bénéficiaire, commande, `paymentRef` au `claimSnapshot` ; crée `obligation_payment_refs` ; preuve `verified`, immuable.
6. **Confirmation du règlement** (`confirmObligationSettlement`) : transaction qui relit tout (signalement non clos, hash du snapshot inchangé, décision `executed`, preuve `verified`, unicité du `paymentRef`), écrit `settlementState:'settled_confirmed'` et l'événement ; aucun mouvement de wallet.
7. **Clôture définitive** (même transaction ou suivante, idempotente) : `closure.state:'closed'` avec les empreintes ; `status` du signalement passe à `resolved` avec les champs de trace attendus par le moteur ; le moteur relit décision et preuve et seulement alors classe l'élément `retained`.

Une correction après exécution = **décision compensatoire** nouvelle (jamais d'`update` d'une décision exécutée). Une révocation est possible tant que la décision n'est pas `executed`.

**Risques par étape** : concurrence (deux approbations simultanées, deux confirmations) → transaction + précondition d'état + `version` ; double paiement → unicité du `paymentRef`, `settled_confirmed` unique ; falsification → empreintes et relecture des octets ; clôture prématurée → la clôture exige les cinq conditions relues dans la même transaction ; changement d'état du bénéficiaire pendant la procédure (un compte absent ou anonymisé le reste, mais un compte scellé peut être anonymisé) → relu à l'étape 5 et 6, jamais réidentifié.

## 7. Protocole N2 détaillé [P]

- **Rôles** : demandeur et approbateur sont des `admins` actifs de rôle `super`, **et** figurent dans un registre serveur seul `config/n2_approvers` (liste de uid, `personRef` opaque désignant une personne physique, instant de désignation, désigné par écrit par le propriétaire). Ajouter une permission `approbation_financiere` n'est pas nécessaire au super-admin (qui n'a pas de clés) mais le registre fournit la même séparation sans toucher aux trois miroirs de permissions ; si la permission est préférée, elle est un changement à autoriser séparément (liste fermée testée en parité).
- **Éligibilité** : compte actif, `ADMIN_MFA_MODE=enforce` **obligatoire** avant toute opération N2 (prérequis bloquant : le défaut actuel est `log`), second facteur présent dans le jeton (`sign_in_second_factor`) et `auth_time` récent (≤ 15 min).
- **Séparation** : `personRef(B) ≠ personRef(A)` (la distinction des uid ne suffit pas), `B ∉ {décideur initial, titulaire du compte, bénéficiaire, représentant}` ; l'assistant IA n'est jamais demandeur ni approbateur. Au moins deux personnes distinctes au registre, sinon toute demande reste `requested` (jamais de dérogation, jamais de compte technique).
- **Fenêtre** : l'approbation doit avoir lieu avant l'expiration de la demande (par exemple 14 jours, valeur à décider) ; passé ce délai, `expired`, nouvelle demande requise ; la créance reste bloquante.
- **Révocation** : par un super-admin du registre, avant exécution seulement, avec motif ; produit un événement et fait passer à `revoked`.
- **Traçabilité** : événement append-only (acteur, `personRef`, instant, `requestId`, empreinte), `logAudit` à chaque étape, `checkRateLimit` sur les demandes, hash de chaînage global.
- **Résistance à la modification manuelle** : (1) règles `allow write: if false` sur les trois collections et le chemin Storage ; (2) toutes les transitions par Cloud Function (Admin SDK) ; (3) **le moteur recalcule** `decisionHash`, `claimHash`, `contentHash` et le chaînage à chaque lecture ; une incohérence rend la créance **ambiguë et bloquante** (jamais réglée par erreur) ; (4) limite connue : un propriétaire de projet GCP / compte de service peut contourner les règles — mitigations : IAM restreint, alertes sur toute écriture non issue des fonctions, relecture périodique d'intégrité, export des empreintes dans `audit_logs`. On ne peut pas promettre l'impossibilité de la modification par un propriétaire de projet ; on garantit qu'elle est **détectée et bloquante**.
- **Contrôles serveur** : niveau déduit de la matrice (jamais d'une entrée client) ; `requestId` généré serveur ; relecture de la commande, du journal source et de l'état du bénéficiaire dans la transaction.

## 8. Politique d'identifiants et d'idempotence [P]

Constat [E] : `<orderId>_beneficiary_closed` (un par commande) et `<orderId>_<kind>_beneficiary_refused` (un par commande et type d'opération). Risques : (a) **écrasement** : le signalement de crédit omis est écrit par `tx.set` ; (b) **fusion** : un second événement (autre bénéficiaire, autre tentative) sur la même commande ne crée pas de signalement ; pour un refus, le bénéficiaire enregistré peut être périmé.

Clé recommandée pour toute **nouvelle** créance : `claimId = "cl_" + hex(SHA-256(canonicalJSON([schemaVersion, orderId, eventType, beneficiary.collection, beneficiary.id, sourceJournalId])))[0..40]` (160 bits, caractères conformes à `ID_PATTERN`, < 128). Le JSON canonique (tableau, pas de concaténation) exclut les collisions par délimiteur ; le `sourceJournalId` distingue deux mouvements différents de la même commande pour le même bénéficiaire ; le document stocke les composants et le moteur **recalcule l'identifiant** (id ≠ hash → ambigu). Écriture en `create` (échec si présent) ; rejeu identique → no-op ; même clé avec contenu différent → erreur d'intégrité (jamais d'écrasement). Un événement qui a un nouveau `sourceJournalId` ou un nouveau bénéficiaire = nouvelle créance. Les identifiants historiques (`<orderId>_beneficiary_closed`) sont conservés comme alias lisibles, jamais renommés ; le moteur accepte les deux formes.

Pour les refus (traces, pas des créances) : clé `(orderId, opération, bénéficiaire.collection, bénéficiaire.id)` — un refus dû à un autre bénéficiaire est une trace distincte ; répétition identique = même trace. Décisions : `decisionId = SHA-256(claimId|requestId)` comme `order_dispute_decisions` ; `requestId` serveur unique, enregistré dans `obligation_requests/{requestId}` en `create`.

## 9. Stratégie de rattrapage historique

**Constat** : L4 n'a jamais été déployée (rapports L4.1, L4.4) ; la base de production n'a donc, selon toute vraisemblance, **aucun** signalement `beneficiary_closed*`. Je n'ai **pas pu le vérifier** (aucune lecture production autorisée) : à confirmer par une lecture seule autorisée avant toute implémentation. Rien n'est inventé ici.

**Mécanisme [P] si des signalements pré-L4.6 existent** :
- *Option B (recommandée en premier, sans écriture)* : l'inspecteur lit, pour chaque commande déjà lue du compte, les documents d'identifiants **déterministes** connus (`<id>_beneficiary_closed`, `<id>_{pay,deliver,cancel}_beneficiary_refused`) ; le moteur évalue via `parties[]`/`beneficiary` (déjà géré en L4.6). Coût : jusqu'à quatre lectures par commande, plafonné par la limite de 201 ; aucune migration ; aucun risque de doublon.
- *Option A (complément contrôlé)* : fonction de rattrapage super-admin, **dry-run d'abord** : parcourt par pages (`type in [...]`, tri par id, curseur, plafond de lot) ; pour chaque signalement vérifie l'intégrité (structure, montants entiers positifs, devise, journal source existant et concordant avec la commande, `claimHash`), calcule les champs plats **uniquement depuis `parties[]`/`beneficiary`**, n'écrit rien en dry-run et produit un rapport signé (empreinte) ; l'exécution réelle exige l'approbation N2 de l'empreinte du rapport, n'ajoute que des champs plats (jamais de modification de montant, bénéficiaire ou statut), est idempotente (même résultat à la deuxième exécution), saute et liste les signalements incomplets (ils restent bloquants), omet un champ plat pour les bénéficiaires multiples d'un même rôle (lecture imbriquée seulement), journalise chaque écriture.
- *Données personnelles* : aucune lecture ni copie de nom ou contact ; seuls les identifiants techniques ; un bénéficiaire absent ou anonymisé n'est jamais réidentifié.

## 10. Matrice des risques et protections

| Risque | Protection proposée |
|---|---|
| Clôture sans paiement | cinq conditions relues dans une seule transaction ; statut seul jamais une preuve ; moteur relit décision + preuve |
| Double paiement / double clôture | `obligation_payment_refs` create-only ; `settled_confirmed` unique ; version et précondition |
| Falsification de preuve | octets relus par le serveur, hash recalculé, immuabilité, vérificateur ≠ demandeur |
| Auto-approbation / collusion triviale | registre `personRef`, MFA imposé, A ≠ B ≠ origine ≠ titulaire |
| Modification manuelle Firestore | règles `false`, empreintes recalculées par le moteur, chaînage, alertes, IAM restreint |
| Écrasement / fusion de créances | `create`-only, clé à hash canonique, vérification de l'id |
| Crédit rétroactif automatique | interdit : aucun code ne crédite un compte fermé ; le règlement est hors système ou via exécutant futur après décision juridique |
| Réidentification d'un anonymisé | jamais ; identifiants techniques seulement |
| Bénéficiaire qui change d'état pendant la procédure | état relu aux étapes 5 et 6 |
| Concurrence clôture / suppression de compte | transactions ; le tombstone est relu ; la procédure ne rouvre aucun compte |
| Fuite de données personnelles | libellés en liste blanche, aucun texte libre recopié par le moteur, preuves en Storage serveur seul |
| MFA non imposé | prérequis bloquant `ADMIN_MFA_MODE=enforce` |
| Un seul super-admin réel | décisions N2 restent `requested`, créances bloquantes |

## 11. Tests nécessaires pour l'implémentation

Unitaires : génération et recalcul des identifiants (collisions de délimiteur, ordre, unicode) ; machine à états (toutes transitions licites et illicites) ; N2 (A = B refusé, même `personRef`, origine = approbateur, expiré, révoqué, MFA absent, `auth_time` ancien) ; preuves (hash falsifié, montant / devise / bénéficiaire / commande discordants, réutilisation de `paymentRef`, preuve d'une autre décision) ; moteur (chaque champ falsifié → ambigu ; statut `resolved` sans décision → bloquant ; `retained` seulement avec décision + preuve valides) ; données incomplètes ; idempotence de chaque callable ; permissions (sous-admin, client, livreur, anonyme). Mutations sur chaque garde. Émulateur `demo-*` : concurrence A/B simultanées, deux confirmations parallèles, clôture contre scellement / anonymisation, rejeu après crash, règles Firestore (écriture interdite, lecture super-admin seule), test de parité des règles. Rattrapage : dry-run puis exécution idempotente, bénéficiaires multiples, incomplets. Pas de test sur production.

## 12. Décisions encore nécessaires

1. Noms définitifs des collections (`obligation_*`) et du chemin Storage.
2. Résolutions autorisées pour `beneficiary_closed` et niveau de chacune : proposition [P] — N2 : `paid_out_of_system` (preuve vérifiée), `paid_to_verified_representative` (preuve + vérification d'identité/qualité) ; N3 (indisponible) : abandon ou renonciation. Où va une somme non réclamée ?
3. Désignation écrite des deux (au moins) approbateurs N2 et de leur `personRef` ; combien de super-admins réels existent aujourd'hui (non vérifié, aucun accès).
4. Activation de `ADMIN_MFA_MODE=enforce` (prérequis).
5. Délai d'expiration d'une demande ; fenêtre de fraîcheur de l'authentification.
6. Politique des refus (`beneficiary_closed_refused`) : clôture par reprise réussie de l'opération ou par support ; qui décide.
7. Option B seule ou B + A pour le rattrapage, après lecture seule autorisée de la production.
8. Décision d'architecture sur le **règlement dans le système** (exécutant vers un représentant vérifié) : hors périmètre tant que l'avis juridique n'est pas rendu.

**Questions nécessitant un avis juridique en Côte d'Ivoire (non tranchées, aucune affirmation de droit ici)** : identification et qualité des héritiers / ayants droit et pièces exigibles ; paiement à un représentant ; prescription et délais de réclamation d'une créance d'un titulaire décédé ou ayant supprimé son compte ; sort des sommes non réclamées (consignation, reversement, enrichissement de la plateforme) ; durée légale de conservation des justificatifs comptables face au droit à l'effacement (loi sur la protection des données personnelles) ; valeur probante des preuves numériques et des signatures électroniques ; obligations liées à la monnaie électronique (fournisseurs de paiement) si le règlement transite par un opérateur ; responsabilité d'AZ en cas de paiement à un faux héritier.

## 13. Découpage des futures missions (proposé)

- **L4.8 — Prérequis de sécurité** : décision sur MFA enforce, registre des approbateurs `config/n2_approvers`, règles Firestore/Storage et test de parité (sans logique financière).
- **L4.9 — Identifiants et moteur** : clé canonique des créances, extension de `RESOLUTIONS` et de la vérification des types L4 dans le moteur, tests de mutation ; inspecteur chargeant décisions et preuves.
- **L5 (déjà prévue) — writers de décisions** : callables `request/approve/attach/verify/confirm`, historique chaîné, audit, rate limit, tests d'émulateur de concurrence.
- **L6 — Preuves** : stockage, relecture d'octets, hash, unicité du `paymentRef`.
- **L7 — Rattrapage historique** (seulement si lecture seule autorisée en révèle) : dry-run puis exécution N2.
- **Mission juridique/métier** parallèle : héritiers, représentants, non réclamé, conservation ; condition d'entrée de tout exécutant de règlement dans le système.
(Les numéros L5–L7 existent déjà dans votre séquence avec d'autres intitulés : à aligner avec vous, aucune mission n'est lancée ici.)

## 14. Compte rendu final

**Fichiers consultés** : `accountObligations.js` (types, matrices, `verifyDecision`, `evaluateFlag`, branche L4), `accountObligationsInspector.js`, `accountClosureActor.js`, `accountClosureRegistry.js`, `adminBilling.js`, `adminGuards.js`, `adminPermissions.js`, `orderActions.js` (créateur du signalement), `adminOrderDisputes.js` (précédent `decisionId`), `index.js` (`logAudit`, câblage des callables), `firestore.rules`, `storage.rules`, `firestore.indexes.json`, `FIRESTORE_SCHEMA.md`, `7E102` (M-3), `2D2A_TECHNICAL_CONTRACT` §3, `2D2A10` Q4, `L4.1`, `L4.4`, `L4.5`, `L4.6`, `7E107`. `accountDeletion.js`, `manualAccountDeletion.js` et `accountDeletionScope.js` n'ont été inspectés qu'indirectement (via l'inspecteur et les rapports) ; ils n'ont pas de logique propre au registre.
**Difficultés d'accès** : aucune pour le dépôt local ; **aucune lecture de la production n'était autorisée**, donc l'existence réelle de signalements historiques, le nombre de super-admins et la valeur de `ADMIN_MFA_MODE` en production n'ont pas été vérifiés.
**Divergences avec les rapports précédents** : voir §3-9 (commentaire « un seul super-admin » périmé ; `clearBeneficiaryReview` « prévu » en 7E-102 alors qu'il existe ; nom planifié `beneficiary_account_closed` vs `beneficiary_closed` écrit ; absence de permission d'approbation financière malgré la mention de 2D2A10).
**Aucun code source, test ou configuration modifié ; aucun accès en écriture Firebase ; aucun déploiement.**
**Git final** : HEAD `d65c8f0`, index vide, stash 0, 35 suivis modifiés, **160 non suivis** (159 + ce rapport), mêmes hashes protégés.
**Risques ouverts** : aucune voie de clôture (intentionnel) ; MFA non imposé ; identité N2 non vérifiable par personne ; impossibilité d'empêcher un propriétaire de projet de modifier Firestore (seulement détecter) ; questions juridiques §12.
**Recommandation pour la prochaine mission** : faire d'abord la mission de prérequis de sécurité (MFA, registre des approbateurs, noms de collections, règles) et obtenir en parallèle une **lecture seule autorisée** de l'existence de signalements en production ; puis le moteur et les identifiants, avant tout writer.

Arrêt : en attente d'une nouvelle autorisation explicite.
