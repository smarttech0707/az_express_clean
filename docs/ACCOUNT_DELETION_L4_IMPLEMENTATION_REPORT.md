# Mission L4 — Sécurisation des paiements, annulations et livraisons

Statut : **implémentée dans le périmètre autorisé, avec réserves et décisions encore bloquantes (§4)**. Aucun commit, push, déploiement ni accès à `az-express-b0469` / préprod ; L5 à L7 non lancées ; `feexpayPayments.js` et le webhook non touchés.

## 0. Signalements documentaires

1. `docs/ACCOUNT_DELETION_L4_L7_PLANNING_REPORT.md` **n'existe pas dans le dépôt** : la planification n'a été donnée que dans la conversation. Les décisions A–E de la consigne ont servi de référence.
2. DR1–DR3 (7E-97) restent des règles **« dérivées, à relire »** (7E-97 R5, 2D2A5 D-8). Elles ne sont pas passées en règles approuvées : l'implémentation suit les décisions A–E de la consigne, qui prévalent là où elles divergent (voir §4.1 pour la contradiction avec DR1/D6-c).
3. Le rapport L3 (§11) étiquette mal L4–L7 ; non corrigé ici (hors périmètre).
4. Le paragraphe 7E-97 §6.6 impose le message Flutter « Ce paiement est suspendu : le support AZ Express va le traiter. Rien n'a été débité. » — appliqué tel quel.

## 1. Résumé des changements

**Garde centrale (`accountClosureActor.js`, non suivi)** : `closureGuard` examine chaque bénéficiaire séparément (tombstone puis profil) avec une politique par partie :
- actif / suppression demandée : l'effet s'applique ;
- quarantaine simple : `onQuarantine` = `skip` (crédit omis, montant tracé), `refuse` (opération refusée sans écriture, défaut) ou `apply` (débit de restitution, epoch+1) ;
- scellé (ou suppression Auth commencée) / anonymisé / absent : `onClosed` = `skip` ou `refuse` (défaut) ;
- tombstone illisible : **toujours refusé**, même avec `onClosed:'skip'` ; une erreur de lecture se propage (aucun crédit).
Ajouts : `assertNotUnderReview` (verrou `ORDER_UNDER_REVIEW`), `REVIEW_REASON` (`beneficiary_closed` levable / `beneficiary_credit_omitted` non levable), `recordBeneficiaryRefusal` met aussi la commande en revue (idempotent). `assertFinancialLock` n'est plus utilisé.

**`payOrderFromWalletCF`** : livreur ou pharmacie crédité en quarantaine, scellé, anonymisé, absent ou illisible ⇒ paiement refusé en entier (`BENEFICIARY_ACCOUNT_CLOSED`), aucun débit, trace `reconciliation_flags/<orderId>_pay_beneficiary_refused` (`completed:false`) + commande `needsReview`. Succès : débit client, crédit livreur / pharmacie, **journaux `pay_order_<orderId>` et `earning_pay_order_<orderId>` écrits dans la même transaction** (identifiants déterministes, plus d'`.add()` post-transaction), `paidAt` / `paidBy`. Toutes les lectures précèdent les écritures. Message d'erreur préfixé `PAYMENT_ORDER_NOT_PAYABLE:` / `ORDER_UNDER_REVIEW:` pour le client Flutter.

**`cancelOrderCF` / `cancelOrderTx`** : le client est **toujours remboursé**. Remboursement de commission d'un livreur en quarantaine, scellé, anonymisé ou absent : **aucun crédit**, `commissionStatus` reste `charged`, signalement `<orderId>_beneficiary_closed` (parties, état, motif, `amountWithheld`) + commande `needsReview` / `beneficiary_credit_omitted`, dans la même transaction. Vendeur marketplace : débit appliqué en quarantaine (restitution, epoch+1) ; vendeur scellé / anonymisé / absent ⇒ **annulation refusée** (sous-cas suspendu, voir §4.3). Enveloppée dans `withRefusalTrace`. Un compte scellé n'est jamais rouvert (tombstone inchangé, testé).

**`deliverOrderCF` / `confirmOrderDeliveryWithProof`** : partenaire scellé / anonymisé / **absent (introuvable)** ⇒ livraison refusée, aucun crédit, trace idempotente + revue (résolution administrative explicite). Partenaire en quarantaine ⇒ livraison faite, crédit partenaire **omis**, somme conservée côté AZ et tracée (`<orderId>_partner_credit_held`, montant) + revue `beneficiary_credit_omitted`. Commande en revue `beneficiary_closed` ⇒ livraison refusée (`ORDER_UNDER_REVIEW`) hors confirmation administrative (`adminConfirmDeliveryCF` inchangée).

**`adminBilling.js`** : nouvelle action `clearBeneficiaryReview` (super-admin, justification ≥ 10 caractères, audit). Ne lève que `beneficiary_closed` ; les revues « crédit non versé » sont refusées (`REVIEW_NOT_CLEARABLE`) ; idempotente par l'état (rejeu = `replay:true`, aucune écriture) ; marque les signalements `*_beneficiary_refused` ouverts comme `cleared` ; ne crédite rien, ne modifie aucun tombstone / profil : les gardes sont ré-évaluées au prochain paiement / livraison, donc un bénéficiaire encore fermé est refusé de nouveau (pas de crédit rétroactif).

**Flutter** : `paymentErrorMessage` (top-level, `@visibleForTesting`) dans `suivi_commande.dart` ; `BENEFICIARY_ACCOUNT_CLOSED` et `ORDER_UNDER_REVIEW` ⇒ message de suspension sans état interne ni donnée du bénéficiaire ; `PAYMENT_ORDER_NOT_PAYABLE` ⇒ message dédié ; autres erreurs inchangées.

`orderRefunds.js` : **non modifié** (autoExpire / limite de débit relèvent de L5, voir §6).

## 2. Fichiers

Modifiés (suivis) : `functions/orderActions.js` (déjà modifié avant L4), `functions/adminBilling.js` (nouveau dans la liste), `lib/screens/client/suivi_commande.dart` (nouveau), `functions/test/orderActions.test.js` (nouveau : attentes des journaux du chemin heureux adaptées).
Non suivis modifiés : `functions/accountClosureActor.js`, `functions/test/accountClosureExceptions.test.js`, `functions/test/accountClosureLock.test.js` (assertion de câblage assouplie : le socle n'est plus importé directement par `orderActions.js`, seuls les writers L3 restent autorisés).
Créés : `functions/test/beneficiaryReviewL4.test.js` (8 tests), `functions/test/orderActionsL4.emulator.test.js` (4 tests), `test/screens/client/suivi_commande_payment_message_test.dart` (3 tests), ce rapport.
Aucun des cinq fichiers sensibles n'est modifié.

Tests existants adaptés (et pourquoi) : tests L3 qui décrivaient l'ancienne politique (livreur en quarantaine crédité à la création du paiement / à l'annulation ; scellé ⇒ annulation refusée) remplacés par la politique des décisions A–D ; le retry d'un refus tombe désormais sur `ORDER_UNDER_REVIEW` (verrou voulu) ; instantané « hors trace » ignore les trois champs de revue ajoutés à la commande ; journaux du test heureux de `payOrderFromWalletCF` vérifiés dans le magasin plutôt que via `.add()`.

## 3. Décisions métier appliquées

| Décision | Application |
|---|---|
| A scellé en annulation | client remboursé, aucun crédit, signalement idempotent, jamais rouvert |
| B absent | aucun crédit, signalement, jamais traité comme actif |
| C anonymisé | aucune opération financière sur le compte (omission signalée / refus) |
| D quarantaine (choix A) | aucun nouveau crédit au bénéficiaire ; sommes non versées conservées côté AZ avec montant tracé ; ne bloque pas les autres acteurs sauf quand aucune retenue sûre n'existe (paiement, §4.2) |
| E partenaire introuvable | livraison refusée, aucun crédit, signalement idempotent, revue + résolution administrative explicite |

## 4. Décisions encore bloquantes (aucune improvisation)

1. **Contradiction D6-c/DR1 ↔ décision D** : la spécification 7E-97 créditait un bénéficiaire en quarantaine (cancel) ; la décision D l'interdit. J'ai suivi D. Les sommes omises (« crédit non versé ») n'ont **aucun mécanisme de règlement** : `clearBeneficiaryReview` ne les lève pas, et le montant est seulement tracé dans les signalements. Décider : voie de règlement (crédit après résolution du dossier, ou acquis AZ).
2. **Paiement avec livreur / pharmacie en quarantaine** : la somme serait prélevée au client sans pouvoir être versée ; aucun mécanisme de retenue sûr n'existe pour la part pharmacie (le livreur dispose de `heldDriverEarning` uniquement pour les courses transférées). Par prudence : **paiement refusé en entier**. Décision demandée : créer une retenue (comme `settlementHold`) ou garder le refus.
3. **Vendeur marketplace anonymisé / scellé / absent à l'annulation** : non tranché. Sous-cas **suspendu** : annulation refusée (fail-closed), ni débit, ni remboursement, ni compensation inventés ; en quarantaine, le débit de restitution reste appliqué.
4. **Crédits propres de l'acteur** (remboursement du client, gain du livreur qui exécute) en quarantaine : laissés inchangés (la quarantaine concerne le destinataire d'un autre compte) ; l'ambiguïté du « choix A » est à confirmer.
5. **Résolution du refus de paiement** : après levée, le paiement redevient possible seulement si le bénéficiaire est redevenu créditable ; sinon la commande reste bloquée. Une livraison à partenaire introuvable se résout par `adminConfirmDeliveryCF` (statut `picked_up` uniquement) : voie de régularisation pour les autres statuts à décider.
6. Statut « dérivé » DR1–DR3 à relire formellement.

## 5. Résultats des tests (Node 22.23.4, garde de sortie réseau, aucune dépendance installée)

- **Suite pure complète : 2795 tests, 2622 réussis, 0 échec, 173 ignorés** (référence L3.1 : 2784 / 2611 / 0 / 173 ; +11 tests). Une première exécution après les éditions avait 9 échecs, tous des tests décrivant l'ancienne politique (adaptés, voir §2).
- Cible : `accountClosureExceptions.test.js` 109/109 ; `beneficiaryReviewL4.test.js` 8/8 (permissions sous-admin / client / non connecté, justification, idempotence, revue non levable, commande sans revue / inconnue, verrou, lecture en erreur, tombstone illisible) ; Flutter `suivi_commande_payment_message_test.dart` 3/3, `flutter test test/screens/client` 119/119 ; `flutter analyze` : une info préexistante (`curly_braces`, ligne 1113), aucune nouvelle.
- Correspondance 7E-97 §8 : #1–#16, #23, #24 couverts par les tests de `accountClosureExceptions.test.js` (garde, refus, traces, journaux, rejeu), `beneficiaryReviewL4.test.js` (levée, message, verrou) et le test Flutter, avec les écarts de politique du §4.

## 6. Mutations (fichiers restaurés, `diff` identique)

Mutants testés (tous tués) : bénéficiaire fermé toujours `skip` (6 échecs), quarantaine `skip` par défaut (2), garde « illisible » neutralisée (1, après ajout d'un test dédié — le premier test ne l'atteignait pas, mutant d'abord survivant), verrou de revue désactivé (3), drapeau de commande désactivé (2), débit vendeur supprimé (3), `partnerHeld` ignoré (1), revue « crédit non versé » levable (1), idempotence de la levée supprimée (1).

## 7. Émulateur dédié (`demo-l4-emu`, port 28080 ; arrêté ensuite)

- `orderActionsL4.emulator.test.js` : **4/4** (journaux dans la transaction et rejeu, quarantaine / scellé ⇒ refus + levée sans crédit rétroactif, annulation scellé / quarantaine / absent, livraison absent / quarantaine / actif sans double crédit).
- `accountClosureExceptions.emulator.test.js` (concurrence avec le scellement) : **5/5 deux fois**, `emulatorRejects: 0`.
- `accountClosureProtocol.emulator.test.js` (L2) : **8/8**.
- Ports 5001, 8080, 9099, 9199, 4000 intacts (mêmes PID). Une exécution de la suite L2 lancée en arrière-plan a été interrompue (trop longue) puis rejouée avec succès seule.

## 8. Invariants financiers vérifiés

Aucun double débit / crédit (rejeu pay, cancel, deliver) ; aucun solde négatif introduit ; client toujours remboursé en annulation ; aucun crédit à un compte en quarantaine / scellé / anonymisé / absent / illisible dans les cas couverts ; journaux du paiement atomiques avec le mouvement d'argent ; signalements et revues déterministes et idempotents ; tombstones jamais modifiés ou rouverts par L4 (hors `epoch+1` d'une restitution en quarantaine) ; lectures avant écritures (validé par l'émulateur). Non couvert : writers hors des cinq fonctions (autoExpire, litiges, retraits) — voir §10.

## 9. État C2

Chemin T1 / webhook non modifié (`accountDeletion.js`, `accountClosureLock/State/Protocol.js`, `feexpayPayments.js` inchangés) ⇒ protocole L0-F **non rejoué**. **C2 reste intermittent sur émulateur (17/20, `Transaction is invalid or closed`) et n'est pas déclaré corrigé.**

## 10. Réserves et risques résiduels

- L4 n'est **pas déclarée close sans réserve** : les décisions bloquantes du §4 (en particulier 1 et 2) conditionnent le comportement financier définitif.
- `orderRefunds.js` / `autoExpireOrders` / limite de débit : non gardés (L5). Les 12 writers de règlement et retraits restent non protégés.
- Fenêtre de course : deux refus simultanés peuvent écrire chacun la trace (contenu identique).
- Deux anomalies d'intégrité de L3.1 §3 (journal `refund` sans profil client, `deliveries+1` hors transaction) non corrigées.
- Preuves sur faux Firestore et émulateur uniquement ; rien en production, rien sur appareil.
- Le message Flutter dépend du préfixe de code dans le message d'erreur des fonctions.

## 11. Git

Avant : HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, 28 suivis modifiés, 138 non suivis (affichage regroupé de `git status`). Après : HEAD `d65c8f0` identique, index vide, stash 0, **31** suivis modifiés (+ `adminBilling.js`, `suivi_commande.dart`, `orderActions.test.js`), non suivis **142** (138 + 3 tests + ce rapport). Hashes des fichiers sensibles inchangés : `ekbineOrders.js` ff24d2c8, `index.js` a9ba2c0d, `professionalSubscriptions.js` 976c2396, `adminPartnerAccounts.js` 1a5cde55, `passwordReset.js` 26975f60 ; `feexpayPayments.js` 232dbcea.
**Confirmation : aucun commit, push, stash, déploiement, accès production / préprod, ni opération Git destructive.**

Arrêt : en attente de votre autorisation explicite et des décisions du §4.
