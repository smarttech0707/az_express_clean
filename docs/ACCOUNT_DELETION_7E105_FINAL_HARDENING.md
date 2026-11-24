# 7E-105 — Corrections finales des réserves 7E-104

Périmètre : `functions/accountObligations.js`, `functions/test/accountObligations.test.js` et ce rapport. Inspecteurs, `index.js`, lots 2C, P3, `professionalSubscriptions.js` non touchés. HEAD `d65c8f0`, index vide, aucun fichier supprimé, aucun émulateur, aucune commande distante. Entrées de travail : 97 préservées, plus les rapports 7E-103, 7E-104 et celui-ci.

## Verdict

**2D-1 PRÊT POUR AUDIT FINAL** — sous la condition, listée au §5, que Node 22.23.4 reste à valider (non disponible ici) et que le schéma du registre de décisions et de preuves soit repris tel quel par le futur écrivain. R1 à R7 sont corrigées et testées ; R8 à R13 sont examinées, aucune n'est un défaut du moteur.

## 1. Corrections

| Réf. | Correction |
|---|---|
| **R1** | `requestId` exigé dans `verifyDecision`, pour les signalements **et** les dossiers client : chaîne de 16 à 128 caractères sûrs (contrainte réelle de `reviewNonPayment`), identique sur la décision et chez l'appelant, et **unique** dans le registre (un même `requestId` sur deux décisions est refusé). `undefined`, `null`, vide, espace, trop court, trop long, non chaîne : bloquant. Le demandeur doit aussi être une identité conforme (sans espace). |
| **R2** | Niveaux alignés sur 7E-102 : `refuted_after_contest` passe de N1 à **N2**. Résolutions retirées de la matrice : `closed_by_contract`, `no_claim_established`. `paid_out_of_system` (client) devient `paid_by_client_out_of_system`, le nom de 7E-102. Aucune nouvelle résolution ajoutée. `waived_by_partner`, `waived_by_driver`, `written_off_by_platform` (et `partner_unreachable_held`, `order_payment_waived_by_platform`) sont absents de la matrice, donc refusés et bloquants ; la liste est exportée (`UNAUTHORIZED_RESOLUTIONS`) à titre documentaire. Toute valeur inconnue, y compris `__proto__` et `constructor`, suit la même règle. La logique `contractRef` est supprimée. |
| **R3** | Pour tout niveau ≥ 2, l'approbateur doit être présent, conforme, **différent du demandeur et du décideur initial**. Décideur initial : `decidedBy` du signalement ; pour un dossier client, `cashPayment.review.byUid` (celui qui a confirmé le non-paiement). Pour `cash_shortfall`, `seller_review`, `driver_advance_unreimbursed` et le dossier client, un décideur initial inconnu ou invalide laisse la résolution en attente. Pour les signalements créés par le système (`commission_untraced`, `partner_credit_missing`…), qui n'ont pas de décideur humain, seule la règle demandeur ≠ approbateur s'applique ; s'il existe un `decidedBy`, il est comparé. Aucune normalisation : une variante avec espace est refusée, pas tolérée comme « distincte ». `requestedAtMs` > 0 et `approvedAtMs ≥ requestedAtMs` exigés. |
| **R4** | Toute résolution dont le niveau minimal est 1 exige `evidenceRef` **et** un document de preuve fourni par l'appelant dans `evidence: [{id, exists, data}]`, lu côté serveur. Le document doit valoir `status:'verified'`, être lié à **cette** décision (`decisionId`), au même sujet (`subjectKind`, `subjectId`) et à la même résolution, avec `verifiedBy` conforme et `verifiedAtMs` entier positif. Une chaîne fournie seule, une preuve absente, `exists:false`, une preuve d'une autre décision, un registre non fourni ou en double : bloquant (`evidence_invalid` pour un registre mal formé). La preuve reste exigée si la décision est sur-validée (niveau 2). Elle n'est pas exigée pour N2 et N3 (hors périmètre demandé). |
| **R5** | `limit` doit valoir exactement 201 (`q.limit === READ_LIMIT`) ; 1, 100, 200, 202, etc. sont refusés. |
| **R6** | `requiredQueries` et le moteur dédoublonnent les identifiants du compte ; `['c1','c1']` produit un seul couple par clé. |
| **R7** | `safeId` est idempotent sur une valeur déjà neutralisée (`invalid:<8 hex>`) : le snapshot reprend les mêmes identifiants que le résultat. |

Impact des suppressions : le rapport 7E-103 présentait `closed_by_contract` et `no_claim_established` comme des interprétations ; elles sont retirées, le dossier reste alors bloquant jusqu'à une décision métier.

## 2. Constats R8 à R13

| Réf. | Examen | Conclusion |
|---|---|---|
| R8 | `remaining` et `tier` sont déclarés par la décision. Le moteur vérifie `remaining === 0` et `tier ≥ minimum` ; il ne peut pas recalculer `remaining` ni lier la décision à un compte ou à un montant. | **Non résolu côté moteur, par nature.** À imposer à l'écrivain (§4). |
| R9 | Trous de tests : dossier client sans demandeur et sans `requestId`, v2 non payée sans journal, signatures de preuve. | **Corrigé** : nouveaux tests (§3). |
| R10 | Commandes wallet non v2 sans preuve de journal. | **Non traité** : hors décision 10, nécessite une décision métier. |
| R11 | Correspondance document ↔ requête non vérifiable. | **Inhérent**, non traité. Le reçu de couverture de 2D-2 en portera la preuve. |
| R12 | Signalements Ekbine par `agentId` : `flag_without_party`, bloquant. | **Fail-closed**, hors périmètre. |
| R13 | Une falsification cohérente du résultat avant le snapshot n'est pas détectable. | **Inhérent.** À neutraliser en 2D-2 : évaluer puis construire le snapshot dans la même fonction, sans stockage intermédiaire. |

## 3. Tests

`node --test test/accountObligations.test.js` : **52 tests, 52 réussis** (43 avant ; les tests des décisions sont réécrits, 9 ajoutés). Nouveaux ou réécrits :
- matrice des résolutions égale à une table indépendante ; valeurs non autorisées absentes ;
- chaque résolution autorisée ferme avec un jeu valide, et reste bloquante avec un niveau, un approbateur ou un accord de créancier en moins ;
- R1 : 12 valeurs de `requestId` invalides côté signalement, 7 côté dossier client, clé absente, `requestId` du signalement différent, `requestId` partagé ;
- R3 : approbateur = demandeur, = décideur initial, manquant, vide, avec espaces, horodatages ; décideur initial manquant ; dossier client (auteur de la revue) ; type sans décideur humain ;
- R4 : six résolutions N1 × (preuve absente, registre non fourni, référence absente ou inventée, 12 variantes de preuve invalide, document absent, preuve réutilisée par une autre décision, sur-validation, `exists:false` avec données, identifiant non conforme, doublon) ;
- valeurs non autorisées × tous les types × niveau 3 maximal ;
- dossier client : `refuted_after_contest` et `paid_by_client_out_of_system` exigent N2 ; un seul responsable reste en attente ; autres noms refusés ;
- commande v2 non payée sans journal ; R5, R6, R7.

Mutations ciblées sur une copie hors dépôt : **42 mutants nouveaux, 39 tués, 3 survivants équivalents** (`own(RESOLUTIONS, …)` remplacé par un accès direct, le type étant déjà restreint à une liste blanche ; validation du tableau `evidence`, car chaque entrée non conforme est de toute façon signalée ; dédoublonnage des ids dans le moteur, sans effet puisque les couples sont comparés par ensemble). Série de 7E-103 rejouée : 39 applicables tués, 6 motifs devenus sans objet après réécriture, couverts par les nouveaux mutants. Mutant « dossier client fermé sans décision » : tué. Le module du dépôt n'a jamais été muté.

Voisins : 8 fichiers, **197/197** inchangés.

## 4. Contrat pour le futur écrivain (proposition, à confirmer)

Décision : `status:'executed'`, `subjectKind`, `subjectId`, `subjectType`, `resolution`, `requestId`, `requestedBy`, `requestedAtMs`, `tier` (calculé par le serveur depuis la matrice, jamais fourni), `remaining`, selon le niveau `approvedBy`, `approvedAtMs`, `creditorConsentRef`, `creditor`, et pour N1 `evidenceRef`. Preuve (collection serveur seule) : `status:'verified'`, `decisionId`, `subjectKind`, `subjectId`, `resolution`, `verifiedBy`, `verifiedAtMs`. L'écrivain doit : vérifier que demandeur et approbateur sont des super-admins réels et distincts ; poser les horodatages ; rendre le registre append-only ; dériver `creditor` du type ; recalculer `remaining` ; construire la preuve en vérifiant la ligne de journal ou le document réel ; ne jamais copier une valeur du client. Il n'existe qu'un seul super-admin aujourd'hui : toutes les résolutions N2 et N3 resteront en attente.

## 5. Points non résolus et limites

1. **Node 22.23.4 non disponible** : seule l'installation `C:\Program Files\nodejs` (v24.22.1) existe, aucun gestionnaire de versions. Rien n'a été installé. Tests exécutés sous 24.22.1 uniquement ; **Node 22 n'est pas validé**.
2. `creditorConsentRef` (niveau 3) reste une chaîne non vérifiée : l'exigence de preuve serveur ne concernait que N1. À traiter si N3 est un jour autorisé.
3. Le moteur ne vérifie pas l'authenticité des documents `decisions` et `evidence`, il suppose qu'ils sont lus par le serveur dans des collections en écriture serveur seule.
4. Le délai de réflexion de 24 h proposé en 7E-102 n'est pas décidé ni codé.
5. R8, R10, R11, R12, R13 : voir §2.
6. Contrat de lecture wallet pour 2D-2 : inchangé (rapport 7E-104 §8).

Je m'arrête ici. 2D-2 n'est pas commencé.
