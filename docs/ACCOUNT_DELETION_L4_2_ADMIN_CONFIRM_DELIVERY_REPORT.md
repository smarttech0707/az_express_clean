# Mission L4.2 — Protection de adminConfirmDeliveryCF

Statut : **terminée dans son périmètre** — aucun partenaire fermé ne peut recevoir de crédit par `adminConfirmDeliveryCF` dans les cas testés (unitaire, mutation, émulateur). Une réserve sur le livreur de la commande (§9). Aucun commit, push ni déploiement ; aucun accès production / préprod ; L5–L7 non lancées ; `feexpayPayments.js` et `orderRefunds.js` non touchés ; règles Firebase non modifiées ; aucun mécanisme de retenue créé.

## 1. État Git

Initial : HEAD `d65c8f0`, branche `finalisation/az-express`, index vide, stash 0, **31 suivis modifiés, 144 non suivis** (identique à L4.1). Hashes inchangés à la fin : `ekbineOrders.js` ff24d2c8, `index.js` a9ba2c0d, `professionalSubscriptions.js` 976c2396, `adminPartnerAccounts.js` 1a5cde55, `passwordReset.js` 26975f60, `feexpayPayments.js` 232dbcea, `orderRefunds.js` d985269a.
Final : HEAD `d65c8f0`, index vide, stash 0, **31 suivis modifiés** (aucun nouveau), **147 non suivis** (144 + 2 fichiers de test + ce rapport). Aucune opération Git destructive.

## 2. Fichiers

Modifiés : `functions/orderActions.js` (fichier contenant `buildDeliverOrder`, donc `adminConfirmDeliveryCF` — déjà modifié avant L4.2), `functions/accountClosureActor.js` (non suivi ; ajout de `assertBeneficiariesCreditable`, justifié : le contrôle d'état d'un compte vit déjà dans ce module et `account_tombstones` ne doit pas apparaître dans `orderActions.js` sans casser les tests de registre), `functions/test/accountClosureExceptions.test.js` (assertion de câblage mise à jour : la confirmation administrative a désormais sa propre garde). Créés : `functions/test/adminConfirmDeliveryL42.test.js` (18 tests), `functions/test/adminConfirmDeliveryL42.emulator.test.js` (3 tests), ce rapport. Ni `index.js` (l'export `adminConfirmDeliveryCF` n'a pas besoin d'être modifié), ni les règles, ni le registre.

## 3. Audit de la fonction

`adminConfirmDeliveryCF = buildDeliverOrder({ adminConfirm: true, requireSuperAdmin })` (`index.js:2493`). Contrôles de rôle : authentification non anonyme, justification ≥ 10 caractères, `requestId` idempotent 16–128, preuve parmi `ADMIN_DELIVERY_EVIDENCE`, limite de débit, `requireSuperAdmin`. Le livreur crédité est celui de la commande (`driverId`), pas l'acteur. Transaction (`runLifecycleTransaction`) : lit `order_dispute_decisions/<hash(orderId|requestId)>` (rejeu ⇒ retour sans écriture), la commande (statut `picked_up` exigé, pas de `settlementHold`), puis les comptes. **Avant L4.2, le mode administratif sautait toute garde** (`if (!adminInfo)`) : le crédit du partenaire (v2 : produits ; historique : `budget`) s'écrivait même si le profil était anonymisé ou en quarantaine ; un tombstone seul n'était pas lu. Écritures hors transaction après validation : compteur de livraisons du livreur, `config/az_wallet` (compteurs), `commissions`, journaux historiques `.add()`, audit — toutes après `return` de la transaction, donc jamais atteintes si elle est refusée.

## 4. Comportement avant / après

| | Avant | Après |
|---|---|---|
| Partenaire actif | crédité | identique (comportement historique) |
| Partenaire en quarantaine / scellé / anonymisé / illisible | crédité (profil présent, tombstone ignoré) | **refus complet** `BENEFICIARY_ACCOUNT_CLOSED` (cause nommée) |
| Partenaire absent | livraison faite + signalement `partner_credit_missing` | **refus complet** |
| Erreur de lecture | selon l'erreur | refus (l'erreur se propage), aucune écriture |
| Partenaire non crédité (cash, prépayé) | pas de contrôle | pas de contrôle (aucun crédit en jeu) |

Mécanisme : `assertBeneficiariesCreditable(tx, db, HttpsError, [{collection, id}])` appelé dans la transaction, **avant la première écriture et après les seules lectures de la commande**, lit le tombstone puis le profil (même lecture que les gardes L1–L4) et refuse tout état autre qu'actif / suppression seulement demandée. Pas d'omission, pas de `skip`, pas d'`apply` (aucun `epoch+1`). Il n'y a pas de contrôle d'acteur de fermeture (l'acteur est un super-admin). Comme la fonction ne sépare pas confirmation et règlement, **l'opération entière est refusée** (consigne §4). La garde utilise le même critère `partnerCredited` que le mode livreur.

## 5. Traitement de chaque état

| État | Résultat |
|---|---|
| actif / suppression demandée | contrôles financiers habituels, crédit unique (journal `earning_<commande>` déterministe en v2) |
| quarantaine (tombstone `closing`) | refus, aucun crédit au partenaire ni au livreur, tombstone intact |
| scellé / suppression Auth commencée | refus, aucune réouverture |
| anonymisé (`isDeleted`) | refus, aucune opération sur le compte |
| absent | refus, aucun profil créé |
| tombstone illisible | refus (jamais une autorisation) |
| erreur Firestore | refus, aucune écriture |

À chaque refus : la commande reste `picked_up` (aucun `deliveredAt`), aucune décision `order_dispute_decisions` n'est enregistrée (rien n'est marqué réglé, le même `requestId` reste réutilisable), aucun journal, aucun `config/az_wallet` (aucune substitution vers AZ), aucune `commissions`, les soldes ne bougent pas. La seule écriture est la trace existante `reconciliation_flags/<commande>_deliver_beneficiary_refused` (`completed:false`) et la mise en revue de la commande (`needsReview`), après l'échec de la transaction. Les informations qui permettent de retrouver la dette (commande, montants `productAmount`/`budget`, partenaire, commission tracée) sont intactes ; **la commission reste due, non réglée et non acquise à AZ**.

## 6. Tests

Node 22.23.4, garde de sortie réseau.
- **Suite pure complète : 2826 tests, 2651 réussis, 0 échec, 175 ignorés** (référence L4.1 : 2807 / 2633 / 0 / 174).
- `adminConfirmDeliveryL42.test.js` 18/18 : (1) actif v2 et historique ; (2–6) quarantaine, scellé, suppression Auth, anonymisé, absent, illisible × v2 et historique : aucune écriture hors trace (soldes, journaux, commande, livreur), pas de `config/az_wallet`, pas de `commissions`, pas de décision enregistrée, tombstone intact ; (7) erreur de lecture du tombstone et du profil ; (9–10) retry après refus (magasin identique) et après succès (même `requestId` = no-op, autre `requestId` refusé, un seul journal, aucun double crédit) ; cash non bloqué ; (12) permissions : sous-admin, client, livreur, inconnu, anonyme, non connecté, justification / `requestId` / preuve invalides ; câblage : la garde précède la première écriture.
- **Mutations** (fichiers restaurés, `diff` identique) : garde désactivée (14 échecs), seul « absent » refusé (11), quarantaine autorisée (3), illisible autorisé (3). Tous tués. Sur l'émulateur, garde désactivée : 2 des 3 tests échouent (dont la course).
- **Émulateur `demo-l42-emu`** (port 28080, arrêté ensuite), `adminConfirmDeliveryL42.emulator.test.js` **3/3 exécuté 3 fois** : états fermés refusés deux fois avec solde intact ; partenaire actif crédité une fois, rejeu sans doublon ; **(8) course réelle** — un scelleur transactionnel inscrit la valeur du portefeuille dans le tombstone : sur 90 rondes, 76 crédits validés avant le tombstone (`walletAtSeal` = 4500) et 14 refus (portefeuille 1000, commande inchangée), **jamais un crédit après le tombstone** ; les deux issues sont observées. Un premier essai comparant des horodatages serveur donnait un faux positif (heure de requête ≠ ordre de commit) : remplacé par le marqueur sérialisable. Régression : `orderActionsL4` 4/4 ; concurrence L3 5/5 (`emulatorRejects: 0`). Ports 5001, 8080, 9099, 9199, 4000 intacts (mêmes PID).

## 7. Cohérence journaux et commandes

Aucun journal positif sans crédit réel (refus : zéro journal ; succès : un journal par crédit). Aucune commande dans un état intermédiaire : la transaction échoue avant toute écriture, les compteurs / commissions / audit sont postérieurs au commit. Idempotence : décision par hash(`orderId|requestId`) inchangée.

## 8. C2

Chemin de quarantaine (`accountDeletion.js`, `accountClosureLock/State/Protocol.js`, `feexpayPayments.js`) non modifié ⇒ L0-F non rejoué. C2 reste intermittent (17/20 sur émulateur) et **n'est pas déclaré corrigé**.

## 9. Risques résiduels et décisions

1. **Livreur de la commande** : en mode administratif il reste crédité sans contrôle d'état (frais de livraison, gain). Un livreur anonymisé / scellé recevrait donc un crédit. Hors de la consigne (partenaire seulement) : non modifié ; à décider (même garde, avec la question de l'acteur engagé avant la quarantaine).
2. Une livraison bloquée par un partenaire fermé n'a **toujours pas de voie de régularisation** (le règlement différé de la dette, avec vérification de l'ayant droit et autorisation administrative, est volontairement hors L4.2) ; le livreur reste sur la course tant que la décision n'est pas prise.
3. Les confirmations administratives de livraison de commandes `settlementHold` (règlement de transfert) et les autres writers de L5 ne sont pas couverts.
4. La trace de refus met la commande `needsReview` : elle bloque ensuite le mode livreur (`ORDER_UNDER_REVIEW`) mais pas le mode administratif (volontaire).
5. Preuves sur faux Firestore et émulateur uniquement ; rien en production, rien sur appareil.

Confirmation : **aucun commit, push, stash, déploiement ni accès production / préprod.** Arrêt : en attente de votre autorisation.
