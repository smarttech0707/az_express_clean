# 7E-103 — Correction 2D-1 ter après arbitrage métier

Périmètre : `functions/accountObligations.js` et `functions/test/accountObligations.test.js` uniquement. Les trois inspecteurs, `index.js`, les lots 2C, P3 et `professionalSubscriptions.js` sont intacts. Aucun outil super-admin. Aucun commit, push, déploiement, émulateur ni action distante.

## Verdict

**2D-1 CORRIGÉ ET TESTÉ SOUS RÉSERVES** — le moteur et ses tests sont conformes aux douze décisions de 7E-102. Les réserves sont listées au §6 : le registre de décisions (`decisions`) est un schéma **proposé**, il n'a pas encore d'écrivain, et il doit être confirmé avant 2D-2.

## 1. Défauts corrigés

| Réf. | Défaut 7E-101 | Correction |
|---|---|---|
| D-1 | Limite de lecture non bornée (`limit` arbitraire acceptée) | `limit` entier de 1 à 201 (`READ_LIMIT`). Tout le reste est refusé (`orders_query_invalid`) : nul, négatif, non entier, chaîne, NaN, Infinity, > 201. Une requête dont `size >= limit` rend la lecture potentiellement tronquée (`<liste>_truncated`) et `manualReviewRequired: true`. |
| D-2 | Un seul contrat `{limit,size}` par collection | Contrat explicite `reads.<liste>.queries = [{key,id,limit,size}]`. `requiredQueries(rôle, ids)` donne les requêtes attendues par rôle : client `clientId` ; livreur `driverId`, `driverIds`, `holderDriverId` ; partenaire `sellerId` + champ propre au type (`pharmacieId`, `restaurantId`, `boulangerieId`) et flags `partnerId`, `sellerId`, `pharmacieId`. Requête manquante, inconnue, dupliquée, mal formée, id étranger, clés en trop : bloquant. Taille de la liste bornée entre la plus grande requête et la somme des requêtes. Aucune pagination dans une transaction : au-delà de la limite, revue manuelle. |
| D-6 | Ids invalides fusionnés ; comptes dépendants de la déduplication | Id invalide → `invalid:<empreinte 8 hex>` distinct. Clé économique `orderId\|créance`, présente seulement si l'`orderId` est fiable ; sinon l'élément reste isolé et bloquant. `summary` et `counts` distinguent `orders`, `economic`, `flags`, indépendamment de la déduplication. |
| E3 | Relation `boulangerieId` non testée | Tests positifs (4 rôles partenaires) et négatif (commande d'une autre boulangerie → `order_not_linked_to_account`). |
| E5 | Montants négatifs non testés | Test : montants négatifs ou non entiers → `amount: null`, jamais propagés. |
| E7 | `retained` invalide avec résumé cohérent | Test : l'élément invalide reste dans le snapshot comme obligation ambiguë, `blocking: true`. |

Défaut trouvé pendant les tests : `clientCashCaseClosed` appelait `verifyDecision(ctx, …)` avec une variable hors portée. La clôture d'un cas espèces client ne pouvait jamais aboutir (fail-closed, donc sans fuite, mais fonction cassée). Corrigé (`env`).

## 2. Mise en œuvre des décisions 7E-102

1–3, 5. **Niveaux de validation.** `RESOLUTIONS` associe à chaque type de signalement ses résolutions admises et leur niveau minimal (1 à 3). `verifyDecision` exige une décision exécutée correspondant au sujet, au type, à la résolution, au `requestId` et au demandeur, avec `remaining === 0`. Niveau ≥ 2 : `approvedBy` différent du demandeur et `approvedAtMs ≥ requestedAtMs`. Niveau 3 : `creditorConsentRef`. Avec un seul responsable, les niveaux 2 et 3 ne sont jamais atteints : l'opération reste en attente (bloquante).
6. **Abandon de créance** (`waived_platform_claim`) : niveau 3, `creditor === 'az_express'` obligatoire. Autre créancier : refusé.
7. **`cash_shortfall`.** Le statut `recorded` est bloquant (`flag_recorded_open`), jamais retenu. Fermeture seulement par `recovered_in_full` (2), `absorbed_by_platform` (2) ou `closed_by_contract` (3, `contractRef` exigé).
8. **Non-paiement espèces du client.** Cas par cas : obligation en revue, `amount: null` (aucune dette inventée). Fermeture par décision `client_cash_nonpayment`. Les niveaux de ces résolutions sont une proposition (voir §6).
9. **`clearBeneficiaryReview`** reste distinct : la fermeture d'un signalement `beneficiary_account_closed` ne ferme jamais la créance de paiement de la commande (test dédié).
10. **Wallet v2.** Pour le rôle client, une commande v2 livrée payée exige `isPaid === true` ET le journal `clients/{uid}/wallet_transactions/order_<id>` rapproché (`type:'payment'`, `orderId`, `amount === totalAmount`). Journal non fourni → `v2_wallet_debit_unverified`. Absent → revue. Incohérent → `v2_wallet_debit_mismatch`. Montants de la commande incohérents → `v2_amounts_inconsistent`.
11. **> 200 documents** : revue manuelle (`manualReviewRequired`), pas de pagination.
12. **Lecture incomplète** : toujours bloquante. Un résultat falsifié ne devient jamais non bloquant (snapshot recalculé).

## 3. Tests

`node --test test/accountObligations.test.js` : **43 tests, 43 réussis** (24 historiques adaptés + 19 nouveaux). Les anciens tests C1 à C6 de 7E-100 sont réécrits pour les nouveaux contrats. Nouveaux : contrat des requêtes (table indépendante, lecture des sources des inspecteurs), retrait une à une de chaque requête exigée, limites, listes séparées, ancien indicateur `truncated`, doublons, wallet v2 et débit rapproché, clé économique et comptes distincts, ids invalides, PII et chaînes longues, snapshot falsifié (dont E7), matrice complète des signalements et des résolutions (tous niveaux, un seul responsable, abandon non-AZ, accord créancier, contrat, `remaining`, `__proto__`/`constructor`, registre absent ou illisible), cas client espèces, E3, E5, statuts terminaux (égalité avec les sources des inspecteurs).

Mutations ciblées : **45 mutants sur le module, 45 tués, 0 survivant** (script hors dépôt, module restauré à l'identique après chaque essai, empreinte vérifiée). Familles : D-1 (4), D-2 (10), E3 (2), D-6 (2), wallet v2 (7), signalements (4), décisions (10), cas espèces client (2), snapshot et C2/C3 (4).

Voisins : 8 fichiers (`accountDeletionHardening`, `manualAccountDeletion`, `accountDeletionSupport`, `accountQuarantineGuards`, `accountQuarantineIndex`, `orderActions`, `transferSettlement`, `partnerOrderFinancial`) : **197/197**.

Environnement : exécuté sous **Node v24.22.1** (le binaire Node 22.23.4 de la mission précédente n'était pas disponible dans cette session). Le module n'utilise que des API standard ; une relance sous Node 22 reste à faire avant intégration.

## 4. Intégrité

HEAD `d65c8f0`, index vide, aucun fichier supprimé. Entrées de travail : 97 existantes + ce rapport. Le module n'est cité par aucun inspecteur (test de non-câblage vert). `index.js` et `professionalSubscriptions.js` apparaissaient déjà modifiés avant la mission ; non touchés ici.

## 5. Préparation de 2D-2 (intégration)

- `inspect()` lit le `wallet_transactions` de premier niveau, pas le sous-collection `clients/{uid}/wallet_transactions` : 2D-2 devra lire par `get` ponctuel `order_<id>` pour chaque id de `requiredWalletDebitIds`.
- Chaque inspecteur doit transmettre ses propres `terminalStatuses` et le détail `queries` réellement exécuté (cohérent avec `requiredQueries`).
- Les commandes non-v2 des flux devis ont aussi un journal `order_<id>` : extension possible, hors périmètre.

## 6. Réserves et interprétations à valider

1. **Registre de décisions** : le schéma (`status`, `subjectKind/Id/Type`, `resolution`, `tier`, `requestedBy/At`, `approvedBy/At`, `creditorConsentRef`, `creditor`, `contractRef`, `remaining`) est une proposition. Aucun écrivain n'existe ; sans lui, tout signalement `resolved` reste bloquant (comportement sûr).
2. Les niveaux par résolution (matrice `RESOLUTIONS`) traduisent mon interprétation des niveaux 1 à 3 de 7E-102, notamment `closed_by_contract` = niveau 3 et les résolutions du cas espèces client. À confirmer.
3. Le contrôle du débit wallet v2 ne s'applique qu'au rôle client ; livreur et partenaire ne vérifient que `isPaid`.
4. Les empreintes d'ids invalides (FNV-1a 32 bits) servent à distinguer, pas à protéger : collisions possibles en théorie, sans effet sur le caractère bloquant.
5. Un seul super-admin disponible : toutes les opérations de niveau 2 et 3 resteront en attente, par conception.
6. Aucun test device ou émulateur n'a été fait (hors périmètre).
