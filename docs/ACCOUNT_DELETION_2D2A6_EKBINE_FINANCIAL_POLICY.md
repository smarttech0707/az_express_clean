# 2D-2A.6 — E-Kbine : confirmation, règlement et obligations financières pendant la fermeture d'un compte

Date : 2026-11-10. Branche `finalisation/az-express`, HEAD `d65c8f0`. Document de politique uniquement : aucun code, test, règle, writer ni inspecteur modifié ; aucun émulateur, accès distant, opération Firebase, commit, push ni déploiement ; aucun document existant modifié ; les changements locaux sont préservés ; aucun lot L0–L8 commencé.

Sources : décision 7E-73 (`EKBINE_SCOPE_DECISION`), audits 7E-72 (`EKCLIENTCONFIRMORDER_AUDIT`, `EKBINE_CONCURRENCY_ANALYSIS`), registre 7E-87, spécification 7E-97, protocole 2D-2A.3 (**P3**), registre 2D-2A.4 (**R4**), décisions 2D-2A.5 (**D5**), `FINANCIAL_EKBINE_2026-11-03.md`, et le code lu **en lecture seule** : `functions/ekbineOrders.js`, `ekbineFlow.js`, `index.js` (exports Ekbine et wrapper `onCall`), `accountAdmission.js`, `accountDeletion.js`, `accountDeletionScope.js`, `partnerAccountDeletion.js`, `firestore.rules` (`ekbine_orders`).

Légende : **[CONF]** décision documentée en source ; **[CODE]** comportement observé dans le code lu ; **[PROP]** proposition de ce document, non décidée ; **[OUVERT]** point sans décision ; **[RISQUE]** risque non résolu. L'analyse est **statique** : aucune fonction n'a été exécutée.

---

## 1. Vocabulaire : états d'un compte

Les sources emploient « quarantaine » pour des états différents. Ce document les distingue strictement.

| État | Marqueurs dans le code | Comportement de `assertNewAccountActivity` |
|---|---|---|
| **Actif** | aucun | autorise |
| **Suppression demandée** (sans tombstone) | `deletionRequested:true` sur le profil, sans `account_tombstones/{uid}` | **refuse** (`accountAdmission.js:11`) |
| **Quarantaine** (fermeture) | tombstone `phase:'closing'` (ou sans `phase`), `isSuspended:true` ; pour les rôles partenaires aussi `deletionRequested:true` (`partnerAccountDeletion.js:34`) | refuse |
| **Scellé** | tombstone `phase:'sealed'` (P3 §1) | refuse |
| **Anonymisé** | `isDeleted:true` | refuse |
| **Profil absent** | document inexistant | cas distinct (voir §6) |

Le wrapper d'appelant `onCall` de `index.js:83-90` refuse tout appelant dont le **tombstone** existe ; il ne lit pas `deletionRequested`.

---

## 2. Les quatre notions, distinguées

| Notion | Définition retenue | Fonction ou chemin | Effet financier |
|---|---|---|---|
| **Confirmation client d'une commande** | déclaration du client que le service a été rendu (`proof_sent → completed`) | `ekClientConfirmOrder` (`ekbineOrders.js:283`) | aucun par elle-même ; **couplé en [CODE]** au règlement ci-dessous dans une seule transaction |
| **Règlement d'une obligation déjà engagée** | crédit du portefeuille de l'agent du montant de débit prouvé (`agentCredited`, `walletBalance`) | même transaction que la confirmation (`ekbineOrders.js:311-317`) ; futur : résolution des flags `ekbine_*_unproven_debit` par décision (2D-2B) | écriture de solde (agent) ; ligne d'audit |
| **Création d'une nouvelle commande** | ouverture d'une commande et débit du client | `ekCreateOrderCF` (`ekbineOrders.js:96`) ; création directe client par les règles (`firestore.rules:902-908`) | débit du client, journal `ekorder_<id>` |
| **Remboursement ou compensation** | restitution au client du montant prouvé débité | `ekCancelOrderCF` (`ekbineOrders.js:199`) ; futur : décisions `refunded_by_ledger`, `debit_disproved` | crédit du client, journal `ekrefund_<id>` |

Règle de conception **[PROP]** : *confirmer* et *régler* sont deux effets distincts. Tant qu'ils restent dans la même transaction, **si le règlement n'est pas permis, la confirmation est refusée en entier** (aucun état modifié). C'est le comportement actuel et celui retenu par 7E-73. L'alternative « terminer la commande sans crédit avec un signalement » a été **écartée** par 7E-72 (`EKCLIENTCONFIRMORDER_AUDIT` §5, « non retenu ici, à trancher avec le métier ») : elle reste **[OUVERT]**.

Faits financiers **[CODE]** : frais = 0 ; le client paie `amount` ; l'agent gagne `amount` si le paiement est par wallet (`ekbineOrders.js:113-118, 139-141`). Paiement hors wallet : aucun mouvement, aucun crédit agent (`creditFor`, `ekbineOrders.js:278-281`, `settlement: 'declarative_no_credit'`). Preuve de débit : `provenDebit` exige wallet, `walletDebited`, `debitedAmount = amount`, aucun remboursement antérieur (`ekbineOrders.js:40-43`). Crédit agent = `debitedAmount`, jamais un champ modifiable par le client.

---

## 3. Cycle de vie et flux d'argent

Statuts **[CODE]** : `pending` → `awaiting_deposit` (acceptation sans preuve de débit) ou `deposit_confirmed` (débit prouvé) → `deposit_proof_sent` / `deposit_rejected` → `deposit_confirmed` → `in_progress` → `proof_sent` → `completed` ; ou `cancelled`.

| Moment | Qui détient l'argent |
|---|---|
| Commande wallet créée | débité au client, conservé par AZ jusqu'à l'issue ; preuve `debitLedgerId = ekorder_<orderId>` |
| `completed` avec débit prouvé | crédité à l'agent (`walletBalance`) |
| `cancelled` avec débit prouvé | remboursé au client (`ekrefund_<orderId>`) |
| Débit non prouvé (commande historique) | aucun mouvement automatique ; flag `ekbine_cancel_unproven_debit` ou `ekbine_confirm_unproven_debit` ; revue humaine |

L'annulation n'est permise que dans `pending` et `awaiting_deposit` (`CANCELLABLE`, `ekbineOrders.js:30`) ; depuis `deposit_confirmed` seulement si `EK_CANCEL_FROM_DEPOSIT_CONFIRMED=true`, **désactivé par défaut** (décision de lancement, `FINANCIAL_EKBINE_2026-11-03.md`). Conséquence **[CODE]** : pour une commande wallet acceptée (débit prouvé), la **seule** issue normale est la confirmation du client ; le client ne peut pas annuler.

Atteignabilité **[CODE]** : les inspecteurs bloquent la suppression tant qu'une commande Ekbine du compte est non terminale (`accountDeletion.js`, requêtes `ekbine_orders` par `clientId` ; `accountDeletionScope.js:42-44`, par `agentId`). Un tombstone n'est donc normalement pas posé tant qu'une commande est engagée. Les cas où une commande engagée coexiste avec une partie fermée sont des **états résiduels** (§7), pas le flux nominal.

---

## 4. Droits d'un agent E-Kbine

« Fermé » = suppression demandée, quarantaine, scellé ou anonymisé (§1).

| Action de l'agent | Agent actif | Suppression demandée | Quarantaine / scellé | Anonymisé | Source |
|---|---|---|---|---|---|
| Accepter une commande (`ekbineAcceptOrder`) | autorisé si éligible | **refusé** (`isEligibleAgent`, garde) | **refusé** (wrapper + garde en transaction) | refusé | [CODE] `ekbineFlow.js:33`, `ekbineOrders.js:354` (garde non commitée) ; [CONF] 7E-68/7E-73 |
| Confirmer/rejeter un dépôt, démarrer (`ekbineAgentDepositAction`) | autorisé si éligible | **refusé** (`isEligibleAgent`) | **refusé** par le wrapper ; **aucune garde en transaction** | refusé | [CODE] `index.js:2130-2150` |
| Passer `in_progress → proof_sent` par écriture directe | autorisé (règles) | **non bloqué** par les règles (pas de test `deletionRequested`) | refusé par `isAuth()` (tombstone) | refusé | [CODE] `firestore.rules:930-934` |
| Recevoir un crédit via la confirmation du client | autorisé | **refusé** (garde) | **refusé** | refusé | [CODE] `ekbineOrders.js:309` ; [CONF] 7E-73 |
| Soumettre une preuve de dépôt | n/a (action du client) | — | — | — | — |

Synthèse **[CONF]** (7E-73 §1) : *un agent en quarantaine ne peut pas faire valider une confirmation qui entraînerait une opération interdite ; le contrôle échoue de manière sûre.* **[CODE]** : l'agent n'a aucun droit d'accepter, de démarrer ou d'être crédité dès qu'il est fermé.

Points à noter **[RISQUE]** :
- `ekbineAgentDepositAction` n'a aucune garde en transaction ; seul le wrapper (hors transaction) protège. Une course entre le wrapper et la pose du tombstone existe en théorie (même famille de fenêtre que celles de 2D-2A.2) ; atteinte seulement avec une commande déjà assignée, donc hors flux nominal (§3).
- L'écriture directe `in_progress → proof_sent` d'un agent « suppression demandée » n'est pas empêchée par les règles.

---

## 5. Confirmation 3 : un agent en quarantaine ne valide pas une confirmation client (7E-73)

**Confirmé**, avec une précision de formulation.

1. **[CONF]** 7E-73 §1 : « Un agent en quarantaine ne doit pas pouvoir valider une confirmation client qui entraîne une opération interdite ; le contrôle échoue de manière sûre. » 7E-73 §2 : conforme à `assertNewAccountActivity(tx, …, agentId, [['ekbine_agents', agentId]])`, placé dans la transaction avant toute écriture, refus `failed-precondition`, commande laissée `proof_sent`, aucun crédit, aucun audit de succès.
2. **Précision** : l'agent ne *valide* pas la confirmation ; c'est le **client** qui confirme. Le refus tient à l'état du **bénéficiaire** (l'agent), pas à celui de l'appelant. Formulation retenue : *la confirmation d'un client est refusée lorsque l'agent bénéficiaire est fermé.*
3. **[CODE]** Le refus couvre : suppression demandée, quarantaine, scellé, anonymisé (garde sur profil et tombstone), et profil agent absent (`not-found`, `ekbineOrders.js:304`, lu avant la garde).
4. **Divergence documentaire (X-1)** : le registre 7E-87 D3 recommandait, pour une commande engagée, de **créditer** l'agent sauf `isDeleted` (option b) ; 7E-73 l'a remplacé par un refus. Selon D5 (D-8), l'arbitrage « 7E-73 prévaut pour l'agent en quarantaine » reste **à confirmer**. Ce document applique 7E-73, décision postérieure et explicite.

---

## 6. Profil du bénéficiaire absent ou anonymisé

| Bénéficiaire | Cas | Comportement actuel [CODE] | Politique proposée [PROP] |
|---|---|---|---|
| **Agent** (crédité à la confirmation) | profil absent | `not-found` (transaction annulée, commande reste `proof_sent`) | **refus**, aucun crédit ; **trace de revue** (§8) |
| Agent | `isDeleted` | refus par la garde | idem ; aucun crédit automatique, jamais |
| Agent | tombstone / suppression demandée | refus | refus ; aucune levée de quarantaine |
| **Client** (remboursé à l'annulation) | profil absent | `ACCOUNT_NOT_FOUND` seulement si un remboursement est dû (`ekbineOrders.js:218-221`) | refus du remboursement ; **revue** ; ne pas déplacer les fonds vers un autre compte |
| Client | `isDeleted` | pas de test de profil dans `ekCancelOrderCF` ; l'appelant tombstoné est refusé par le wrapper | rester refusé ; le remboursement d'un client anonymisé ne passe **pas** par le portefeuille (§7) |
| Client | tombstone | appelant refusé par le wrapper | voir §7 (X-2) |

Règle absolue (consigne) : **aucun crédit automatique vers un compte anonymisé ou absent**. Tout cas ambigu reste bloqué ou passe en revue.

---

## 7. Règlement d'une obligation déjà engagée sans lever la quarantaine

### 7.1 Ce que disent les sources

1. **[CONF]** 7E-73 : commandes terminées ou déjà engagées : comportement inchangé ; un client en quarantaine peut clôturer une commande engagée (audit 7E-72 §5, « testé »).
2. **[CONF]** 7E-97 D6-b/c : clôture des commandes **de livraison** engagées (`payOrderFromWalletCF`, `cancelOrderCF`, `deliverOrderCF`, `confirmOrderDeliveryWithProof`) par une exception de wrapper `onCallClosing` limitée à une liste fermée de quatre fonctions. **Aucune fonction Ekbine n'y figure** (7E-97 §5).
3. **[CONF]** D5 D-8 / P3 : aucun crédit automatique vers un profil `isDeleted` ; D-7 : annulation d'une demande avant `sealed` sous nouvelle inspection ; jamais de levée automatique de quarantaine.

### 7.2 Contradiction non résolue X-2 : le client fermé ne peut pas clôturer

**[CODE]** Les trois fonctions de clôture côté client (`ekClientConfirmOrder`, `ekCancelOrderCF`, `ekbineSubmitDepositProof`) sont déclarées avec l'`onCall` local de `index.js` (`index.js:2032, 2104, 2811`). Ce wrapper refuse un appelant sous tombstone. Les tests de 7E-72/7E-73 appellent la fonction construite directement (faux Firestore), **sans** le wrapper. Donc :
- en fonctionnement réel, un **client en quarantaine ne peut pas** confirmer, annuler ni envoyer une preuve ;
- l'affirmation de 7E-73/7E-72 « le client en quarantaine peut clôturer » n'est vraie qu'au niveau de la fonction, pas de la fonction déployée.

Deux issues, **aucune décidée [OUVERT]** :
- (a) corriger la documentation : un client fermé ne peut pas clôturer une commande Ekbine (cohérent avec le fait que le moteur refuse la quarantaine tant qu'une commande Ekbine est non terminale) ;
- (b) étendre la liste fermée de 7E-97 §5 à `ekClientConfirmOrder`, `ekCancelOrderCF` (et éventuellement la preuve de dépôt), avec garde d'acteur en transaction ; cela modifie une liste de 7E-97 déclarée « fermée » et exige la décision du propriétaire.

### 7.3 Risque X-3 : impasse « suppression demandée » d'un agent

**[CODE]** Dans le flux partenaires, lorsque l'inspection est bloquée (par exemple par une commande Ekbine non terminale), le code pose `deletionRequested:true` sur le profil de l'agent, avec le commentaire « Pending deletion prevents new activity but does not suspend existing work » (`partnerAccountDeletion.js:21-24`). Or la garde de confirmation lit `deletionRequested` (`accountAdmission.js:11`) et refuse. Résultat : agent avec `deletionRequested`, commande engagée en `proof_sent`, le client ne peut plus la confirmer ; la commande ne devient jamais terminale ; la suppression de l'agent reste bloquée par cette même commande. La commande wallet ne peut pas être annulée (statut hors `CANCELLABLE`). Aucune Cloud Function d'administration ne règle une commande Ekbine (le fichier `ekbine_orders` n'apparaît que dans `ekbineOrders.js`, `ekbineReconciliation.js`, `accountDeletion*.js` et `index.js`) ; seule une modification directe par un administrateur (`firestore.rules:909`, `isAdmin()`) est possible, hors protocole financier.

Atteignabilité : le flux partenaires n'est actif que si `operations_control/account_deletion.partnerInventoryVersion === 1` (`partnerAccountDeletion.js:16`). Son état de production est **inconnu**.

Le commentaire du code (« ne suspend pas le travail existant ») est donc en tension avec la garde de 7E-72. **[OUVERT]** : distinguer « suppression demandée » (travail existant à terminer) de « quarantaine » (tombstone) dans la garde de confirmation, ou prévoir un chemin d'issue contrôlé.

### 7.4 Conditions de règlement proposées

Un règlement d'une obligation Ekbine engagée (crédit de l'agent, remboursement du client) n'est **jamais automatique** vers un compte fermé, absent ou anonymisé. Chemins admis **[PROP]** :

| Situation | Chemin | Conditions |
|---|---|---|
| Agent actif, client quelconque non tombstoné | confirmation normale | `proof_sent`, débit prouvé ; crédit = `debitedAmount` |
| Agent « suppression demandée » seulement | **[OUVERT]** : refus actuel ; autoriser le règlement de l'engagé serait cohérent avec 7E-87 D3 (b) et D6-b par analogie | décision du propriétaire |
| Agent en quarantaine ou scellé | refus ; sortie par **annulation de la demande de suppression** (D-7, avant `sealed`, sous nouvelle inspection) après quoi la confirmation redevient possible, **ou** par décision administrative N2 (futur writer) | aucune levée automatique ; N2 : deux responsables |
| Agent anonymisé ou absent | **aucun crédit** ; décision N2 avec preuve, résolution hors portefeuille (compensation hors système, jamais un crédit sur le profil anonymisé) | N2 ; preuve vérifiée côté serveur |
| Client fermé : remboursement dû | selon X-2 ; sinon par décision N2 hors portefeuille si le client est anonymisé | idem |
| Débit non prouvé | aucun mouvement automatique ; flags existants ; résolution N1/N2 selon `RESOLUTIONS` (2D-2A.1) ; **origine requise** pour N2, absente des anciens flags (bloquants) | 7E-107, D-6 |

---

## 8. Matrice des opérations

Colonnes : **A** autorisée, **R** refusée, **V** mise en revue (trace et résolution humaine). Les états de partie sont ceux du §1. Statut : **[CONF]**, **[CODE]**, **[PROP]**, **[OUVERT]**.

| # | Opération | Condition | Client actif | Client suppression demandée | Client en quarantaine/scellé | Agent actif | Agent suppression demandée | Agent quarantaine/scellé | Agent anonymisé/absent | Statut |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Créer une commande (`ekCreateOrderCF`) | nouvelle activité | A | R (`assertActive`) | R (wrapper + garde) | n/a | n/a | n/a | n/a | [CONF] 7E-73, [CODE] |
| 2 | Créer une commande en écriture directe | règles | A (si non tombstoné) | A | R (`isAuth`) | n/a | n/a | n/a | n/a | [CODE] ; [RISQUE] contourne les contrôles serveur tant que les règles l'autorisent |
| 3 | Accepter (`ekbineAcceptOrder`) | nouvelle mission | n/a | n/a | n/a | A | R | R | R | [CONF] 7E-68/73, [CODE] |
| 4 | Envoyer une preuve de dépôt (client) | commande engagée | A | A | R (wrapper) | n/a | n/a | n/a | n/a | [CODE] ; X-2 [OUVERT] |
| 5 | Confirmer/rejeter dépôt, démarrer (agent) | commande engagée | n/a | n/a | n/a | A | R | R | R | [CODE] |
| 6 | Écrire `proof_sent` (agent, règles) | commande engagée | n/a | n/a | n/a | A | A (non bloqué) | R | R | [CODE] ; [RISQUE] |
| 7 | **Confirmer** + régler l'agent (`ekClientConfirmOrder`) | `proof_sent`, débit prouvé | A | A | R (wrapper) | A (crédit) | **R** | **R** | **R** (aucun crédit) | [CONF] 7E-73 (agent), [CODE] ; X-2, X-3 [OUVERT] |
| 8 | Confirmer, paiement hors wallet | `proof_sent` | A | A | R (wrapper) | A, crédit 0 | R | R | R | [CODE] |
| 9 | Confirmer, débit non prouvé | `proof_sent` | A | A | R (wrapper) | A, crédit 0 + flag, revue | R | R | R | [CODE] |
| 10 | Annuler + rembourser (`ekCancelOrderCF`) | `pending`/`awaiting_deposit` ; débit prouvé | A | A | R (wrapper) | n/a | n/a | n/a | n/a | [CODE] ; X-2 [OUVERT] |
| 11 | Annuler, débit non prouvé | idem | A, aucun remboursement, flag **V** | A | R | n/a | n/a | n/a | n/a | [CODE] |
| 12 | Rembourser un client anonymisé ou absent | — | R : aucun crédit | R | R | n/a | n/a | n/a | n/a | [CONF] consigne ; [PROP] trace **V** |
| 13 | Créditer un agent anonymisé ou absent | — | n/a | n/a | n/a | n/a | n/a | n/a | R : aucun crédit, **V** | [CONF] consigne |
| 14 | Résoudre un flag Ekbine ancien (sans origine) | N2 | bloquant | bloquant | bloquant | bloquant | bloquant | bloquant | bloquant | [CONF] 7E-107, D-6 |
| 15 | Résoudre un flag Ekbine nouveau (avec origine) | N1/N2 selon `RESOLUTIONS` | N1 ou N2 par deux responsables | idem | idem | idem | idem | idem | idem, jamais par crédit vers un profil anonymisé | [PROP] ; writer 2D-2B non construit |
| 16 | Annuler la demande de suppression | avant `sealed`, nouvelle inspection | A (autorité à définir) | A | A avant `sealed` ; R après | A | A | A avant `sealed` ; R après | n/a | [CONF] D-7 (principe) ; modalités [OUVERT] |
| 17 | Toute levée automatique de quarantaine | — | R | R | R | R | R | R | R | [CONF] consigne |
| 18 | Réglage administratif d'une commande bloquée | writer inexistant | — | — | — | — | — | — | — | [OUVERT] ; seul le chemin manuel hors protocole existe |

---

## 9. Conséquences financières et traces d'audit

### 9.1 Conséquences

| Scénario | Effet | Ce qui garantit l'absence de perte |
|---|---|---|
| Confirmation refusée (agent fermé) | aucune écriture ; l'argent du client reste retenu par AZ (commande `proof_sent`) | aucune écriture partielle (refus dans la transaction) ; commande visible par le support |
| Agent anonymisé alors qu'une commande wallet est engagée | argent client retenu ; l'agent n'est pas payé | le moteur interdit l'anonymisation tant que la commande est non terminale (§3) |
| Annulation sans preuve de débit | aucun remboursement automatique | flag `ekbine_cancel_unproven_debit`, revue |
| Crédit de l'agent quand le solde est non nul avant suppression | `walletBalance ≠ 0` bloque la suppression (`accountDeletionScope.js:31-33`) | régularisation (7E-97 R6) |

### 9.2 Traces d'audit — état actuel [CODE]

| Événement | Trace |
|---|---|
| Création | `logAudit` après la transaction (succès) et pour les refus typés |
| Annulation | `logAudit` après la transaction ; le flag de non-preuve **après** (hors transaction) ; `logAudit` avale ses erreurs (`index.js:300-312`) |
| Confirmation réussie | ligne `audit_logs` **dans** la transaction (`ekbineOrders.js:325`), avec `creditReason` |
| Confirmation refusée (agent fermé) | **aucune trace** : l'erreur est levée avant toute écriture, sans passage par `logAudit` |

### 9.3 Traces requises [PROP]

1. Refus d'une confirmation pour cause de bénéficiaire fermé ou absent : une trace de revue idempotente **hors transaction**, sur le modèle de D6-a (flag `beneficiary_account_closed` posé après l'échec), afin que le support voie les commandes immobilisées ; **[A]** : décision du propriétaire, car Ekbine n'est pas nommé dans D6.
2. Flags d'annulation et de confirmation écrits **dans** la transaction, avec `origin`/`decidedBy` (P3 §5).
3. Toute résolution N1/N2 : décision, preuve, approbateurs, `requestId`, ligne `audit_logs` stricte.
4. Aucune trace ne contient de donnée personnelle (numéros, noms) ; identifiants techniques seulement.

---

## 10. Synthèse

### 10.1 Décisions confirmées en source

1. 7E-73 §1 : agent en quarantaine → échec sûr ; client en quarantaine → pas de création de commande Ekbine ; commandes terminées/engagées → comportement inchangé.
2. Frais = 0, le client paie le montant exact, l'agent gagne `amount` si wallet (code, mémoire du projet).
3. Aucun crédit automatique vers un compte anonymisé ou absent ; aucune levée automatique de quarantaine (consigne de cette mission).
4. Anciens flags Ekbine sans origine fiable : bloquants (7E-107, D-6).
5. Annulation de demande de suppression : principe uniquement avant `sealed`, sous nouvelle inspection (D-7).
6. N2 : deux responsables ; N3 bloquant (7E-102, 7E-105, 7E-107).

### 10.2 Contradictions documentaires non résolues

| # | Contradiction | Sources |
|---|---|---|
| X-1 | créditer l'agent en quarantaine (recommandation) ↔ refuser (décision) | 7E-87 D3 ↔ 7E-73 §1 ; arbitrage à confirmer (D5 D-8) |
| X-2 | « le client en quarantaine peut clôturer une commande engagée » ↔ le wrapper refuse tout appelant tombstoné ; les fonctions Ekbine ne sont pas dans la liste fermée de `onCallClosing` | 7E-72 audit §5, 7E-73 ↔ `index.js:83-90`, `index.js:2032, 2104, 2811` ; 7E-97 §5 |
| X-3 | « la suppression demandée ne suspend pas le travail existant » ↔ la garde de confirmation refuse `deletionRequested` ⇒ impasse | `partnerAccountDeletion.js:21-24` ↔ `accountAdmission.js:11`, 7E-72 |
| X-4 | formulation « l'agent valide » ↔ le client confirme ; le refus tient à l'état du bénéficiaire | 7E-73 §1 ↔ code |
| X-5 | l'alternative « terminer sans crédit + signalement » est écartée par 7E-72 sans décision métier finale | 7E-72 audit §5 |
| X-6 | l'annulation depuis `deposit_confirmed` est désactivée au lancement ; le client n'a pas d'autre issue que confirmer | `FINANCIAL_EKBINE_2026-11-03.md` ↔ besoins de clôture |

### 10.3 Points encore ouverts

1. Résolution de X-2 : (a) corriger la documentation, ou (b) étendre `onCallClosing` à des fonctions Ekbine.
2. Résolution de X-3 : traitement d'un agent « suppression demandée » avec commande engagée.
3. Arbitrage X-1 (D3 contre 7E-73).
4. Chemin de règlement administratif d'une commande Ekbine bloquée (aucun writer n'existe).
5. Trace de revue pour les confirmations refusées (§9.3).
6. Garde en transaction de `ekbineAgentDepositAction` et restriction des écritures directes d'agent « suppression demandée ».
7. Écriture directe des commandes par le client (règles) tant que l'application n'a pas migré.
8. Origine serveur des nouveaux flags et sort des anciens (D-6).
9. État de production de `partnerInventoryVersion` : inconnu.

### 10.4 Risques

1. Argent client immobilisé sans chemin de règlement contrôlé (X-3, X-2).
2. Résolution manuelle par modification directe de Firestore, hors traçabilité du protocole.
3. Fenêtres de course sur les fonctions non gardées en transaction (`ekbineAgentDepositAction`).
4. Une politique appliquée uniquement dans le code non commité : les gardes Ekbine ne sont pas dans HEAD.
5. Tests de 7E-72/7E-73 ne couvrant pas le wrapper : fausse assurance sur la clôture par un client fermé.

---

## 11. Prochaines autorisations (non approuvées)

1. Décisions du propriétaire sur X-1, X-2, X-3 et la trace de revue (§10.3) ; sans elles, aucune modification Ekbine ne doit commencer (lot L6 de P3).
2. Inventaire en lecture seule des états Ekbine résiduels (si une base de test synthétique existe) ; aucun accès production.
3. Ensuite seulement, lots de développement et tests de P3 §7, sur autorisation distincte.

Je m'arrête ici. Aucun lot n'est commencé.
