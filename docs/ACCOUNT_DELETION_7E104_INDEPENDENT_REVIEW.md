# 7E-104 — Audit indépendant de 2D-1 ter

Lecture seule. HEAD `d65c8f0`, index vide. Module (`e73a18339b7f…`) et tests (`803c146ed9a0…`) identiques avant et après l'audit. Les sondes et mutants ont tourné sur une **copie** dans le dossier temporaire de session, jamais sur le dépôt. Aucun émulateur, aucune commande distante, aucun déploiement. Entrées de travail : 97 préservées, plus le rapport 7E-103, plus ce rapport.

## Verdict

**2D-1 VALIDÉ SOUS RÉSERVES.**

Le moteur est fail-closed sur tout ce que j'ai essayé : lecture tronquée ou non prouvée, requêtes absentes ou mal formées, registre de décisions absent, résultat falsifié. Je n'ai trouvé **aucun chemin qui rende un résultat non bloquant sans preuve**, sauf un cas réel (R1, fermeture d'un dossier espèces client sans `requestId`). Quatre réserves (R1 à R4) doivent être traitées avant l'intégration dans les inspecteurs, car elles touchent des règles arbitrées en 7E-102 ou la traçabilité d'une clôture. Les autres sont des durcissements ou des points à décider.

Résultats rejoués : `accountObligations.test.js` 43/43, voisins 197/197 (Node 24.22.1, voir §9).

## 1. Réserves à traiter avant intégration

| Réf. | Constat | Preuve | Gravité |
|---|---|---|---|
| **R1** | Un dossier espèces client est fermé par une décision **sans `requestId`**. Pour les signalements, `resolutionRequestId` est exigé sur le signalement ; pour le client, `requestId` est lu dans la décision elle-même (`clientCashCaseClosed`), donc `undefined === undefined` passe. | Sonde : décision `refuted_after_contest`, `requestedBy:'a'`, niveau 1, sans `requestId` → `blocking:false`, `cash_nonpayment_case_closed`. Un mutant qui supprime le contrôle de `requestedBy` survit aussi : le cas client n'est pas testé sans demandeur. | Moyenne. Corriger : exiger `isStr(d.requestId)` dans `verifyDecision`, ajouter les deux tests négatifs. |
| **R2** | Écarts avec 7E-102 : (a) `refuted_after_contest` est au niveau **1** dans le code, **N2** dans 7E-102 (§M-5). Un seul responsable peut donc effacer un dossier client. (b) `no_claim_established` n'existe pas dans 7E-102 ; `paid_out_of_system` remplace `paid_by_client_out_of_system` ; `written_off_by_platform` (N3) est absent. (c) `closed_by_contract` (N3) est une **invention de 7E-103** : 7E-102 prévoyait `waived_by_partner` (N3, consentement du partenaire). (d) `waived_by_driver` (N3) et `partner_unreachable_held` ne sont pas codés (fail-closed, donc bloquants). | Comparaison ligne à ligne, §5. | Haute pour (a), moyenne pour le reste. Décision humaine requise sur (b) et (c) ; (a) est un écart de code. |
| **R3** | 7E-102 exige pour N2 : approbateur ≠ demandeur **et ≠ `decidedBy` d'origine du signalement**. Le code ne contrôle que ≠ demandeur. | Sonde : signalement `cash_shortfall` avec `decidedBy:'adm2'`, décision N2 approuvée par `adm2` → accepté, non bloquant. | Moyenne. |
| **R4** | Aucune **preuve** n'est exigée dans la décision. Une décision de niveau 1 (`verified_no_debit`, `refunded_by_ledger`, `payment_completed`…) est acceptée sans référence de justificatif, alors que 7E-102 impose « preuve vérifiée par le serveur ». | Sonde : `commission_untraced` / `verified_no_debit`, niveau 1, aucun champ de preuve → fermé. | Moyenne : tolérable tant que le futur écrivain vérifie, mais le moteur doit au moins exiger la présence d'une référence (voir §6). |

## 2. Autres constats

| Réf. | Constat | Gravité |
|---|---|---|
| R5 | `limit` accepté de 1 à 201. 7E-102 §M-6 fixait `READ_LIMIT = 201` et refusait **toute autre valeur**. Une limite plus basse avec `size < limit` passe comme « complète ». | Basse. Passer à `limit === 201` (cohérent avec les inspecteurs, `limit(201)`). |
| R6 | `requiredQueries('client',['a','a'])` émet deux fois le même couple ; le moteur rejette alors le doublon (`*_query_duplicate`). Fail-closed mais le contrat se contredit. | Basse. Dédoublonner `ids` dans `requiredQueries` et dans le moteur. |
| R7 | Le snapshot **re-hache** les identifiants déjà invalides : `invalid:5fcfc6f5` dans le résultat devient `invalid:63955100` dans le snapshot. Aucun impact sur le blocage ; le reçu et le résultat ne se recoupent plus. | Basse. |
| R8 | `remaining` et `tier` sont déclarés par la décision elle-même. Rien ne lie `remaining` au montant du signalement ni à la somme des recouvrements, ni la décision au compte concerné. | À traiter par l'écrivain du registre (§6) ; le moteur ne peut pas le recalculer. |
| R9 | Écart de tests révélé par mutation (§7) : cas client sans demandeur ; v2 non payée sans journal ; les tests D-2b et C6 comparent par simple présence de chaîne dans les sources des inspecteurs (faible). | Basse. |
| R10 | Commandes **non v2** payées par wallet : `isPaid:true` accepté sans preuve de journal. Le journal du `payOrderFromWallet` est à identifiant automatique (non déterministe) ; celui de `catalogQuote`/`deliveryQuote` est `order_<id>` mais ces commandes ne sont pas v2. Hors décision 10. | À décider (extension éventuelle). |
| R11 | 7E-102 §M-6 point (4) « chaque document correspond à au moins un couple » n'est pas vérifié : un document ne porte pas la requête qui l'a ramené. Le moteur vérifie seulement le lien métier (champ propriétaire). | Basse, inhérent au contrat. |
| R12 | Les signalements Ekbine portent `agentId` (`ekbineReconciliation.js:67`). Aucun rôle agent n'existe dans le moteur : un tel signalement est `flag_without_party` (bloquant). Fail-closed, hors périmètre actuel. | Info. |
| R13 | Le snapshot ne peut pas détecter une altération **cohérente** (obligations vidées + résumé nul + `blocking:false`). Inhérent : il recalcule depuis ce qu'on lui donne. L'appelant doit appeler `evaluateAccountObligations` puis `buildFinancialSnapshot` dans la même fonction, sans stockage intermédiaire. | Info. |

## 3. D-1 et D-2 (contrôles 1 et 2)

Vérifié par lecture et par sondes :
- `limit` : 1 à 201 uniquement ; 0, négatif, 1.5, NaN, Infinity, chaîne, `null`, `undefined`, booléen, 202, `1e15` sont refusés (`orders_query_invalid`).
- `size >= limit` (donc 201/201, ou 100/100) → `<liste>_truncated`, `manualReviewRequired:true`, code ambigu. Les documents de la lecture tronquée restent évalués. 200 documents pour la limite 201 : complet.
- Aucun chemin ne rend un résultat tronqué non bloquant : la troncature est un élément ambigu, donc `blocking` ; `manualReviewRequired` est recalculé par `buildFinancialSnapshot` (jamais repris).
- Requêtes attendues par rôle : conformes à 7E-102 (client `clientId` ; livreur `driverId`, `driverIds`, `holderDriverId` ; partenaires `sellerId` + champ de type, flags `partnerId`/`sellerId`/`pharmacieId`). Chaque couple (clé, id) est exigé. Test indépendant : retrait une à une de chaque requête → `*_queries_incomplete` pour les 6 rôles.
- Requête inconnue, id étranger, doublon, entrée à clés en trop ou manquantes, `null`, chaîne, liste vide, `queries` non tableau, `reads` absent/nul/booléen/tableau → tous bloquants.
- Une collection non entièrement examinée ne peut donc pas autoriser l'anonymisation, **sous réserve** que l'inspecteur décrive honnêtement ses requêtes (le moteur ne voit pas la base) ; d'où le test de contrat et le reçu de couverture à bâtir en 2D-2.
- Écarts : R5 (limite < 201), R6 (ids dupliqués), R11.

## 4. D-6 et dossier espèces client (contrôles 3 et 4)

- Clé `orderId|créance` : calculée seulement si l'`orderId` est fiable. Commandes distinctes → clés distinctes. Plusieurs symptômes d'une même créance (commande impayée + revue + signalement) partagent la clé. Sans identifiant fiable : aucune clé, élément isolé et bloquant.
- Identifiants invalides : empreinte FNV-1a 32 bits (`invalid:<8 hex>`), distincts en pratique ; une collision n'a d'effet que sur l'affichage dédupliqué, jamais sur les comptes (qui ne passent pas par la déduplication). Constat R7 sur le re-hachage.
- `orders` / `economic` / `flags` : cohérents (sondes et tests). Les défauts d'appel (ambigus sans clé) gonflent `economic` ; c'est conservateur.
- `clientCashCaseClosed` : la variable hors portée est corrigée (`env`). Scénarios vérifiés : sans registre → revue ; registre invalide → bloquant ; statut ≠ `executed`, autre commande, autre type, résolution inconnue, `__proto__`, `remaining ≠ 0`, niveau insuffisant, un seul responsable pour N2 → bloquants ; décision conforme → `cash_nonpayment_case_closed` (retained). **Exception : R1.** Le dossier client « refuté » (`verification: refuted`) n'est pas une obligation. Pour livreur et partenaire, `confirmed_unpaid` n'ouvre rien par ce bloc (leur position passe par `cashRemittance`).

## 5. Niveaux de validation face à 7E-102 (contrôle 6)

Légende : ✓ conforme · ✗ écart · ○ non codé (bloquant, donc sûr) · ? invention de 7E-103.

| Type / résolution | 7E-102 | Code | |
|---|---|---|---|
| `commission_untraced` / `verified_no_debit`, `refunded_by_ledger` | N1 | 1 | ✓ |
| `commission_untraced` / `waived_platform_claim` | N3, créance d'AZ | 3 + `creditor === 'az_express'` + accord | ✓ (le créancier est déclaré par la décision, voir §6) |
| `partner_credit_missing` / `paid_to_partner_ledger` ; `paid_out_of_system` | N1 ; N2 | 1 ; 2 | ✓ |
| `partner_credit_missing` / `partner_unreachable_held` | reste ouvert | absent | ○ |
| `seller_review` | N2 | 2 | ✓ |
| `driver_advance_unreimbursed` / `reimbursed_by_ledger` ; `reimbursed_out_of_system` | N1 ; N2 | 1 ; 2 | ✓ |
| `driver_advance_unreimbursed` / `waived_by_driver` | N3 | absent | ○ |
| `ekbine_*` / `debit_proven_and_settled`, `debit_disproved` ; `refunded_by_ledger` | N1 ; N2 (liste ambiguë) | 1, 1 ; 2 | ✓ (lecture raisonnable) |
| `cash_shortfall` / `recovered_in_full`, `absorbed_by_platform` | N2 | 2 | ✓ |
| `cash_shortfall` / `waived_by_partner` | N3, consentement du partenaire | absent | ○ |
| `cash_shortfall` / `closed_by_contract` | non prévu | 3 + `contractRef` + accord | ? |
| `beneficiary_account_closed` / `payment_completed` ; `beneficiary_substituted` | N1 ; N2 | 1 ; 2 | ✓ |
| `beneficiary_account_closed` / `order_payment_waived_by_platform` | N3 | absent | ○ |
| client espèces / `refuted_after_contest` | **N2** | **1** | **✗ (R2a)** |
| client espèces / `paid_by_client_out_of_system` | N2 | `paid_out_of_system` 2 (nom différent) | ✓ au nom près |
| client espèces / `written_off_by_platform` | N3 | absent | ○ |
| client espèces / `no_claim_established` | non prévu | 2 | ? |

Décision 6 (renonciation seulement pour créances AZ) : respectée dans le code, car la seule renonciation codée est `waived_platform_claim`. Règle N2 « ≠ `decidedBy` d'origine » : R3. Délai de réflexion de 24 h proposé en 7E-102 : non codé et non décidé ; à traiter dans l'écrivain.

`closed_by_contract` : cohérent avec la décision 7 (reliquat ouvert tant qu'il n'y a pas de preuve contractuelle **et** une décision de clôture adaptée), mais le niveau 3, la référence `contractRef` et le fait que le partenaire « supporte seulement si son contrat le prévoit » sont des choix du code, pas des arbitrages. À valider ; sinon retirer la résolution (le dossier reste alors bloquant, ce qui est sûr).

## 6. Registre `decisions` : fail-closed et preuves manquantes (contrôle 5)

- Sans registre, avec registre vide, illisible, dupliqué ou incomplet : tout signalement `resolved` et tout dossier client restent bloquants. Un statut `resolved` seul n'est jamais accepté : il faut les six champs de trace du signalement **et** une décision correspondante (sujet, type, résolution, `requestId`, demandeur, `executed`, niveau, `remaining === 0`).
- Champs de preuve vérifiés par le moteur : `status`, `subjectKind`, `subjectId`, `subjectType`, `resolution`, `requestId`, `requestedBy`, `tier`, `remaining`, et selon le niveau `approvedBy`, `approvedAtMs`, `requestedAtMs`, `creditorConsentRef`, `creditor`, `contractRef`.
- **Encore nécessaire** (moteur ou écrivain) :
  1. Moteur : `requestId` obligatoire dans tous les cas (R1) ; au moins une référence de preuve (`evidenceRef`) par résolution (R4) ; approbateur ≠ `decidedBy` d'origine (R3).
  2. Écrivain : `requestedBy` et `approvedBy` doivent être des super-admins réels et distincts ; horodatages posés par le serveur ; registre append-only ; niveau (`tier`) **calculé par le serveur** à partir de la matrice, jamais fourni ; `creditor` dérivé du type de signalement (jamais saisi) ; `remaining` recalculé (montant d'origine moins recouvrements enregistrés) et lié au montant du signalement (R8) ; lien décision ↔ compte ; vérification de la preuve elle-même (ex. ligne de journal pour `refunded_by_ledger`) ; délai de réflexion si décidé.
  3. Le moteur ne gère pas l'annulation ou le remplacement d'une décision (une décision `revoked` est ignorée, car non `executed`). À préciser avec l'écrivain.

## 7. Qualité des tests et mutations

J'ai rejoué sur copie 27 mutants **différents** de ceux de 7E-103 (4 motifs introuvables, non comptés) : 18 tués, 5 survivants. Analyse :
- Survivants équivalents : suppression des deux contrôles `subjectKind`/`subjectId` dans le filtre de `clientCashCaseClosed` (redondants avec `verifyDecision`) ; `size` négatif admis (ne peut que resserrer la borne supérieure).
- Survivants révélant un manque de test : contrôle de `requestedBy` côté client (lié à R1) ; `isPaid === true` dans `needsDebitProof` (aucun test « v2 non payée sans journal »).
- Les 45 mutants de 7E-103 restent plausibles ; je n'ai pas rejoué toute la série.

## 8. Wallet : chemin réel et contrat de lecture pour 2D-2 (contrôle 7)

Constats sur les sources :
- **Trois emplacements distincts**. (1) `wallet_transactions` de premier niveau : lu par `inspect()` (`where userId == uid`, statut terminal), contient les recharges FeexPay et les lignes `ekbine_payment` **que le client peut écrire** (règle ligne 862) : à ne jamais utiliser comme preuve. (2) `clients/{uid}/wallet_transactions` : journal d'affichage et de preuve. (3) Sous-collections livreur/vendeur.
- Dans (2), le client ne peut créer que des lignes `purchase` à identifiant automatique de 20 caractères (règle ligne 333) : un document `order_<orderId>` ne peut venir que d'une Cloud Function ou d'un admin. C'est ce qui rend la preuve fiable.
- Écrivains de `order_<orderId>` : `partnerOrderQuote.js:298` (v2 ; champs `type:'payment'`, `amount: total`, `orderId`, `provider`, `txId`, `productAmount`, `deliveryFee`), `catalogQuote.js:198` et `deliveryQuote.js:207` (non v2). `payOrderFromWallet` (`orderActions.js:142`) écrit un `payment` à identifiant automatique, pas `order_<id>`.
- Sens du mouvement : porté par `type` (`payment`, `refund`, `earning`, `commission`…), le montant est toujours positif. Le module teste `type === 'payment'` et `amount === totalAmount` : conforme.
- Identifiant déterministe : pas de doublon possible pour `order_<id>`. Remboursements et inversions sont des lignes **distinctes** (`refund` automatiques ; `admin_refund_<orderId>` pour la boutique) : elles n'invalident pas le débit d'origine, et un remboursement ne crée pas d'obligation pour le titulaire. Le module n'a donc pas à les lire.
- Non comparés par le module (renforcement possible) : `txId === 'order_<id>'`, `provider === 'wallet'`, `productAmount`/`deliveryFee` du journal contre la commande.

Contrat de lecture proposé pour 2D-2 (sans modifier les inspecteurs aujourd'hui) :
1. Après lecture des commandes du client, calculer `requiredWalletDebitIds('client', orders)`.
2. Pour chaque identifiant, **lecture ponctuelle** `clients/{uid}/wallet_transactions/{id}` dans la même transaction, avec `uid` ∈ `ids` du compte inspecté, **jamais** le niveau supérieur.
3. Construire `walletDebits = [{id, exists, data}]`. Une erreur de lecture doit faire échouer l'inspection ; elle ne doit jamais produire `exists:false`.
4. Ajouter dans le reçu de couverture la liste des identifiants lus (preuve que chaque lecture requise a eu lieu).
5. Budget : au pire 200 lectures supplémentaires par inspection ; à mesurer avec les ~1 600 lectures de 7E-102.
6. Le module ne vérifie pas que `walletDebits[].id` provient du bon chemin : un reçu de chemin (`path`) est à prévoir si l'on veut le prouver.

## 9. Environnement Node (contrôle 8)

Node **22.23.4 non disponible**. Seule installation détectée : `C:\Program Files\nodejs\node.exe`, v24.22.1 ; aucun gestionnaire de versions (nvm, fnm, volta, scoop) ni autre `node.exe` jusqu'à trois niveaux dans Program Files, LOCALAPPDATA et le profil. `functions/package.json` demande `"node": "22"`. Je n'ai rien installé ni modifié. Les tests ont donc été rejoués sous 24.22.1 uniquement (43/43 et 197/197). Une exécution sous Node 22.23.4 reste à faire avant l'intégration (la CI ou une machine équipée suffit).

## 10. Avant 2D-2 (rappel, sans le commencer)

Corriger R1 à R4 (et idéalement R5 à R7) dans le module et ses tests ; faire valider par vous R2(b), R2(c) et la lecture N2 de `refuted_after_contest` ; rejouer sous Node 22.23.4 ; spécifier l'écrivain du registre selon le §6. Je m'arrête ici et attends votre autorisation explicite.
