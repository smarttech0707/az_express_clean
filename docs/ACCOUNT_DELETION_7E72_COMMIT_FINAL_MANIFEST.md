# Mission 7E-72 — Manifeste final des commits (suppression de compte, P1)

Date : 2026-11-07 · Branche `finalisation/az-express` · HEAD `aa3d1b0` · **Aucun commit, aucun `git add`, aucun push, aucun reset.** Remplace pour l'exécution le §5 de `ACCOUNT_DELETION_7E71_COMMIT_MANIFEST.md` (non modifié). Jamais `git add .` ni `git add -A` : chemins explicites uniquement.

## 1. Ce qui a changé depuis le manifeste 7E-71

| Changement 7E-72 | Fichier | Commit |
|---|---|---|
| Garde de quarantaine de l'agent dans `ekClientConfirmOrder` ; garde client dans `ekCreateOrderCF` | `functions/ekbineOrders.js` (+8 lignes, en plus des +3 de 7E-68) | 2 |
| 11 nouveaux tests | `functions/test/ekbineQuarantineGuards.test.js` (nouveau) | 2 |
| Rapporteur du processus fils forcé (`--test-reporter=spec`) | `functions/test/restaurantV2Preprod.test.js` (1 ligne) | 3 (indépendant) |
| Marge de quota par défaut 0,5 → 1,0 | `test-env/deploy-account-deletion-preprod.ps1` | 4 |
| 6 documents `ACCOUNT_DELETION_7E72_*` | `docs/` | 5 |

## 2. Vérification de la séparabilité (faite)

Pour chaque proposition de scission, l'état du dépôt a été reconstitué **sans toucher à Git ni au dépôt** : `git archive HEAD` extrait dans un dossier temporaire, fichiers du commit superposés, puis `node --test test/*.test.js` (sans émulateur, Node 24) :

| Reconstitution | `index.js` se charge | Tests | Échecs |
|---|---|---|---|
| HEAD + commit 1 seul | oui | 2304 | 8 ¹ |
| HEAD + commits 1 + 2 | oui | 2315 (+11 tests E-Kbine) | 8 ¹ — **identiques** à la ligne précédente |
| HEAD + tout (équivalent à l'arbre de travail) | oui | 2315 | 9 ¹ ² |

¹ Échecs identiques entre les trois reconstitutions, **dus à l'extraction partielle** (pas de `web/`, `lib/`, `.git` : tests d'association Android/iOS, d'hébergement, de simulation de script, d'inventaires Flutter) — ils passent dans le dépôt réel (2275 réussis sur 2323 en suite complète, seul `dispatchRetry` échoue).
² Un test supplémentaire, `passwordHash.test.js` « verifySecret is not fooled by a truncated/tampered hash », a échoué **une fois** : test probabiliste préexistant (si le hachage tiré se termine par `00`, le « hachage altéré » est l'original ; ~1 chance sur 256 par exécution). Rejoué 6 fois dans le dépôt : 6/6. Fichier non touché par ces missions.

→ Le commit 1 est déployable seul ; le commit 2 s'ajoute sans régression ; l'ordre 1 → 2 est obligatoire (`passwordReset.js`, `adminPartnerAccounts.js`, `ekbineOrders.js`, `professionalSubscriptions.js` importent `accountAdmission.js`, introduit par le commit 1).

## 3. Les cinq commits

### Commit 1 — moteur, gardes financières, plafonds (obligatoire pour P1 et P2)
| Fichier | État |
|---|---|
| `functions/accountDeletion.js`, `functions/partnerAccountDeletion.js`, `functions/accountDeletionSupport.js`, `functions/accountAdmission.js` | modifiés |
| `functions/accountCleanup.js` | **nouveau — requis** : importé par `accountDeletion.js` et `partnerAccountDeletion.js` ; sans lui `index.js` ne se charge pas |
| `functions/index.js`, `functions/feexpayPayments.js`, `functions/azia/index.js`, `functions/azia/pendingActions.js`, `functions/pilotCap.js` | modifiés |
| `functions/test/accountDeletionHardening.test.js`, `accountQuarantineGuards.test.js`, `accountQuarantineIndex.test.js`, `accountQuarantineConcurrency.emulator.test.js` | nouveaux |
| `functions/test/pilotCap.test.js` | modifié |
| `rules-tests/account-deletion.test.js`, `account-deletion-lifecycle.test.js`, `account-deletion-real.test.js` | modifiés (injection de `checkRateLimit`) |

- **Dépendances** : tout dépend de `accountCleanup.js` et `accountAdmission.js` ; `index.js` dépend des cinq autres modules. Fichier non scindable : `index.js` mélange P1, P2 et plafonds (pas de `git add -p`).
- **Tests associés** : 21 + 17 + 11 + 9 (émulateur) + 10 ; règles de suppression 63 (Node 22 et 24).
- **Risque de régression** : moyen (chemins d'argent : `initiateFeexPayPayment`, `initiateWithdrawal`, `feexPayWebhook`, `aiConfirmAction`) ; couvert par 178 tests paiements, 470 règles.
- **Mélange avec des changements étrangers** : aucun relevé (diffs relus avec `-w --ignore-cr-at-eol`).

### Commit 2 — gardes de quarantaine des fonctions « P3 reporté » et E-Kbine
`functions/passwordReset.js`, `functions/adminPartnerAccounts.js`, `functions/ekbineOrders.js`, `functions/professionalSubscriptions.js`, `functions/test/passwordReset.test.js`, `functions/test/ekbineQuarantineGuards.test.js` (nouveau).
- Fonctions touchées : `resetAccountPassword`, `manageAdminPartnerAccount`, `ekbineAcceptOrder`, `ekClientConfirmOrder`, `ekCreateOrderCF`, `manageProfessionalSubscription`. **Aucune n'est déployée en P1/P2.**
- Dépend du commit 1. **Peut être réalisé séparément et différé** sans effet sur P1.
- Tests : 11 nouveaux + `ekbineOrders` 43 + `passwordReset`.
- Régression : faible à moyenne (E-Kbine : 54/54 tests de la famille). Revue métier E-Kbine / partenaires non signée → raison de l'isoler.

### Commit 3 — correctif de test (indépendant)
`functions/test/restaurantV2Preprod.test.js`. Aucune dépendance ; sans lien avec la suppression de compte ; peut être commité n'importe quand, y compris avant le commit 1.

### Commit 4 — outillage de déploiement
`test-env/deploy-account-deletion-preprod.ps1`. Aucune dépendance de code ; ne modifie pas ce qui est déployé. Jamais exécuté en réel.

### Commit 5 — documentation
`docs/ACCOUNT_DELETION_RELEASE_CHECKLIST.md` (modifié) et les `docs/ACCOUNT_DELETION_7E66…7E72_*.md` (nouveaux).

### Ne pas ajouter (inchangé)
`.firebase/hosting.YnVpbGRcd2Vi.cache`, `AZ_Express_*.aab`, `AZ_Express_Windows_to_Mac_Validated.patch`, `az_splash_log.txt`, `functions_after_failed_deploy.txt`, `qr-release/`, `scripts/hosting/`, `scripts/maintenance/`, `test-env/.emulators.pid`, `web/downloads/`, `lib/services/account_deletion_service.dart`, `web/legal/*.html`, tout `.env*`.

## 4. Ordre recommandé

1 → 2 → 3 → 4 → 5 (3 est libre). Le script de déploiement exige que `functions/`, `firestore.rules`, `firestore.indexes.json` et `firebase.json` soient propres : seuls les commits 1, 2 et 3 le garantissent ; **les commits 4 et 5 ne sont pas requis pour passer ce contrôle**, mais le script lui-même devrait être commité avant usage (traçabilité).

## 5. Vérifications avant de stager (humain)

```bash
git status --short
git diff --stat -w --ignore-cr-at-eol -- functions rules-tests docs test-env
cd functions && npm test                  # 0 échec attendu hors tests d'émulateur (166 ignorés)
```
Après chaque `git add`, `git diff --cached --stat` doit lister **exactement** les chemins du commit, rien d'autre.

## 6. Commandes Git exactes (NON exécutées)

### Commit 1
```bash
git add -- \
  functions/accountDeletion.js \
  functions/accountCleanup.js \
  functions/partnerAccountDeletion.js \
  functions/accountDeletionSupport.js \
  functions/accountAdmission.js \
  functions/index.js \
  functions/feexpayPayments.js \
  functions/azia/index.js \
  functions/azia/pendingActions.js \
  functions/pilotCap.js \
  functions/test/accountDeletionHardening.test.js \
  functions/test/accountQuarantineGuards.test.js \
  functions/test/accountQuarantineIndex.test.js \
  functions/test/accountQuarantineConcurrency.emulator.test.js \
  functions/test/pilotCap.test.js \
  rules-tests/account-deletion.test.js \
  rules-tests/account-deletion-lifecycle.test.js \
  rules-tests/account-deletion-real.test.js
git diff --cached --stat
git commit -m "feat(account-deletion): quarantine guards, cleanup engine and preprod caps" \
  -m "Relit le tombstone dans les transactions financieres (paiement, retrait, confirmation AZ IA), met en attente les paiements tardifs (held_for_review), nettoie les donnees AZ IA, plafonne les demandes, protege les administrateurs, et plafonne les 4 fonctions de garde en preproduction uniquement." \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

### Commit 2
```bash
git add -- \
  functions/passwordReset.js \
  functions/adminPartnerAccounts.js \
  functions/ekbineOrders.js \
  functions/professionalSubscriptions.js \
  functions/test/passwordReset.test.js \
  functions/test/ekbineQuarantineGuards.test.js
git diff --cached --stat
git commit -m "feat(account-deletion): quarantine guards for E-Kbine, password reset, partner admin and subscriptions" \
  -m "ekClientConfirmOrder ne credite plus un agent supprime ou en quarantaine ; ekCreateOrderCF refuse un client en quarantaine ; ekbineAcceptOrder, resetAccountPassword, manageAdminPartnerAccount et manageProfessionalSubscription relisent le tombstone. Fonctions non deployees en P1/P2." \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

### Commit 3
```bash
git add -- functions/test/restaurantV2Preprod.test.js
git diff --cached --stat
git commit -m "test(restaurant-v2): force the spec reporter of the child test run so the report check works on Node 22" \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

### Commit 4
```bash
git add -- test-env/deploy-account-deletion-preprod.ps1
git diff --cached --stat
git commit -m "chore(preprod): add dedicated account-deletion deploy script (simulation by default, never run for real)" \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

### Commit 5
```bash
git add -- \
  docs/ACCOUNT_DELETION_RELEASE_CHECKLIST.md \
  docs/ACCOUNT_DELETION_7E66_PRODUCTION_SAFETY_REPORT.md \
  docs/ACCOUNT_DELETION_7E67_FUNCTION_RISK_MATRIX.md \
  docs/ACCOUNT_DELETION_7E67_RECOMMENDED_DEPLOYMENT_SCOPE.md \
  docs/ACCOUNT_DELETION_7E68_LOCAL_HARDENING_REPORT.md \
  docs/ACCOUNT_DELETION_7E69_VALIDATION_REPORT.md \
  docs/ACCOUNT_DELETION_7E69_PREPROD_RUNBOOK.md \
  docs/ACCOUNT_DELETION_7E70_PREPROD_PREPARATION_REPORT.md \
  docs/ACCOUNT_DELETION_7E70_PREPROD_DEPLOYMENT_PLAN.md \
  docs/ACCOUNT_DELETION_7E70_PREPROD_TEST_MATRIX.md \
  docs/ACCOUNT_DELETION_7E70_PREPROD_ROLLBACK_PLAN.md \
  docs/ACCOUNT_DELETION_7E71_TECHNICAL_CONSOLIDATION_REPORT.md \
  docs/ACCOUNT_DELETION_7E71_NODE22_VALIDATION.md \
  docs/ACCOUNT_DELETION_7E71_PREPROD_FUNCTION_LIMITS.md \
  docs/ACCOUNT_DELETION_7E71_DEPLOY_SCRIPT_REVIEW.md \
  docs/ACCOUNT_DELETION_7E71_COMMIT_MANIFEST.md \
  docs/ACCOUNT_DELETION_7E71_HELD_FOR_REVIEW_RESOLUTION_PROPOSAL.md \
  docs/ACCOUNT_DELETION_7E72_FINAL_P1_VALIDATION_REPORT.md \
  docs/ACCOUNT_DELETION_7E72_EKBINE_CONCURRENCY_ANALYSIS.md \
  docs/ACCOUNT_DELETION_7E72_NODE22_FINAL_TESTS.md \
  docs/ACCOUNT_DELETION_7E72_EKCLIENTCONFIRMORDER_AUDIT.md \
  docs/ACCOUNT_DELETION_7E72_COMMIT_FINAL_MANIFEST.md \
  docs/ACCOUNT_DELETION_7E72_P1_CAPACITY_REVIEW.md
git diff --cached --stat
git commit -m "docs(account-deletion): missions 7E-66 to 7E-72 reports and preprod plans" \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

### Contrôle final
```bash
git status --short      # attendu : seuls les éléments « ne pas ajouter » restent
git log --oneline -6
```

## 7. Le script de déploiement peut-il déployer par erreur ? (vérifié)

Analyse du code et **simulations** (mode par défaut, aucune commande distante) :

| Risque | Résultat |
|---|---|
| Hosting / toutes les fonctions | impossible : seule commande de déploiement possible = `firebase deploy --project az-express-preprod --only functions:<noms de la table>` ; refus de tout déploiement sans `--only` ou avec une cible hors `functions:<nom>` ; aucune étape Hosting/Firestore/Storage/index |
| Production | simulations `-Project az-express-b0469`, `-Project az-express-clean`, `-ProjectNumber 697217052961` : **REFUS** avant toute action |
| Fonctions non autorisées | liste blanche de 8 noms en dur, validée à chaque appel ; fonction absente de la table → refus |
| `-Stage all` / `preflight` en réel | refusés par le code (`-Execute exige UNE étape`) ; **non rejoués en réel** (interdit) |
| Arbre non propre en réel | refusé (`functions`, `firestore.rules`, `firestore.indexes.json`, `firebase.json`) ; en simulation : avertissement |
| Marge de quota | défaut 1,0 vCPU : P1 (18,75) accepté, P2 (19,75) refusé sans `-MinMarginVcpu` explicite |

Limite : le chemin `-Execute` n'a jamais été exécuté ; sa sécurité repose sur la lecture du code et sur les refus observés en simulation.
