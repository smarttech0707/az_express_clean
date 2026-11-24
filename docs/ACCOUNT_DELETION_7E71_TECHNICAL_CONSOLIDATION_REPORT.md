# Mission 7E-71 — Consolidation technique avant préproduction (suppression de compte)

Date : 2026-11-07 · Branche `finalisation/az-express` · HEAD `aa3d1b0` · Cible future : `az-express-preprod` · Production `az-express-b0469` : jamais touchée.
**Rien n'a été déployé, activé, commité, poussé ni modifié à distance.** Aucune commande distante n'a été lancée dans cette mission (les seules lectures distantes datent de 7E-70). `operations_control/account_deletion` n'a pas été créé. Documents liés : `…_NODE22_VALIDATION.md`, `…_PREPROD_FUNCTION_LIMITS.md`, `…_DEPLOY_SCRIPT_REVIEW.md`, `…_COMMIT_MANIFEST.md`, `…_HELD_FOR_REVIEW_RESOLUTION_PROPOSAL.md` (la consigne était tronquée après le 5ᵉ document ; le 6ᵉ est une hypothèse).

## 1. Verdict

**PRÊT SOUS CONDITIONS** pour demander une autorisation de déploiement en préproduction **de la phase P1 (4 fonctions de suppression)**. **Pas prêt** pour la phase P2 (gardes financières) tant que la marge de quota n'est pas décidée par un humain.

| # | Condition | État |
|---|---|---|
| C1 | Quota Cloud Run : **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE** (usage réel illisible ; P1 → 18,75/20 théorique ; P1+P2 → 19,75/20, marge 0,25 vCPU) | ouvert (décision humaine, options dans `FUNCTION_LIMITS` §4) |
| C2 | Commit du périmètre (17 fichiers + modifications 7E-71) — le script exige un arbre propre | prêt à valider (`COMMIT_MANIFEST`), **non fait** |
| C3 | Plafond des 4 gardes | **préparé en local** (fait), non appliqué à distance |
| C4 | Script de déploiement dédié | **préparé** (syntaxe valide), jamais exécuté |
| C5 | Revue métier E-Kbine / partenaires / AZ IA signée | ouverte (fonctions du lot P3, hors P1/P2) |
| C6 | `held_for_review` sans outil de résolution | bloque l'**activation complète**, pas le pilote (`HELD_FOR_REVIEW…` §7) |
| C7 | Un test préexistant échoue sous Node 22 (format de rapport) et `dispatchRetry.emulator` échoue sous émulateur | ouverts, hors périmètre (§6) |

## 2. État initial et protection du dépôt (étape 1)

- `git status --short` relevé avant toute modification : branche `finalisation/az-express`, HEAD `aa3d1b0`. 12 fichiers suivis modifiés (11 sources + `test/passwordReset.test.js`) et 5 fichiers de `functions/` non suivis (`accountCleanup.js` + 4 tests) = les **17 fichiers** ; plus docs 7E-66→70, `lib/services/account_deletion_service.dart`, 3 tests de règles, 2 pages légales, un cache Hosting et des éléments étrangers (`.aab`, patch, journaux, `qr-release/`, `scripts/`, `web/downloads/`…).
- Les 4 rapports 7E-70 sont présents. Aucune modification existante écrasée ; aucun fichier supprimé ; aucun reset Git ; aucune ligne de modification antérieure retirée.
- Fichiers que 7E-71 a **modifiés** : `functions/pilotCap.js`, `functions/index.js`, `functions/azia/index.js`, `functions/azia/pendingActions.js`, `functions/test/pilotCap.test.js`, `functions/test/accountQuarantineGuards.test.js` (+1 test), `functions/test/accountQuarantineConcurrency.emulator.test.js` (identifiants préfixés, voir §6). **Créés** : `test-env/deploy-account-deletion-preprod.ps1` et les 6 documents `docs/ACCOUNT_DELETION_7E71_*`.
- Fins de ligne : les fichiers existants sont en CRLF ; toutes les modifications ont préservé le CRLF (vérifié par comptage).

## 3. Plafonds des quatre fonctions de garde (étape 2)

Détail : `…PREPROD_FUNCTION_LIMITS.md`. Résumé :
- Avant : `initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction`, `feexPayWebhook` n'ont **aucun `maxInstances`** ni `cpu`/`concurrency` (défaut plateforme : 1 vCPU, jusqu'à 100 instances → 400 vCPU théoriques face à un quota de 20).
- Préparé : `pilotLightOptions()` → `{ maxInstances: 1, cpu: 0.25, concurrency: 1 }` **uniquement** si `GCLOUD_PROJECT === 'az-express-preprod'`, `{}` ailleurs. Empreinte 1,0 vCPU. Mémoire, délai, secrets, région inchangés.
- Production inchangée : prouvé par 3 tests (`pilotCap.test.js`) et par la comparaison du manifeste des 135 points d'entrée (seules ces 4 diffèrent, uniquement en préproduction).
- **Impact financier** : l'exactitude des écritures d'argent ne dépend pas du nombre d'instances ; le débit est sérialisé et le scénario « webhooks concurrents » de la matrice 7E-70 ne démontre plus de concurrence réelle en préproduction. Démarrage à froid à 0,25 vCPU **non mesuré**.
- **Choix humain en attente** : marge 0,25 vCPU insuffisante ; options A à E présentées. Le script refuse P2 par défaut (`MinMarginVcpu` 0,5).

## 4. Node.js 22 (étape 3)

Détail : `…NODE22_VALIDATION.md`. Node 22.23.4 obtenu en dossier temporaire (rien installé globalement). Analyse statique : 326 paquets avec `engines`, aucun incompatible ; aucune API postérieure à Node 22 ; pas de module natif d'exécution. Exécution : sans émulateur **2304 tests · 2137 réussis · 1 échec · 166 ignorés** sous Node 22 (Node 24 : 2138 réussis, 0 échec). L'échec est un défaut du test `restaurantV2Preprod.test.js:121` (motif `ℹ fail 0` propre au rapporteur de Node 24 ; le test fils réussit 35/35). Règles de suppression 63/63 sous Node 22 ; concurrence : 8/9 puis 9/9 (intermittence d'émulateur sur C2 ; 6/6 isolé sous chaque version). **Non fait** : `npm ci` sous Node 22, build `nodejs22`, suite émulateurs complète, règles principales et Storage sous Node 22 → **NON VÉRIFIÉ**. CI actuelle sur Node 20 (dérive à noter).

## 5. Script de déploiement (étape 4)

Détail : `…DEPLOY_SCRIPT_REVIEW.md`. `test-env/deploy-account-deletion-preprod.ps1` (221 lignes, ASCII) : simulation par défaut, identifiant + numéro de projet, refus de la production, liste blanche de 8 fonctions en 2 étapes, jamais Hosting/global/`--force`/`firebase use`, plafond vérifié par analyse locale, projection de quota, triple confirmation en réel, arrêt à la première erreur, journal sans secret. **Analyse syntaxique : 0 erreur. Jamais exécuté** → chemins réels NON VÉRIFIÉS.

## 6. Revue des 17 fichiers contre HEAD (étape 5)

Diffs relus avec `git diff -w --ignore-cr-at-eol`. Modules locaux atteints depuis `index.js` : 131 ; **un seul non suivi : `accountCleanup.js`**.

| Fichier | Changement | Fonctions / rôles / paiements / commandes | Risque de régression |
|---|---|---|---|
| `accountAdmission.js` (+11) | ajoute `assertTargetNotClosing` ; `assertNewAccountActivity` inchangé | gardes de quarantaine ; aucun effet sur commandes | faible ; `accountAdmission.test.js` 7/7 |
| `accountDeletion.js` (+76) | limites 5/h, 10/dossier, 60 s, 6 échecs ; audit strict avant suppression Auth ; blocage `admins` (D3) ; nettoyage inconnu → revue ; fin des reprises au plafond | moteur client/livreur ; **ne touche ni paiements ni commandes** (inspection en lecture) | moyenne (nouveau comportement) ; 21 + 63 tests |
| `accountCleanup.js` (nouveau) | effacement notifications et données AZ IA par UID ; conserve consentement, actions confirmées, exécutions d'outils | données personnelles ; conservations **à valider juridiquement** | moyenne ; couvert par `accountDeletionHardening` |
| `partnerAccountDeletion.js` (+25) | même nettoyage/plafond côté partenaires | partenaires **hors ouverture** (`partnerInventoryVersion` absent) | faible tant que fermé |
| `accountDeletionSupport.js` (+6) | `retry` remet `attempts` à 0 et relance un dossier plafonné | support super-admin | faible |
| `index.js` | `initiateFeexPayPayment` : création de la demande dans une transaction qui relit le tombstone ; `initiateWithdrawal` : garde au début de la transaction ; `setPharmaciePassword` : cible ; `checkRateLimit`/`logAudit` injectés ; plafond préproduction ×3 | recharges et retraits des clients/livreurs ; **`txRef.set` devient transactionnel** : léger changement de chemin d'écriture | moyenne sur les paiements → 11 tests dédiés + C1-C3 + 178 tests de la famille paiement |
| `feexpayPayments.js` (+72) | statut `held_for_review`, lecture parallèle profil + tombstone dans la transaction de crédit, idempotence étendue | `feexPayWebhook` : **ne bloque jamais** un webhook authentique ; ne crédite jamais un profil anonymisé ni un paiement né après la quarantaine | moyenne ; webhook dupliqué/inconnu/montant faux testés ; **aucun outil de résolution** |
| `azia/pendingActions.js` | garde dans la transaction de confirmation, avant `confirmHandler` ; paramètre `options` | `aiConfirmAction` : une action préparée avant la quarantaine n'est jamais exécutée après | faible ; 174 tests AZ IA |
| `azia/index.js` (+2) | câblage du plafond | `aiConfirmAction` en préproduction | faible |
| `pilotCap.js` (+12) | `pilotLightOptions` | préproduction uniquement | faible ; 10 tests |
| `passwordReset.js` (+3) | refus si le compte cible est en suppression | `resetAccountPassword` (artisan/pharmacie) ; **`artisanLogin`/`pharmacieLogin` inchangés** | faible ; 324 tests rôles |
| `adminPartnerAccounts.js` (+3) | refus si la cible a un tombstone (message existant conservé) | `manageAdminPartnerAccount` | faible → revue métier requise (module −46/+355 lignes vs production) |
| `ekbineOrders.js` (+3) | `ekbineAcceptOrder` : agent en quarantaine refusé dans la transaction | E-Kbine, **`fee = 0` inchangé** | faible |
| `professionalSubscriptions.js` (+4/−1) | tombstone relu dans la transaction | débits d'abonnement | faible |
| 4 tests + `passwordReset.test.js` | nouveaux tests / double étendu | — | — |

Points d'attention demandés :
- **`ekClientConfirmOrder`** : **non modifié** par ces 17 fichiers. Il crédite l'**agent** ; l'agent n'est pas relu contre le tombstone *dans* la transaction de confirmation (seule la garde du wrapper `onCall` s'applique, côté appelant). Classement inchangé de 7E-69 : *compatible sous réserve* — revue métier requise, non traité ici.
- **Fonctions de recharge** : `initiateFeexPayPayment` (modifiée) ; `adminDriverRecharge` et `assertDriverRechargeAllowed` non modifiées (tests de la famille paiement : 178/178).
- **Outils AZ IA** (`azia/tools/*`) : aucun diff ; la protection est au niveau de la confirmation. Un outil qui écrirait sans passer par une action confirmée n'est pas couvert par cette garde (aucun cas constaté, non audité exhaustivement).
- **Ne pas conclure** qu'un test unitaire prouve la sécurité d'une opération financière : les preuves de ce dossier sont des transactions d'émulateur, qui ne reproduisent ni la charge ni la latence de Firestore de production.

## 7. Tests (étape 6) — PASS / FAIL / SKIP / NON VÉRIFIÉ

Les décomptes proviennent de sorties conservées dans le dossier temporaire de session.

| Catégorie | Commande / périmètre | Résultat | Statut |
|---|---|---|---|
| Suite `functions` sans émulateur, Node 24 | `node --test test/*.test.js` | 2304 · 2138 réussis · 0 échec · **166 ignorés** (exigent un émulateur) | PASS (166 SKIP) |
| Idem, Node 22 | idem | 2304 · 2137 · **1 échec** · 166 ignorés | **FAIL (1, défaut du test, §4)** |
| Gardes — quarantaine (unitaires) | `accountAdmission` 7, `accountDeletionHardening` 21, `accountQuarantineGuards` 17, `accountQuarantineIndex` 11, `pilotCap` 10 | 65 → 66 avec le test ajouté, 0 échec | PASS |
| Concurrence Firestore Emulator | `accountQuarantineConcurrency.emulator.test.js` | Node 24 : 9/9 (×4 exécutions) ; Node 22 : 8/9 puis 9/9 | PASS, avec **1 FAIL intermittent d'émulateur sous Node 22 (C2)** |
| Règles de suppression (Auth + Firestore + Storage) | 4 fichiers, `--test-concurrency=1` | **63/63** (Node 24 et Node 22) | PASS |
| — 1ᵉʳ essai de cette mission | mêmes 3 fichiers **sans** `--test-concurrency=1` et sans `account-new-flows` | 56 · 37 · **19 échecs** | **FAIL — invocation invalide** (suites parallèles sur le même projet démo, interdit par la liste de contrôle) ; non retenu, **conservé ici pour mémoire** |
| Règles Firestore principales | `test:rules` (24 fichiers) | **470/470** | PASS (Node 24 seulement) |
| Règles Storage | `test:storage` (3 fichiers) | **128/128** | PASS (Node 24 seulement) |
| Paiements (feexpay*, recharges, wallet, cash) | 8 fichiers | 178/178 | PASS |
| AZ IA | 12 fichiers | 174/174 | PASS |
| Rôles administrateurs / partenaires / E-Kbine / mots de passe | 10 fichiers | 324/324 | PASS |
| Non-régression des commandes | 17 fichiers | 423/423 | PASS |
| Suite complète sous émulateurs Auth + Firestore, Node 24 | `test/*.test.js`, `--test-concurrency=1` | 2312 tests · 2263 réussis · **2 échecs** · 47 ignorés (Storage/AZ_E2E_RULES) · durée 1003 s. Échecs : (1) `dispatchRetry.emulator` « trois passes simultanées en phase 2 » (préexistant, fichier non touché) ; (2) `financialConcurrency.emulator` « E-Kbine création : 8 appels simultanés » : 7 appels sur 8 ont réussi (assert `7 !== 8`) | **FAIL (2)** — (2) est **nouveau par rapport à 7E-69** ; rejoué seul 3 fois sur émulateur neuf : **12/12 ×3 PASS** → classé intermittence d'émulateur sous contention (même famille que C2), **non prouvé** ; `ekbineOrders.js` ne diffère de HEAD que par la garde de `ekbineAcceptOrder`, pas par la création. Un 8ᵉ appel échoué n'a pas produit de double débit (assertions d'argent non atteintes : à confirmer par rejeu en suite complète) |
| Suite complète sous émulateurs, Node 22 ; build `nodejs22` ; `npm ci` | — | non exécutés | NON VÉRIFIÉ |
| Tests d'appareil / émulateur mobile | — | non exécutés | NON VÉRIFIÉ |

**Régression découverte et corrigée dans cette mission.** La première exécution complète sous émulateurs a produit 3 échecs au lieu d'1 : deux tests « cash » de `partnerOrderConcurrency.emulator.test.js` refusés par « Compte supprimé ou en cours de suppression ». Cause : mes tests de concurrence (7E-69) créaient des tombstones avec des identifiants (`cc0…cc7`, `cd1`) **identiques** à ceux de ces tests, dans l'émulateur partagé. Aucun code de production en cause. Correction : tous mes identifiants sont préfixés `qz71_`. Preuve : mon fichier + `partnerOrderConcurrency.emulator.test.js` dans une même session : **36/36**.

**Échec préexistant sans lien** : `dispatchRetry.emulator.test.js` « trois passes simultanées en phase 2 » (déjà en 7E-69, fichier non touché) — voir le résultat de la suite complète ci-dessus.

### Invariants demandés

| Invariant | Preuve | Statut |
|---|---|---|
| Aucun double crédit | C1 (3 webhooks concurrents + rejeu, 6 rondes), C2, `accountQuarantineGuards` 10 (webhook dupliqué), rejeu après mise en attente | PASS (émulateur) |
| Aucun solde négatif | A2 (retrait vs quarantaine), plafonds de solde inchangés ; suites paiements | PASS (émulateur / unitaire) |
| Aucune validation d'action après quarantaine | B, B2 (émulateur), `accountQuarantineGuards` 2, 3 | PASS |
| Aucune suppression automatique d'un administrateur | `accountQuarantineGuards` 13-15 (demande refusée ; dossier existant bloqué avant quarantaine) | PASS (unitaire) ; **non rejoué sur Auth réel** |
| Aucun crédit automatique après événement suspect | C2/C3, `accountQuarantineGuards` 8, 9, 12 : paiement tardif ou profil anonymisé → `held_for_review`, solde inchangé | PASS |
| Idempotence des webhooks | C1-C3, tests 10 et `feexpayPayments.test` | PASS |
| Comportement sûr si la lecture du tombstone échoue | AZ IA (test 5), recharge/retrait (Index 4), **webhook : test ajouté en 7E-71** (lecture en échec → aucun crédit, paiement inchangé), règle pure `tombstone_date_unreadable` (test 12) | PASS (unitaire) ; **non reproduit en préproduction** |

## 8. `held_for_review` (étape 7)

Détail : `…HELD_FOR_REVIEW_RESOLUTION_PROPOSAL.md`. Posé uniquement par le webhook (transaction de crédit) ; conserve le paiement vérifié, ne touche pas au solde, trace sécurité + audit ; aucun outil de consultation ni de résolution (console Firebase seulement) ; l'application affiche tout statut inconnu comme « en attente ». Outil sécurisé **proposé** (super-admin, double validation, vérification de référence/montant/devise, idempotence, audit, crédit / remboursement / rejet séparés, remboursement *enregistré* hors système). **Aucun développement financier.** Bloque l'**activation complète**, pas le pilote préproduction (FeexPay `DISABLED`).

## 9. Préparation du commit (étape 8)

Détail : `…COMMIT_MANIFEST.md` (classement A à G, commandes avec chemins explicites, jamais `git add .`, 3 commits proposés). **Aucun commit.** À exclure : cache Hosting, `.aab`, patch, journaux, `qr-release/`, `scripts/`, `web/downloads/`, `test-env/.emulators.pid`. À reporter : `account_deletion_service.dart`, pages légales.

## 10. Risques ouverts

1. Quota Cloud Run non confirmé ; marge théorique de P2 : 0,25 vCPU.
2. Concurrence réelle de Firestore de production non démontrée (émulateur).
3. Intermittence de l'émulateur (`Transaction is invalid or closed`) sous contention, y compris sous Node 22.
4. `held_for_review` sans outil de résolution.
5. `ekClientConfirmOrder` : bénéficiaire non relu dans la transaction ; revue métier E-Kbine/partenaires/AZ IA non signée.
6. Script de déploiement jamais exécuté ; démarrage à froid à 0,25 vCPU non mesuré ; comportement de la file d'attente avec concurrence 1 non mesuré.
7. Node 22 : `npm ci`/build non vérifiés ; test préexistant incompatible avec le rapporteur TAP ; CI sur Node 20.
8. Valeurs des secrets de préproduction non vérifiables sans lecture.
9. Conservations de données (consentement IA, actions confirmées, exécutions d'outils) à valider juridiquement.
10. Production : les 4 fonctions de garde restent sans plafond dans le code (état préexistant).

## 11. Corrections proposées mais non appliquées

- `restaurantV2Preprod.test.js:121` : motif `/^(ℹ|#) fail 0$/m` (voir Node 22).
- Aligner `ci.yml` (Node 20) sur le runtime 22 — décision d'équipe.
- Outil `resolveHeldPayment` / `listHeldPayments` (proposition).
- Garde du bénéficiaire dans `ekClientConfirmOrder` (après revue métier).

## 12. Prochaine étape recommandée

1. Décider du quota (relevé humain en console ; options C/D du document des plafonds).
2. Valider le manifeste, puis autoriser séparément les 3 commits (aucun n'est fait).
3. Après commit : autorisation distincte pour la **simulation** puis pour l'exécution de **P1** seule (`-Stage functions-deletion`).
4. P2 et la création de `operations_control/account_deletion` : autorisations distinctes ultérieures.

*Aucun déploiement, aucune activation, aucun commit, aucune modification distante. En attente d'une autorisation distincte.*
