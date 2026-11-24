# Mission 7E-92 — Revue globale des lots 2A et 2B avant Commit 2

Date : 2026-11-09 · Revue uniquement. Aucun `git add`, staging, commit, push, pull/merge/rebase/reset, déploiement, commande distante, changement de secret ou de configuration, activation de FeexPay. Aucun fichier de code, de test ou de configuration modifié par cette mission (seul ce rapport est créé). Production `az-express-b0469` non touchée ; émulateurs de l'utilisateur (5001/8080/9099) non perturbés. Rapport non suivi.

Convention de preuve : **[U]** preuve unitaire (faux Firestore) · **[E]** preuve d'émulateur Firestore local isolé · **[L]** lecture de code / de diff · **[H]** hypothèse non vérifiée.

## 1. Résumé exécutif
- Les **sept hunks P2** de `functions/index.js` sont **identiques** à ceux validés en 7E-88/89 : les lignes ajoutées du diff actuel (39) sont exactement celles des patchs de référence `index_p2.patch` (37) + `index_p3.patch` (2) ; `git apply --check --reverse` réussit sur l'arbre de travail et les deux patchs s'appliquent individuellement au blob HEAD. **[L]**
- Le **lot 2B** est limité à `deliveryQuote.js` (+4), `orderActions.js` (+7, trois hunks), deux fichiers de test unitaire/émulateur, un fichier d'ordonnancements, 12 lignes Flutter et 1 test Flutter. `payOrderFromWalletCF` (`buildPayOrderFromWallet`, l. 48-493) n'a aucune garde et aucun hunk. **[L]**
- Preuves rejouées aujourd'hui (Node 22.23.4) : tests unitaires ciblés **tous réussis** ; **18/18 scénarios d'émulateur réussis, 0 ignoré** (2A : 9, 2B : 9) sur un émulateur isolé `demo-7e92` ; Flutter `test/quote/` 55/55 et analyse propre (7E-91).
- **Défaut de comptage découvert** : `accountQuarantineConcurrency.emulator.test.js` (lot 2A) compte **1 « réussi »** sans émulateur alors qu'aucun scénario ne s'exécute (même défaut que celui corrigé en 7E-91 pour les fichiers 2B ; `cashPayment.emulator.test.js`, hors lots, l'a aussi). À corriger avant Commit 2 (test seulement).
- Deux fichiers contiennent des modifications **mélangées** : `functions/index.js` (7 hunks 2A + 1 hunk P3) et `functions/accountAdmission.js` (fonction d'appui du hunk P3, importée par le hunk 2 de 2A). Un indexage **par hunk** est nécessaire pour `index.js`.
- Verdict : **LOTS VALIDÉS AVEC RÉSERVES — CORRECTIONS AVANT COMMIT** (une correction de test mineure et une décision de découpage ; voir §10).

## 2. Revue du lot 2A
### 2.1 Les sept hunks de `functions/index.js`
| # | Ligne | Nature | Fonction | Événement protégé | Statut vérifié | Position | Risque de concurrence | Tests | Preuve |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 7 | import `pilotLightOptions` | — | — | — | — | — | `pilotCap.test.js` | [U][L] |
| 2 | 80-82 | import `assertNewAccountActivity, assertTargetNotClosing` | — | — | — | — | — | chargement d'`index.js` | [L] |
| 3 | 378 | `...pilotLightOptions()` | `initiateFeexPayPayment` | capacité préprod (1 instance, 0,25 vCPU, concurrence 1) ; `{}` en production | — | options | — | `pilotCap.test.js` (production inchangée, préprod plafonnée) | [U] |
| 4 | 454-470 | **garde** dans `db.runTransaction` | `initiateFeexPayPayment` | nouvelle demande de recharge (`wallet_transactions` pending) | tombstone + `clients/{uid}` + profil du rôle : refus si tombstone, `deletionRequested`, `isDeleted` ; lecture en erreur ⇒ refus | première instruction de la transaction, après validation et limite de débit, avant la création | quarantaine entre le contrôle d'entrée et l'écriture ⇒ conflit via le profil lu, nouvel essai voit le tombstone | `accountQuarantineIndex` (recharge ×5), scénario A | [U] [E] |
| 5 | 565 | `...pilotLightOptions()` | `feexPayWebhook` | capacité préprod | — | options | — | `pilotCap.test.js` | [U] |
| 6 | 620 | `...pilotLightOptions()` | `initiateWithdrawal` | capacité préprod | — | options | — | `pilotCap.test.js` | [U] |
| 7 | 674-675 | **garde** dans `db.runTransaction` | `initiateWithdrawal` | nouveau débit / réservation de fonds | idem hunk 4 (profil de `collectionFor(userType)`) | première instruction de la transaction de débit, avant la lecture du solde | idem | `accountQuarantineIndex` (retrait ×5), scénario A2 | [U] [E] |
Seuls les hunks 4 et 7 sont des gardes ; 1, 2, 3, 5, 6 sont des imports ou des options de capacité. **Hunk 8 (`setPharmaciePassword`, l. 1886) = P3 distinct, hors 2A.** [L]

### 2.2 Gardes du lot 2A portées par les fichiers d'appui
| Fichier | Contenu | Garde / protection | Tests | Preuve |
|---|---|---|---|---|
| `feexpayPayments.js` (+69/−3, hunks tous liés au webhook) | `HELD_STATUS`, `shouldHoldPayment`, branche de mise en attente | paiement vérifié sur profil anonymisé, ou créé après le tombstone, ou tombstone sans date lisible ⇒ `held_for_review`, wallet intact, HTTP 200 ; collecte créée avant la quarantaine ⇒ créditée ; idempotence à deux niveaux | `accountQuarantineGuards` (webhook ×6), `feexpayPayments` (52) ; scénarios C1, C2, C3 | [U] [E] |
| `azia/pendingActions.js` (+9/−1) | garde dans la transaction de confirmation | action préparée avant la quarantaine jamais exécutée après (avant `confirmHandler`) ; l'annulation reste permise | `accountQuarantineGuards` (AZ IA ×6), `pendingActions` (10) ; scénarios B, B2 | [U] [E] |
| `azia/index.js` (+2), `pilotCap.js` (+11/−1), `pilotCap.test.js` (+52/−1) | options de capacité préprod | production inchangée | `pilotCap` (10) | [U] |
| `accountAdmission.js` (+10/−1) | `assertTargetNotClosing` + export | aide du hunk P3 (non appelée par 2A) | 1 test unitaire de la fonction | [U] |
Vérifié par lecture : `feexpayPayments.js` ne contient aucune modification de la compensation de retrait (`applyPayoutStatus`, `compensateFailedWithdrawal`) → lot 2C non touché. [L]

## 3. Revue du lot 2B
| Élément | Constat | Preuve |
|---|---|---|
| `deliveryQuote.js:199` | `assertNewAccountActivity(tx, db, HttpsError, uid)` dans la transaction, après `assertActiveClient`, avant débit et création ; le rejeu d'un devis utilisé retourne avant (aucune écriture) ; couvre wallet **et** espèces (nouvelle commande) | [U] [E] |
| `orderActions.js:1337` (`payBoutiqueOrderCF`) | garde juste après la lecture du client, partenaire `sellers/{sellerId}`, avant contrôle de solde et toute écriture | [U] [E] |
| `orderActions.js:1540` (`payBoutiqueOrderCashCF`) | garde avant la première écriture (stock) ; aucun wallet touché (testé) | [U] [E] |
| Lecture du tombstone / quarantaine | dans la transaction, fail-closed (lecture impossible ⇒ aucun effet) | [U] |
| Absence de débit après tombstone | toute commande validée ≤ tombstone (`createTime`), refus ⇒ aucune commande, solde intact | [E] 222 rondes d'ordonnancements + 75 rondes (Q1-Q3) |
| Idempotence | devis : rejeu ⇒ même commande, solde inchangé ; 3 appels simultanés ⇒ un seul débit (Q4) | [U] [E] |
| Double débit / double retrait de stock | deux achats pour un solde ⇒ un seul (Q5) ; stock retiré = nombre d'acceptations, crédit vendeur cohérent | [E] |
| Commande créée après refus | non : refus ⇒ 0 commande, nouvelles tentatives refusées sans effet | [U] [E] |
| Premier niveau de défense | les trois callables passent par le wrapper `onCall` (`assertAccountEnabled`, `permission-denied` / `ACCOUNT_DELETION_IN_PROGRESS`) ; la garde transactionnelle est le second niveau | [L] |
| Flutter | `quoted_checkout_runner.dart` (+12) : `isAccountClosingRefusal` + message clair ; refus ⇒ `CheckoutFailed` (jamais de succès ni de commande locale, reprise effacée) ; `internal`/réseau ⇒ incertain ; `quote_account_closing_test.dart` 6 tests | [U] Flutter |
| `payOrderFromWalletCF` | hors lot : `buildPayOrderFromWallet` (l. 48-493) sans garde ni hunk ; les trois hunks `orderActions.js` sont aux l. 13, ~1335, ~1538 | [L] |
Aucune anomalie de code relevée dans 2B. [L]

## 4. Contrôle des tests (rejoué aujourd'hui, Node v22.23.4)
| Fichier | tests | réussis | ignorés | Remarque |
|---|---|---|---|---|
| `accountQuarantineGuards` | 17 | 17 | 0 | 2A, [U] |
| `accountQuarantineIndex` | 11 | 11 | 0 | 2A, [U] |
| `pilotCap` | 10 | 10 | 0 | 2A, [U] |
| `feexpayPayments` | 52 | 52 | 0 | régression webhook |
| `pendingActions` | 10 | 10 | 0 | régression AZ IA |
| `accountDeletionHardening` | 26 | 26 | 0 | commit 1 |
| `walletDebitQuarantineGuards` | 28 | 28 | 0 | 2B, [U] |
| `deliveryQuote` / `billingCompatibility` / `marketplaceBoutiqueBilling` | 22 / 25 / 26 | tous | 0 | régression 2B |
| `accountQuarantineConcurrency.emulator` (sans émulateur) | 1 | **1 (faux)** | 0 | **aucun scénario exécuté**, compté « réussi » |
| `walletDebitQuarantine.emulator`, `…Orderings.emulator` (sans émulateur) | 1 / 1 | 0 | 1 / 1 | correct (ignoré) |
**Émulateur isolé `demo-7e92` (`127.0.0.1:18089`, hub 14400, logging 14500) — les trois fichiers, `--test-concurrency=1` : 18 tests, 18 réussis, 0 échec, 0 ignoré, 749 s.** Détail : 2A A (6 créées / 19 refusées), A2 (10 / 15), B, B2 (25 exécutées avant / 0 bloquées), E, C1 (2 rejets de transaction rejoués, aucun double crédit), C2 (25 crédités / 25 mis en attente), C3, D ; 2B Q1 (12 / 13 dont 9 garde + 4 contention), Q2 (1 / 24), Q3 (0 / 25), Q0, Q4, Q5 ; ordonnancements : quote (during 21 acc./4 garde, jitter 20/3/2 contention), wallet (during 25/0, jitter 15/10), cash (during 25/0, jitter 20/5), `quarantine_first` 0/12 garde et `call_first` 12/0 pour les trois.
**Suite Functions complète (7E-91, code inchangé depuis)** : 2350 tests, 2182 réussis, 0 échec, 168 ignorés. Historique 2349/2183/166 ; l'écart (+1 test, −1 réussi, +2 ignorés) est expliqué en 7E-91. **Correction de ce chiffre** : les 2182 « réussis » contiennent au moins **1 faux réussi** (fichier 2A ci-dessus) et **1** autre préexistant (`cashPayment.emulator`, hors lots) ; les réussis réellement exécutés sont donc au plus 2180, les ignorés réels au moins 170. Aucun fichier émulateur n'est compté comme exécuté ici.
Flutter (7E-91) : `flutter test test/quote/` 55/55 ; `flutter analyze` des deux fichiers : aucune alerte. Non rejoué dans cette mission (aucun fichier Flutter modifié depuis).

## 5. Réserves techniques (conservées)
1. **`Transaction is invalid or closed`** : reproduit avec le SDK Admin seul sans code AZ Express (14/200 contre 0/200 selon qu'une lecture suit celle du profil) **[E]** ; non démontré pour Firestore de production **[H]**. Rejouée aujourd'hui : 4/25 en Q1 et 2/25 en jitter-quote. Effet toujours sans écriture (fail-closed).
2. **Refus tardif de `payBoutiqueOrderCashCF`** dans le scénario « quarantaine lancée dans la transaction » : **0/25 refusé** (7E-91 : 0/25 ; ici 0/25) — **et aujourd'hui aussi `payBoutiqueOrderCF` : 0/25** (7E-91 : 3/25). Explication de conception : une quarantaine lancée après la lecture de la garde attend le verrou et est validée APRÈS l'appel (la commande précède le tombstone, invariant respecté) ; le refus se produit seulement si la quarantaine est validée avant la lecture de la garde, exercé par `quarantine_first` et `jitter` (cash : 5 à 7 refus, wallet : 10 à 12). Le chemin « refus pendant la transaction » reste donc peu exercé **[E]**.
3. **Flutter** dépend du texte serveur (`ACCOUNT_DELETION_IN_PROGRESS`, `Compte supprime ou en cours de suppression`), sans `details.reason` ; à remplacer si le contrat serveur évolue **[L]**.
4. **Flux devis inactif** (`QuotedOrderConfig.enabled = false`, wallet seul) et jamais testé sur appareil/émulateur Android dans ces lots.
5. **Tests d'émulateur ignorés/absents** : un fichier dont les scénarios ne s'enregistrent pas sans émulateur ne doit jamais compter comme exécuté (défaut ci-dessus, 2A).
6. **Quota Cloud Run** : **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE** ; `pilotLightOptions` ne s'applique qu'en préproduction.
7. Autres limites connues : B2 (garde AZ IA) : 0 blocage observé en concurrence, branche de refus couverte en unitaire seulement ; la garde AZ IA lit `clients/{uid}` uniquement ; émulateur ≠ production ; `afterConfirm` de la recharge AZ IA hors transaction ; événement de sécurité/audit du webhook en « meilleur effort » ; l'outil `held_for_review` n'existe pas (D4) : **bloquant avant activation avec FeexPay réel** ; achats boutique sans clé d'idempotence (inchangé).

## 6. Manifeste exact du futur Commit 2 (vérifié sur le diff actuel)
### A. Lot 2A
| Fichier | État | Contenu à inclure | Remarque |
|---|---|---|---|
| `functions/index.js` | modifié (+27/−12) | **hunks 1 à 7 uniquement** (= `index_p2.patch`, 37 lignes) | **FICHIER MÉLANGÉ** : exclure le hunk 8 (`setPharmaciePassword`, = `index_p3.patch`). Indexation par hunk obligatoire. |
| `functions/accountAdmission.js` | modifié (+10/−1) | fichier entier | **MÉLANGÉ par usage** : définit `assertTargetNotClosing`, appelée seulement par P3/commit 3b ; importée (nom) par le hunk 2. Décision humaine : l'inclure entier (recommandé, cohérent avec l'import) ou scinder. |
| `functions/feexpayPayments.js` | modifié (+69/−3) | fichier entier | tous les hunks = webhook |
| `functions/azia/pendingActions.js` | modifié (+9/−1) | fichier entier | |
| `functions/azia/index.js` | modifié (+2) | fichier entier | |
| `functions/pilotCap.js` | modifié (+11/−1) | fichier entier | |
| `functions/test/pilotCap.test.js` | modifié (+52/−1) | fichier entier | |
| `functions/test/accountQuarantineGuards.test.js` | nouveau, 220 l., sha `a23a6debf5b53702` | fichier entier | contient 1 test du helper P3 et 3 tests de barrière admin du moteur (commit 1) : sans dépendance au hunk 8 |
| `functions/test/accountQuarantineIndex.test.js` | nouveau, 169 l., sha `d1ead735e30b5262` | fichier entier | |
| `functions/test/accountQuarantineConcurrency.emulator.test.js` | nouveau, 247 l., sha `2f60221ed650eb39` | fichier entier **après** correction du comptage (§10) | |
### B. Lot 2B
| Fichier | État | Contenu |
|---|---|---|
| `functions/deliveryQuote.js` | modifié (+4/−0) | fichier entier (aucune modification préalable) |
| `functions/orderActions.js` | modifié (+7/−0) | fichier entier (aucune modification préalable) |
| `functions/test/walletDebitQuarantineGuards.test.js` | nouveau, 199 l., sha `99c8672924a30e32` | entier |
| `functions/test/walletDebitQuarantine.emulator.test.js` | nouveau, 173 l., sha `67407fc30fca1eeb` | entier |
| `functions/test/walletDebitQuarantineOrderings.emulator.test.js` | nouveau, 241 l., sha `5d2dab114b3bdfc7` | entier |
| `lib/widgets/quoted_checkout_runner.dart` | modifié (+12/−0) | fichier entier |
| `test/quote/quote_account_closing_test.dart` | nouveau, 159 l., sha `18ed20d5bd9485ad` | entier |
Total attendu : 17 chemins = 10 modifiés (dont `index.js` pour ses seuls hunks 1 à 7) + 7 nouveaux fichiers de test.

### C. Hors périmètre (ne pas inclure)
- **Hunk 8 `setPharmaciePassword`** (`index.js` l. 1886) et les autres gardes P3 : `passwordReset.js` (+`passwordReset.test.js`), `adminPartnerAccounts.js`, `professionalSubscriptions.js`.
- **Commit 3 E-Kbine** : `ekbineOrders.js`, `test/ekbineQuarantineGuards.test.js`.
- **Commit 4 / préprod** : `functions/test/restaurantV2Preprod.test.js`, `test-env/deploy-account-deletion-preprod.ps1`.
- Documentation / web : `docs/ACCOUNT_DELETION_RELEASE_CHECKLIST.md`, tous les rapports `docs/ACCOUNT_DELETION_7E*.md`, `web/legal/*.html`.
- Lots 2C et 2D, outil `held_for_review`, `payOrderFromWalletCF`, `transferSettlement`.
- Commit 1 `65e738b` (9 fichiers, +719/−32) et Commit 1B `294332e` (4 fichiers Flutter, +163/−4) : inchangés.
- Artefacts : `*.aab`, `AZ_Express_Windows_to_Mac_Validated.patch`, `az_splash_log.txt`, `functions_after_failed_deploy.txt`, `qr-release/`, `scripts/hosting/`, `scripts/maintenance/`, `web/downloads/`, `.firebase/hosting.*.cache`, `test-env/.emulators.pid`.

## 7. Fichiers et hunks hors périmètre rencontrés dans l'arbre de travail
Voir §6-C. Aucun fichier du lot n'embarque de modification sans rapport direct, à l'exception des deux fichiers mélangés signalés (`index.js`, `accountAdmission.js`).

## 8. État Git
HEAD `294332e42bfb352b71eca861b08d6f36dee6e853` · branche `finalisation/az-express` · index vide (0) · 0 commit au-delà de `294332e` · aucun push, aucun déploiement · Commit 1 (9 fichiers, +719/−32) et Commit 1B (4 fichiers, +163/−4) inchangés · sept hunks P2 identiques (§1) · P3 séparé (hunk 8) · `git status` identique avant/après la revue (100 entrées, hors ce rapport) · `git diff --check` : uniquement des avertissements LF/CRLF, aucune erreur. Contrôles de patchs en lecture seule (`git apply --check`, sans écriture ni index).

## 9. Disque C: — `%TEMP%\az_build_android`
Espace C: : **349 Mo libres** sur 100,2 Go (99,8 Go utilisés) — marge très faible (cause des échecs Flutter de 7E-91).
- **Contenu** : copie de build Android Flutter d'un test du **02/11/2026** (création 19:38) : 4 880 fichiers, 3 502 dossiers, **2 847 Mo** ; dont `build/` 2 694 Mo (68 `.so` = 1 472 Mo, 2 APK **debug** `app-debug.apk` de 186 Mo, 6 `.dill`, 1 015 `.dex`), `.dart_tool/` 143 Mo, `android/` 9 Mo, deux journaux `pre-test.txt` / `pre-analyze.txt`, et de petits dossiers `lib/`, `test/`, `test-env/` (copies, 0,3 Mo ; modifiés jusqu'au 08/11).
- **Dernière modification** : fichiers du 02/11 (dernier 21:30) ; dossier racine 06/11 08:59.
- **Processus** : aucun processus ne référence ce chemin ; aucun Gradle/Java de build actif (les `java.exe` présents sont des émulateurs Firebase : deux de l'utilisateur lancés le 29/10, un de cette mission le 09/11 16:24, libéré ensuite).
- **Nature** : sorties de build **reproductibles** (APK debug, `.so`, `.dex`, `.dill`) ; **0 point de reparse** (aucune jonction ni lien symbolique pouvant pointer vers le dépôt) ; aucun keystore, `key.properties`, `.env` ni `GoogleService-Info.plist` ; seule trace de configuration Firebase client : `build/app/generated/res/processDebugGoogleServices/values.xml` (clé d'API client générée par le build).
- **Recommandation** (non exécutée) : après avoir confirmé que les deux APK debug du 02/11 ne servent plus, supprimer le dossier en entier, en PowerShell, `Remove-Item -LiteralPath "$env:TEMP\az_build_android" -Recurse -Force` (≈ 2,8 Go). Autres candidats ultérieurs, à vérifier un par un : `%TEMP%\az_isolated_tariff` (98 Mo) et `az_isolated_flutter` (91 Mo) (copies isolées du 09/11 14:06), `%TEMP%\gfw-install-*.exe` (2 × 64 Mo), et dans le scratchpad de la session `n22repo` (260 Mo) et `previous-app-release-nov1.aab` (85 Mo, copie de sauvegarde à ne supprimer que si l'original est confirmé). Rien n'a été supprimé ni interrompu dans cette mission.

## 10. Recommandation
1. **Correction avant Commit 2 (test seulement, quelques lignes)** : ajouter à `accountQuarantineConcurrency.emulator.test.js` la même branche `else { test('…', { skip }, () => {}); }` que celle ajoutée aux fichiers 2B en 7E-91, pour qu'elle soit **ignorée** et non « réussie » sans émulateur. Aucune assertion à modifier. Non appliquée ici (revue uniquement).
2. **Décision de découpage** : indexer `functions/index.js` par hunk à partir de `index_p2.patch` (hunks 1-7) et trancher l'inclusion de `accountAdmission.js` entier (recommandé).
3. **Avant toute activation** (non requis pour committer) : outil `held_for_review` (D4), lots 2C/2D, quota confirmé, essais avec émulateur Android du flux devis si activé.
4. Libérer de l'espace disque avant de relancer des suites Flutter (§9).
5. Aucun commit ne sera créé sans nouvelle autorisation humaine distincte, avec manifeste fichier par fichier.

## Verdict
**LOTS VALIDÉS AVEC RÉSERVES — CORRECTIONS AVANT COMMIT**
Code des lots 2A et 2B cohérent et prouvé (unitaire + 18/18 d'émulateur rejoués) ; réserves §5 conservées ; une correction de test (comptage) et une décision de découpage (`index.js`, `accountAdmission.js`) avant tout Commit 2. Aucun commit créé. Arrêt : en attente d'une nouvelle autorisation humaine distincte.
