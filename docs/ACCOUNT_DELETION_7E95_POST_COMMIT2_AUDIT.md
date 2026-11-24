# Mission 7E-95 — Audit post-Commit 2

Date : 2026-11-09. Audit local en lecture seule : aucun `git add`, staging, commit, amend, push, pull/merge/rebase/reset, déploiement, modification Firebase distante, changement de secret, activation de FeexPay, suppression ou nettoyage. Production `az-express-b0469` intouchée ; émulateurs 5001/8080/9099 non perturbés. Les seuls fichiers créés sont dans le scratchpad (copie `git archive HEAD`) et le présent rapport.

## 1. Historique des trois commits
| # | Hash complet | Parent | Date (UTC) | Message |
|---|---|---|---|---|
| 1 | `65e738bc35c2519acae05e2e1dfca169c5eff753` | `aa3d1b0a…` | 2026-11-07 22:41 | `fix(account-deletion): secure P1 deletion request gate` |
| 1B | `294332e42bfb352b71eca861b08d6f36dee6e853` | `65e738bc…` | 2026-11-08 15:05 | `fix(account-deletion): handle structured deletion gate errors` |
| 2 | `d65c8f00bdcedba570a66a5633913db46127be3d` | `294332e4…` | 2026-11-09 18:04 | `fix(account-deletion): guard financial activity during quarantine` |
Les trois hashes, l'ordre chronologique et la chaîne parent/enfant sont conformes à la référence. Branche `finalisation/az-express`, HEAD `d65c8f0…`.

## 2. Manifeste exact et statistiques
- **Commit 1** — 9 fichiers, +719/−32 : `functions/accountCleanup.js`, `accountDeletion.js`, `accountDeletionSupport.js`, `index.js` (1 ligne), `partnerAccountDeletion.js`, `test/accountDeletionHardening.test.js`, `rules-tests/account-deletion{-lifecycle,-real,}.test.js`.
- **Commit 1B** — 4 fichiers, +163/−4 : `lib/services/account_deletion_service.dart`, `lib/widgets/account_deletion_dialog.dart`, `test/services/account_deletion_service_test.dart`, `test/widgets/account_deletion_dialog_test.dart`.
- **Commit 2** — 17 fichiers, +1612/−19 : exactement le manifeste 7E-93/7E-94 (10 modifiés dont `functions/index.js` partiel + 7 ajoutés). Aucun fichier inattendu dans aucun des trois commits.
- `git show --check` : propre pour les trois. Recherche de secrets dans les lignes ajoutées (clés privées, `AIza…`, `sk-…`, `ghp_…`, `client_secret`, `private_key`) : **aucune** correspondance ; les seuls motifs « secret » vus en 7E-94 sont des noms de variables et la valeur factice `test-only-not-a-secret`.

## 3. Contrôle du Commit 2
- `functions/index.js` : **7 hunks** dans le commit ; lignes ajoutées/supprimées **identiques** à `index_p2.patch` (`0a1ce967…`). Hunk 8 (`setPharmaciePassword`, `assertTargetNotClosing(db …`) : **0** occurrence dans HEAD, **1** hunk / 1 occurrence dans le worktree ; `git apply --check --reverse index_p3.patch` réussit sur le worktree (P3 intact, non committé).
- `functions/accountAdmission.js` : committé en entier ; worktree identique à HEAD ; export `{assertNewAccountActivity, assertTargetNotClosing}` (l. 23) cohérent avec l'import de `index.js` (l. 82) ; `assertTargetNotClosing` définie l. 16, jamais appelée dans HEAD hors test (appelants P3 non committés).
- Gardes présentes dans HEAD : `deliveryQuote.js:199`, `orderActions.js:1337` et `:1540`, `azia/pendingActions.js:85`, `index.js:457` (initiateFeexPayPayment) et `:675` (initiateWithdrawal), `feexpayPayments.js` (`HELD_STATUS`, `shouldHoldPayment`).
- `payOrderFromWalletCF` : **non modifiée**. Le diff de `orderActions.js` ne contient que 3 hunks (import l. 13, gardes l. 1335 et l. 1538) ; l'unique occurrence du nom dans le commit est un commentaire de contexte dans `index.js` (« Fabriques pour payOrderFromWalletCF … »), pas du code.

## 4. Tests (Node v22.23.4)
Exécutés **dans cette mission**, sur une copie `git archive HEAD functions` (donc le contenu committé, indépendant du worktree) :
| Série | Résultat |
|---|---|
| Unitaires ciblés (16 fichiers : Commit 1 `accountDeletionHardening` ; 2A `accountQuarantineGuards`, `accountQuarantineIndex`, `pilotCap`, `feexpayPayments`, `pendingActions`, `accountAdmission` ; 2B `walletDebitQuarantineGuards`, `deliveryQuote`, `deliveryQuoteWiring`, `orderActions`, `marketplaceBoutiqueBilling`, `billingCompatibility` ; + 3 fichiers émulateur sans émulateur) | **324 tests : 321 réussis, 0 échec, 3 ignorés** (les 3 fichiers émulateur, comptés comme ignorés, pas réussis) |
| Émulateur isolé `demo-7e95`, `127.0.0.1:18089` (hub 14400, logging 14500), `--test-concurrency=1` — 2A `accountQuarantineConcurrency` (9) + 2B `walletDebitQuarantine` (6) | **15 réussis sur 15** |
| Émulateur isolé — 2B `walletDebitQuarantineOrderings` (3 × 74 rondes), exécuté seul | **3 réussis sur 3** : `quarantine_first` 0 accepté / 12 refusés par la garde pour quote, wallet et cash ; `call_first` 12 acceptés / 0 refus |
Soit **18/18 scénarios d'émulateur réussis**, 0 ignoré dans ces runs.
**Incident de test, sans lien avec le code** : le premier lancement groupé a été interrompu pendant `Orderings` (code 143 = SIGTERM) par mon propre `timeout 540`, qui a coupé l'émulateur ; le fichier a été rejoué seul, sans limite serrée, et réussit. Une première tentative avait aussi échoué sur un chemin de binaire mal transmis par Git Bash (erreur de lancement, aucun test exécuté). Ces deux accrocs sont des problèmes de harnais, pas des défauts du produit.
**Non rejoués / non exécutés** : tests Flutter du Commit 1B et de `quote_account_closing_test` (aucun fichier Flutter modifié depuis leur dernière exécution, 55/55 et analyse propre en 7E-91 ; non relancés pour ne pas aggraver le disque C: à 335 Mo libres) ; `npm run test:rules` (Java) ; suite complète (déjà mesurée en 7E-93 : 2350 / 2181 / 0 échec / 169 ignorés sur l'arbre réel) ; tests sur appareil. Aucune compilation Android.

## 5. Worktree (87 entrées = 86 d'avant + le rapport 7E-94 ; 7E-95 s'y ajoute)
11 modifiées + 76 non suivies, toutes préservées. Classement (lecture seule) :
| Catégorie | Entrées |
|---|---|
| **Hunk P3** (`setPharmaciePassword`) | `functions/index.js` : 1 hunk, 2 lignes — **seul reste de ce fichier** |
| **P3 / commit 3b** (garde de la cible d'un changement de mot de passe, abonnements pro) | `passwordReset.js` (+3), `adminPartnerAccounts.js` (+3), `professionalSubscriptions.js` (tombstone relu dans la transaction), `test/passwordReset.test.js` (+2) — tous liés à `assertTargetNotClosing` ou à la quarantaine ; dépendent de `accountAdmission.js` déjà committé |
| **Commit 3 E-Kbine** | `ekbineOrders.js` (+8 : 3 gardes de quarantaine, client et agent) ; `test/ekbineQuarantineGuards.test.js` (non suivi) |
| **Lot 2C** (`payOrderFromWalletCF`) | aucun diff en attente : lot non commencé |
| **Lot 2D** (`transferSettlement`) | aucun diff en attente |
| **Outil `held_for_review`** | aucun code (seulement le document `ACCOUNT_DELETION_7E71_HELD_FOR_REVIEW_RESOLUTION_PROPOSAL.md`) |
| **Scripts** | `test-env/deploy-account-deletion-preprod.ps1`, `scripts/hosting/`, `scripts/maintenance/`, `qr-release/`, `test-env/.emulators.pid` |
| **Documentation** | `docs/ACCOUNT_DELETION_RELEASE_CHECKLIST.md` (M) + ~62 rapports `ACCOUNT_DELETION_7E*` non suivis |
| **Autres** | `test/restaurantV2Preprod.test.js` (M, 1 ligne : `--test-reporter=spec`), `web/legal/{confidentialite,delete-account}.html` (M), `.firebase/hosting.*.cache` (M), artefacts `.aab` ×4, `AZ_Express_Windows_to_Mac_Validated.patch`, `az_splash_log.txt`, `functions_after_failed_deploy.txt`, `web/downloads/` |
**Mélanges de périmètres signalés** : (a) `professionalSubscriptions.js` a une garde de quarantaine sans lien avec le moteur P1 — à rattacher explicitement au commit 3b lors de sa préparation ; (b) `restaurantV2Preprod.test.js` est un changement de test restaurant sans rapport avec la suppression de compte, à ne pas mêler au commit 3 ni 3b ; (c) `ACCOUNT_DELETION_RELEASE_CHECKLIST.md` touche à la suppression de compte mais est de la documentation. Aucun autre mélange.

## 6. Réserves techniques
1. `Transaction is invalid or closed` (INVALID_ARGUMENT) : reproduit avec le SDK Admin brut, fail-closed sans écriture ; comportement de production non démontré. Réobservé aujourd'hui (O-quote/wallet : quelques rondes en contention).
2. Refus « pendant la transaction » (`during`) peu exercé : cash 0 refus sur 25 ; exercé par `quarantine_first` et `jitter`.
3. Flutter dépend du texte d'erreur serveur ; flux devis inactif, jamais testé sur appareil.
4. **Quota Cloud Run NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE** ; `pilotLightOptions` ne vaut qu'en préproduction.
5. `held_for_review` : le webhook met en attente mais **aucun outil support/admin** ne traite ces paiements (D4) — bloquant avant activation.
6. Lots 2C, 2D, commit 3 (E-Kbine) et 3b (P3) non faits ; la porte de suppression reste fermée.
7. Tests Flutter, `test:rules`, appareil non rejoués ici ; disque C: 335 Mo libres.

## 7. État Git final
HEAD `d65c8f00bdcedba570a66a5633913db46127be3d` · branche `finalisation/az-express` · index vide (0 entrée) · aucun nouveau commit · aucun push · aucun déploiement · aucune activation · `functions/index.js` : 1 hunk (P3) restant dans le worktree · ports 18089/14400/14500 libres, 5001/8080/9099 inchangés · rien supprimé.

## 8. Recommandation pour le lot 2C
Le lot 2C (garde dans `buildPayOrderFromWallet`, `orderActions.js` l. 48-493, c.-à-d. `payOrderFromWalletCF`) est le seul flux de débit wallet pour commande qui reste sans garde transactionnelle ; il est le suivant logique. Recommandation : (1) mission d'analyse **avant** code — cartographier les lectures/écritures de la transaction pour placer la garde avant la première écriture, identifier les partenaires à relire (vendeur ou restaurant selon `sellerType`), et le cas des commandes déjà créées dont le client est mis en quarantaine entre création et paiement ; (2) réutiliser `assertNewAccountActivity` (aucun nouveau helper) et le modèle de tests 2B (garde unitaire + ordonnancements + concurrence) ; (3) ne pas mêler 2D, E-Kbine ni P3 ; (4) conserver la règle « refus ⇒ aucun effet » et prévoir le message Flutter correspondant si l'erreur est visible côté client ; (5) traiter à part l'outil `held_for_review`, indispensable avant toute activation.

## Verdict
**TROIS COMMITS VALIDÉS — PRÊT POUR LOT 2C**
Hashes, chaîne, messages, manifestes et statistiques conformes ; aucun secret ajouté ; hunks 1 à 7 dans le Commit 2, hunk P3 dans le worktree ; `payOrderFromWalletCF` intacte ; 321 unitaires réussis (3 ignorés comptés comme tels) et 18/18 scénarios d'émulateur réussis sur le contenu committé. Réserves listées ci-dessus, dont le quota Cloud Run non confirmé. Arrêt : aucun commit, aucun push, aucun déploiement, aucune activation ; en attente d'une nouvelle autorisation humaine.
