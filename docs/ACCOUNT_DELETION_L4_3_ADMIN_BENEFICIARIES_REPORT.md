# Mission L4.3 — Protection des deux bénéficiaires administratifs

Statut : **terminée** dans son périmètre. Dans les cas testés (unitaire, mutation, émulateur), aucun crédit au partenaire ni au livreur n'est possible par `adminConfirmDeliveryCF` lorsque l'un des deux — ou le payeur d'une commission rendue — est en quarantaine, scellé, anonymisé, absent ou illisible. Aucun commit, push ni déploiement ; aucun accès production / préprod ; L5–L7 non lancées ; `feexpayPayments.js`, `orderRefunds.js`, règles Firebase non touchés ; aucun mécanisme de retenue, réserve ou paiement différé créé.

## 1. État Git

Initial : HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, **31 suivis modifiés, 147 non suivis** (identique à L4.2). Hashes inchangés à la fin : `ekbineOrders.js` ff24d2c8, `index.js` a9ba2c0d, `professionalSubscriptions.js` 976c2396, `adminPartnerAccounts.js` 1a5cde55, `passwordReset.js` 26975f60, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a.
Final : HEAD `d65c8f0`, index vide, stash 0, **31 suivis modifiés** (aucun nouveau), **150 non suivis** (147 + 2 fichiers de test + ce rapport). Aucune opération Git destructive.

## 2. Fichiers

Modifiés : `functions/orderActions.js` (un seul bloc : liste des comptes vérifiés en mode administratif) ; `functions/test/accountClosureExceptions.test.js` (regex de câblage adaptée au nouveau bloc). `accountClosureActor.js` : **non modifié** (`assertBeneficiariesCreditable`, déjà écrit en L4.2, suffit). Créés : `functions/test/adminConfirmDeliveryL43.test.js` (9 tests, dont une matrice de 36 combinaisons), `functions/test/adminConfirmDeliveryL43.emulator.test.js` (5 tests), ce rapport.

## 3. Contrôles

Dans la transaction de `buildDeliverOrder` en mode `adminConfirm`, avant toute écriture, **un seul appel** `assertBeneficiariesCreditable(tx, db, HttpsError, adminBeneficiaries)` lit pour chaque compte le tombstone puis le profil (même lecture que les gardes L1–L4) :

- **livreur de la commande** (`livreurs/<driverId>`) : **toujours**, quel que soit le mode de paiement — il reçoit le gain, ses compteurs et sa libération ; une confirmation administrative sur un livreur fermé laissait aussi un état incohérent (mise à jour post-transaction de `deliveries` sur un profil absent) ;
- **partenaire** (`restaurants`, `pharmacies`, `boulangeries`, …) : quand il serait crédité (même critère qu'en L4.2 ; pas de contrôle s'il n'y a aucun crédit : cash, prépayé) ;
- **payeur de la commission** (ajout, signalé) : quand une commission tracée a été prélevée sur un livreur **autre** que celui de la commande — il peut recevoir un remboursement de commission (cas historique « commission rendue ») ; l'inclure ferme le troisième chemin de crédit possible. Un payeur identique au livreur n'ajoute rien. Cas de sur-refus à connaître : payeur distinct fermé alors que la commission ne serait pas rendue ; il est rare (les courses transférées, seul cas de payeur ≠ livreur, sont exclues de ce mode) et fail-closed.

Sont acceptés uniquement les états **actif** et **suppression seulement demandée** ; **quarantaine, scellé (ou suppression Auth commencée), anonymisé, absent, illisible** : refus `BENEFICIARY_ACCOUNT_CLOSED` avec la cause et le compte nommés (identifiants techniques seulement). Une erreur de lecture se propage : jamais une autorisation. Le contrôle est transactionnel : un tombstone créé après la lecture invalide la transaction, rejouée, qui refuse. Pas d'`apply`, de `skip` ni d'`epoch+1`.

## 4. Résultats : toutes les combinaisons (commande v2, 6 × 6 états)

États : actif, quarantaine, scellé, anonymisé, absent, illisible pour le partenaire **et** pour le livreur → **36 combinaisons : 1 confirmée (actif/actif), 35 refusées intégralement**, dont les tables de la mission (fermé/actif, actif/fermé, fermé/fermé, illisible/actif, actif/illisible). Pour chacune des 35 : le magasin est identique hors trace (aucun solde, journal, commande ou livreur modifié), la commande reste `picked_up` sans `deliveredAt`, aucun journal, pas de `config/az_wallet`, pas de `commissions`, pas de décision `order_dispute_decisions` (rien n'est marqué réglé), aucun tombstone créé ni modifié, trace `<commande>_deliver_beneficiary_refused` (`completed:false`), et un retry avec le même `requestId` est strictement sans effet. Lorsqu'un seul compte est fermé, la cause nommée est celle de ce compte. Compléments : livreur fermé sur commande historique et sur commande cash (aucun partenaire à créditer) : refus ; partenaire fermé sur commande historique : livreur actif non crédité ; payeur de commission distinct : 5 états fermés refusés (cible nommée), actif confirmé ; erreur de lecture sur partenaire (profil et tombstone) et sur livreur (profil et tombstone) : refus sans écriture ; permissions : sous-admin, client, livreur, inconnu, anonyme, non connecté refusés sans écriture.

## 5. Absence de crédit partiel et de journal fictif

Prouvé par la matrice : dans chacune des 35 paires refusées, ni le compte fermé ni le compte actif ne bouge (soldes d'origine 1000 / 900), `journals = 0`. Succès : exactement un journal par crédit (2), rejeu du même `requestId` = no-op, autre `requestId` sur commande livrée refusé. Un refus erroné corrigé (compte en réalité actif) puis rejoué donne un seul crédit chacun.

## 6. Tests

Node 22.23.4, garde de sortie réseau.
- **Suite pure complète : 2836 tests, 2660 réussis, 0 échec, 176 ignorés** (référence L4.2 : 2826 / 2651 / 0 / 175).
- **Mutations unitaires** (fichiers restaurés, `diff` identique) : livreur non vérifié (6 échecs), partenaire non vérifié (16), payeur non vérifié (1), livreur vérifié seulement si un partenaire est crédité (2), état « scellé » autorisé (10). Tous tués. Sur l'émulateur, livreur non vérifié : 2 des 5 tests échouent (matrice et course côté livreur).
- **Émulateur `demo-l43-emu`** (port 28080, arrêté ensuite), `adminConfirmDeliveryL43.emulator.test.js` **5/5 exécuté 3 fois** : états fermés × cible (partenaire, livreur, les deux) refusés deux fois avec soldes et journaux intacts ; actifs crédités une fois avec rejeu sans doublon ; **course réelle** — scelleur transactionnel qui relit les deux portefeuilles et inscrit `partnerAtSeal` / `driverAtSeal` dans le tombstone (marqueurs sérialisables, aucun horodatage) ; 3 cibles × 30 rondes × 3 exécutions = 270 rondes : crédité 19–26 / 30 et refusé 4–11 / 30 selon les exécutions (les deux issues observées), **jamais un crédit après un tombstone, jamais un crédit partiel**, rejet métier toujours `BENEFICIARY_ACCOUNT_CLOSED`.
- `emulatorRejects` : 0 à 2 par série de 30 rondes (rejets d'infrastructure de l'émulateur « Transaction is invalid or closed », même famille que l'intermittence C2), **comptés et jamais pris pour un succès** : à chaque rejet, la livraison n'est pas validée et aucun solde n'a bougé (assertions par ronde). Un premier essai sans cette comptabilisation échouait sur ces rejets, et non sur une violation.
- Régressions sur le même émulateur, une suite à la fois : `adminConfirmDeliveryL42` 3/3, `orderActionsL4` 4/4, concurrence L3 5/5 (`emulatorRejects: 0`). Ports 5001, 8080, 9099, 9199, 4000 intacts (mêmes PID).

## 7. Invariants financiers vérifiés

Aucun crédit à un compte fermé, absent ou illisible ; aucun crédit partiel ; aucune écriture avant la vérification (câblage testé : un seul appel, avant la première écriture) ; aucune décision enregistrée sur refus ; aucun détournement vers AZ ; pas de journal positif sans crédit réel ; idempotence par `requestId` ; aucun compte rouvert ou modifié. La dette (commande, montants, partenaire, commission tracée) reste intacte et non réglée ; `clearBeneficiaryReview` n'autorise aucun règlement.

## 8. C2

Chemin de quarantaine (`accountDeletion.js`, `accountClosureLock/State/Protocol.js`, `feexpayPayments.js`) non modifié ⇒ L0-F non rejoué. C2 reste intermittent (17/20 sur émulateur) et **n'est pas déclaré corrigé**.

## 9. Risques résiduels

1. Une livraison dont le livreur ou le partenaire est fermé reste bloquée sans voie de régularisation (le règlement différé est une mission distincte) ; le livreur reste sur la course.
2. La garde du livreur est systématique : une confirmation administrative est impossible tant que le livreur de la commande est fermé, même sans crédit (cash). C'est la règle approuvée ; l'alternative serait de réaffecter la commande, hors périmètre.
3. Le sur-refus possible du payeur de commission distinct (§3) est fail-closed.
4. Les autres chemins de livraison administratifs (`settlementHold` / règlement de transfert) et les writers de L5 ne sont pas couverts.
5. Les rejets d'infrastructure de l'émulateur sous contention restent comptés, non éliminés ; ils n'ont jamais produit d'état financier incorrect.
6. Preuves sur faux Firestore et émulateur uniquement ; rien en production, rien sur appareil.

Confirmation : **aucun commit, push, stash, déploiement ni accès production / préprod.** Arrêt : en attente de votre autorisation.
