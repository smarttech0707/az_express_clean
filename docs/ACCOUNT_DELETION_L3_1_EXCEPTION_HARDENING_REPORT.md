# Mission L3.1 — Finalisation des exceptions contrôlées

Statut : terminée, arrêt avant toute autorisation. Aucun commit, push ni déploiement ; aucun accès à `az-express-b0469` ; L4 à L7 non lancées ; `feexpayPayments.js` et le webhook non touchés.

## 0. Précision sur les références de décision

La consigne cite « DR3 » pour le bénéficiaire absent. Dans la spécification 7E-97 (§1), **DR3 vise l'acteur** dont le profil est absent. Le bénéficiaire absent relève de **DR2 / §6.4** (« partenaire à créditer `anonymized`/`absent` ⇒ refus `BENEFICIARY_ACCOUNT_CLOSED` »). Le résultat demandé est le même pour le point 1 ; j'ai appliqué DR2 §6.4 et gardé les deux notions séparées. Rappel : DR1–DR3 sont des règles « dérivées, à relire à l'autorisation d'implémentation » (7E-97 R5, 2D2A5 D-8) ; cette relecture est une décision encore à confirmer (§7).

## 1. Bénéficiaire absent traité comme anonymisé (corrigé)

- `closureGuard` ne tolère plus l'absence : le paramètre `legacyAbsentBeneficiary` introduit en L3 est supprimé. Chaque bénéficiaire est désormais verrouillé **séparément** (ordre déterministe) afin que le refus nomme la partie et son état : `failed-precondition / BENEFICIARY_ACCOUNT_CLOSED` avec `details = { cause: 'absent'|'anonymized'|'sealed'|'unreadable'|…, reason: <code ACCOUNT_*>, collection, id }`.
- Effet : partenaire introuvable à la livraison ⇒ livraison refusée, commande inchangée, livreur et partenaire non crédités, aucun signalement `partner_credit_missing`. Même règle pour `confirmOrderDeliveryWithProof`, et pour `payOrderFromWalletCF` (livreur ou pharmacie absent).
- Non confondu avec l'acteur appelant sans profil (point 3). Un partenaire qui n'est **pas** crédité (paiement espèces) n'est pas contrôlé : pas de refus à tort (test).
- Conséquence assumée : une course dont `sellerId` pointe un partenaire inexistant ne peut plus être livrée par `deliverOrderCF` ; elle reste récupérable par la confirmation administrative (`adminConfirmDeliveryCF`, non modifiée). Voir §7.

**Test existant modifié (signalé)** : `test/partnerOrderFinancial.test.js` « partenaire introuvable à la livraison : livreur payé, montant dû signalé » décrivait exactement l'ancien comportement (livraison + livreur payé + `partner_credit_missing`). Il affirme maintenant le refus, l'absence de crédit et la trace. Un autre test historique (`partnerOrderReconciliation`, rapprochement de `partner_credit_missing` existants) n'est pas concerné : les signalements déjà en base restent lisibles.

## 2. Traces des refus (ajoutées)

`payOrderFromWalletCF`, `deliverOrderCF`, `confirmOrderDeliveryWithProof` : si la transaction échoue avec `BENEFICIARY_ACCOUNT_CLOSED`, une trace est écrite **après** l'échec (la transaction n'a rien écrit) :
- document déterministe `reconciliation_flags/{orderId}_pay_beneficiary_refused` ou `{orderId}_deliver_beneficiary_refused` ; lecture puis écriture seulement s'il n'existe pas ⇒ **un retry ne crée rien de plus ni ne modifie la trace** (test : contenu identique, même `createdAtMs`) ;
- contenu : `orderId`, `type:'beneficiary_closed_refused'`, `operation`, `status:'open'`, `needsReview:true`, **`completed:false`** (jamais un faux « paiement réussi »), `beneficiary:{collection,id,state}`, `createdAtMs`. Aucune donnée personnelle ni solde (test) ;
- si l'écriture de la trace échoue, le refus métier d'origine est renvoyé quand même (test) ; une transaction qui échoue pour une autre raison n'écrit aucune trace (test) ; un refus d'**acteur** (scellé…) n'écrit aucune trace de bénéficiaire (test) ;
- identifiants distincts de `{orderId}_beneficiary_closed` (annulation, DR1) pour éviter qu'une trace de refus de paiement soit prise pour un remboursement omis.

Limite : deux refus strictement simultanés peuvent chacun écrire la trace (même contenu, seul `createdAtMs` diffère) ; sans conséquence financière.

## 3. Acteur sans profil — audit (aucune modification de comportement)

Constats figés par `test/accountClosureActorWithoutProfile.test.js` (5 tests), appelant authentifié **sans profil et sans tombstone** :

| Fonction | Résultat | Contournement ? |
|---|---|---|
| `payOrderFromWalletCF` | non propriétaire : `permission-denied` ; propriétaire sans profil : solde 0 ⇒ `SOLDE_INSUFFISANT`, ou montant 0 ⇒ écriture sur document absent refusée ; aucune écriture | Non (identité, propriété, solde tenus) |
| `deliverOrderCF` | non lié : `permission-denied` ; lié sans profil : refusé (écriture du portefeuille sur document absent), aucune écriture sans partenaire | Non. Avec partenaire crédité, le crédit partenaire et le statut sont validés puis la mise à jour post-transaction `driverRef.update` (compteur de livraisons, existante) échoue : état incohérent **préexistant**, anomalie d'intégrité, pas d'accès indu |
| `cancelOrderCF` | non propriétaire : `permission-denied` ; propriétaire sans profil : annulation faite, **aucun crédit possible**, mais un journal `refund` est écrit sans crédit correspondant | Non (pas de création d'argent), mais **anomalie d'intégrité** |
| `ekClientConfirmOrder` | non propriétaire : `permission-denied` ; propriétaire sans profil : confirmation acceptée (propriété + débit prouvé portés par la commande), agent crédité du montant prouvé | Non (le client n'est pas relu hors quarantaine, comportement historique) |

Conclusion : **aucun contournement d'identité, de propriété, de rôle ni de solde démontré** ; le comportement historique est donc conservé (consigne). Deux anomalies d'intégrité à corriger sur décision, sans urgence de sécurité :
1. `cancelOrderTx` : ne pas écrire le journal `refund` (ou refuser l'annulation) lorsque le profil client est absent ;
2. `buildDeliverOrder` : déplacer `driverRef.update(deliveries +1)` dans la transaction, ou le rendre tolérant à l'absence de profil.
Si le mur DR3 littéral est voulu (acteur sans profil ⇒ refus partout), c'est un changement distinct qui casserait des tests historiques (solde client absent, preuves de livraison) : à demander séparément.

## 4. Bénéficiaire en quarantaine / scellé / anonymisé / absent — analyse sans modification

Comportement actuel de `cancelOrderCF` (paramètre `closure`), quatre situations **non assimilées** :

| Bénéficiaire (payeur de commission, vendeur marketplace) | Comportement actuel | Fondement |
|---|---|---|
| en quarantaine simple (tombstone `closing`, profil non anonymisé) | crédit/débit effectué ; son `epoch + 1` dans la même transaction | D6-c, catégorie C |
| scellé (`phase:'sealed'`, Auth en cours de suppression) | annulation **refusée en entier**, aucune écriture, trace `BENEFICIARY_ACCOUNT_CLOSED` (pas de signalement) | socle L1 : un scellé est toujours refusé |
| anonymisé (`isDeleted`) | client remboursé, crédit omis, `commissionStatus` reste `charged`, signalement `{orderId}_beneficiary_closed` | DR1 |
| absent (ni profil ni tombstone) | même traitement que l'anonymisé (`skip` + signalement) | extension de DR1 : le socle traite absent et anonymisé de la même façon |

Questions métier à trancher (aucune modification faite) :
1. **Scellé** : refuser l'annulation (le client attend la fin de l'anonymisation, puis peut réessayer) ou la traiter comme l'anonymisé (rembourser le client, omettre et signaler) ? Le texte DR1 ne mentionne que l'anonymisé. Risque du refus : un client bloqué tant que le bénéficiaire n'est pas anonymisé ; risque du `skip` : divergence si le scellement est défait par une reprise administrative.
2. **Absent** : DR1 ne le cite pas ; l'assimiler à l'anonymisé est cohérent avec le point 1 mais mérite une confirmation explicite.
3. **Vendeur marketplace anonymisé** : débit omis (extension de DR1 que j'ai posée en L3) — le vendeur garde alors les produits d'une commande annulée ; à confirmer ou à refuser.
4. **Bénéficiaire en quarantaine** : crédité (inchangé) ; confirmer qu'un crédit sur un portefeuille en quarantaine est bien voulu (il modifie l'`epoch` et peut repousser son scellement).

## 5. Fichiers

Modifiés dans L3.1 : `functions/accountClosureActor.js` (non suivi), `functions/orderActions.js` (déjà modifié : import, retrait de `legacyAbsentBeneficiary`, deux enveloppes `withRefusalTrace`), `test/accountClosureExceptions.test.js`, `test/partnerOrderFinancial.test.js` (**tracé, passe de propre à modifié**). Créé : `test/accountClosureActorWithoutProfile.test.js`. Ni `index.js` ni `ekbineOrders.js` ne sont touchés par L3.1 (leurs hashes sont ceux d'après L3). Registre et autres writers inchangés.

## 6. Tests (Node 22.23.4, garde de sortie réseau)

- Fichier d'exceptions : maintenant 105 tests (101 en L3) dont la trace (anonymisé / absent / scellé × livreur, pharmacie, partenaire × avec/sans quarantaine × retry) ; audit : 5 tests.
- Contrôle par mutation (trace neutralisée) : 4 tests échouent ; fichier restauré (identique).
- **Suite pure complète : 2784 tests, 2611 réussis, 0 échec, 0 annulé, 173 ignorés** (référence L3 : 2775/2602/0/173).
- Émulateur `demo-l31-emu` (port 28080 dédié), concurrence avec le scellement 15 rondes × 5 fonctions × 2 exécutions : **5/5 et 5/5**, jamais les deux, jamais aucun, `emulatorRejects: 0`, les deux issues observées. Émulateur arrêté ; ports 5001, 8080, 9099, 9199, 4000 intacts (mêmes PID).
- C2 : le chemin T1 / webhook n'est pas modifié (`accountDeletion.js`, `accountClosureLock/State/Protocol.js`, `feexpayPayments.js` inchangés) ⇒ L0-F **non rejoué**, justifié. C2 reste intermittent sur émulateur et n'est pas déclaré corrigé.

## 7. Décisions encore nécessaires

1. Confirmer la relecture DR1–DR3 (statut « dérivé ») et l'interprétation DR2 §6.4 (absent = refus) ; accepter qu'une course au partenaire inexistant ne se livre plus que par confirmation administrative, ou prévoir une voie de régularisation.
2. Règle de l'annulation pour bénéficiaire scellé / absent / vendeur anonymisé (§4).
3. Corrections d'intégrité du §3 (journal `refund` sans crédit ; compteur de livraisons hors transaction).
4. Trace de refus : fenêtre de conservation et traitement (L7) ; propriétaire du traitement des `…_beneficiary_refused`.

## 8. Risques restants

- Les 12 writers de règlement et les retraits restent non protégés (inchangé depuis L3).
- Le refus d'une livraison pour partenaire absent bloque le livreur sur sa course tant qu'une confirmation administrative n'est pas faite.
- Journaux de `payOrderFromWalletCF` toujours post-transaction ; incrément du compteur de preuve QR sans epoch (inchangés).
- Preuve sur émulateur et faux Firestore uniquement ; rien en production ni sur appareil.

## 9. Préservation

HEAD `d65c8f0` ; branche `finalisation/az-express` ; index vide ; stash 0. Suivis modifiés : **28** (27 + `test/partnerOrderFinancial.test.js`, modification nécessaire au point 1). Non suivis : **137** avant ce rapport (136 + `accountClosureActorWithoutProfile.test.js`), 138 avec lui. Fichiers sensibles : `professionalSubscriptions.js` (`976c2396`), `adminPartnerAccounts.js` (`1a5cde55`), `passwordReset.js` (`26975f60`) inchangés ; `index.js` (`a9ba2c0d`) et `ekbineOrders.js` (`ff24d2c8`) identiques à la fin de L3, non touchés par L3.1. Aucune opération Git destructive.

Arrêt : en attente de votre autorisation explicite.
