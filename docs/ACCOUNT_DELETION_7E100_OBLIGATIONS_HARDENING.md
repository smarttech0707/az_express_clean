# Mission 7E-100 — Durcissement de `accountObligations.js` (corrections C1 à C6)

Date : 2026-11-09 · HEAD `d65c8f00bdcedba570a66a5633913db46127be3d` (inchangé), branche `finalisation/az-express`, index vide. Aucun staging, commit, amend, push, pull/merge/rebase/reset, déploiement, modification Firebase distante, secret, FeexPay. Production `az-express-b0469` intouchée. Aucun émulateur lancé. Les trois inspecteurs, `index.js`, les lots 2C, P3 et `professionalSubscriptions.js` n'ont pas été touchés (leurs diffs sont ceux d'avant la mission).
Fichiers modifiés par la mission : `functions/accountObligations.js` (601 lignes, sha256 `d2b7cad8…`), `functions/test/accountObligations.test.js` (675 lignes, `63c96152…`), ce rapport. Rien d'autre.
Lecture préalable : 7E-99, 7E-98, 7E-97, 7E-87 (registre) et les écrivains réels : voir 7E-99 §2 (statuts) ; pour cette mission, relus `partnerOrderActions.js` l. 280-362 (champs écrits par `reviewCashNonPayment` et `resolveCashRemittance`), `partnerOrderReconciliation.js` l. 70-85 (`V2_WALLET_NOT_MARKED_PAID`), `orderActions.js`, `driverRelease.js`, `adminOrderDisputes.js`, `ekbineOrders.js` (types de flags), `feexpayPayments.js` (`reviewReason`).
Note : la lecture du registre 7E-87 n'a pas été rejouée intégralement dans cette fenêtre ; les décisions D6-a/b/c reprises de 7E-97 n'ont pas été touchées.

## 1. Défauts corrigés
| # | Défaut (7E-99) | Correction |
|---|---|---|
| C1 | `truncated` reconnu seulement sous la forme `{orders:true}` ; toute autre forme = lecture complète | Solution **B** : preuve de couverture `reads` ; plus aucun booléen déclaratif |
| C2 | commande v2 wallet livrée non payée ignorée | exclusion v2 supprimée ; seule la boutique reste exclue |
| C3 | texte libre des documents recopié dans `reason`/`status`/ids | listes blanches + identifiants bornés |
| C4 | `buildFinancialSnapshot` levait une exception sans `summary` et recopiait `blocking` | recalcul complet depuis des éléments normalisés, jamais d'exception |
| C5 | règles de flags trop larges ; aucun chemin `resolved` | règles à trace de décision ; spécification de l'outil super-admin (§6), non codé |
| C6 | ensemble terminal du module plus large que celui des inspecteurs | `terminalStatuses` obligatoire, validé strictement |
Également (C7 de 7E-99) : documents en double et option `legacyAbsentIsPaid` traités (voir §2).

## 2. Modifications réalisées
**C1 — pourquoi la solution B.** Un schéma fermé sur `truncated` (A) reste déclaratif : l'appelant peut oublier de le fournir ou de le mettre à jour, et « absent = complet » reste la pente naturelle. B fait calculer la troncature par le module à partir de faits observables.
- Entrée : `reads: { orders: {limit, size}, settlements: {limit, size}, flags: {limit, size} }`.
- Une liste fournie est **complète seulement si** : `limit` entier ≥ 1, `size` entier ≥ 0, `size === liste.length`, `size < limit`. Le plafond atteint signifie « il y en a peut-être d'autres » (convention `limit(201)` des inspecteurs).
- Sinon, élément ambigu bloquant : `reads_missing`, `<liste>_coverage_unproven` (forme invalide, clé en plus, type non entier), `<liste>_read_size_mismatch`, `<liste>_truncated`. Clé de `reads` inconnue ⇒ `reads_unknown_key`.
- Les documents effectivement lus restent évalués même si la lecture est tronquée (aucune donnée ignorée).
- Ancien `truncated` : accepté **uniquement** comme objet dont toutes les valeurs sont `false`. `true`, `'true'`, `1`, `{orders:1}`, `{ordres:true}`, `[]`, `null`, `0`, `false` (non objet)… ⇒ `truncated_flag_invalid_or_set`.
- Liste non fournie pour une liste requise ⇒ `<liste>_not_provided` (inchangé) ; document répété dans une liste ⇒ évalué une fois + `<liste>_duplicate_document_id`.
**C2.** `if (delivered && o.type !== 'boutique')` (l'exclusion `!amountsV2` est retirée). Une commande v2 wallet livrée avec `isPaid:false` est donc une obligation ouverte (`unpaid_delivered_wallet`, montant = `budget`) ; `isPaid` absent ou non booléen ⇒ ambigu. Raison : `partnerOrderReconciliation` exige `isPaid === true` sur toute commande wallet v2 (le débit est fait à la création, le marquage doit suivre). Aucun statut ni champ inventé. La boutique garde son traitement distinct (la vraie dette vit sur `boutique_orders`). Les commandes v2 espèces restent évaluées par `cashRemittance`. **`legacyAbsentIsPaid` est supprimé** : sa simple présence ajoute `legacy_option_unsupported`, et l'absence de `isPaid` bloque toujours (recommandation 7E-99 ; aucun écrivain actuel ne l'omet).
**C3.** Voir §4. **C4.** Voir §5. **C5.** Voir §6. **C6.** Voir §7.

## 3. Règles financières vérifiées (inchangées sauf mention)
Les règles de 7E-99 §2 sont conservées : commande active ⇒ ouverte ; `settlementHold`/`settlementStatus` ; `heldDriverEarning` non réglé ; `deliveryFeeHold` ; `cancelRequestAfterPickup` ; `cashRemittance` (partiel, contesté, résolu, `merchantCashSettled`) ; `cashPayment.verification` ; `transfer_settlements` ; drapeaux `refundPending/needsReview/paymentStatus`. **Modifiées par 7E-100** : v2 wallet non payée (C2) ; statut inconnu relatif à l'ensemble terminal de l'appelant (C6) ; flags (C5) ; couverture des lectures (C1).
Point à retenir : sous l'ensemble de `inspect()`, un statut `closed` est **non terminal** (comme dans `inspect()`), mais le module le classe « inconnu » (ambigu) au lieu de « actif » (ouvert). Les deux bloquent ; seul le code de raison diffère (`financial_state_ambiguous` au lieu d'une opération active).

## 4. Liste blanche des libellés (C3)
- **`item()` est le point de passage unique** : aucun élément ne peut quitter le module sans être normalisé.
- `reason` : ensemble fermé `REASONS` (≈ 130 valeurs : raisons fixes du module, `flag_open:<type>`, `flag_recorded:<type>`, `needs_review:<raison connue>`). Toute autre valeur ⇒ `unrecognized_reason`.
- `status` : statuts connus (commandes actifs/terminaux, règlements, flags) sinon `unrecognized` ; non-chaîne ⇒ `null`.
- Types de flags : `cash_payment_review, cash_shortfall, commission_untraced, partner_credit_missing, seller_review, driver_advance_unreimbursed, ekbine_cancel_unproven_debit, ekbine_confirm_unproven_debit` (le champ `kind` d'Ekbine est lu comme `type`) ; autre ⇒ `other`.
- `reviewReason` : une seule valeur connue (`beneficiary_account_closed`) ; autre ⇒ `needs_review`. (Aucun écrivain de `orders.reviewReason` n'a été retrouvé : `feexpayPayments` l'écrit sur une transaction, pas une commande ; liste à compléter si un écrivain apparaît.)
- Identifiants `refId`/`orderId` (séparés des libellés) : `^[A-Za-z0-9_.:-]{1,128}$`, sinon `id_invalid`. L'identifiant d'origine reste dans la donnée source ; le snapshot ne porte qu'un identifiant technique borné.
- `source`, `party`, `type`, `state` : ensembles fermés ; `amount` : entier sûr ≥ 0 ou `null` ; `currency` : constante `XOF`.
- Testé avec des chaînes de 3 000 caractères, téléphones, noms, adresses, identifiants-injection : aucun ne figure dans le résultat ni dans le snapshot ; bornes ≤ 128 caractères.

## 5. Gestion des snapshots (C4)
`buildFinancialSnapshot(result, options)` :
- ne lève jamais (même avec un `Proxy` ou un getter qui lève) ;
- normalise chaque élément via `item()` ; un élément de `obligations` à l'état `retained`, ou de `retained` qui n'est pas exactement `retained` de type `reconciliation_recorded`, devient une obligation **ambiguë** (`item_invalid`) ;
- **recalcule** `blocking`, `code` et les compteurs à partir des éléments (jamais depuis `result.blocking/code/summary`) ;
- compare le résultat reçu au recalcul : `summary` absent, `blocking` ou `code` différents ⇒ ajout d'un élément ambigu `result_inconsistent` (donc snapshot bloquant) ; résultat illisible ⇒ `result_unreadable` ;
- trie de façon déterministe (type, refId, reason, state), **dédoublonne**, garde 50 éléments (bloquants d'abord), `truncated`/`omitted` exacts, compteurs sur le total ;
- `atMs` accepté seulement entier sûr, sinon `null` ; aucune écriture Firestore.
Propriété visée et testée : un résultat altéré ne devient **jamais** non bloquant ; un snapshot n'est non bloquant que si tous les éléments sont réellement conservés (`retained`) et le résultat cohérent.

## 6. Spécification de l'outil super-admin de résolution des flags (C5) — à NE PAS coder maintenant
**Comportement du module après 7E-100 (fail-closed)** :
| Statut du flag | Résultat |
|---|---|
| `open` (tout type, y compris Ekbine) | **bloquant** (`review`, `flag_open:<type>`) |
| `recorded` | conservé non bloquant **seulement si** `type==='cash_shortfall'` ∧ `decidedBy` ∧ `requestId` chaînes non vides ∧ `amount` entier ≥ 0 (champs réellement écrits par `resolveCashRemittance`) ; sinon **ambigu bloquant** |
| `reviewed` | clos **seulement si** `type==='cash_payment_review'` ∧ `reviewedBy`, `reviewedAtMs`>0, `requestId`, `decision` ∧ `verification ∈ {refuted, confirmed_unpaid}` (champs écrits par `reviewCashNonPayment`) ; sinon ambigu. Le résiduel de `confirmed_unpaid` reste porté par `cashRemittance` |
| `resolved` | **aucun écrivain actuel** ; clos seulement avec la trace de l'outil spécifié ci-dessous : `resolvedBy`, `resolvedAtMs`>0, `resolutionRequestId` ; sinon ambigu |
| autre / absent / casse différente | ambigu |
| flag sans partie reconnue, ou d'un autre compte | ambigu (même clos) |
**Tant que l'outil n'existe pas**, tout flag `open` (hors `cash_payment_review` revu) bloque l'anonymisation du compte concerné : c'est voulu. Levée possible uniquement par une action humaine journalisée.
**Spécification de l'outil `resolveReconciliationFlag` (callable super-admin, nouvelle Cloud Function, enveloppe `{success,error,message,data,code}`)** :
1. **Autorisation** : super-admin uniquement (même contrôle que `resolveCashRemittance`/`adminBilling`), permission dédiée `reconciliation.resolve`; rate limit `checkRateLimit`; refus pour tout autre rôle, y compris admin simple et AZ IA (aucun outil IA d'admin).
2. **Entrée** : `flagId`, `requestId` (idempotence, UUID), `resolution` ∈ liste fermée (`settled_by_payment`, `settled_by_adjustment`, `waived_by_decision`, `not_due_after_verification`), `justification` 20 à 500 caractères, `evidence` (références internes : ids de journaux wallet/transferts, pas de texte libre sensible), `amountResolved` entier si applicable.
3. **Contrôle du document d'origine** (dans la transaction, lectures avant écritures) : le flag existe, `status === 'open'` (refus si `recorded`/`reviewed`/`resolved`), type connu ; la commande `orderId` existe et appartient à une partie du flag ; relecture des champs financiers pertinents.
4. **Vérification de la résolution financière** : la résolution doit être **démontrée** par les données, pas déclarée — par type : `partner_credit_missing` ⇒ un journal wallet de crédit du vendeur lié à la commande existe ; `commission_untraced` ⇒ preuve de commission ou décision `waived_by_decision` par super-admin ; `seller_review`/`driver_advance_unreimbursed` ⇒ journal de remboursement lié à `decisionKey` ; `ekbine_*` ⇒ remboursement journalisé ou décision explicite. Aucun mouvement d'argent n'est fait par l'outil : il **constate**.
5. **Écriture** : `status:'resolved'`, `resolvedBy`, `resolvedAtMs` (horloge serveur), `resolutionRequestId`, `resolution`, `resolutionJustification`, `resolutionEvidence`, `previousStatus:'open'`, `version` incrémentée. Jamais d'effacement du flag.
6. **Audit immuable** : `logAudit` dans `audit_logs` (collection `write:false` pour les clients) dans la même transaction : acteur, horodatage, `flagId`, avant/après, justification, identifiant de requête. Aucune modification a posteriori.
7. **Prévention des doubles résolutions** : verrou par transaction + `requestId` idempotent (rejouer = même réponse, pas de nouvelle écriture) ; une seconde résolution avec un autre `requestId` est refusée (`ALREADY_RESOLVED`).
8. **Traçabilité** : le champ `financialSnapshot` d'un dossier de suppression porte l'identifiant du flag et son état ; la résolution ne modifie jamais un wallet ni une commande.
9. **Tests requis** : refus non super-admin ; double résolution ; replay idempotent ; flag non `open` ; commande étrangère ; preuve absente ⇒ refus ; concurrence ; audit écrit ; règles Firestore inchangées (`reconciliation_flags` Admin SDK seulement) ; non-régression du module (`resolved` avec trace ⇒ non bloquant).
10. **Hors périmètre** : aucune résolution automatique, aucun changement des écrivains existants, aucune migration des flags `recorded` historiques.
11. **Décisions métier à prendre avant le code** : la liste fermée `resolution` ; la preuve exigée par type ; si `waived_by_decision` est admis.

## 7. Configuration des statuts terminaux (C6)
- `terminalStatuses` est **obligatoire** : tableau non vide, sans doublon, composé de statuts de `KNOWN_TERMINAL_STATUSES` (`delivered, cancelled, expired, completed, refunded, failed_refunded, failed, rejected, declined, closed`) ; actif (`pending`…) ou inconnu ⇒ invalide ⇒ résultat bloquant `terminal_statuses_invalid`. Aucun défaut ; l'export permissif `TERMINAL_STATUSES` a été supprimé.
- Ensembles des inspecteurs (exportés `INSPECTOR_TERMINAL_STATUSES`, figés) :
| Inspecteur | Statuts terminaux |
|---|---|
| `accountDeletion` (`inspect()`) | delivered, cancelled, expired, completed, refunded, failed_refunded, failed, rejected |
| `accountDeletionScope` | idem + `closed` |
| `manualAccountDeletion` | idem + `declined`, `closed` |
- **Un test lit le source des trois inspecteurs** (sans les modifier) et vérifie l'égalité exacte des ensembles : toute dérive future d'un inspecteur casse le test.
- Statut absent de l'ensemble de l'appelant et non actif ⇒ `unknown_or_unreadable_status` (ambigu, bloquant) : jamais accepté implicitement.

## 8. Tests et mutations (Node v22.23.4)
- **34 tests, 34 passent** (24 historiques conservés, adaptés uniquement là où le contrat a changé volontairement : v2 non payée, preuves de flags, option legacy, troncature). 230 assertions.
- Nouveaux : C1 (formes de `reads` et de `truncated`, 30+ valeurs ambiguës), C1b, C1c (doublons), C2 (variantes v2, contradictions), C3 (PII, 3 000 caractères, ids invalides), C4 et C4b (summary absent, falsification, plus de 50, doublons, malformés, getters qui lèvent, éléments forgés), C5 (matrice des états), C6 et C6b (configurations, égalité avec les sources des inspecteurs).
- Les 24 tests historiques passent avec un adaptateur qui ajoute `terminalStatuses`/`reads` **uniquement quand ils sont absents** ; les tests 7E-100 appellent la fonction stricte directement.
- **Mutations : 42 mutants, 41 détectés, 1 survivant.** Survivant : « C6 caller set ignored » — **mutant équivalent** (il ne change que la branche « actif vs terminal » dont les résultats coïncident pour tout statut atteignable : un statut terminal de l'appelant appartient toujours à `KNOWN_TERMINAL_STATUSES`). Deux survivants initiaux (raison non filtrée sur élément forgé de snapshot ; rétention forgée avec résumé cohérent) ont révélé des tests trop faibles ; le test C4b les a ajoutés et ils sont maintenant tués.
- Voisins : **197/197** (`accountDeletionHardening`, `manualAccountDeletion`, `accountDeletionSupport`, `accountQuarantineGuards`, `accountQuarantineIndex`, `orderActions`, `transferSettlement`, `partnerOrderFinancial`), 0 ignoré. Suite complète `npm test` non relancée (aucun fichier existant modifié).
- Pureté : test textuel conservé (aucun `require`, horloge, Firestore, réseau) ; test de non-branchement conservé.
- Aucun test sur production ; aucun émulateur utilisé.

## 9. Réserves restantes
| # | Réserve |
|---|---|
| R1 | Les flags `open` autres que `cash_payment_review` bloquent sans issue tant que l'outil C5 n'existe pas ; spécification prête, décisions métier nécessaires |
| R2 | `resolved` n'a pas d'écrivain : sa règle est un **contrat** avec l'outil futur, non éprouvé sur des données réelles |
| R3 | Un statut `closed` sous `inspect()` donne `ambigu` au lieu d'« actif » : même blocage, code de raison différent |
| R4 | `reviewReason` : liste blanche d'une valeur ; à compléter si un écrivain de `orders.reviewReason` est trouvé |
| R5 | Valeurs historiques réelles en production inconnues ⇒ blocages possibles (fail-closed) ; mesure en préproduction sur données synthétiques (protocole 7E-99 §7) |
| R6 | Le client dont le non-paiement espèces est `confirmed_unpaid` n'est pas bloqué (dette portée par livreur/partenaire) : décision métier à confirmer |
| R7 | Boulangerie standard : articles non encaissés par conception (hors module) |
| R8 | Intégration (2D-2), tests d'émulateur et durée de transaction non mesurés ; `financialBlocker` lit hors transaction |
| R9 | Tests unitaires purs : aucun test device |

## 10. Préparation de 2D-2
Le manifeste 7E-99 §10 reste valable avec ces **précisions de contrat** :
1. Chaque appelant passe `terminalStatuses: INSPECTOR_TERMINAL_STATUSES.<son inspecteur>`.
2. Chaque appelant passe `reads` avec, pour **chaque** requête, la `limit` réellement posée (201) et `size` = nombre de documents obtenus ; `size >= limit` ⇒ blocage (cohérent avec l'actuel `history_requires_manual_review`).
3. Ne passer au prédicat que les documents `orders` (`doc.ref.parent.id === 'orders'`) ; les quatre autres collections de commandes restent traitées par leurs inspecteurs.
4. Ne pas passer `truncated` ni `legacyAbsentIsPaid`.
5. Écrire `buildFinancialSnapshot(result, {atMs})` dans le dossier de suppression au blocage et à l'anonymisation (additif, après décision explicite).
6. Prérequis : décision sur l'outil de résolution des flags (§6) ; sans lui, les comptes concernés restent bloqués.
7. Ordre : intégration `inspect()` (transactionnel) → `readDeletionScope` → `financialBlocker` (non transactionnel, à traiter à part), tests d'émulateur pour chaque.
Aucune intégration n'est faite ici.

## 11. Périmètre et Git
- Créés/modifiés par la mission : `functions/accountObligations.js`, `functions/test/accountObligations.test.js`, ce rapport (+ artefacts hors dépôt dans le scratchpad : script de patch, harnais de mutation, copies de sauvegarde en dossier temporaire).
- HEAD `d65c8f00…`, parent `294332e…`, `65e738b…` intacts ; index vide ; aucun commit/push/déploiement ; `git status` : 94 entrées avant ce rapport (95 avec lui), les 93 d'avant la revue plus le rapport 7E-99.
- Inspecteurs (`accountDeletion.js`, `accountDeletionScope.js`, `manualAccountDeletion.js`), `partnerAccountDeletion.js`, `accountAdmission.js` : aucun diff ajouté ; `index.js` : seul le hunk P3 préexistant ; `professionalSubscriptions.js` : diff préexistant.

## Verdict
**2D-1 CORRIGÉ ET TESTÉ — PRÊT POUR INTÉGRATION**
Les six défauts sont corrigés et couverts : 34/34 tests, 41 mutants sur 42 détectés (le dernier est équivalent), 197/197 tests voisins sous Node 22.23.4. Condition d'usage : l'intégration 2D-2 doit respecter le contrat du §10, et les flags `open` sans chemin de fermeture continueront de bloquer tant que l'outil du §6 n'existe pas. Aucune modification des inspecteurs, aucun staging, aucun commit, aucun push, aucun déploiement. En attente d'une nouvelle autorisation humaine.
