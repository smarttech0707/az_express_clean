# Mission 7E-88 — Lot 2A (gardes P2) : finalisation et validation locale

Date : 2026-11-09 · Strictement local. Aucun `git add`, commit, push, pull/merge/rebase/reset, déploiement, commande distante, changement de secret, activation de `operations_control/account_deletion` ni changement de configuration FeexPay. Production `az-express-b0469` non touchée. Rapport non suivi.

## 1. Constat principal
Les sept hunks P2 étaient **déjà présents et corrects** dans l'arbre de travail ; après audit, **aucune modification de code ni de test n'a été nécessaire**. Cette mission est donc une validation : aucun fichier de code ou de test n'a été modifié, aucune assertion ajoutée, supprimée ou affaiblie.

## 2. Manifeste exact du lot 2A
Fichiers de code (tous modifiés, non indexés) :
| Fichier | +/− | Rôle |
|---|---|---|
| `functions/index.js` (hunks 1–7 uniquement) | 27/12 au total, dont hunk 8 = P3 exclu | gardes recharge/retrait, import, options pilote |
| `functions/accountAdmission.js` | 10/1 | export de `assertTargetNotClosing` (requis par l'import du hunk 2 ; utilisé par P3, non appelé par 2A) |
| `functions/feexpayPayments.js` | 69/3 | `held_for_review`, `shouldHoldPayment`, idempotence webhook |
| `functions/azia/pendingActions.js` | 9/1 | garde `assertNewAccountActivity` dans la transaction de confirmation |
| `functions/azia/index.js` | 2/0 | options pilote pour `aiConfirmAction` |
| `functions/pilotCap.js` | 11/1 | `pilotLightOptions` (préprod uniquement) |

Tests du lot : `functions/test/accountQuarantineGuards.test.js` (220 l.), `accountQuarantineIndex.test.js` (169 l.), `accountQuarantineConcurrency.emulator.test.js` (247 l., 9 scénarios, ignoré sans émulateur), `pilotCap.test.js` (+52/−1) ; existants de régression : `feexpayPayments`, `pendingActions`, `accountDeletionHardening`.

Exclus explicitement (non touchés) : hunk 8 `setPharmaciePassword` (P3), `ekbineOrders.js` et `ekbineQuarantineGuards.test.js` (commit 3), `passwordReset`, `adminPartnerAccounts`, `professionalSubscriptions`, `restaurantV2Preprod.test.js`, pages légales, script de déploiement, lots 2B/2C/2D, outil held_for_review.

## 3. Les sept hunks P2
| # | Emplacement | Contenu | Fonction protégée |
|---|---|---|---|
| 1 | l.7 | import `pilotLightOptions` | — |
| 2 | l.80-82 | import `assertNewAccountActivity, assertTargetNotClosing` | — |
| 3 | l.378 | `...pilotLightOptions()` | `initiateFeexPayPayment` (capacité préprod) |
| 4 | l.454-470 | création du `wallet_transactions` pending dans `db.runTransaction` précédée de `assertNewAccountActivity(…, [[collectionFor(userType), uid]])` | `initiateFeexPayPayment` |
| 5 | l.565 | `...pilotLightOptions()` | `feexPayWebhook` |
| 6 | l.620 | `...pilotLightOptions()` | `initiateWithdrawal` |
| 7 | l.674-675 | `assertNewAccountActivity(firestoreTx, …, [[colName, uid]])` en première instruction de la transaction de débit | `initiateWithdrawal` |

Analyse par hunk garde (4 et 7) :
- **Risque** : nouvelle recharge ou nouveau débit pour un compte supprimé/en quarantaine (tombstone existant, `deletionRequested`, `isDeleted`) ; fonds réservés ou débités vers un compte en cours de suppression.
- **Point de contrôle** : relecture du tombstone, de `clients/{uid}` et du profil de rôle **dans la même transaction** que l'écriture ; échec de lecture = refus (fail-closed).
- **Moment** : après validation et limitation de débit, **avant** toute création de transaction / tout débit. Toutes les lectures de la garde précèdent les écritures (contrainte Firestore respectée ; en 7, la garde est avant la lecture du portefeuille, toutes lectures).
- **Compatibilité transactionnelle** : la garde lit le profil existant, donc une quarantaine concurrente (qui le modifie) provoque un conflit et un nouvel essai qui voit le tombstone (scénarios émulateur ; comportement de production non prouvé).
- **Opérations déjà engagées honorées** : la garde ne porte que sur les *nouvelles* opérations. Le webhook FeexPay d'une collecte créée avant le tombstone est crédité normalement (tests webhook) ; seule une collecte créée après quarantaine, ou sur profil anonymisé, passe en `held_for_review` sans toucher au portefeuille. L'annulation AZ IA reste permise (non gardée par conception). Compensations de retrait (`applyPayoutStatus`, `compensateFailedWithdrawal`) inchangées (lot 2C).
- **Double exécution** : le débit reste dans une seule transaction (solde relu) ; la recharge garde son contrôle « pending existant » ; le webhook est idempotent (`credited || completed || held_for_review`, à deux niveaux).

Garde AZ IA (fichiers de support) : `assertNewAccountActivity` dans la transaction de `aiConfirmAction`, après les contrôles de statut/uid et avant tout `confirmHandler`.

## 4. Modifications faites
Aucune (code, tests, règles). Seul ce rapport est créé.

## 5. Tests exécutés (Node v22.23.4)
`node -e "require('./index.js')"` : chargement OK.
`node --test` sur `accountQuarantineGuards`, `accountQuarantineIndex`, `pilotCap`, `feexpayPayments`, `pendingActions`, `accountDeletionHardening` :

**126 tests, 126 PASS, 0 échec, 0 annulé, 0 ignoré, ~10 s.**

Couverture : compte actif (opération normale), quarantaine et tombstone (refus recharge/retrait/confirmation AZ IA), profil anonymisé, opération engagée avant tombstone (crédit normal), idempotence et répétition du webhook (un seul crédit), absence de double débit/crédit, webhooks/schedulers non enveloppés, options de capacité (aucun changement en production ; 1 instance / 0,25 vCPU / concurrence 1 en préprod), barrière admin du moteur (D3).

## 6. Tests non exécutés
- `accountQuarantineConcurrency.emulator.test.js` (9 scénarios de concurrence) : **non exécuté** — il exige un émulateur Firestore et Java sur des ports dédiés ; les émulateurs de l'utilisateur occupent 5001/8080/9099 et n'ont pas été perturbés. Il reste à rejouer avant revue finale. Un résultat d'émulateur ne prouverait de toute façon pas le comportement de production.
- Suite `npm test` complète, `npm run test:rules`, `flutter test` : non exécutés (hors besoin).
- Aucun test de déploiement, de quota, ni sur appareil.

## 7. Risques résiduels
1. Concurrence prouvée uniquement sur émulateur (fichier ci-dessus non rejoué dans cette mission) ; atomicité qui repose sur la lecture d'un profil existant.
2. `aiConfirmAction` : la garde lit `clients/{uid}` seulement (acteurs non-clients sans conflit de lecture de profil) ; placée avant l'expiration (une action expirée est refusée au lieu d'être marquée expirée).
3. `afterConfirm` de la recharge AZ IA s'exécute hors transaction ; événement de sécurité/audit du webhook post-transaction en « best effort ».
4. **D4 : aucun outil pour lister/résoudre les paiements `held_for_review`** — bloquant avant activation avec FeexPay réel.
5. Lots 2B (createOrderFromQuoteCF, payBoutiqueOrderCF), 2C (restitutions D1/D2) et 2D (moteur) non traités : la couverture financière reste partielle.
6. `assertTargetNotClosing` est exporté dans le lot mais utilisé uniquement par le hunk P3 : le commit 2A doit l'embarquer sans le hunk 8.
7. Découpage du commit 2A : `functions/index.js` mélange hunks 1–7 (2A) et 8 (P3) ; un indexage par hunk sera nécessaire (patch `index_p2.patch` dans `test-env/runtime/7e73-patches/`).
8. **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE.**

## 8. État Git final
HEAD `294332e42bfb352b71eca861b08d6f36dee6e853` (inchangé), branche `finalisation/az-express`, index vide (0 fichier), `git status` : 89 entrées (88 avant le rapport + ce rapport). `git diff --check` : seuls des avertissements LF/CRLF, aucune erreur d'espace. `functions/index.js` : 8 hunks (7 P2 + 1 P3 distinct, non intégré). Commits 1 et 1B inchangés ; aucun fichier des lots 2B/2C/2D ou du commit 3 modifié par cette mission.

## 9. Opérations distantes
Aucune (pas de push, fetch, pull, déploiement, commande Firebase, appel réseau Git). `D:\h75.txt` non lu : à supprimer manuellement.

## Verdict
**LOT 2A IMPLÉMENTÉ — TESTS SOUS CONDITIONS**
Les sept hunks P2 sont présents, relus et validés (126/126 tests ciblés sous Node 22.23.4, chargement d'`index.js` OK), mais les 9 scénarios de concurrence sur émulateur n'ont pas été rejoués dans cette mission. Aucun commit créé. Arrêt : en attente d'une nouvelle autorisation humaine distincte.
