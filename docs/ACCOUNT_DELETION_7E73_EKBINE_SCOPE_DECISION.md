# Mission 7E-73 — Périmètre E-Kbine et décision sur le test des 8 appels

Date : 2026-11-07 · Aucun code modifié dans cette mission. Complète `ACCOUNT_DELETION_7E72_EKCLIENTCONFIRMORDER_AUDIT.md` et `…EKBINE_CONCURRENCY_ANALYSIS.md` (non remplacés).

## 1. Décision métier retenue (reprise telle que donnée)

- Un agent en quarantaine ne doit pas pouvoir valider une confirmation client qui entraîne une opération interdite ; le contrôle échoue de manière sûre.
- Un client en quarantaine ne peut pas créer de commande ; aucun wallet n'est nécessaire pour déclencher ce refus ; aucune commande n'est créée après la mise en quarantaine.
- Commandes terminées ou déjà engagées : comportement inchangé.

## 2. Conformité du code actuel (`functions/ekbineOrders.js`, +8 lignes de 7E-72)

| Exigence | Code | Test (`ekbineQuarantineGuards.test.js`, 11 tests) | Verdict |
|---|---|---|---|
| Confirmation : agent en quarantaine → échec sûr | `assertNewAccountActivity(tx, …, agentId, [['ekbine_agents', agentId]])` dans la transaction, **avant toute écriture** ; refus `failed-precondition`, commande reste `proof_sent`, aucun crédit, aucun audit de succès | tombstone ; profil `isDeleted` ; `deletionRequested` ; lecture en erreur ; course (tombstone posé après la lecture de la commande) | conforme |
| Création : client en quarantaine → refus sans wallet | même garde sur le client appelant, après `assertActive`, avant tout débit ni `tx.create` ; testé pour `wallet`, `orange_money`, `cash` | création refusée, solde 5000 intact, 0 commande | conforme |
| Aucune commande après la quarantaine | refus **dans la transaction** (pas seulement à l'entrée de la fonction) | course simulée | conforme (faux Firestore) |
| Commandes terminées / engagées inchangées | `alreadyDone` retourné **avant** la garde ; client appelant en quarantaine peut clôturer une commande engagée | 3 tests dédiés | conforme |
| Lecture du tombstone en erreur | l'erreur remonte, transaction sans écriture | 2 tests | conforme |

Aucune modification supplémentaire n'est nécessaire pour appliquer la décision retenue.

## 3. Dépendance cachée avec le moteur P1 ?

- Aucun fichier du commit 1 (`accountDeletion`, `accountCleanup`, `partnerAccountDeletion`, `accountDeletionSupport`) n'importe `ekbineOrders` ; vérifié par lecture des `require`.
- Inversement, `ekbineOrders.js` importe `assertNewAccountActivity` d'`accountAdmission.js`, **fonction déjà présente à HEAD** (le commit 2 n'ajoute à ce module que `assertTargetNotClosing`, que E-Kbine n'utilise pas). **Le commit E-Kbine ne dépend donc ni du commit 1 ni du commit 2.**
- Le moteur P1 lit déjà les `ekbine_orders` du compte pour décider de bloquer (`inspect`) : cela ne dépend pas de ces gardes.
- Les clients/livreurs sont les seuls rôles de P1 ; un agent E-Kbine n'a pas de tombstone tant que le périmètre partenaires est fermé (`partnerInventoryVersion` absent).

**Conclusion : le commit E-Kbine (commit 3) reste séparé de P1, de P2 et des gardes P3 (commit 3b).** `ekCreateOrderCF` et `ekClientConfirmOrder` ne sont pas dans le périmètre de déploiement P1.

## 4. Test `financialConcurrency.emulator` — « E-Kbine création : 8 appels simultanés »

**Décision : le test reste actif et inchangé. Aucune assertion modifiée, aucun retry ajouté.**

### Comportement observé
Le test lance 8 appels identiques (même client, même clé) et exige `8 réussites`, un seul `alreadyDone: false`, solde 4000, une commande. Il reçoit parfois `7 !== 8`.

| Contexte | Résultat |
|---|---|
| 7E-69, suite complète Node 24 | PASS |
| 7E-71, suite complète Node 24 (code avant 7E-72) | FAIL 7/8 (12,3 s) |
| 7E-72, suite complète Node 22 | FAIL 7/8 (11,9 s) |
| 7E-72, suite complète Node 24 ×2 | PASS (3,6 s) ×2 |
| Fichier seul, Node 24 ×3 | PASS 12/12 |
| Sonde 40 rondes × 8 appels, **code actuel** | 3 rondes en échec (7 sur 8), erreur `3 INVALID_ARGUMENT: Transaction is invalid or closed.` |
| Même sonde, **`HEAD:ekbineOrders.js`** | 2 rondes en échec (dont une à 1 réussite sur 8), même erreur |

### `INVALID_ARGUMENT` de l'émulateur contre `ABORTED` de Firestore réel
Quand des transactions concurrentes se disputent les mêmes documents, **Firestore réel** annule la perdante avec `ABORTED` (ou « transaction has expired »), que l'Admin SDK 7.11.6 **relance** (jusqu'à 5 tentatives, avec attente) ; l'appel aboutit donc. **L'émulateur** renvoie `INVALID_ARGUMENT: Transaction is invalid or closed`, que le SDK **ne relance pas** (seul le message « transaction has expired » est relancé, `transaction.js` `isRetryableTransactionError`) ; l'appel échoue. La différence est dans l'outil de test, pas dans le code de création.

### Conséquences financières observées
Dans **toutes** les rondes en échec (code actuel et HEAD) : solde final 4000, **une seule** commande, aucun double débit. L'échec est un appel rejeté, jamais une écriture incorrecte. Les rondes à 1 réussite sur 8 ont aussi conservé l'invariant.

### Limites de la preuve
- Résultats d'un **émulateur**, pas de Firestore réel : l'absence de double débit en production repose sur le caractère transactionnel (lecture avant écriture, `tx.create` sur un identifiant déterministe), non sur une mesure réelle de contention.
- Échantillon petit (40 rondes ×2 ; 5 suites complètes) : les fréquences (~5 % en sonde ; 2 échecs sur 5 suites complètes) sont indicatives.
- **Cause du déclenchement en suite complète non établie** : ni le fichier seul, ni le fichier précédé de `accountQuarantineConcurrency` ne reproduisent l'échec. Le test est donc un défaut de test d'intégration **non résolu**, pas une « intermittence expliquée ».
- Pas de test sur `HEAD` en suite complète (non fait).

### Modification de test éventuelle — présentée séparément, NON APPLIQUÉE
Option A : exécuter les 8 appels en deux rafales de 4. Option B : compter à part le rejet exact `INVALID_ARGUMENT / Transaction is invalid or closed` tout en gardant les assertions d'argent (solde 4000, 1 commande, au plus 1 `alreadyDone:false`) et exiger au moins 1 réussite. Justification technique : le comportement testé (idempotence et unicité du débit) ne dépend pas du nombre de rejets propres à l'émulateur. Risque : l'option B affaiblirait la détection d'une vraie régression qui ferait échouer des appels. **Décision humaine requise ; hors des 6 commits.**
