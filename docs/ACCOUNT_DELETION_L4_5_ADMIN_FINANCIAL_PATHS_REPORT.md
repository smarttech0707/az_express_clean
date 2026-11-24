# Mission L4.5 — Sécurisation des chemins administratifs financiers

Statut : **terminée dans son périmètre**. Dans les cas testés (unitaire, mutation, émulateur), aucun des cinq chemins ne crédite ni ne débite un bénéficiaire en quarantaine, scellé, anonymisé, absent ou illisible. **Réserve** : le chemin `partnerOrderActions.js` → `cancelOrderTx` (`partner_refused`, action d'un partenaire, non administrative) reste hors garde (voir §9). Aucun commit, push, stash ni déploiement ; aucun accès production / préprod ; L4.6, L4.7, L5–L7 non lancées ; `feexpayPayments.js`, `orderRefunds.js`, règles Firebase et les cinq fichiers sensibles non touchés ; aucun registre de décisions, module de règlement différé, grand livre, portefeuille ou réserve créé.

## 1. État Git

Initial : HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, 31 suivis modifiés, 151 non suivis.
Final : HEAD `d65c8f0`, index vide, stash 0, **34 suivis modifiés** (+`adminOrderDisputes.js`, `transferSettlement.js`, `test/transferSettlement.test.js`), **154 non suivis** (151 + 2 fichiers de test + ce rapport). Aucune opération Git destructive.
Hashes (`git hash-object`) inchangés : `ekbineOrders.js` ff24d2c8, `index.js` a9ba2c0d, `professionalSubscriptions.js` 976c2396, `adminPartnerAccounts.js` 1a5cde55, `passwordReset.js` 26975f60, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a.

## 2. Fichiers

Modifiés (production) : `functions/adminBilling.js` (resolveFeeHold, refundBoutiqueOrder, appel de closeStuckDelivery) ; `functions/adminOrderDisputes.js` (partialRefund, appel d'exceptionalCancel) ; `functions/transferSettlement.js` (approve wallet) ; `functions/orderActions.js` (**un seul bloc**, voir §3-b).
Modifiés (tests, adaptations légitimes) : `test/transferSettlement.test.js` (le message attendu pour un livreur absent devient `BENEFICIARY_ACCOUNT_CLOSED` : même refus, sans écriture, message de la garde) ; `test/adminConfirmDeliveryL43.test.js` (le test de câblage compte l'appel unique **dans `buildDeliverOrder`**, `cancelOrderTx` en portant désormais un second).
Créés : `test/adminFinancialPathsL45.test.js` (13 tests), `test/adminFinancialPathsL45.emulator.test.js` (5 tests), ce rapport. `accountClosureActor.js` : **non modifié** (`assertBeneficiariesCreditable` suffit). `partnerOrderActions.js` inspecté, **non modifié**.

## 3. Chemins audités : état initial et protection

Garde commune : `assertBeneficiariesCreditable(tx, db, HttpsError, [...])`, dans la transaction, **après toutes les lectures et avant la première écriture**. Seuls les états actif et « suppression demandée » passent ; sinon refus `BENEFICIARY_ACCOUNT_CLOSED` (cause et compte nommés), toute l'opération est annulée.

| Chemin | État initial | Bénéficiaires vérifiés |
|---|---|---|
| **a. resolveFeeHold** | crédit client / livreur / payeur de commission sans aucune vérification ; payeur absent ignoré en silence alors que la retenue était marquée résolue | `refundClient` → client ; `payDriver` → livreur de la retenue ; payeur de la commission rendue (`refundClient` et `retain` si commission tracée). `retain` sans commission tracée : aucun bénéficiaire, inchangé |
| **b. closeStuckDelivery** et **adminOrderDisputes `exceptionalCancel`** | exécutent `cancelOrderTx` sans garde (client « toujours remboursé », payeur de commission rendu, vendeur débité) | mode administratif de `cancelOrderTx` (`closure: { admin: true, HttpsError }`) : client (si remboursé), payeur de commission (si rendu), vendeur (si débité) — **par défaut refus**, y compris pour le débit d'un vendeur non actif |
| **c. refundBoutiqueOrder** | crédit client et débit vendeur sans vérification ; vendeur absent ignoré en silence | client + vendeur (si `sellerId` valide) |
| **d. adminOrderDisputes `partialRefund`** | crédit client + livreur sans vérification d'état de fermeture | client + livreur |
| **e. transferSettlement `approve` (wallet)** | crédit de chaque livreur sans vérification | tous les livreurs à crédit > 0 ; branche **cash** : aucun mouvement de wallet, inchangée (testée avec un livreur scellé) |

**Écart justifié (b)** : `cancelOrderTx` (orderActions.js, fichier hors liste autorisée) est seul à connaître les crédits réellement prévus (client, payeur, vendeur) ; le garder depuis `adminBilling.js` / `adminOrderDisputes.js` aurait dupliqué cette logique. Le changement est **additif** (`closure.admin === true`) : les appelants clients (`closure: { fn, HttpsError }`) et automatiques (`closure` absent) sont strictement inchangés. Conséquence signalée : pour une annulation administrative, le client n'est plus « toujours remboursé » — s'il est fermé, l'annulation est refusée plutôt que la somme perdue.

## 4. Traitement des cinq états (+ « suspension demandée »)

Quarantaine, scellé, anonymisé, absent, illisible : **refus intégral** sur les cinq chemins. Absent : certains chemins refusent avant la garde avec leur message historique « introuvable » (livreur/client/profil) — refus également, sans écriture ; le test l'accepte explicitement (`refused`). Erreur de lecture Firestore (tombstone) : propagée, aucune écriture (testée sur resolveFeeHold et refundBoutiqueOrder). Jamais d'`apply`, de `skip`, d'`epoch+1`, de détournement vers AZ, de réouverture de compte.

## 5. Résultats des tests (Node 22.23.4 via `node.exe` explicite, garde de sortie réseau)

- **Unitaire, `adminFinancialPathsL45.test.js` : 13/13.** Matrices états × bénéficiaires : resolveFeeHold `refundClient` client × payeur (36), `payDriver` (6), `retain` ; refundBoutiqueOrder client × vendeur (36) ; closeStuckDelivery client × vendeur (36) + payeur (5 états) ; exceptionalCancel client × livreur payeur (36) ; partialRefund client × livreur (36) ; transferSettlement dA × dB (36) ; cash inchangé. Pour chaque refus : magasin **strictement identique** (aucun solde, journal, statut, décision `order_dispute_decisions`, `config/az_wallet` créé), deux essais successifs identiques. Succès : un journal par crédit, rejeu sans second journal. Permissions : sous-admin, client, livreur, inconnu refusés sans écriture. Régularisation puis retry avec le même identifiant : un seul crédit (somme des soldes vérifiée).
- **Mutations : 15/15 tuées**, fichiers restaurés (`diff` identique) : garde resolveFeeHold supprimée / sans payeur / sans livreur ; refund sans vendeur / sans client ; closeStuck sans mode admin ; cancelOrderTx admin sans vendeur / sans payeur / sans client ; exceptionalCancel sans mode admin ; partialRefund sans garde / sans livreur ; settlement sans garde / premier livreur seulement ; état « scellé » autorisé dans la garde.
- **Émulateur `demo-l45-emu`** (port 28080, arrêté ensuite), `adminFinancialPathsL45.emulator.test.js` **5/5 exécuté 3 fois** : états fermés sur chaque chemin refusés, soldes et journaux intacts, retry sans effet ; **course réelle clôture / opération** pour resolveFeeHold, refundBoutiqueOrder, partialRefund, transferSettlement (4 chemins × 25 rondes × 3 exécutions = 300 rondes), scelleur transactionnel à marqueurs sérialisables (valeurs de portefeuilles vues) : crédité 14–23 / 25, refusé 2–11 / 25 (les deux issues observées), `emulatorRejects: 0`, **jamais un crédit visible après un tombstone, jamais un crédit partiel**. Régressions sur le même émulateur, une suite à la fois : adminOrderDisputes 8/8, marketplaceBoutiqueBilling 6/6, transferSettlement 7/7, orderActionsL4 4/4, L4.2 3/3, L4.3 5/5. Ports 5001, 8080, 9099, 9199, 4000 intacts (mêmes PID).
- **Suite pure complète : 2850 tests, 2673 réussis, 0 échec, 177 ignorés** (référence L4.3 : 2836 / 2660 / 0 / 176). Une première exécution, lancée par erreur avec un `PATH` ne résolvant pas Node 22, avait donné 1 échec (le test de câblage L4.3 mentionné §2) ; il a été adapté puis la suite relancée avec le Node 22.23.4 explicite : 0 échec.
- Non rejouée : concurrence L3 (`accountQuarantineConcurrency`) et L0-F, le chemin de quarantaine n'étant pas modifié.

## 6. Invariants vérifiés

Aucun crédit ni débit sur un compte fermé, absent ou illisible dans les cinq chemins ; aucune écriture avant la vérification ; aucun crédit partiel ; aucune décision ni retenue marquée « résolue », aucun statut « settled » / « refunded » / « delivered », aucun journal sur refus ; aucun détournement vers AZ (`retainedDeliveryFees`, `totalCommissions` non touchés) ; références de dette conservées (retenue `pending_admin_review`, `settlementHold`, commande et montants intacts) ; idempotence par statut / identifiant de décision ; aucun compte rouvert ni modifié.

## 7. Chemins encore non protégés

1. **`cancelOrderTx` appelé par `partnerOrderActions.js` (`partner_refused`, ligne ~419)** : refus d'une commande par un **partenaire** (non administratif) ; il appelle `cancelOrderTx` sans `closure`, donc client « toujours remboursé » et vendeur éventuellement débité sans vérification d'état. À traiter dans une mission dédiée.
2. `orderRefunds.js` (expirations / limite de débit) et les writers de L5 : volontairement non touchés.
3. Journaux **post-transaction** (`cancelOrderPostTx`, `partialPostTx`) : comportement non atomique préexistant, inchangé.
4. Tracing seul (pas de retenue) pour les sommes omises des chemins L4–L4.3 : inchangé, le règlement différé reste une mission distincte (option 1 de L4.4, non implémentée).

## 8. C2

Chemin de quarantaine (`accountDeletion.js`, `accountClosureLock/State/Protocol.js`, `feexpayPayments.js`) non modifié ⇒ L0-F non rejoué. C2 reste intermittent (17/20 sur émulateur) et **n'est pas déclaré corrigé**.

## 9. Risques résiduels

1. Une opération administrative dont un bénéficiaire est fermé reste bloquée, sans voie de régularisation tant que le règlement différé n'existe pas ; les sommes restent dues au bénéficiaire ou à ses ayants droit.
2. Sur-refus assumé (fail-closed) : `closeStuckDelivery` / annulation exceptionnelle refusées si le client est fermé, `resolveFeeHold` refusé si le payeur d'une commission à rendre est fermé, même si la décision choisie ne le créditerait pas autrement (`retain` avec commission tracée).
3. Comportement changé pour profil absent : vendeur absent (refundBoutiqueOrder) et payeur absent (resolveFeeHold) ne sont plus ignorés en silence mais refusés.
4. Preuves sur faux Firestore et émulateur uniquement ; rien en production, rien sur appareil.

Confirmation : **aucun commit, push, stash, déploiement ni accès production / préprod.** Arrêt : en attente de votre autorisation.
