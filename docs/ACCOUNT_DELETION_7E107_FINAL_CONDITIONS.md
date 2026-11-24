# 7E-107 — Levée des conditions finales de 2D-1

Fichiers modifiés : `functions/accountObligations.js`, `functions/test/accountObligations.test.js` et ce rapport. Inspecteurs, `index.js`, lots 2C, P3, `professionalSubscriptions.js` non touchés. HEAD `d65c8f0`, index vide, aucun fichier supprimé, aucun émulateur, aucune commande distante. Entrées de travail : 101 avant ce rapport (97 d'origine + rapports 7E-103 à 7E-106), toutes préservées.

## Verdict

**2D-1 PRÊT POUR INTÉGRATION CONDITIONNELLE.**

Les six décisions (C1, R10, Ekbine, origine, tests seller_review et driver_advance, paiement hors système) sont appliquées et testées. Les conditions d'entrée dans 2D-2 sont au §9. Deux points relèvent d'une interprétation de ma part et doivent être confirmés : le traitement non bloquant des commandes wallet historiques (§2) et le blocage de `paid_by_client_out_of_system` (§6).

## 1. C1 — Consentement N3

1. **Décision appliquée.** Toute résolution de niveau 3 est indisponible : `verifyDecision` renvoie `flag_level3_unavailable` si la résolution est de niveau 3 **ou** si la décision déclare `tier: 3`, avant tout autre contrôle sur le consentement. Ni la chaîne `creditorConsentRef`, ni un document de consentement fourni comme preuve, ni deux ou trois approbateurs, ni le créancier `az_express` ne peuvent fermer le dossier. La seule résolution de niveau 3 connue est `waived_platform_claim` ; elle reste dans la matrice à titre documentaire.
2. **Fichiers.** Module (`verifyDecision`, suppression du code de consentement et de renonciation devenu inatteignable) et tests.
3. **Tests.** Test C1 : consentement absent, présent mais non vérifié, deux approbateurs, trois responsables, document de consentement « vérifié » fourni dans `evidence`, niveaux 1 à 4, niveau 3 déclaré sur une résolution de niveau 2. Tous bloquants, aucun élément conservé. La boucle sur la matrice complète vérifie aussi que toute résolution de niveau 3 reste bloquée. Une mutation supprimant la première barrière survit : équivalente, la seconde (`tier === 3`) suffit.
4. **Réserve.** Le contrat futur du consentement reste celui du rapport 7E-106 §4. Sans lui, la renonciation de créance est impossible.

## 2. R10 — Commandes wallet non v2 : générations d'écrivain

### Écrivains réels (sources lues)

| Génération | Écrivain | Garantie de journal | Preuve disponible |
|---|---|---|---|
| **v2** | `partnerOrderQuote.js:298` (Restaurant, Boulangerie), commits du 2026-11-03 | `clients/{uid}/wallet_transactions/order_<orderId>` écrit **dans la même transaction** que la création ; `type:'payment'`, `amount = totalAmount` | journal déterministe |
| **devis serveur** | `catalogQuote.js:198` (Colis, Blanchisserie, Eau & Boissons) et `deliveryQuote.js:207` (Livraison, Courses), commits du 2026-11-03 | même journal `order_<orderId>`, même transaction, `amount = budget + shoppingBudget` (`catalogTariff.js:185`, `deliveryQuote.js:200`) ; la commande porte `tariffQuoteId` | journal déterministe |
| **historique A : création client Flutter** | `delivery_order_service.dart:71-91` (et écrans équivalents) : débit du `wallet` + `lastPaidOrderId` dans une transaction **cliente** ; règle Firestore `walletDebitMatchesPaidOrder` (`firestore.rules`, introduite par le commit du 2026-08-25) | **aucun journal garanti** dans `clients/{uid}/wallet_transactions` ; la règle protège la cohérence débit/commande à la création, pas un document de preuve | aucune par document |
| **historique B : règlement après livraison** | `payOrderFromWalletCF`, `orderActions.js:55-160` (pharmacie, anciennes commandes), depuis 2026-07-02 | `isPaid:true` est posé dans la **transaction de débit** ; le journal est ajouté **après** la transaction, avec identifiant automatique (`orderActions.js:142`) | `isPaid` fiable, journal non garanti ni retrouvable par identifiant |

Période à risque (à vérifier, voir réserve) : entre l'assouplissement de la règle de création (commentaire de la règle : 2026-07-19) et `walletDebitMatchesPaidOrder`, un client malveillant pouvait créer plusieurs commandes `isPaid:true` pour un seul débit. Les dates ci-dessus sont des dates de **commit** ; je n'ai pas pu établir les dates de déploiement en production (aucun accès distant).

### Décision appliquée

- **v2 et devis serveur** (générations avec journal garanti) : le client doit avoir le journal `order_<id>`, de type `payment`, avec le bon `orderId` et le bon montant. Journal absent ou divergent : **revue bloquante** (`*_wallet_debit_missing` / `*_wallet_debit_mismatch`, montant renseigné). Journal non fourni par l'appelant : ambigu bloquant (défaut d'appel). Montants inexploitables : ambigu bloquant.
- **Historique** (A et B) : le journal n'est pas garanti, donc on ne l'exige pas. La commande n'est **ni une dette inventée ni un règlement déclaré** : elle reçoit un nouvel état **`manual_review`**, type `legacy_wallet_payment_unproven`, montant nul, listé dans un tableau distinct `manualReview` du résultat et du snapshot (compteur `manualReview`). Cet état est **non bloquant**.
- Seul le **client** est concerné (le payeur). Commandes annulées, non livrées, espèces, boutique : exclues. Une commande historique `isPaid:false` reste une dette bloquante.

### Pourquoi non bloquant

Presque toute commande Livraison/Courses payée par wallet **avant le 2026-11-03** est de génération A, et toute commande pharmacie payée à la livraison de génération B. Bloquer ces commandes bloquerait la quasi-totalité des clients qui ont déjà utilisé le wallet, ce que la consigne interdit. Le moteur ne déclare cependant jamais ces commandes « réglées » : elles apparaissent dans `manualReview`, avec un compteur persistable dans le snapshot, pour une revue humaine ultérieure.

### Tests

Devis serveur : journal conforme, absent, divergent (7 variantes), non fourni, montants inconsistants (7 variantes), sans achats, `isPaid:false`, livreur et partenaire non concernés, commandes exclues. Historique : non bloquant, non réglé, non dette, exclusions, dette historique `isPaid:false` restant bloquante, mélange de générations, revue manuelle plus vraie dette. v2 : état revue / ambigu. Snapshot : conservation, déterminisme, suppression ou vidage de `manualReview`, valeurs non tableau, élément glissé dans les obligations, vraie dette glissée dans `manualReview`, mauvais type. Mutations ciblées : générations, état, comptage, blocage.

### Réserves R10

1. **Décision métier à confirmer** : traiter la génération historique en revue manuelle non bloquante est mon interprétation de « ne pas les déclarer réglées » + « ne jamais bloquer tous les clients ». Si vous préférez les bloquer, ou les bloquer seulement sur la période à risque, c'est une modification mineure du moteur (changer l'état) mais une décision de gestion.
2. Le moteur ne distingue pas A et B (rien dans le document de commande ne les sépare) ni ne repère la période à risque (il faudrait `createdAt` et des dates de déploiement établies).
3. Les commandes marketplace et assimilées non listées ci-dessus tombent dans la génération historique par défaut. Un écrivain non identifié ne donne jamais de blocage ni de règlement automatique.
4. L'état de déploiement de production n'a pas pu être établi : si les fonctions de devis ne sont pas encore déployées, toutes les commandes de production sont historiques.

## 3. Ekbine — `debit_disproved`

1. **Décision appliquée.** `debit_disproved` passe au niveau N2 pour `ekbine_cancel_unproven_debit` et `ekbine_confirm_unproven_debit`. Les types Ekbine rejoignent la liste des types dont le décideur initial est obligatoire : décideur initial absent ou invalide ⇒ bloquant. Approbateur distinct du demandeur et du décideur initial.
2. **Tests.** Les deux types : cas positif, un seul responsable, second responsable absent, approbateur = demandeur, approbateur = décideur initial, décideur initial absent ou vide, demandeur = décideur initial (autorisé), variante avec espace, `refunded_by_ledger` (N2 aussi), `debit_proven_and_settled` (N1 avec preuve), signalement par `agentId` seul (bloquant).
3. **Conséquence à connaître.** Les écrivains actuels (`ekbineOrders.js:266` et `:320`) ne posent **pas** de `decidedBy` : tant que le futur outil n'enregistre pas un décideur initial, aucune résolution N2 Ekbine ne peut se fermer (comportement demandé).

## 4. Demandeur et décideur initial

Confirmé par tests, pour les huit résolutions N2 concernées et pour le dossier client : le demandeur **peut** être le décideur initial ; l'approbateur ne peut être ni l'un ni l'autre. Cas « les trois identiques » : bloquant. Aucune différence artificielle n'est imposée entre demandeur et décideur initial.

## 5. seller_review et driver_advance_unreimbursed

Tests ajoutés, pour les résolutions N2 de chaque type : décideur initial présent et approbateur indépendant (ferme) ; décideur initial absent ou nul (bloquant) ; approbateur = décideur initial (bloquant) ; approbateur = demandeur (bloquant) ; demandeur = décideur initial (ferme). Les résolutions N1 (`reimbursed_by_ledger`) n'exigent pas de décideur initial (la preuve l'est). Les mutations qui retirent `seller_review` ou `driver_advance_unreimbursed` de la liste sont maintenant tuées.

## 6. `paid_out_of_system`

1. **Décision appliquée.** Trois résolutions « hors système » : `paid_out_of_system` (partenaire), `reimbursed_out_of_system` (livreur), `paid_by_client_out_of_system` (client). Chacune exige deux validations (N2) **et** un document de preuve lu côté serveur, vérifié, lié à la décision, au sujet et à la résolution, contenant : `amount` égal à la créance du signalement, `currency` `XOF`, `beneficiaryId` égal au bénéficiaire de la créance (partenaire : `sellerId` ; livreur : `driverId`), `orderId` égal à celui du signalement, `paymentRef` conforme, `contentHash` hexadécimal de 64 caractères, `immutable:true`. La créance (montant, bénéficiaire, commande) est calculée **par le moteur** depuis le signalement, jamais depuis la décision ni la preuve ; si elle est inexploitable (montant absent, nul, négatif ou texte, bénéficiaire ou commande absents), la résolution reste bloquante, y compris lorsque la preuve « vide » ressemble à la créance « vide ».
2. **`paid_by_client_out_of_system` est indisponible.** La créance du client n'a ni titulaire ni montant de référence définis (7E-102 §M-5 : « à fixer »), donc aucune concordance de bénéficiaire n'est possible. Le dossier client reste bloquant même avec deux approbateurs et une preuve plausible. Seule `refuted_after_contest` (N2) ferme un dossier client.
3. **Tests.** Cas positif, un seul responsable, même personne, preuve absente ou non lue, référence textuelle seule, 28 variantes de preuve invalide (montant, devise, bénéficiaire, commande, référence, empreinte, immuabilité, statut, décision), créances inexploitables, montants divergents, preuve réutilisée par une autre décision, preuve et créance « vides ».
4. **Réserve.** « Immuable » est attesté par `immutable:true` et `contentHash` dans un document lu côté serveur ; le moteur ne peut pas vérifier l'immutabilité réelle (règles Firestore du futur écrivain : création sans modification).

## 7. Node.js

Node **22.23.4 non disponible**. Seule installation : `C:\Program Files\nodejs\node.exe`, v24.22.1 (vérifié par `where`/recherche, aucun gestionnaire de versions). Rien n'a été installé ni modifié. Les résultats ci-dessous sont **des résultats Node 24.22.1**, distincts d'une validation Node 22 (non faite).

## 8. Résultats

- `accountObligations.test.js` : **60 tests, 60 réussis** (Node 24.22.1). Précédemment 52 : 8 ajoutés, 6 adaptés.
- Voisins (`accountDeletionHardening`, `manualAccountDeletion`, `accountDeletionSupport`, `accountQuarantineGuards`, `accountQuarantineIndex`, `orderActions`, `transferSettlement`, `partnerOrderFinancial`) : **197/197**.
- Mutations ciblées sur copie hors dépôt : **48 mutants, 46 tués, 2 équivalents** (barrière redondante du niveau 3 ; type de `manualReview` non tableau, qui échoue de toute façon à l'itération). Le dépôt n'a jamais été muté.
- Empreintes finales : module `40ebef4416f25b12`, tests `6999ef71f727b17a`.

## 9. Conditions d'entrée dans 2D-2

1. Confirmer la politique des commandes wallet historiques (§2) et, si besoin, la période à risque.
2. Confirmer l'indisponibilité de `paid_by_client_out_of_system` jusqu'à définition du titulaire et du montant de la créance client.
3. Exécuter les tests sous Node 22.23.4 (CI ou machine équipée).
4. Spécifier le writer du registre `decisions`, `evidence` (collections serveur seule), des contraintes de §6, et l'unicité des `requestId` (7E-105 §4, 7E-106 §3).
5. Contrat de consentement N3 (7E-106 §4) avant d'ouvrir le niveau 3.
6. Contrat de lecture : requêtes `requiredQueries`, journaux `order_<id>` pour les générations v2 et devis (`requiredWalletDebitIds`) par lecture ponctuelle de `clients/{uid}/wallet_transactions`, `decisions` et `evidence`, reçu de couverture, snapshot construit dans la même fonction, échec sur toute erreur de lecture. Un inspecteur qui veut traiter `manualReview` comme bloquant doit le décider explicitement.
7. Réserves ouvertes de 7E-106 non concernées par cette mission : lecture « demandeur = décideur initial » (confirmée ici par tests), preuve N2 hors système (traitée ici), consentement N3 (bloqué ici).
8. Mesure du budget de lectures en préproduction avant tout déploiement.

Je m'arrête ici. 2D-2 n'est pas commencé.
