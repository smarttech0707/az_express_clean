# Mission 7E-93 — Corrections finales et préparation du Commit 2

Date : 2026-11-09 · Mission locale. Aucun `git add`, staging, commit, push, pull/merge/rebase/reset, déploiement, commande distante, changement de secret ou de production, activation de FeexPay. `git apply` n'a servi qu'en `--check` (sans écriture) et sur des copies du scratchpad. Rien supprimé du disque C:. Production `az-express-b0469` intouchée ; émulateurs de l'utilisateur (5001/8080/9099) non perturbés. Rapport non suivi.
Seule modification de fichier du dépôt : le test 2A (§1). Preuves : **[U]** unitaire · **[E]** émulateur Firestore local isolé · **[L]** lecture/diff.

## 1. Correction du comptage 2A
`functions/test/accountQuarantineConcurrency.emulator.test.js` : ajout, en fin de fichier, de la même branche `else` que celle posée sur les fichiers 2B en 7E-91 :
```js
} else {
  // Sans émulateur, aucun scénario n'est enregistré : on le DIT (ignoré) plutôt que de compter un faux « réussi ».
  test('concurrence quarantaine/paiement (lot 2A) — émulateur Firestore requis', { skip }, () => {});
}
```
247 → 250 lignes (+3 lignes), sha256 `2f60221ed650eb39` → `d634aeaca5d26da8`. Aucune assertion ni logique modifiée ; la branche n'est exécutée que si `skip` est vrai (émulateur absent, ou projet qui n'est pas `demo-*` / qui contient `az-express`).
Vérifications **[U]** :
| Situation | Avant | Après |
|---|---|---|
| sans émulateur | 1 test, **1 réussi** (faux) | 1 test, **0 réussi, 1 ignoré** |
| `FIRESTORE_EMULATOR_HOST` défini mais projet `az-express-b0469` (garde-fou « refus de tourner ») | — | 1 ignoré, aucune connexion tentée |
| les trois fichiers émulateur sans émulateur | 2 ignorés + 1 faux réussi | **3 ignorés, 0 réussi** |
Avec émulateur, le fichier exécute ses 9 scénarios inchangés (§2). Une vraie erreur n'est pas masquée : seul `skip` (environnement) déclenche l'ignoré.

**`functions/test/cashPayment.emulator.test.js` (hors Commit 2, non modifié)** : **correction de mon rapport 7E-92** : ce fichier n'a **pas** le défaut. Ses 7 tests sont déclarés au niveau racine avec `{ skip }` ; sans émulateur : 7 tests, 0 réussi, **7 ignorés** (mesuré). Mon repérage par motif en 7E-92 était trop grossier. Le seul faux « réussi » du dépôt était donc le fichier 2A, maintenant corrigé.

## 2. Résultats des tests (Node v22.23.4)
**Suite complète, arbre de travail réel** (`node --test test/*.test.js`) : **2350 tests, 2181 réussis, 0 échec, 0 annulé, 169 ignorés**. Écart avec 7E-92 (2350 / 2182 / 168) : −1 réussi, +1 ignoré = le faux réussi du fichier 2A devenu ignoré ; total inchangé. Historique 7E-90 : 2349 / 2183 / 166 (écart cumulé expliqué : +1 fichier de test 7E-91, et deux faux réussis devenus ignorés).
**Tests unitaires ciblés** : voir §6 (copie « HEAD + Commit 2 »).
**Émulateur isolé** `demo-7e93`, `127.0.0.1:18089` (hub 14400, logging 14500, Firestore seul), exécuté **dans la copie « HEAD + Commit 2 »** (§4), `--test-concurrency=1` : **18 tests, 18 réussis, 0 échec, 0 ignoré** [E].
| Fichier | Résultats notables |
|---|---|
| 2A `accountQuarantineConcurrency` (9) | A : 3 créées / 22 refusées ; A2 : 8 / 17 ; B ; **B2 : 20 exécutées avant, 5 bloquées par la garde (première exécution où la branche de refus AZ IA est observée en concurrence)** ; E ; C1 : 0 rejet, aucun double crédit ; C2 : 25 crédités / 25 mis en attente ; C3 ; D |
| 2B `walletDebitQuarantine` (6) | Q1 : 14 acceptées / 11 refusées (6 garde, 5 contention) ; Q2 : 0 / 25 (24 garde, 1 contention) ; Q3 : 0 / 25 ; Q0, Q4 (un seul débit), Q5 (un seul achat) |
| 2B `…Orderings` (3 × 74 rondes) | quote : `quarantine_first` 0/12, `call_first` 12/0, `during` 23 acc./2 garde, `jitter` 23/2 ; wallet : `during` 23/2, `jitter` 16 acc./7 garde/2 contention ; cash : `during` 25/0, `jitter` 9 acc./16 garde |
Invariants vérifiés à chaque ronde (7E-91/92) : aucune commande ni débit validé après le tombstone, refus ⇒ aucun effet, un seul débit, pas de double retrait de stock.
**Comportement sans émulateur** : 3 fichiers = 3 ignorés, 0 réussi (§1).
**Suite complète de la copie « HEAD + Commit 2 »** : voir §4 (25 échecs identiques à HEAD pur, tous dus à des fichiers hors `functions/`).
**Non exécutés** : Flutter (`test/quote/` et analyse) non rejoué — aucun fichier Flutter modifié depuis 7E-91 (55/55, analyse propre) ; `npm run test:rules` (Java) et tests d'appareil.

## 3. Analyse de `functions/accountAdmission.js`
Diff : **+10/−1**, ajoute `assertTargetNotClosing` et son export ; `assertNewAccountActivity` est **inchangée** (déjà à HEAD).
| Usage de `assertTargetNotClosing` | Fichier | Lot |
|---|---|---|
| appel (`setPharmaciePassword`, l. 1887) + import de nom (l. 82) | `index.js` | appel = hunk 8 (**P3**) ; import = hunk 2 (**2A**, destructuration commune aux deux noms) |
| appel (l. 69) | `passwordReset.js` | P3 / commit 3b |
| appel (l. 203) | `adminPartnerAccounts.js` | P3 / commit 3b |
| 3 assertions (l. 217-219) | `accountQuarantineGuards.test.js` | 2A (test unitaire du helper, sans lien avec le callable `setPharmaciePassword`) |
Aucun code du lot 2B (`deliveryQuote.js`, `orderActions.js`) ni des gardes 2A (`feexpayPayments.js`, `azia/pendingActions.js`, hunks 4 et 7) ne l'appelle. Ils n'utilisent que `assertNewAccountActivity`, déjà présente à HEAD.
**Mesure (copie « HEAD + Commit 2 » avec `accountAdmission.js` remis à sa version HEAD)** [U] : `index.js` **charge** (135 exports ; `assertTargetNotClosing` importé = `undefined`, jamais appelé) ; `accountQuarantineIndex` 11/11, `pendingActions` 10/10, `walletDebitQuarantineGuards` 28/28 ; **seul échec : 1 test du helper** dans `accountQuarantineGuards` (`TypeError`, 16/17). Donc le Commit 2 ne dépend **pas fonctionnellement** de ce fichier ; la dépendance est **textuelle** (import du hunk 2) et **de test** (1 test).
**Options** :
- **A (recommandée) — inclure `accountAdmission.js` en entier.** Ajout purement additif (une fonction exportée, aucun appelant dans le commit), aucun effet comportemental ; hunk 2 conservé tel que validé ; le futur commit P3 n'aura plus à toucher ce fichier ; le test du helper reste dans 2A et passe.
- **B — découper** : (i) ne pas inclure `accountAdmission.js` ; (ii) réécrire le hunk 2 pour n'importer que `assertNewAccountActivity` (donc un **patch P2 modifié**, différent de celui validé en 7E-88/89) ; (iii) retirer du fichier de test le test du helper, ou le déplacer. Trois retouches, un patch non validé, et le commit P3 devrait réintroduire import, fonction et test. Plus risqué, bénéfice purement cosmétique.
**Décision humaine à prendre** (A recommandée). Le comportement métier du P3 (`setPharmaciePassword`) n'est modifié dans aucune des deux options ; le hunk 8 reste hors du commit.

## 4. Manifeste du Commit 2 (reconstitué à partir du diff réel) — 17 chemins
Copie de contrôle « HEAD + Commit 2 » (scratchpad, hors dépôt) construite avec exactement ces fichiers ; comparaison ignorant les fins de ligne : **seuls ces 15 chemins `functions/` diffèrent de HEAD** (9 modifiés dont `index.js`, 6 nouveaux), aucun autre.
| # | Chemin | Statut Git | Hunks / contenu | Lot | Tests associés | Hors périmètre dans le fichier ? |
|---|---|---|---|---|---|---|
| 1 | `functions/index.js` | M (+27/−12) | **hunks 1 à 7** (= `index_p2.patch`, 37 lignes ajoutées/supprimées) | 2A | `accountQuarantineIndex`, `pilotCap`, `accountQuarantineConcurrency` (A, A2) | **OUI : hunk 8 (P3), à exclure** |
| 2 | `functions/accountAdmission.js` | M (+10/−1) | fichier entier | 2A (appui P3) | `accountQuarantineGuards` | aucun ; contenu utilisé seulement par P3 (§3, option A) |
| 3 | `functions/feexpayPayments.js` | M (+69/−3) | entier : `HELD_STATUS`, `shouldHoldPayment`, branche de mise en attente | 2A | `accountQuarantineGuards`, `feexpayPayments`, C1-C3 | non |
| 4 | `functions/azia/pendingActions.js` | M (+9/−1) | entier : garde de confirmation, `options` | 2A | `accountQuarantineGuards`, `pendingActions`, B, B2 | non |
| 5 | `functions/azia/index.js` | M (+2) | entier | 2A | `pilotCap` | non |
| 6 | `functions/pilotCap.js` | M (+11/−1) | entier | 2A | `pilotCap` | non |
| 7 | `functions/test/pilotCap.test.js` | M (+52/−1) | entier (import + 3 tests) | 2A | — | non |
| 8 | `functions/test/accountQuarantineGuards.test.js` | ?? (220 l., sha `a23a6debf5b53702`) | entier | 2A | — | contient 1 test du helper P3 et 3 tests de la barrière admin du moteur (comportement du commit 1) : sans dépendance au hunk 8 |
| 9 | `functions/test/accountQuarantineIndex.test.js` | ?? (169 l., sha `d1ead735e30b5262`) | entier | 2A | — | non |
| 10 | `functions/test/accountQuarantineConcurrency.emulator.test.js` | ?? (250 l., sha `d634aeaca5d26da8`) | entier, **version corrigée** | 2A | — | non |
| 11 | `functions/deliveryQuote.js` | M (+4/−0) | entier | 2B | `walletDebitQuarantineGuards`, `deliveryQuote`, Q1, Q4, O-quote | non |
| 12 | `functions/orderActions.js` | M (+7/−0) | entier (3 hunks : import, wallet, espèces) ; `buildPayOrderFromWallet` (l. 48-493) intact | 2B | idem boutique : Q2, Q3, Q5, O-wallet, O-cash | non |
| 13 | `functions/test/walletDebitQuarantineGuards.test.js` | ?? (199 l., sha `99c8672924a30e32`) | entier | 2B | — | non |
| 14 | `functions/test/walletDebitQuarantine.emulator.test.js` | ?? (173 l., sha `67407fc30fca1eeb`) | entier | 2B | — | non |
| 15 | `functions/test/walletDebitQuarantineOrderings.emulator.test.js` | ?? (241 l., sha `5d2dab114b3bdfc7`) | entier | 2B | — | non |
| 16 | `lib/widgets/quoted_checkout_runner.dart` | M (+12/−0) | entier | 2B (Flutter) | `quote_account_closing_test` | non |
| 17 | `test/quote/quote_account_closing_test.dart` | ?? (159 l., sha `18ed20d5bd9485ad`) | entier | 2B (Flutter) | — | non |
Totaux : 10 modifiés (dont `index.js` partiel) + 7 nouveaux = 17 ; **16 fichiers entiers + 1 partiel (`index.js`)**.
**Dépendances vérifiées** : `deliveryQuote.js`, `orderActions.js`, `azia/pendingActions.js` n'importent que `assertNewAccountActivity` (à HEAD) ; les tests 2B n'utilisent que des aides suivies (`billingWorld.js`, `fakeFirestore.js`, `fake_quote_server.dart`) ; aucun des 17 fichiers n'importe un fichier non suivi hors manifeste (confirmé par la copie de contrôle). Aucun fichier n'est retenu au seul titre d'un ancien manifeste.

## 5. Séparation P2 / P3
- Lignes ajoutées/supprimées actuelles de `functions/index.js` : **39 = 37 (P2) + 2 (P3)**, identiques aux patchs de référence (`index_p2.patch` sha `0a1ce967…`, `index_p3.patch` sha `8d0beea9…`, inchangés) ; 8 hunks.
- `git apply --check --reverse index_p2.patch` : exit 0 sur l'arbre de travail ; les deux patchs s'appliquent individuellement au blob HEAD ; la copie « HEAD + P2 » contient **0** occurrence du hunk 8 (`assertTargetNotClosing(db`).
- Aucun autre fichier du manifeste ne mélange P2 et P3 (`accountAdmission.js` : seul cas d'appui, traité au §3). Les fichiers P3 (`passwordReset.js`, `adminPartnerAccounts.js`, `professionalSubscriptions.js`, `test/passwordReset.test.js`) sont hors manifeste.
- Compilable et testable : copie « HEAD + Commit 2 » → `index.js` charge ; tests ciblés **[U]** ci-dessous réussis ; émulateur 18/18 **[E]** ; suite complète de la copie : 2208 tests, 2053 réussis, **25 échecs identiques à HEAD pur** (2146 / 1994 / 25 / 127 ignorés dans la même copie partielle). Les 25 échecs sont des `ENOENT` sur des fichiers situés hors de `functions/` (`lib/`, `firestore.rules`, `firebase.json`, `web/`…), absents de ma copie partielle : l'ensemble des noms d'échecs est **identique** (diff vide). Écart attendu : +62 tests = 56 (17 + 11 + 28) + 3 (`pilotCap`) réussis + 3 émulateur ignorés.
Tests ciblés dans la copie (Node 22.23.4) : accountQuarantineGuards 17/17, accountQuarantineIndex 11/11, pilotCap 10/10, feexpayPayments 52/52, pendingActions 10/10, accountDeletionHardening 26/26, accountAdmission 7/7, walletDebitQuarantineGuards 28/28, deliveryQuote 22/22, deliveryQuoteWiring 2/2, billingCompatibility 25/25, marketplaceBoutiqueBilling 26/26, orderActions 85/85, catalogQuote 25/25, manifestLoad 1/1 ; 3 fichiers émulateur sans émulateur : 3 ignorés.

## 6. Plan d'indexation sélective (à exécuter lors d'une mission ultérieure **autorisée**, jamais ici)
Depuis `D:\az_express_clean`, shell Git Bash. S'arrêter à la première vérification qui échoue.
```bash
# 0. Préconditions
test "$(git rev-parse HEAD)" = 294332e42bfb352b71eca861b08d6f36dee6e853
test "$(git branch --show-current)" = finalisation/az-express
test -z "$(git diff --cached --name-only)"                       # index vide
P=test-env/runtime/7e73-patches
sha256sum $P/index_p2.patch $P/index_p3.patch                    # 0a1ce9678fb9651a… / 8d0beea98a4dea15…
git apply --check --reverse $P/index_p2.patch                    # P2 est bien dans l'arbre
sha256sum functions/test/accountQuarantineConcurrency.emulator.test.js   # d634aeaca5d26da8…
# 1. 16 fichiers ENTIERS (chemins explicites ; jamais « . » ni « -A »)
git add -- \
  functions/accountAdmission.js functions/feexpayPayments.js \
  functions/azia/index.js functions/azia/pendingActions.js functions/pilotCap.js \
  functions/deliveryQuote.js functions/orderActions.js functions/test/pilotCap.test.js \
  functions/test/accountQuarantineGuards.test.js functions/test/accountQuarantineIndex.test.js \
  functions/test/accountQuarantineConcurrency.emulator.test.js \
  functions/test/walletDebitQuarantineGuards.test.js functions/test/walletDebitQuarantine.emulator.test.js \
  functions/test/walletDebitQuarantineOrderings.emulator.test.js \
  lib/widgets/quoted_checkout_runner.dart test/quote/quote_account_closing_test.dart
# 2. functions/index.js : les SEULS hunks 1 à 7, dans l'index (l'arbre de travail n'est pas touché)
git apply --cached $P/index_p2.patch
# 3. Vérifications avant commit
git diff --cached --name-status                                  # exactement 17 lignes : 10 M + 7 A
git diff --cached --check
git diff --quiet -- functions/accountAdmission.js functions/feexpayPayments.js functions/azia functions/pilotCap.js \
  functions/deliveryQuote.js functions/orderActions.js lib/widgets/quoted_checkout_runner.dart   # exit 0 : rien de non indexé
diff <(git diff --cached -U0 functions/index.js | grep -E '^[+-][^+-]' | sort) <(grep -E '^[+-][^+-]' $P/index_p2.patch | sort)   # vide
git diff -U0 functions/index.js | grep -c '^@@'                  # 1 : il ne reste que le hunk 8 (setPharmaciePassword)
git diff -U0 functions/index.js | grep -c 'assertTargetNotClosing(db'   # 1
git status --short | grep -c '^[MA]'                             # 17
# 4. Test de l'arbre INDEXÉ exact (copie hors dépôt)
T=$(git write-tree); D=<scratchpad>/stage; mkdir -p $D; git archive $T functions | tar -x -C $D
(cd $D/functions && NODE_PATH='D:\az_express_clean\functions\node_modules' node22 --test test/accountQuarantine*.test.js test/walletDebit*.test.js test/pilotCap.test.js test/feexpayPayments.test.js test/pendingActions.test.js test/deliveryQuote.test.js test/orderActions.test.js)
# 5. Commit (sans --no-verify), puis contrôles
git commit -F <scratchpad>/msg_commit2.txt
git show --stat --format='%H %s' HEAD                            # 17 fichiers
test "$(git rev-list --count 294332e..HEAD)" = 1
git diff HEAD -- functions/index.js | grep -c '^@@'              # 1 (hunk 8 seul, reste non committé)
git status --short                                               # reste = fichiers hors manifeste (+ index.js M)
# Pas de push, pas de déploiement.
```
- **Retour arrière avant commit** (index seulement, l'arbre de travail est conservé) : `git restore --staged -- <chemins>`. Après commit : le retour éventuel est une décision humaine (pas de `reset` dans ce plan).
- **Message de commit proposé** :
```
security(account-deletion): block new financial activity for accounts in deletion

Lot 2A: re-read the tombstone inside the transaction that creates a top-up
request (initiateFeexPayPayment) and the one that debits a withdrawal
(initiateWithdrawal); hold verified FeexPay payments received on an anonymized
profile or created after quarantine (held_for_review) instead of crediting
them; re-check the account when an AI action is confirmed (aiConfirmAction);
preprod-only capacity options for these functions (production unchanged).
Lot 2B: same in-transaction guard for createOrderFromQuoteCF, payBoutiqueOrderCF
and payBoutiqueOrderCashCF; the Flutter checkout shows a clear message when the
server refuses a new order for an account being deleted.

Tests: unit tests, in-transaction ordering and concurrency scenarios against an
isolated Firestore emulator (demo project), Flutter contract tests.
Not included: setPharmaciePassword guard and other P3 guards, E-Kbine, refund
and credit policies, deletion-engine inspection gaps, held_for_review tool.
No deployment; the deletion gate stays closed.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
```

## 7. Réserves restantes (inchangées, non masquées)
1. `Transaction is invalid or closed` : reproduit avec le SDK Admin seul sans code AZ Express (14/200 contre 0/200) **[E]**, non démontré en production **[H]** ; rejouée aujourd'hui (Q1 : 5 sur 25 ; Q2 : 1 ; wallet-jitter : 2), toujours sans écriture.
2. Refus « pendant la transaction » : nouveau constat — `during` : cash 0/25 refus, quote 2/25, wallet 2/25. Conception : une quarantaine lancée après la lecture de la garde est validée après l'appel ; le refus est exercé par `quarantine_first` et `jitter` (cash : 16 refus au jitter aujourd'hui). Le cas reste peu exercé en mode `during` **[E]**.
3. Flutter dépend encore du texte serveur (`ACCOUNT_DELETION_IN_PROGRESS`, `Compte supprime ou en cours de suppression`) ; le flux devis est **inactif** et n'a jamais été testé sur appareil.
4. Un fichier d'émulateur sans émulateur est maintenant **ignoré** (3/3) ; plus aucun faux « réussi » connu.
5. **Quota Cloud Run NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE** ; `pilotLightOptions` ne s'applique qu'en préproduction.
6. Hors lots, bloquants avant activation : outil `held_for_review` (D4), lots 2C et 2D, commit 3 (E-Kbine), gardes P3.
7. Un seul appareil/émulateur non requis pour ce commit ; `npm run test:rules` (Java) non rejoué.
8. Disque C: : 331 Mo libres (rien supprimé ; voir 7E-92 §9) — risque pour les suites Flutter.

## 8. État Git final
HEAD `294332e42bfb352b71eca861b08d6f36dee6e853` · branche `finalisation/az-express` · index vide (0) · 0 commit au-delà de `294332e` · aucun push, aucun déploiement · Commit 1 (`65e738b`, 9 fichiers, +719/−32) et Commit 1B (`294332e`, 4 fichiers, +163/−4) inchangés · `functions/index.js` : 8 hunks identiques à P2+P3 · `git status` : 101 entrées avant ce rapport (identiques à l'avant-mission, hors ce rapport, les chemins relatifs mis à part) · `git diff --check` : uniquement des avertissements LF/CRLF · `cashPayment.emulator.test.js` non modifié. Ports 18089/14400/14500/9151 libres ; 5001/8080/9099 en écoute (non touchés). Aucune opération distante ; `D:\h75.txt` non lu.

## Verdict
**COMMIT 2 PRÊT — AUTORISATION HUMAINE POSSIBLE**
La correction de comptage est faite ; le manifeste (17 chemins), la séparation P2/P3 et la copie de contrôle « HEAD + Commit 2 » (tests ciblés, 18/18 d'émulateur, mêmes 25 échecs de copie partielle que HEAD pur) sont établis ; le plan d'indexation sélective est prêt. Une décision reste à votre charge avant autorisation : **inclusion de `accountAdmission.js` en entier (option A, recommandée) ou découpage (option B)**. Aucun commit, aucune indexation, aucun push, aucun déploiement. Arrêt : en attente d'une nouvelle autorisation humaine distincte.
