# Mission L4.1 — Sécurisation financière et régularisation

Statut : **partiellement terminée, avec réserves** (conformément à la condition de fin : aucune réserve financière sûre n'existe pour les sommes omises ; elles ne sont donc pas « réellement protégées » au sens du §9 de la mission). Ce qui est faisable sans nouvelle architecture est fait et testé ; le reste est bloqué et documenté (§8). Aucun commit, push ni déploiement ; aucun accès production / préprod ; L5–L7 non lancées ; `feexpayPayments.js` non touché.

## 1. État Git

Initial (relevé avant toute modification) : HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, **31 suivis modifiés, 142 non suivis** (identique au rapport L4). Hashes : `ekbineOrders.js` ff24d2c8, `index.js` a9ba2c0d, `professionalSubscriptions.js` 976c2396, `adminPartnerAccounts.js` 1a5cde55, `passwordReset.js` 26975f60, `feexpayPayments.js` 232dbcea (tous inchangés à la fin).
Final : HEAD `d65c8f0`, index vide, stash 0, **31 suivis modifiés** (aucun nouveau : `orderActions.js`, `adminBilling.js` et `suivi_commande.dart` l'étaient déjà depuis L4), **144 non suivis** (142 + `functions/test/financialIntegrityL41.test.js` + ce rapport). `orderRefunds.js` : non modifié (d985269a). Aucune opération Git destructive.

## 2. Audit des sommes omises (Travail 1)

Question centrale : une somme non créditée est-elle « conservée » par un mécanisme financier existant, ou seulement inscrite dans un signalement ? Constat : **aucun code de production ne lit** `reconciliation_flags` de type `beneficiary_closed`, `beneficiary_closed_refused` ni `partner_credit_held` (recherche exhaustive) ; il n'existe **aucune action de règlement** de ces sommes (`clearBeneficiaryReview` ne règle rien). Les seuls mécanismes de retenue existants sont `heldDriverEarning` + `settlementStatus:'pending_admin_review'` + `transfer_settlements` (part du livreur d'une course transférée), `deliveryFeeHold` + `resolveFeeHold` (frais de livraison Marketplace/Boutique après récupération). Aucun ne couvre une part de partenaire, de pharmacie ni un remboursement de commission.

| Chemin | Somme non versée | Montant / devise | Commande | Bénéficiaire prévu | Motif | Conservation réelle | Rapprochement | Résolution possible | Double règlement |
|---|---|---|---|---|---|---|---|---|---|
| Annulation, remboursement de commission | commission débitée au livreur à l'acceptation | `commissionAmount` (ou preuve wallet), XOF | `orderId` | livreur payeur | quarantaine / scellé / anonymisé / absent | **Oui, sous forme d'état existant** : `commissionStatus` reste `charged`, journal `commission_<commande>_<livreur>` inchangé, aucun crédit nulle part ; la somme n'a pas quitté AZ | signalement `<orderId>_beneficiary_closed` : `kind:'commission_refund_omitted'`, `currency:'XOF'`, `parties[{collection,id,state,reason,amountWithheld,sourceJournalId}]`, commande `reviewReason:'beneficiary_credit_omitted'` | **Aucune voie sûre** (voir §3, §8) | annulation à usage unique (statut terminal), signalement à identifiant déterministe, aucun exécutant de règlement ⇒ aucun double crédit possible aujourd'hui |
| Paiement wallet | aucune (paiement refusé en entier) | — | — | — | — | rien débité, rien conservé à gérer | trace `<orderId>_pay_beneficiary_refused` (`completed:false`) | refus tant que le bénéficiaire est fermé | sans objet |
| Livraison, crédit partenaire | **aucune** : corrigé en L4.1 (livraison refusée) | — | — | — | — | sans objet | trace `_deliver_beneficiary_refused` | refus tant que le partenaire est fermé | sans objet |

**Changement L4.1 majeur (Décision A)** : en L4, un partenaire en quarantaine laissait livrer en omettant son crédit (`partner_credit_held`) — c'était un signalement présenté comme une conservation. Corrigé : `deliverOrderCF` / `confirmOrderDeliveryWithProof` **refusent la livraison** si le partenaire à créditer est en quarantaine, scellé, anonymisé, absent ou illisible (aucune écriture financière, trace, commande en revue). Le code `partner_credit_held` est supprimé. Le livreur n'est pas payé non plus tant que la livraison est bloquée.

Pour l'annulation (Décision C) le client est toujours remboursé ; la commission reste côté AZ (déjà prélevée) : c'est la seule « conservation » réelle, et elle n'est qu'implicite (pas de grand livre AZ). Le signalement la rend **rapprochable**, il ne la **retient** pas. Je ne crée aucune réserve.

## 3. Régularisation administrative — `clearBeneficiaryReview` (Travail 2)

- **Levable** : revue `beneficiary_closed` (refus de paiement / livraison / annulation) uniquement.
- **Jamais levable** : revue `beneficiary_credit_omitted` (somme due non versée) → `REVIEW_NOT_CLEARABLE`. Aucune action n'existe pour la régler : voir blocage §8.1.
- **Nouveau (L4.1)** : la levée relit l'état ACTUEL de chaque bénéficiaire refusé (tombstone puis profil, via `isBeneficiaryCreditable` dans `accountClosureActor.js`) et n'aboutit que si tous sont actifs (ou suppression seulement demandée). Sinon `BENEFICIARY_STILL_CLOSED` sans aucune écriture. Sans signalement de refus exploitable : `BENEFICIARY_NOT_VERIFIABLE` (on ne devine pas). Un tombstone n'étant jamais supprimé, un compte en quarantaine / scellé / anonymisé n'est donc **jamais** « débloqué » : la levée ne sert qu'à corriger un refus fait à tort (bénéficiaire en réalité actif). Elle ne rouvre aucun compte, ne crédite rien, ne vaut pas preuve de règlement ; la garde est de toute façon ré-évaluée au paiement / livraison suivant (pas de crédit rétroactif).
- Idempotence : état relu dans la transaction ; rejeu = `replay:true` sans écriture ; signalements `_beneficiary_refused` passés en `cleared` une seule fois ; liste des signalements étendue à `cancel`.
- Un super-admin ne peut saisir ni montant ni preuve : seule la justification texte est acceptée.

## 4. Acteur en quarantaine (Travail 3)

Distinction vérifiée par tests : le **remboursement propre du client** en quarantaine (engagé avant) n'est pas suspendu ; le **crédit du bénéficiaire** (livreur) est versé s'il est actif, omis s'il est fermé ; le **gain propre du livreur acteur** en quarantaine est versé à la livraison ; deux parties en quarantaine ⇒ le client est remboursé, le livreur non crédité. Identités, portefeuilles et journaux : `pay_order_<id>` / `earning_pay_order_<id>` (déterministes, dans la transaction) ; aucune autre voie modifiée.

## 5. `orderRefunds.js` (Travail 4) — périmètre

Contenu (157 lignes) : `refundAmounts`, `readSeller`, `refundClientAndSeller`, `expireOrderTx` (expiration sans livreur / partenaire 60 min), `rateLimitCancelTx`. Appelé par les planificateurs (`autoExpireOrders`) : **aucun acteur humain**, aucune garde de fermeture. Non modifié.
Appartient à L5 (writers de règlement système, planificateurs). Incohérences connues avec les chemins L4 : (a) il rembourse toujours le client, y compris compte anonymisé (écriture sur profil supprimé non vérifiée) ; (b) il **débite le vendeur marketplace** (plafonné) sans consulter son état, alors que `cancelOrderCF` refuse pour un vendeur fermé (E) — l'autoexpiration peut donc débiter un compte anonymisé / scellé ; (c) pas de signalement ni de revue. Aucun de ces écarts n'est un invariant introduit par L4.1 ; les corriger exige la décision E et appartient à L5.

## 6. Marketplace (Travail 5)

Inchangé et bloqué : vendeur absent, scellé ou anonymisé ⇒ annulation refusée (aucun débit, remboursement ni compensation inventé) ; en quarantaine, le débit de restitution (plafonné) reste appliqué avec epoch+1 (règle D6-c historique). Tests pour les trois états fermés. Options et conséquences (à décider, **non implémentées**) :
1. *Refuser durablement* (état actuel) : le client reste sans remboursement jusqu'à régularisation manuelle hors système ; aucune perte AZ, mais blocage client indéfini.
2. *Rembourser le client, ne rien débiter le vendeur* : le client est servi, AZ supporte la perte du produit (le vendeur garde les gains) — coût réel pour AZ, à valider financièrement.
3. *Rembourser le client, débit tracé en créance sur le vendeur fermé* : nécessite un registre de créances (nouvelle architecture) et une base légale pour un compte anonymisé.
4. *Rembourser le client, retenir sur un solde séquestre* : nécessite un mécanisme de séquestre inexistant.

## 7. Résultats des tests

Node 22.23.4, garde de sortie réseau, aucune dépendance installée.
- **Suite pure complète : 2807 tests, 2633 réussis, 0 échec, 174 ignorés** (référence L4 : 2795 / 2622 / 0 / 173). Une exécution intermédiaire avait 2 échecs (registre : `adminBilling.js` contenait « account_tombstones » et importait le socle) corrigés en déplaçant la lecture dans `accountClosureActor.js` — pas en adaptant les tests de registre.
- Nouveaux tests : `financialIntegrityL41.test.js` (8) — conservation de la somme des portefeuilles, signalement rapprochable (champs, pas de donnée personnelle), rejeu identique, acteur ≠ bénéficiaire (4 cas), marketplace absent / scellé / anonymisé / quarantaine, tombstone illisible et lecture en erreur ; `beneficiaryReviewL4.test.js` (réécrit : 11 tests, levée refusée tant que le bénéficiaire est scellé / en quarantaine / anonymisé / absent / illisible, levée d'un refus erroné, rejeu, permissions, non vérifiable) ; `accountClosureExceptions.test.js` (livraison refusée avec partenaire en quarantaine, aucune fausse réserve).
- **Mutations** (fichiers restaurés, `diff` identique) : contrôle d'état de la levée neutralisé (2 échecs), contrôle « non vérifiable » (1), contrôle réduit à « absent » (2), livraison avec partenaire en quarantaine `skip` (1), champs de rapprochement supprimés (1 + 1), crédit du bénéficiaire fermé à l'annulation (5). Tous tués. (Rappel L4 : 9 mutants + 1 test ajouté pour un mutant survivant.)
- **Émulateur** `demo-l41-emu` (port 28080, arrêté ensuite) : `orderActionsL4.emulator.test.js` 4/4 (adapté : partenaire en quarantaine ⇒ refus ; levée refusée tant que fermé puis acceptée après simulation d'un refus erroné et paiement unique) ; concurrence avec le scellement 5/5, `emulatorRejects: 0`. Ports 5001, 8080, 9099, 9199, 4000 intacts (mêmes PID). Les protocoles L2 n'ont pas été rejoués (non modifiés).

## 8. Décisions et blocages encore nécessaires

1. **Règlement des sommes omises (blocage principal)** : aucun mécanisme existant ne retient ni ne règle la commission non remboursée. Options : (a) la commission reste acquise à AZ (décision explicite, légale pour un compte anonymisé) — alors `clearBeneficiaryReview` pourrait clore le dossier avec une décision `retain` et sa justification, sans mouvement ; (b) paiement différé à un ayant droit : exige procédure et identité hors système. Aucune des deux n'est implémentée ici.
2. **Paiement avec livreur / pharmacie en quarantaine** : reste refusé en entier ; créer une retenue (analogue à `settlementHold`) est une décision d'architecture distincte.
3. **Voie de régularisation des livraisons bloquées (partenaire fermé)** : `adminConfirmDeliveryCF` n'applique **aucune garde de bénéficiaire** — elle peut créditer le portefeuille d'un partenaire anonymisé ou en quarantaine, ce qui contredit les décisions A/C. Je ne l'ai pas modifiée (hors des chemins nécessaires aux réserves L4, flux administratif) ; **risque résiduel à traiter** : appliquer la même garde au crédit partenaire dans le mode `adminConfirm`, ou imposer une décision administrative explicite.
4. **Marketplace** : choisir entre les options du §6.
5. `orderRefunds.js` / `autoExpireOrders` : voir §5 (L5, décision E nécessaire pour le débit vendeur fermé).
6. DR1–DR3 toujours « dérivées, à relire ».

## 9. Invariants financiers vérifiés

Somme des portefeuilles : +remboursement client uniquement lorsque le bénéficiaire est fermé ; aucun crédit à un compte quarantaine / scellé / anonymisé / absent / illisible dans les cas couverts (pay, cancel, deliver, proof) ; aucune écriture financière sur refus (seules trace et revue) ; rejeu : magasin identique ; paiement : débit, crédit et journaux atomiques ; aucune levée qui crédite, rouvre ou modifie un tombstone ; aucun double crédit après levée puis paiement ; lecture en erreur ⇒ aucune écriture. Non vérifiés (hors périmètre) : `adminConfirmDeliveryCF`, `orderRefunds.js`, retraits, litiges.

## 10. C2

Chemin T1 / webhook non modifié (`accountDeletion.js`, `accountClosureLock/State/Protocol.js`, `feexpayPayments.js` inchangés) ⇒ L0-F **non rejoué**. C2 reste intermittent sur émulateur (17/20) et **n'est pas déclaré corrigé**.

## 11. Risques résiduels

- Les sommes omises ne sont protégées que par l'absence de crédit et l'état de la commission : aucun exécutant de règlement ni grand livre, donc aucune récupération automatisée (§8.1).
- Le blocage de livraison peut laisser un livreur sans issue tant que le partenaire est fermé (résolution hors système ou via la confirmation administrative non gardée).
- `adminConfirmDeliveryCF` peut contourner la décision « aucun crédit à un bénéficiaire fermé ».
- `autoExpireOrders` peut débiter un vendeur fermé (L5).
- Preuves sur faux Firestore et émulateur uniquement ; rien en production, rien sur appareil.

## 12. Fichiers

Examinés : `orderActions.js`, `orderRefunds.js`, `adminBilling.js`, `accountClosureActor.js`, `accountClosureRegistry.js`, tests de registre / verrou. Modifiés : `functions/orderActions.js` (livraison : partenaire en quarantaine refusé, suppression de `partner_credit_held` ; annulation : signalement enrichi), `functions/adminBilling.js` (levée avec vérification d'état), `functions/accountClosureActor.js` (`isBeneficiaryCreditable`), `functions/test/accountClosureExceptions.test.js`, `functions/test/beneficiaryReviewL4.test.js`, `functions/test/orderActionsL4.emulator.test.js`. Créés : `functions/test/financialIntegrityL41.test.js`, ce rapport.

Confirmation : **aucun commit, push, stash, déploiement ni accès production / préprod.** Arrêt : en attente de votre autorisation et des décisions du §8.
