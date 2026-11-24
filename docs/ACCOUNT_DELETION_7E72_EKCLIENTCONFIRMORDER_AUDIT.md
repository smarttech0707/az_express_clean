# Mission 7E-72 — Audit de `ekClientConfirmOrder` (et de `ekCreateOrderCF`)

Date : 2026-11-07 · Code : `functions/ekbineOrders.js` (`buildEkClientConfirmOrder`, `buildEkCreateOrder`) · Câblage : `functions/index.js` (`ekClientConfirmOrder` : `maxInstances 2, cpu 0.5`). Analyse locale uniquement.

## 1. Rôles et documents

| Élément | Constat |
|---|---|
| Appelant | le **client** (`clients/{uid}`, `order.clientId === uid` exigé) |
| Agent bénéficiaire | `ekbine_agents/{order.agentId}` : c'est son `walletBalance` qui est crédité (+ `totalCompleted`, `lastOrderId`) |
| Montant crédité | dérivé de la **preuve de débit** de la commande (`debitedAmount` si `provenDebit`), jamais de `agentEarning` ; 0 hors wallet ou sans preuve |
| Statut | `proof_sent → completed` ; `completed` avec `agentCredited` défini → `alreadyDone` sans écriture |
| Écritures (une seule transaction) | `ekbine_orders/{id}` (statut, `agentCredited`, `creditReason`), `ekbine_agents/{agentId}` (incrément), `reconciliation_flags` (si débit non prouvé), `audit_logs` |

## 2. Avant 7E-72 : ce qui manquait

La transaction lisait la commande et l'agent, **sans** relire `account_tombstones/{agentId}` ni les marqueurs `isDeleted` / `deletionRequested` du profil agent. Un agent en cours de suppression ou anonymisé pouvait donc être crédité. Le profil agent est le seul document concerné ; le client appelant n'est pas bénéficiaire.

## 3. La suppression d'un agent peut-elle se produire en P1 ?

Le moteur du pilote P1 (`accountDeletion.js`) ne traite que les rôles `client` et `livreur` (`ROLES`). Un tombstone d'agent E-Kbine ne peut naître que par le moteur **partenaires** (`partnerAccountDeletion.js`), atteint seulement si `operations_control/account_deletion.partnerInventoryVersion === 1` — valeur absente dans le pilote. De plus, un UID client qui possède aussi un profil agent est bloqué (`multiple_roles_manual_review`).
→ **Pour le pilote synthétique P1, le scénario « agent en quarantaine » est inatteignable par le chemin nominal.** Il devient réel dès l'ouverture du périmètre partenaires. Raison de corriger maintenant : la garde est peu coûteuse, et sans elle l'ouverture partenaires aurait créé silencieusement un crédit sur compte supprimé.

## 4. Fenêtre de course

Quarantaine posée entre `tx.get(orderRef)` et l'écriture du crédit : sur Firestore réel, la transaction est annulée/relancée si un document lu a changé, mais le **tombstone n'était pas dans les documents lus** (il peut même ne pas exister encore au moment de la lecture) ; la création du tombstone par le moteur ne conflictue donc pas avec la confirmation. D'où la relecture explicite du tombstone dans la transaction, avant les écritures : une création concurrente de tombstone invalide la lecture et force la relance, qui refuse alors.

## 5. Correctif appliqué (local, non commité)

`ekbineOrders.js`, dans `buildEkClientConfirmOrder`, après la lecture de l'agent et avant toute écriture :

```js
await assertNewAccountActivity(tx, db, HttpsError, agentId, [['ekbine_agents', agentId]]);
```

Propriétés :
- **Fail-closed** : si la lecture du tombstone échoue, l'erreur remonte, la transaction n'écrit rien (testé).
- **Refus sans changement d'état** : la commande reste `proof_sent`, aucun crédit, aucun audit de succès ; le support peut la traiter.
- **Idempotence conservée** : le contrôle est placé *après* le retour `alreadyDone` ; un rejeu d'une commande déjà `completed` ne change rien, même si l'agent est ensuite en quarantaine (testé).
- **Pas de nouvelle règle financière** : montants, preuve de débit, signalements de réconciliation et flux inchangés.
- Le client appelant en quarantaine **peut** encore clôturer une commande déjà engagée (aucune nouvelle activité ; le moteur refuse d'ailleurs la quarantaine tant qu'une commande E-Kbine est non terminale) — testé.

**Décision métier signalée** : si l'agent est fermé, le client ne peut pas confirmer (refus). Alternative possible : terminer la commande **sans** crédit avec un signalement `reconciliation_flags` (comme `unproven_debit`). Non retenu ici car elle change l'issue financière ; à trancher avec le métier.

## 6. Découverte liée : `ekCreateOrderCF` sans garde de quarantaine

La création de commande (`buildEkCreateOrder`) n'appliquait que `assertActive` (`deletionRequested` / `isDeleted` / `isBlocked`). Or le moteur ne pose `deletionRequested` que pour le rôle **livreur** ; la quarantaine d'un **client** pose `isSuspended` et le tombstone, deux marqueurs que `assertActive` ne lit pas. Conséquence démontrée par test sur le code de `HEAD` :
- un client en quarantaine pouvait créer une commande **hors wallet** (`orange_money`, `cash`…), sans débit à bloquer, qui apparaît ensuite comme opération non terminale ;
- les commandes wallet restent limitées par le solde nul exigé pour la suppression.
Le moteur re-inspecte à chaque passage (`inspect`) et bloquerait le dossier, mais la fenêtre entre la dernière inspection et l'anonymisation restait ouverte.

Correctif (une ligne, même schéma que 7E-68), dans la transaction de création, après `assertActive` et avant toute écriture :
```js
await assertNewAccountActivity(tx, db, HttpsError, uid, []);
```
Le rejeu d'une même clé (commande déjà créée) retourne toujours `alreadyDone` sans débit. Cette fonction (`ekCreateOrderCF`) **n'est pas** dans le périmètre de déploiement P1 ; la modification est incluse parce que le défaut « action après quarantaine » a été démontré, et elle peut être retirée du commit sans impact sur P1 (`functions/ekbineOrders.js` est déjà classé « P3 reporté »).

## 7. Tests ajoutés — `functions/test/ekbineQuarantineGuards.test.js` (11 tests)

| Cas demandé | Test | Sur `HEAD` | Avec correctif |
|---|---|---|---|
| Agent normal | confirmation, tombstone absent → crédité une fois | PASS | PASS |
| Agent en quarantaine | tombstone → refus, aucun crédit, commande `proof_sent` | **FAIL** | PASS |
| Profil agent anonymisé / `deletionRequested` | refus, aucun crédit | **FAIL** | PASS |
| Tombstone absent | cas nominal ci-dessus | PASS | PASS |
| Lecture du tombstone en erreur | échec sûr, aucun crédit | **FAIL** | PASS |
| Quarantaine avant la confirmation (course) | tombstone posé après la lecture de la commande → refus | **FAIL** | PASS |
| Double confirmation | un seul crédit ; rejeu après quarantaine → `alreadyDone` | PASS | PASS |
| Commande déjà terminée / annulée | `alreadyDone` / « Statut invalide » | PASS | PASS |
| Client appelant en quarantaine | peut clôturer une commande engagée | PASS | PASS |
| Création : client en quarantaine (wallet, orange_money, cash) | refus, aucune commande, solde intact | **FAIL** | PASS |
| Création : lecture du tombstone en erreur | échec sûr | **FAIL** | PASS |
| Création : rejeu de clé après quarantaine | `alreadyDone`, un seul débit | PASS | PASS |

Mesure : sur le `ekbineOrders.js` de `HEAD`, 6 de ces tests échouent ; avec le correctif, 11/11. Suites E-Kbine existantes (`ekbineOrders`, `ekbineDepositFlow`, `ekbineReconciliation`) : 43/43 inchangées (54 au total).

## 8. Limites

- Preuves au **faux Firestore** (pas de concurrence réelle) pour ces 11 tests ; la course « tombstone posé pendant la transaction » est simulée en le posant après la lecture de la commande. Le comportement de relance sur Firestore réel n'est pas démontré ici.
- Aucun test de bout en bout avec un agent réellement supprimé (périmètre partenaires fermé).
- `ekCancelOrderCF` (remboursement vers le wallet du client) n'a pas été modifié : le client en quarantaine n'a pas de commande non terminale (le moteur le refuse), et un remboursement ne crée pas d'activité nouvelle. **Non vérifié par émulateur.**
