# Mission 7E-108 — Audit indépendant final avant 2D-2

Périmètre : `functions/accountObligations.js` et son test, après 7E-107. Lecture seule sur le code et les tests ; seul ce fichier est créé. Aucun commit, push, déploiement, accès distant, émulateur ni staging. 2D-2 n'est pas commencé.

## Verdict

**2D-1 VALIDÉ SOUS RÉSERVES**

Je n'ai trouvé aucun chemin fail-open dans le moteur sur les points audités. Les conditions d'intégration ne sont pas toutes « satisfaites » : C5 (Node 22.23.4) est impossible ici, C8 (budget de lectures) n'est pas mesuré, C6 et C7 sont des livrables de 2D-2 qui n'existent pas encore. Ces quatre points empêchent le verdict le plus haut.

## 0. État vérifié

- HEAD `d65c8f0`, index vide (0 fichier indexé). 102 entrées de statut : les 101 entrées de travail préservées plus le rapport 7E-107. Ce rapport sera la 103e.
- Module : empreinte `40ebef4416f25b12` (inchangée depuis 7E-107). Tests : `6999ef71f727b17a`.
- Node disponible : **v24.22.1 uniquement**. Node 22.23.4 est absent (`package.json` exige 22). Je n'ai rien installé. Aucune validation sous Node 22 n'est donc revendiquée.
- Tests du module : 60/60 réussis.
- Suite complète `node --test test/*.test.js` : 2410 tests, 2241 réussis, **0 échec**. Je n'ai pas détaillé la nature des 169 restants (sans doute ignorés ou à statut spécial).
- Mutations, rejouées sur copie (script de 7E-107, 44 mutants) : **44 tués, 0 survivant**. Quatre motifs multi-lignes n'étaient pas trouvés à cause des fins de ligne CRLF ; je les ai rejoués après normalisation de la copie. Le dépôt n'a pas été modifié.

## 1. Corrections de 7E-107

| Correction | Constat |
|---|---|
| N3 bloquant (`flag_level3_unavailable`) | Deux gardes : résolution de niveau ≥ 3 et `tier === 3` déclaré. Les mutants qui retirent chaque garde sont tués. |
| Ekbine `debit_disproved` en N2 | Présent dans la matrice pour les deux types Ekbine. Les deux mutants « niveau 1 » sont tués. |
| Décideur initial requis | Liste d'origine : cash_shortfall, seller_review, driver_advance_unreimbursed, client_cash_nonpayment et les deux types Ekbine. Origine absente ⇒ bloquant. Les trois mutants qui retirent un type de la liste sont tués. |
| Preuve hors système | Une résolution hors système exige une preuve serveur avec statut, appariement décision/sujet/résolution, montant, devise XOF, bénéficiaire, commande, `paymentRef`, `contentHash` hex64 et `immutable:true`. 11 mutants sur ces champs sont tués. |
| Génération des écrivains | v2 / devis / historique via `walletGeneration`. Les mutants sont tués. |

## 2. Wallet v2 et devis serveur

- Journal `clients/{uid}/wallet_transactions/order_<id>` exigé : `type:'payment'`, `orderId` égal, montant égal à `totalAmount` (v2) ou `budget + shoppingBudget` (devis).
- Absent ou divergent ⇒ REVUE (bloquant). Journal non fourni ⇒ AMBIGU (bloquant). Montants incohérents ⇒ AMBIGU.
- Limite : le module ne peut pas prouver l'authenticité des documents fournis. C'est la tâche du lecteur de 2D-2 (C7).

## 3. Commandes historiques et `manual_review` (décision complémentaire R10)

Sondes exécutées sur le module réel (scratchpad, aucune écriture dans le dépôt) :

| Cas | Résultat |
|---|---|
| Commande wallet historique seule | non bloquante ; 1 entrée `manual_review` (`legacy_wallet_payment_unproven`) |
| + `refundPending` / `needsReview` / `paymentStatus pending` | bloquant (obligations `open`/`review`) |
| + `settlementHold` / `heldDriverEarning` non réglé | bloquant |
| + `deliveryFeeHold` ou `cancelRequestAfterPickup` au statut non reconnu | bloquant (ambigu) |
| + drapeau `refundPending` non booléen | bloquant (ambigu) |
| + `isPaid` faux ou absent | bloquant ; pas de `manual_review` (dette réelle ou ambiguë) |
| + statut inconnu | bloquant (ambigu) |
| + drapeau de réconciliation ouvert (`cash_payment_review`) | bloquant |

Contrôle des conditions de la décision R10 :
1. Pas de journal garanti ET pas de preuve positive de non-paiement : un `manual_review` non bloquant n'apparaît que si `isPaid === true`, la commande est livrée en wallet, hors boutique, et sans marqueur v2 ni devis.
2. Aucune contradiction financière : toutes les contradictions sondées ci-dessus restent bloquantes, et l'entrée `manual_review` coexiste avec elles sans les masquer.
3. Référence et historique conservés : l'entrée porte `orderId`, `refId`, `status`, `claim`, `economicKey` ; le snapshot la conserve dans `items` et `counts.manualReview`. Aucune donnée personnelle (pas de nom, téléphone ni adresse).
4. Jamais présentée comme paiement confirmé : état `manual_review`, `amount: null`, raison explicite. Le test `snapshot : revue manuelle conservée sans devenir bloquante, jamais falsifiable en règlement` couvre la normalisation.

Réserve : `manualReviewRequired` du snapshot signifie « lecture tronquée » et reste faux pour un cas historique non bloquant. Le consommateur de 2D-2 doit lire `counts.manualReview` et ne pas confondre les deux. À écrire dans le contrat C7.

Cas client hors système : `paid_by_client_out_of_system` reste indisponible, aucune créance n'étant définie (créancier, montant, preuve). Je n'ai inventé aucune créance ; le mutant « claim tiré de la décision » est tué.

## 4. Preuves de paiement réellement rapprochées

La créance est calculée par le moteur à partir du flag (`sellerId` pour partner_credit_missing, `driverId` pour driver_advance_unreimbursed) et du montant. La preuve doit correspondre sur tous les champs ; une référence en texte libre ne suffit pas. Chaque champ a un mutant tué.

## 5. Niveaux N1 / N2 / N3

- N1 : preuve serveur exigée, sauf cas explicitement sans preuve.
- N2 : approbateur ≠ demandeur et ≠ décideur initial ; `approvedAtMs ≥ requestedAtMs > 0`.
- `requestId` : motif `^[A-Za-z0-9_.:-]{16,128}$`, égal entre décision, flag et appelant, unique dans le registre fourni.
- Résolutions non autorisées (`closed_by_contract`, `no_claim_established`, `waived_by_partner`, `waived_by_driver`, `written_off_by_platform`) : absentes de la matrice ⇒ bloquantes.

## 6. N3 bloquant dans tous les cas

Testé : consentement absent, présent mais non vérifié, deux approbateurs. Dans tous les cas la résolution reste bloquante. Aucun chemin N3 n'est autorisé tant que le contrat de consentement n'existe pas.

## 7. Résolutions Ekbine

`debit_proven_and_settled` en N1 ; `debit_disproved` et `refunded_by_ledger` en N2 ; décideur initial requis. Les flags Ekbine n'ont pas de `decidedBy` (`ekbineOrders.js:266,320`), donc l'origine est absente par défaut et le cas reste bloquant jusqu'à ce que le writer de 2D-2 la fournisse.

## 8. Les huit conditions d'entrée de 2D-2 (7E-106 §10)

| # | Condition | Preuve ou manque |
|---|---|---|
| C1 | N3 bloquant avec test négatif | **Satisfaite.** Garde du module, tests négatifs, deux mutants tués. |
| C2 | Décision R10 | **Satisfaite côté moteur.** Décision métier reçue ; sondes ci-dessus. |
| C3 | Niveaux Ekbine et lecture « demandeur = décideur initial » | **Satisfaite côté moteur.** Matrice et tests présents. Reste à confirmer par le métier que l'origine Ekbine sera bien fournie par le writer. |
| C4 | Tests manquants | **Satisfaite.** 60 tests ; origine seller_review et driver_advance couverte ; preuve N2 testée. |
| C5 | Tests sous Node 22.23.4 | **Non satisfaite.** Node 22.23.4 absent ; validé sous Node 24.22.1 seulement. À exécuter en CI ou sur machine équipée. |
| C6 | Spécification du writer du registre et des preuves, `requestId` unique | **Manque.** Le schéma est proposé dans les rapports mais aucun writer n'existe. Le module ne vérifie l'unicité qu'au sein du registre fourni. |
| C7 | Contrat de lecture de 2D-2 | **Manque (livrable de 2D-2).** Le module fournit `requiredQueries` (limite 201) et `requiredWalletDebitIds`, et signale la troncature. Les lectures ponctuelles, le reçu de couverture et l'échec sur erreur de lecture restent à construire. |
| C8 | Budget de lectures mesuré en préproduction | **Non satisfaite.** Rien n'est mesuré. |

## 9. Conservation des références historiques après anonymisation

`accountDeletion.js` ne supprime que des champs personnels explicites du profil et des commandes liées, et conserve les documents `orders` (identifiants, montants, statuts). `orderId` et `economicKey` restent donc des références stables. Les entrées du snapshot ne contiennent que des identifiants techniques, des montants, un statut et une raison. Le moteur ne lit pas les inspecteurs et je ne les ai pas modifiés. Non vérifié : le comportement réel du nettoyage sur des données de production.

## 10. Limites et réserves restantes

1. Node 22.23.4 non disponible ; aucune validation sous la version cible.
2. Le module ne peut pas authentifier décisions, preuves ni journaux. Il suppose un lecteur serveur honnête.
3. Unicité du `requestId` limitée au registre fourni.
4. Niveau, `remaining` et origine sont déclarés par l'appelant ; le writer doit les calculer.
5. Correspondance document ↔ requête non vérifiable par le module.
6. Flags Ekbine identifiés par `agentId` seul ⇒ `flag_without_party` (bloquant).
7. Une falsification cohérente faite avant l'instantané n'est pas détectable.
8. Délai de réflexion de 24 h : non approuvé et non implémenté.
9. Les périodes des écrivains historiques reposent sur les dates de commit, pas sur les déploiements ; l'état de production est inconnu.
10. Je n'ai pas expliqué les 169 tests non réussis de la suite complète (probablement ignorés).

Je m'arrête ici. Aucune suite n'est engagée sans autorisation humaine explicite ; 2D-2 n'est pas commencé.
