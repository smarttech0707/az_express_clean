# Mission 7E-90 — Gardes transactionnelles des commandes payées (lot 2B)

Date : 2026-11-09 · Strictement local. Aucun `git add`, commit, push, pull/merge/rebase/reset, déploiement, commande distante, changement de secret, activation de FeexPay ; `operations_control/account_deletion` non créé ; production `az-express-b0469` non touchée. Rapport non suivi.

## 1. Manifeste
| Fichier | Statut | Changement |
|---|---|---|
| `functions/deliveryQuote.js` | modifié (+4/−0) | import + 1 garde dans la transaction de `createOrderFromQuoteCF` |
| `functions/orderActions.js` | modifié (+7/−0) | import + 1 garde dans `buildPayBoutiqueOrder` + 1 garde dans `buildPayBoutiqueOrderCash` |
| `functions/test/walletDebitQuarantineGuards.test.js` | nouveau (28 tests unitaires) | faux Firestore strict |
| `functions/test/walletDebitQuarantine.emulator.test.js` | nouveau (6 tests émulateur) | ignoré sans émulateur `demo-*` |

Aucune modification de `accountAdmission.js` (helper du lot 2A réutilisé tel quel : `assertNewAccountActivity`). Les deux fichiers de code n'avaient aucune modification préalable.

## 2. Analyse des trois fonctions
**Constat commun** : les trois fonctions lisaient déjà le client dans la transaction, mais ne testaient que `deletionRequested`/`isDeleted`. Or la quarantaine pose un **tombstone + `isSuspended`** (le `deletionRequested` n'est posé que pour les livreurs, `isDeleted` seulement à l'anonymisation) : ce test était donc inopérant pendant la quarantaine. Aucun contrôle du tombstone n'existait.

| | `createOrderFromQuoteCF` (`deliveryQuote.js`) | `payBoutiqueOrderCF` (`orderActions.js`) | `payBoutiqueOrderCashCF` |
|---|---|---|---|
| Lectures tx | devis, client, commande | produit, vendeur, client | produit, vendeur |
| Écritures tx | client (`wallet`, `lastPaidOrderId`) + `wallet_transactions/order_{id}` (si wallet), `orders` (create), devis `used` | client (−total), vendeur (+produits), produit (stock), `boutique_orders`, `orders` | produit (stock), `boutique_orders`, `orders` |
| Débit wallet | oui si `paymentMethod==='wallet'` | oui, toujours | **aucun** |
| Idempotence | devis `open→used` + `orderId` ; rejeu → même commande, sans débit (retour avant la garde) ; `ORDER_EXISTS` | aucune clé (chaque appel = nouvel achat ; protégé par solde et stock lus dans la transaction) | idem |
| Statuts | devis expiré / déjà utilisé / prix changé | stock, solde, `acceptedTotal` | stock, `acceptedTotal` |
| Garde ajoutée | `assertNewAccountActivity(tx, …, uid)` après `assertActiveClient`, avant total/débit/créations (wallet **et** espèces : c'est une nouvelle commande) | `assertNewAccountActivity(tx, …, uid, [['sellers', sellerId]])` juste après la lecture du client, avant tout contrôle de solde et toute écriture | `assertNewAccountActivity(tx, …, uid)` avant la première écriture (stock) ; client seul |

**Garde (rappel)** : relit dans la transaction `account_tombstones/{uid}` puis `clients/{uid}` (et le vendeur) ; refuse si tombstone, `deletionRequested`, `isDeleted` ; toute erreur de lecture propage (fail-closed). Elle est placée après les lectures existantes et avant la première écriture : la règle Firestore « lectures avant écritures » est respectée (les tests unitaires utilisent un faux Firestore qui lève une erreur si une lecture suit une écriture).

**Différence wallet / espèces** : `payBoutiqueOrderCashCF` ne touche aucun wallet (test dédié), mais crée une *nouvelle* commande et retire du stock : la garde l'applique par cohérence (décision 7E-87). Aucune opération déjà engagée n'est bloquée : le rejeu d'un devis déjà utilisé reste servi sans nouveau débit, y compris après quarantaine ; `payOrderFromWalletCF` (règlement d'une commande engagée) n'est pas touché (lot 2C).

**Erreur renvoyée** : `HttpsError('failed-precondition', 'Compte supprime ou en cours de suppression')`, propagée telle quelle (non convertie en enveloppe `QuoteRefusal` dans `createOrderFromQuoteCF`) — comme pour les gardes du lot 2A.

## 3. Tests exécutés (Node v22.23.4)
**Unitaires — `walletDebitQuarantineGuards.test.js` : 28/28 PASS.** Couvrent : client actif accepté (3 flux) ; profil en suppression / anonymisé ; tombstone existant (wallet et espèces) ; quarantaine posée **entre** les contrôles d'entrée et la transaction ; lecture du tombstone impossible (fail-closed) ; échec transactionnel (stock épuisé) ⇒ aucun état partiel ; rejeu d'un devis utilisé après quarantaine ⇒ même commande, un seul débit ; tentatives répétées après refus ⇒ aucun effet ; vendeur anonymisé ; flux espèces sans wallet touché ; zéro écriture (comparaison intégrale du magasin).
**Contrôle de discrimination** : gardes retirées temporairement (puis restaurées, empreintes identiques) → **17 des 28 tests échouent** ; avec les gardes, 28/28.

**Émulateur — `walletDebitQuarantine.emulator.test.js` : 6/6 PASS** (Firestore seul, `demo-7e90`, `127.0.0.1:18089`, hub 14400, logging 14500 — ports libres avant/après, mêmes que 7E-89 ; config dans le scratchpad hors dépôt ; émulateurs de l'utilisateur 5001/8080/9099 non touchés) :
| Test | Résultat | Constat |
|---|---|---|
| Q0 témoin sans quarantaine | PASS | les trois flux aboutissent (donc un refus vient bien de la garde) |
| Q1 quote wallet vs quarantaine (25) | PASS | 13 acceptées avant le tombstone, 12 refusées (9 par la garde, 3 erreurs de contention de l'émulateur) |
| Q2 boutique wallet vs quarantaine (25) | PASS | 1 acceptée, 24 refusées par la garde ; débit, stock et crédit vendeur cohérents |
| Q3 boutique espèces vs quarantaine (25) | PASS | 0 acceptée, 25 refusées par la garde |
| Q4 3 appels concurrents, même devis (10 rondes) | PASS | une seule création, un seul débit, une seule commande |
| Q5 2 achats concurrents, solde pour un seul (10 rondes) | PASS | un seul réussit, solde 0, jamais négatif |
Invariants vérifiés à chaque ronde : horodatage de validation (`createTime`) de toute commande ≤ celui du tombstone ; refus ⇒ aucune commande et solde intact ; accepté ⇒ exactement un débit. **Contrôle de discrimination** : gardes retirées → Q1 et Q2 échouent dès la ronde 0 (« commande validée après la quarantaine »).

**Non-régression** : `node --test test/*.test.js` sous Node 22.23.4 : **2349 tests, 2183 PASS, 0 FAIL, 166 ignorés** (tests d'émulateur sans émulateur, dont ceux de la suite), `index.js` se charge. Le lot 2A (126 tests de 7E-88) n'est pas affecté.

## 4. Réserves
1. **Erreur de contention de l'émulateur** : sous contention, certaines exécutions de Q1 ont renvoyé `3 INVALID_ARGUMENT: Transaction is invalid or closed` (3/25 dans la dernière exécution ; variable d'une exécution à l'autre, absente en Q2/Q3 de la dernière). Ces appels échouent **sans effet** (solde et commandes vérifiés), donc fail-closed, mais ce n'est pas un refus de la garde : le test les compte à part et rejette tout autre motif. Comportement de production non prouvé ; la cause exacte (artefact de l'émulateur ou nouvelle tentative du SDK) n'a pas été isolée.
2. Q2/Q3 : la quarantaine précède presque toujours la transaction (1/25 et 0/25 acceptées) ; la fenêtre « acceptée avant le tombstone » est donc peu exercée pour la boutique (mieux couverte en Q1 : 13/25). L'émulateur ne prouve pas la production.
3. `payBoutiqueOrderCF`/`Cash` n'ont aucune clé d'idempotence : deux appels identiques créent deux achats (sans changement, protégés par solde et stock) ; hors périmètre 2B.
4. La garde vendeur `[['sellers', sellerId]]` ne teste que les drapeaux de profil (pas de tombstone vendeur) ; `readProductBoutiqueSeller` refuse déjà vendeur supprimé/suspendu.
5. `createOrderFromQuoteCF` propage une `HttpsError` (et non l'enveloppe `{success:false}`) pour ce refus ; le client Flutter du flux n'étant pas activé, l'adaptation éventuelle est à décider avec l'activation.
6. Lots 2C/2D, commit 3, outil `held_for_review`, quota : inchangés ; **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE**.
7. Commit 2B futur : ces deux fichiers n'étaient pas modifiés auparavant, donc indexables entiers ; les tests sont deux nouveaux fichiers.

## 5. État Git final
HEAD `294332e42bfb352b71eca861b08d6f36dee6e853` (inchangé), index vide, aucun commit, push ni déploiement. `git status` : 95 entrées (91 avant + 2 modifiés + 2 nouveaux tests). `functions/index.js` : 8 hunks (7 P2 + hunk P3 `setPharmaciePassword` distinct), inchangé ; autres fichiers du lot 2A, commits 1/1B, E-Kbine, `payOrderFromWalletCF`, `transferSettlement`, moteur de suppression, quatre fichiers Flutter : non modifiés. `git diff --check` : uniquement des avertissements LF/CRLF.

## 6. Opérations distantes
Aucune. Émulateur Firestore local isolé arrêté (ports 18089/14400/14500/9151 libres). `D:\h75.txt` non lu.

## Verdict
**LOT 2B IMPLÉMENTÉ ET TESTÉ — PRÊT POUR REVUE**
(avec les réserves du §4, notamment l'erreur de contention de l'émulateur non isolée). Aucun commit créé. Arrêt : en attente d'une nouvelle autorisation humaine distincte.
