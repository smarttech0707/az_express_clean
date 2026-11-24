# Mission L2.1 — Correction des inspecteurs de retraits et audit des tests de concurrence C7/C7b

Statut : terminée, arrêt avant toute autorisation supplémentaire. Aucun commit, aucun push, aucun déploiement, aucun accès à `az-express-b0469`. L3 non lancée, aucun writer financier branché.

## 1. Problème initial

L'inspecteur historique traite `withdrawal_requests` avec l'ensemble de statuts terminaux des **commandes** (`INSPECTOR_TERMINAL_STATUSES`). `sent` (payout confirmé par FeexPay) et `processed` (règlement manuel admin) n'y figurent pas : un compte ayant déjà effectué un retrait abouti est donc refusé à la suppression comme s'il avait une obligation ouverte.

Reproduction (script hors dépôt, moteur + inspecteur existants) : `sent` → bloqué (`active_or_unresolved_operation`), `processed` → bloqué, `failed_refunded` → mis en quarantaine. Défaut confirmé.

## 2. Statuts de retrait et décisions

Statuts établis d'après les écritures réelles (`initiateWithdrawal`, `applyPayoutStatus`, `checkWithdrawalStatus`, `adminApproveWithdrawalCF`), pas d'après les seuls libellés.

| Statut | Écrit par | Décision |
|---|---|---|
| `processing` | initiateWithdrawal (solde débité, payout non accusé) | OUVERT → bloque |
| `provider_pending` | référence obtenue, état non final | OUVERT → bloque |
| `pending_manual` | issue ambiguë, mismatch, suivi épuisé | OUVERT → bloque |
| `sent` | applyPayoutStatus SUCCESSFUL (`settlementConfirmed:true`) | CLOS **si** `settlementConfirmed===true`, `compensated!==true`, ni `needsReview` ni `anomaly` ; sinon AMBIGU |
| `processed` | adminApproveWithdrawalCF (`settlementConfirmed:true`, `processedBy`) | CLOS si mêmes conditions **et** `processedBy` non vide ; sinon AMBIGU |
| `failed_refunded` | compensation unique (`compensated:true`, wallet recrédité) | CLOS si `compensated===true`, `settlementConfirmed!==true`, sans `needsReview`/`anomaly` |
| tout autre (dont l'ancien `pending`, `completed`, casse erronée, statut illisible) | — | AMBIGU → bloque |

Autres cas bloquants : drapeaux contradictoires (`compensated` et `settlementConfirmed` ensemble), drapeau non booléen, montant invalide, `userId` sans rapport avec le compte, document non objet. Liste : absente, non tableau, sans preuve de couverture, tronquée (201), taille incohérente, doublon, requête incomplète ⇒ bloque (une liste vide sans preuve de lecture n'est pas une preuve).

## 3. Modifications

- `functions/accountObligations.js` (moteur, non suivi) : ajout de `classifyWithdrawal`, `evaluateWithdrawals`, `WITHDRAWAL_STATUS`, `WITHDRAWAL_STATE`, `WITHDRAWAL_REASONS`. `evaluateAccountObligations` inchangé.
- `functions/test/accountObligationsWithdrawals.test.js` (nouveau, 12 tests) : matrice par statut, documents produits par les **vrais** écrivains (`applyPayoutStatus` appelé sans le modifier, `buildAdminApproveWithdrawal`), couverture des listes, absence de fuite de texte, non-régression du moteur. Contrôle par mutation : faire ignorer `settlementConfirmed` à `sent` fait échouer 1 test.
- `functions/test/support/sealStateChecker.js` et `functions/test/accountClosureSealState.test.js` (nouveaux, 14 tests) : vérificateur d'état final de C7/C7b et son contrôle négatif.
- `functions/test/accountClosureProtocol.emulator.test.js` : C7 et C7b réécrits.

**Non modifié** : `feexpayPayments.js`, webhook, `index.js`, règles Firestore, E-Kbine, les 16 writers non gardés, `accountClosureProtocol.js`, `accountDeletion.js`, `accountDeletionScope.js`.

### Point à signaler — branchement hors périmètre

Le prédicat est corrigé et testé **mais pas branché** : la sur-restriction réelle persiste en production du code tant qu'il n'est pas appelé. Le brancher exige de modifier `accountDeletion.js`, `accountDeletionScope.js` et `accountObligationsInspector.js`, hors du périmètre autorisé. Branchement minimal proposé (à autoriser séparément) : retirer `withdrawal_requests` des listes génériques de l'inspecteur historique ; lire `withdrawal_requests where userId==id limit(201)` avec reçu de couverture (`{key:'userId', id, limit:201, size}`) ; appeler `evaluateWithdrawals` et fusionner son résultat dans le blocage.

## 4. Audit de C7 et C7b

Constats sur l'ancienne version (L2) : le rejet émulateur `3 INVALID_ARGUMENT: Transaction is invalid or closed` était compté puis ignoré ; le test ne vérifiait ni l'état final complet, ni l'absence de suppression prématurée, ni la convergence après rejet.

Nouvelle version :
- seule l'erreur `code 3` + `Transaction is invalid or closed` est tolérée ; toute autre erreur fait échouer le test ;
- nombre de tentatives par processus compté (exécutions du callback de lecture ; le SDK rejoue seulement sur les erreurs qu'il estime rejouables) ;
- après chaque ronde, `assertSafeSealState` : phase ∈ {closing, sealed} ; si scellé : jeton tombstone = jeton dossier, `sealEpoch = epoch = 0`, empreintes identiques, `sealedAtMs` présent ; si closing : aucun champ de scellé ni jeton sur le dossier ; jamais `deleting`, `deleteStartedAtMs`, `authDeletedAtMs` ; profil du compte intact ; epoch et empreinte du dossier inchangés ;
- au plus un scellement effectif ; scellé sans succès enregistré = anomalie comptée (`committedDespiteReject`) ;
- rejeu séquentiel des processus rejetés : le détenteur du bail converge (`ok`), le non-détenteur reçoit `closure_lease_lost`, jamais un succès ;
- le vérificateur est lui-même testé : 14 tests purs (états sûrs acceptés ; 13 corruptions refusées : jeton divergent, état à moitié écrit, `deleting` posé, `authDeletedAtMs`, compte modifié, epoch, empreinte, etc.).

Résultats (émulateur local dédié, projet `demo-l2-c7a`, 10 rondes chacun) :
- **C7** : `{"emulatorRejects":2,"bothOk":8,"oneOk":2,"noneOk":0,"committedDespiteReject":0,"replays":2,"maxAttempts":3,"meanAttempts":1.75}` — 2 rejets émulateur (rondes 4 et 6, rejet dès la première lecture, 0 callback exécuté), l'autre processus a scellé (`tok-b`), le rejeu du rejeté a convergé, état final sûr à chaque ronde.
- **C7b** : `{"emulatorRejects":0,"holderRejected":0,"otherRejected":0,"replays":20,"committedDespiteReject":0,"maxAttempts":1}` — le non-détenteur n'a jamais réussi, `tok-theirs` jamais écrit, le détenteur a toujours scellé.
- Détail par ronde conservé hors dépôt : `scratchpad\l2\c7_detail.jsonl` (20 lignes).

Conclusion et limites : sur ces exécutions, un rejet `INVALID_ARGUMENT` n'a laissé aucun état dangereux et la reprise converge. Ce n'est **pas** une preuve du comportement de Firestore en production (où la contention donne ABORTED et le SDK rejoue) ; c'est une preuve sur émulateur, sur 10 rondes par scénario. Le protocole garantit la sûreté par le bail + epoch + jeton vérifiés dans la transaction, pas par l'absence de rejet.

## 5. Résultats exacts (Node 22.23.4, garde de sortie réseau active)

- Retraits : 12/12 ; avec tests moteur : 72/72.
- Vérificateur C7 (contrôle négatif) : 14/14.
- Émulateur, `^L2-C7` seul : 2/2.
- Suite pure complète : **2518 tests, 2345 réussis, 0 échec, 0 annulé, 173 ignorés** (référence L2 : 2492/2319/0/173 ; écart +26 = 12 + 14).
- C2 non rejoué : le chemin de quarantaine utilisé par C2 n'a pas été touché (seuls `accountObligations.js` et des tests ont changé).
- Émulateur propre arrêté ; ports 5001, 8080, 9099, 9199, 4000 préexistants intacts.

## 6. Contrôle de préservation

HEAD `d65c8f0` ; branche `finalisation/az-express` ; index vide ; stash 0 ; **25** fichiers suivis modifiés ; non suivis (`git status`) : 127 avant ce rapport, 128 avec lui (124 + `accountObligationsWithdrawals.test.js` + `accountClosureSealState.test.js` + `support/sealStateChecker.js` ; le rapport s'ajoute). Écart avec l'attendu « 126 » : `test/support/` n'est pas replié, les deux nouveaux fichiers de test et le vérificateur comptent chacun. Cinq hashes sensibles inchangés (`21a9cc9a`, `9f00f1c1`, `976c2396`, `1a5cde55`, `26975f60`).

## 7. Risques restants

- Prédicat de retraits non branché (voir §3) : la sur-restriction subsiste dans le flux réel.
- Un administrateur peut modifier les champs de retrait (règles : update admin) : un faux « clos » écrit à la main n'est pas détectable par le prédicat.
- `needsReview` et `anomaly` sont traités de façon conservatrice (bloquent) : un retrait résolu sans effacer ces marques restera bloquant.
- Ancien statut `pending` : bloque (le serveur ne l'écrit plus) ; à purger si des documents historiques existent.
- Rôles hors moteur (`ekbine_agent`, `real_estate_agent`, `fleet_owner`) : contrôles historiques seulement.
- 16 writers B/C/D toujours non gardés ; registre de décisions vide jusqu'à L7.
- Les preuves de concurrence restent émulateur seulement.

## 8. Conséquences pour L3

L3 doit inclure le branchement des retraits (§3) avant de s'appuyer sur l'inspecteur pour les comptes ayant déjà retiré. Les writers de retraits (`checkPendingWithdrawals`, `adminApproveWithdrawalCF`) devront être gardés par le verrou financier ; le prédicat suppose que ces écrivains posent bien `settlementConfirmed` et `compensated` comme aujourd'hui. Aucune hypothèse de L2 sur le protocole (T1/T2/T2b/F/T3) n'est modifiée.

Arrêt : en attente de votre autorisation pour le branchement et pour L3.
