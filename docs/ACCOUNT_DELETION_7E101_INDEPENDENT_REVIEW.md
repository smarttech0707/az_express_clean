# Mission 7E-101 — Revue indépendante et contradictoire de 2D-1 (corrections C1 à C6 de 7E-100)

Date : 2026-11-09 · HEAD `d65c8f0` (inchangé), index vide. **Aucun fichier du dépôt modifié** (hors ce rapport), aucun staging/commit/push/déploiement, aucune commande distante, aucun émulateur, aucun secret. Les sondes et mutants ont tourné sur des copies dans le scratchpad.
Conclusions de 7E-100 non reprises telles quelles : chaque point ci-dessous a été vérifié dans le code, par sonde ou par mutation.

## 1. Fichiers et versions examinés
| Fichier | Empreinte / état |
|---|---|
| `functions/accountObligations.js` | 601 lignes, sha256 `d2b7cad883517fff…` (non committé) |
| `functions/test/accountObligations.test.js` | 675 lignes, sha256 `63c96152980fc4d2…` (non committé) |
| `accountDeletion.js`, `accountDeletionScope.js`, `manualAccountDeletion.js` | lecture seule, aucun diff dans le worktree |
| `docs/…7E100…`, `…7E99…`, `…7E97…`, `…7E87_DECISION_REGISTER.md` | relus (D1-D5 : registre 7E-87 ; D6-a/b/c : 7E-97 §1) |
| Écrivains relus pour C2/C5 | `partnerOrderQuote.js:320`, `catalogQuote.js:209`, `deliveryQuote.js:222`, `partnerOrderActions.js` (l. 280-362), `orderActions.js` (flags), `adminOrderDisputes.js` (l. 505-523), `ekbineOrders.js` |
Environnement : Node v22.23.4 (binaire isolé). Worktree : 95 entrées avant ce rapport.

## 2. Vérifications effectuées
- Relecture intégrale du module et des 34 tests ; rejeu des tests (34/34) et des 8 fichiers voisins (197/197).
- 21 sondes adverses (`P1`…`P21`) contre le module réel.
- 19 mutants **nouveaux**, différents des 42 de 7E-100 (`E1`…`E19`).
- Comparaison par script des trois ensembles terminaux avec les sources des inspecteurs.
- Confrontation des règles C2/C5 aux écrivains et aux décisions D1-D6.

## 3. Résultats C1 à C6
### C1 — Troncature : **conforme, avec un trou de contrat**
Confirmé OK (tests et sondes) : liste absente ⇒ `<liste>_not_provided` ; `reads` absent/non objet ⇒ `reads_missing` ; `size` absent, négatif, non entier, ou ≠ longueur ⇒ bloquant ; `size === limit` ⇒ `_truncated` ; `size > limit` ⇒ `_truncated` ; doublons ⇒ évalués une fois + bloquant ; ancien `truncated` mal formé ou à clé inconnue ⇒ bloquant (`true`, `'true'`, `1`, `{orders:1}`, `{ordres:true}`, `[]`, `null`…). `truncated:{}` est toléré (inoffensif). Les documents lus d'une lecture tronquée restent évalués. **Aucune lecture incomplète ne devient « aucune obligation » tant que l'appelant dit la vérité sur `limit`.** Défauts :
- **D-1 (Moyenne) — `limit` n'est pas borné.** Sonde P1 : 5 000 commandes dont 2 500 non payées, `reads.orders = {limit:1e15, size:5000}` ⇒ `blocking:false`. Le module ne peut pas savoir quelle limite l'appelant a posée dans sa requête : il croit la valeur déclarée. Une erreur d'appelant (mauvaise constante) rend donc la troncature invisible, ce que C1 voulait supprimer. Correctif simple : constante `READ_LIMIT = 201` du module, exigée (`limit === READ_LIMIT`).
- **D-2 (Moyenne, contrat 2D-2) — une seule paire `{limit,size}` par liste.** Les inspecteurs lisent plusieurs requêtes par rôle (partenaire : `sellerId`/`pharmacieId`/`restaurantId`/`boulangerieId` ; flags : `clientId`/`driverId`/`partnerId`/`sellerId`/`pharmacieId`). Le contrat 7E-100 §10.2 ne dit pas comment les fusionner ; si l'appelant additionne les tailles, `size>=limit` peut être vrai à tort (faux blocage) ; s'il prend la plus grande, une requête tronquée parmi quatre est possible à masquer. Il faut un format `queries:[{limit,size}]` (tronqué si l'une atteint sa limite) avant 2D-2.
- D-3 (Info) : `reads.<liste>` hérité par prototype passe les contrôles `Object.keys` (P2). Non atteignable avec des données Firestore ; à ignorer.

### C2 — Wallet v2 : **conforme**
Confirmé par les écrivains : `partnerOrderQuote:320`, `catalogQuote:209`, `deliveryQuote:222` écrivent `isPaid: paymentMethod === 'wallet'` ⇒ une commande v2 wallet vraie vaut `isPaid:true` dès la création ; `partnerOrderReconciliation` signale `isPaid !== true` en gravité haute. Donc livrée + wallet + `isPaid:false` = obligation ouverte, absent/non booléen = ambigu, payée = non bloquante, boutique exclue (`orderActions` l. 1397/1585 : `type:'boutique'`, `isPaid:false` normal), espèces non payées non bloquantes (`isPaid:false` « ne prouve rien », `orderActions` l. 1012). Sondes : v2 payée + `settlementHold` ⇒ `settlement_held` seulement. **Écart documentaire** : 7E-97 §4.2 listait `amountsVersion !== 2` comme condition d'exclusion ; 7E-100 la retire sur la base de 7E-99. Cela ne contredit aucune décision D1-D6 (la spécification 7E-97 n'est pas une décision humaine) mais **modifie le comportement spécifié** : à faire acter. Limites observées (non défauts) : la règle ne vise que `status === 'delivered'` (sondes P6 : `completed`/`refunded`/`failed`/`rejected`/`expired` non payés ⇒ non bloquants ; aucun écrivain de `orders` ne pose `completed`) et une commande `cancelled` payée n'est surveillée que via `refundPending` (comme aujourd'hui).

### C3 — Confidentialité : **conforme avec réserves mineures**
`item()` est bien le point de passage unique : `reason` (liste blanche), `status` (liste blanche), `type/state/source/party` (ensembles fermés), `amount` (entier ≥ 0), `refId/orderId` (`^[A-Za-z0-9_.:-]{1,128}$`). Vérifié sur les chemins d'erreur (entrée non objet, getter qui lève, `Proxy`, éléments forgés de snapshot avec texte libre) : aucune fuite. Réserves :
- **D-4 (Basse)** : un identifiant composé de chiffres (`2250700000000`) passe la validation (P7). Les identifiants de documents sont des ids générés ; le risque est faible mais la validation est syntaxique, pas sémantique.
- **D-5 (Moyenne-basse)** : la validation d'identifiant remplace par `id_invalid`, **sans conserver la trace** (voir D-6).

### C4 — Snapshot : **conforme pour le caractère bloquant ; défaut de comptage**
Confirmé : résultat absent/illisible/falsifié/incohérent ⇒ toujours bloquant (`result_unreadable`/`result_inconsistent`), `blocking`/`code`/compteurs recalculés, aucune exception, 50 éléments, `truncated`/`omitted` exacts, tri déterministe (300 permutations aléatoires, 0 divergence — P4), 20 000 commandes évaluées en 44 ms (P11).
- **D-6 (Moyenne-basse) — la déduplication fusionne des éléments distincts.** P3 : 120 commandes non payées avec des ids invalides ⇒ résultat `summary.open = 120`, mais snapshot `counts.open = 1`, `items = 1` (clé de dédoublonnage identique : `id_invalid`). Le snapshot **sous-déclare** la dette (le caractère bloquant reste correct) et perd la traçabilité promise pour la période post-anonymisation. Cause : `counts` calculés après déduplication, sur des clés où `refId` est écrasé. Correctif : calculer les compteurs avant déduplication (ou ne dédupliquer que les doublons exacts d'origine) ; conserver un hachage ou un index de l'identifiant d'origine.
- Écart de rapport : 7E-100 §2 annonce « C7 traités » ; seuls les doublons et l'option legacy le sont. Les champs à `null` sont toujours traités comme absents (**D-7, Basse**, P5 : `settlementHold`, `settlementStatus`, `heldDriverEarning`, `deliveryFeeHold`, `cancelRequestAfterPickup`, `cashPayment`, `refundPending`, `needsReview`, `paymentStatus` à `null` ⇒ non bloquants ; `isPaid:null` ⇒ ambigu, correct). Comportement défendable (`null` = champ effacé) mais non documenté ni testé.

### C5 — Flags : **conforme sur les preuves ; contrat de l'outil insuffisant**
Règles vérifiées dans le code et les tests : `open` ⇒ bloquant pour tout type (y compris inconnu) ; `recorded` ⇒ conservé seulement pour `cash_shortfall` avec `decidedBy`+`requestId`+`amount` entier ≥ 0 — exactement les champs écrits par `resolveCashRemittance` ; `reviewed` ⇒ clos seulement pour `cash_payment_review` avec `reviewedBy`, `reviewedAtMs>0`, `requestId`, `decision`, `verification ∈ {refuted, confirmed_unpaid}` — exactement les champs de `reviewCashNonPayment` (le `merge:true` conserve `type`) ; `resolved` ⇒ jamais écrit aujourd'hui, accepté seulement avec `resolvedBy`/`resolvedAtMs`/`resolutionRequestId` ; casse (`Open`), statut vide/absent, flag sans partie ou d'un autre compte ⇒ ambigu même clos.
Le **contrat de l'outil super-admin n'est pas assez précis** pour éviter une clôture injustifiée ou impossible :
1. Aucune **correspondance type de flag → résolutions admises → preuve exigée** : la liste `resolution` est globale, la « preuve par type » est décrite en prose (« journal wallet de crédit lié à la commande » sans collection, champ ni montant à rapprocher).
2. `waived_by_decision` (renoncer à un dû) est proposé sans décision métier : c'est la voie de clôture injustifiée par excellence.
3. Aucun principe de **séparation** : un super-admin peut résoudre le flag d'un compte dont la suppression est en cours, sans second contrôle ni plafond de montant.
4. Pas de règle pour `cash_payment_review` (doit passer par `reviewCashNonPayment`, sinon `cashPayment.verification` reste `pending_review` et bloque quand même) ni pour le flag `beneficiary_account_closed` prévu par D6-a (voir §5).
5. Pas de définition de la **preuve d'absence de dette résiduelle** ni du comportement en cas de preuve contradictoire.
6. Pas de délai/escalade pour les flags `open` (7E-97 §4.3 promettait « pas de blocage permanent » et un `blockedSince` à 30 jours) : le comportement actuel produit des blocages permanents tant que l'outil n'existe pas.

### C6 — Statuts terminaux : **conforme**
Comparaison par script avec les sources réelles : `accountDeletion.js:5` (8 statuts), `accountDeletionScope.js:3` (9, + `closed`), `manualAccountDeletion.js:18` (10, + `declined`, `closed`) ⇒ les trois ensembles exportés sont **strictement égaux** (valeur et ordre) ; tous en minuscules ; aucune utilisation de `TERMINAL` dans `partnerAccountDeletion.js`. Un test (C6b) lit les sources et échouera si un inspecteur dérive. `terminalStatuses` est obligatoire, validé (non vide, sans doublon, statuts connus, pas d'actif) ; aucun export permissif. `closed` sous `inspect()` ⇒ ambigu (bloquant, comme l'inspecteur), `declined` n'est terminal que pour la voie manuelle. Risque de classement prématuré : `completed`, `refunded`, `failed`, `rejected`, `expired` sont traités comme terminaux **par les inspecteurs eux-mêmes** (aucune régression) ; le module n'y ajoute pas de règle d'argent.

## 4. Défauts confirmés
| # | Gravité | Description | Preuve |
|---|---|---|---|
| D-1 | Moyenne | `reads.limit` non borné : troncature masquable | sonde P1 |
| D-2 | Moyenne | contrat `reads` incapable de décrire plusieurs requêtes par liste | analyse inspecteurs + contrat 7E-100 §10 |
| D-6 | Moyenne-basse | snapshot : sous-comptage et perte de traçabilité quand les ids sont invalides ou fusionnés | sonde P3 (120 ⇒ 1) |
| D-5 | Basse | `id_invalid` supprime la traçabilité de l'identifiant | P3 |
| D-7 | Basse | `null` ≈ absent non documenté, C7 annoncé « traité » à tort | sonde P5 |
| D-4 | Basse | identifiants numériques non filtrés | P7 |
| D-8 | Basse | trois trous de tests : `boulangerieId` partenaire (E3), montants négatifs (E5), éléments invalides de `retained` avec résumé cohérent (E7) | mutants survivants |
Aucun défaut fail-open **dans le moteur** n'a été trouvé hors D-1. Aucun défaut critique.
Mutants E9 et E19 (survivants) sont équivalents en pratique (la normalisation `item()` produit le même état ; deux éléments de même type/refId/reason mais d'états différents n'existent pas).

## 5. Décisions métier encore nécessaires
| # | Décision | Pourquoi |
|---|---|---|
| M-1 | **Chemin de fermeture des flags `open`** (outil super-admin ou procédure support) : types, résolutions admises, preuve exigée, `waived_by_decision` admis ou non, second contrôle | sans elle, `commission_untraced`, `partner_credit_missing`, `seller_review`, `driver_advance_unreimbursed`, `ekbine_*` bloquent à vie ; contredit « pas de blocage permanent » (7E-97 §4.3) |
| M-2 | **`cash_shortfall` `recorded` est-il une dette définitivement abandonnée ?** | le module le conserve non bloquant (preuve : décision super-admin tracée). Mais `owedTo:'partner'` : un livreur peut être anonymisé alors que le reliquat n'est pas recouvré. Aucun registre D1-D6 ne l'établit |
| M-3 | **Flag `beneficiary_account_closed` (D6-a, 7E-97 §6.2)** : `clearBeneficiaryReview` efface-t-il aussi le flag ? | sinon le flag `open` reste, classé `flag_open:other`, et bloque à vie malgré la résolution administrative de D6-a |
| M-4 | **Client dont le non-paiement espèces est `confirmed_unpaid`** (R6 de 7E-99/7E-100) | non bloquant aujourd'hui ; la dette éventuelle du client n'est portée nulle part |
| M-5 | **Acter la suppression de l'exclusion v2 dans la spécification 7E-97** | comportement différent du texte approuvé (justifié par les écrivains) |
| M-6 | Format `queries` de `reads` (D-2) et valeur imposée de `limit` (D-1) | prérequis du contrat 2D-2 |
D1 à D5 (registre 7E-87) et D6-a/b/c (7E-97) : **non contredites**. D1/D2 (comptes anonymisés non crédités) et D6 (paiement/annulation/livraison) concernent 2C ; 2D-1 ne crédite ni ne débite. D4 (`held_for_review` avant FeexPay) inchangée. D3 hors périmètre.

## 6. Tests exécutés
| Exécution | Résultat |
|---|---|
| `test/accountObligations.test.js` (Node 22.23.4) | **34/34**, 0 ignoré (230 lignes d'assertion) |
| 8 fichiers voisins (`accountDeletionHardening`, `manualAccountDeletion`, `accountDeletionSupport`, `accountQuarantineGuards`, `accountQuarantineIndex`, `orderActions`, `transferSettlement`, `partnerOrderFinancial`) | **197/197**, 0 ignoré |
| 21 sondes adverses | 3 écarts (P1, P3, P5), le reste conforme |
| 19 mutants nouveaux | **14 tués**, 5 survivants : E3, E5, E7 (trous de tests, D-8) ; E9, E19 (équivalents) |
| Comparaison des ensembles terminaux | 3/3 égalités exactes |
Aucun test modifié ; aucun émulateur ; suite `npm test` complète non relancée (aucun fichier existant modifié).
Chiffres de 7E-100 non recontrôlés dans cette revue : « ≈130 raisons » de la liste blanche, « 30+ valeurs ambiguës » de C1 (non pertinent pour le verdict).

## 7. Verdict
**2D-1 VALIDÉ SOUS RÉSERVES**
Le moteur est sain : pur, déterministe, fail-closed sur tous les chemins testés, et la correction des six points est réelle (C2 et C6 vérifiés contre les écrivains et les sources, C5 contre les champs exacts des writers). Réserves : D-1 et D-2 (contrat de lecture) à corriger avant tout branchement ; D-6 (comptage du snapshot) ; décisions M-1 à M-6.
**Je ne recommande pas 2D-2 à ce stade** : les règles de résolution nécessaires (M-1, M-2, M-3, point 1 à 6 du contrat de l'outil) ne sont pas définies. Prochaine étape suggérée, sur autorisation : (a) une mission de décision sur M-1 à M-4 ; (b) un correctif ciblé D-1/D-2/D-6/D-8 du module ; puis seulement 2D-2.
Aucune modification de code, aucun staging, aucun commit, aucun push, aucun déploiement. En attente d'une nouvelle autorisation humaine.
