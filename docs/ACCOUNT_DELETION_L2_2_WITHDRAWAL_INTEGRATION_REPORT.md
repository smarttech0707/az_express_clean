# Mission L2.2 — Branchement de la classification des retraits dans les chemins de suppression

Statut : terminée, arrêt avant toute autorisation. Aucun commit, push ni déploiement ; aucun accès à `az-express-b0469` ; L3 non lancée ; les 16 autres writers non branchés ; webhook FeexPay non modifié.

## 1. Branchements effectués (3 fichiers autorisés)

Le prédicat `classifyWithdrawal` / `evaluateWithdrawals` de `accountObligations.js` (L2.1) n'est pas modifié. Un point d'entrée unique le rend appelable des chemins réels :

| Fichier | Modification |
|---|---|
| `functions/accountObligationsInspector.js` | Nouvelle fonction `inspectWithdrawals(tx, db, {accountUid})` (+ export `WITHDRAWAL_BLOCK`). Une requête `withdrawal_requests where userId == uid limit(201)`, reçu de couverture `{key, id, limit, size}`, appel de `evaluateWithdrawals`. Retourne `{blocking, reason, docs}`. Toute exception de lecture se propage. |
| `functions/accountDeletion.js` (client/livreur) | `inspect()` : `withdrawal_requests` retiré de la liste générique de requêtes (qui jugeait les statuts avec l'ensemble des commandes) ; après cette liste, appel de `inspectWithdrawals` (même position de lecture qu'avant : dernière). Les retraits réglés restent ajoutés à `related` (champs personnels purgés comme avant). |
| `functions/accountDeletionScope.js` (partenaires, tous rôles du périmètre) | La requête `withdrawal_requests` est marquée `kind:'withdrawal'` et traitée par le même `inspectWithdrawals`. Rôles hors moteur (agents E-Kbine, immobilier, flotte) inclus : ils passent par ce périmètre, pas par le moteur. |

Motifs de refus conservés (compatibles avec les tests et l'exploitation) : ouvert → `active_or_unresolved_operation` ; ambigu / sans preuve / inconnu → `financial_regularization_required` ; 201 résultats → `history_requires_manual_review`. Les contrôles historiques `refundPending === true` et `paymentStatus === 'pending'` restent bloquants, même sur un retrait « réglé ».

**Troisième chemin (suppression manuelle, `manualAccountDeletion.js`)** : ce fichier ne lit pas `withdrawal_requests` et n'est pas dans la liste autorisée. Il n'y avait donc rien à brancher, et aucune divergence n'existe aujourd'hui. Il n'a pas été modifié ; si une vérification des retraits y est voulue, c'est une modification distincte à autoriser (le helper est prêt).

Non modifiés : `feexpayPayments.js`, webhook, `index.js`, règles, E-Kbine, `accountClosureProtocol.js`, `partnerAccountDeletion.js`, `manualAccountDeletion.js`.

## 2. Classification finale (inchangée depuis L2.1)

| Statut | Décision |
|---|---|
| `processing`, `provider_pending`, `pending_manual` | OUVERT → bloque |
| `sent` | clos seulement si `settlementConfirmed===true`, `compensated!==true`, sans `needsReview`/`anomaly` |
| `processed` | idem + `processedBy` non vide |
| `failed_refunded` | clos seulement si `compensated===true`, `settlementConfirmed!==true`, sans `needsReview`/`anomaly` |
| inconnu / illisible / ancien `pending` / montant ou drapeau invalide / contradictoire | AMBIGU → bloque |
| lecture incomplète, tronquée, en erreur | bloque (erreur : la transaction échoue, rien n'est écrit) |

## 3. Preuves de règlement

Établies à L2.1 d'après les écritures réelles, jamais le nom du statut : `applyPayoutStatus` (SUCCESSFUL → `sent` + `settlementConfirmed:true`, FAILED → compensation `compensated:true`) et `adminApproveWithdrawalCF` (`processed` + `settlementConfirmed:true` + `processedBy`). Les 12 tests de L2.1 construisent les documents avec ces vraies fonctions.

## 4. Tests (Node 22.23.4, garde de sortie réseau active)

Nouveau fichier `test/accountDeletionWithdrawals.test.js` : 48 tests, sur les chemins réels (`buildAccountDeletion` complet : demande → quiétude → inspection → scellé/suppression Auth simulée) :
- client **et** partenaire (rôle `seller`), 21 cas chacun : `sent` / `processed` / `failed_refunded` confirmés ne bloquent plus (suppression terminée, scellé posé) ; plusieurs retraits tous réglés ; `sent` sans preuve, `sent` avec `settlementConfirmed:false`, `processed` sans preuve ou sans `processedBy`, `failed_refunded` sans compensation ; `processing`, `provider_pending`, `pending_manual` ; réglé + en attente ; réglé + sans preuve ; statut inconnu, ancien `pending`, statut absent ; montant absent ; drapeaux contradictoires ; `needsReview` ; `refundPending` ; chaque bloqué vérifie le motif, l'absence d'appel `delete` Auth et l'absence de scellé ;
- livreur (réglé / en cours), retrait d'un autre compte ignoré, retraits réglés conservés dans l'historique, plafond 201, erreur de lecture (client et partenaire : la transaction échoue, aucun `delete`, jamais scellé).
- Contrôle par mutation (prédicat remplacé par « tout retrait non `failed_refunded` bloque ») : 10 tests échouent ; fichier restauré (comparé identique).

Adaptation d'un test existant, signalée : le test de périmètre de `accountObligations.test.js` interdisait toute mention de `accountObligations` dans `accountDeletionScope.js` ; il exige maintenant que le fichier n'importe pas le moteur directement (`require('./accountObligations')` absent) mais bien l'inspecteur. Aucun test négatif supprimé.

Résultats :
- Classification des retraits + moteur + inspecteur + protocole + registre + suppression durcie + manuelle + nouveaux : 209 tests dont 208 OK au premier passage ; l'échec (test de périmètre ci-dessus) a été corrigé légitimement, 60/60 après correction.
- **Suite pure complète : 2566 tests, 2393 réussis, 0 échec, 0 annulé, 173 ignorés** (référence L2.1 : 2518/2345/0/173 ; écart +48 = nouveaux tests).
- Émulateur local `demo-l22-emu*` (config dédiée, ports 28080/24400/24500), fichier L2 complet : **8/8** — dont C7b `{"emulatorRejects":2,"holderRejected":0,"otherRejected":2,"replays":20,"committedDespiteReject":0,"maxAttempts":2}`, C2real-T1 25 rondes 0 rejet webhook, C2real-T2b 25/25 scellées 0 rejet.
- Émulateur arrêté ; ports 5001, 8080, 9099, 9199, 4000 préexistants intacts.

Régressions : aucune. Une exécution de la suite complète lancée avant la correction du test de périmètre l'a vu échouer (course entre l'édition et la lecture du fichier) ; la relance propre est à 0 échec.

## 5. Statut de C2

`inspect()` s'exécute dans la transaction de quarantaine T1 de `buildAccountDeletion` : j'ai donc rejoué le protocole L0-F. Les lectures sont les mêmes documents, dans le même ordre (la requête retraits reste en dernière position) ; seule leur évaluation change. Webhook, `feexpayPayments.js`, ordre de lecture et tests C2 non touchés.
- 20 rejeux isolés de `C2.` (projets `demo-l2c2-isoN`) : **17 PASS / 3 FAIL** (iso5, iso15, iso20), les trois par `3 INVALID_ARGUMENT: Transaction is invalid or closed` — résultat identique à L2 (17/3) et dans la fourchette de la base L0-F (5/21 échecs). C2 reste **intermittent ; il n'est pas corrigé** et je ne le déclare pas corrigé. Aucun invariant financier violé n'a été observé dans les rejeux L2-C2real (T1 et T2b : 0 rejet webhook).
- Limite : preuve sur émulateur uniquement, rien sur Firestore de production.

## 6. Contrôle de préservation

HEAD `d65c8f0` ; branche `finalisation/az-express` ; index vide ; stash 0 ; cinq hashes sensibles inchangés (`21a9cc9a`, `9f00f1c1`, `976c2396`, `1a5cde55`, `26975f60`). Écarts annoncés :
- fichiers suivis modifiés : **26** (au lieu de 25) — `accountDeletionScope.js` était propre et a été modifié sur autorisation ; les hunks préexistants de `accountDeletion.js` sont intacts (modifications ajoutées uniquement) ;
- non suivis : **129** (128 + `test/accountDeletionWithdrawals.test.js`) ; ce rapport s'ajoute (130).

## 7. Risques restants

- `manualAccountDeletion.js` ne contrôle pas les retraits (comportement inchangé, à décider).
- Un administrateur peut modifier les champs d'un retrait : un faux « réglé » écrit à la main n'est pas détectable.
- Les retraits n'entrent pas dans l'empreinte `snapshotDigest` : T2b les contrôle via `inspect()` (blocage) mais un retrait créé puis réglé entre T2 et T2b ne change pas l'empreinte ; les ouvertures sont bloquées dans la même transaction, les retraits en cours de création relèvent du verrou financier des writers (non branchés, L3).
- `initiateWithdrawal`, `checkPendingWithdrawals`, `adminApproveWithdrawalCF` ne sont toujours pas gardés par le verrou : une course writer/scellement sur ces chemins reste ouverte (L3).
- `needsReview`/`anomaly` bloquent de façon conservatrice ; l'ancien statut `pending` bloque.
- C2 intermittent sur émulateur ; aucune preuve de production.

Arrêt : en attente de votre autorisation (décision sur le chemin manuel, puis L3).
