# Mission 7E-71 — Manifeste de commit (suppression de compte, préproduction)

Date : 2026-11-06 · Branche `finalisation/az-express` · HEAD `aa3d1b0` · **Aucun commit, aucun `git add`, aucun push n'a été fait.** Ce document ne fait que préparer une liste à valider par un humain. Jamais `git add .` ni `git add -A`.

## 1. État de départ (2026-11-06, avant les modifications 7E-71)

12 fichiers suivis modifiés + 5 fichiers de `functions/` non suivis = les « 17 fichiers » des missions 7E-64/68/69, auxquels s'ajoutent des fichiers de documentation, de règles de test, de client et de pages légales. Vérifié : parmi les **131 modules locaux** atteints depuis `functions/index.js`, un seul n'est pas suivi par Git : **`functions/accountCleanup.js`** — il doit impérativement être commité, sinon un déploiement depuis un clone propre échoue au chargement.

Fichiers ajoutés ou modifiés par la mission 7E-71 : `functions/pilotCap.js`, `functions/index.js` (3 lignes de plafond en plus de 7E-68), `functions/azia/index.js` (2 lignes), `functions/azia/pendingActions.js` (paramètre `options`), `functions/test/pilotCap.test.js` (+3 tests), `test-env/deploy-account-deletion-preprod.ps1` (nouveau), et les 6 documents `docs/ACCOUNT_DELETION_7E71_*.md`.

## 2. Classement

### A. Nécessaires au pilote de suppression (moteur)
| Fichier | État | Contenu |
|---|---|---|
| `functions/accountDeletion.js` | modifié (+76/−~) | limites (5/h, 10 par dossier, 60 s, 6 échecs), audit strict avant suppression Auth, blocage administrateur D3, nettoyage inconnu → revue manuelle |
| `functions/accountCleanup.js` | **nouveau (137 l.)** | inventaire/effacement notifications et données AZ IA, plafond de tentatives |
| `functions/partnerAccountDeletion.js` | modifié (+25) | même nettoyage et plafond côté partenaires |
| `functions/accountDeletionSupport.js` | modifié (+6) | reprise motivée remet le compteur à zéro |
| `functions/accountAdmission.js` | modifié (+11) | `assertNewAccountActivity` + `assertTargetNotClosing` |

### B. Nécessaires aux gardes (quarantaine relue dans la transaction)
| Fichier | État | Fonctions touchées | Déploiement prévu |
|---|---|---|---|
| `functions/index.js` | modifié | `initiateFeexPayPayment`, `initiateWithdrawal`, `feexPayWebhook` (plafond), `setPharmaciePassword`, câblage `checkRateLimit`/`logAudit` du moteur | P2 / P3 |
| `functions/feexpayPayments.js` | modifié (+72) | `feexPayWebhook` : statut `held_for_review`, lecture parallèle profil + tombstone | P2 |
| `functions/azia/pendingActions.js` | modifié | `aiConfirmAction` : garde dans la transaction ; paramètre `options` (plafond) | P2 |
| `functions/azia/index.js` | modifié (+2) | câblage `pilotLightOptions` | P2 |
| `functions/pilotCap.js` | modifié (+12) | `pilotLightOptions` (vide hors préproduction) | P2 |
| `functions/passwordReset.js` | modifié (+3) | `resetAccountPassword`, `artisanLogin`/`setArtisanPin` (compte cible) | P3 (reporté) |
| `functions/adminPartnerAccounts.js` | modifié (+3) | `manageAdminPartnerAccount` | P3 (reporté) |
| `functions/ekbineOrders.js` | modifié (+3) | `ekbineAcceptOrder` | P3 (reporté) |
| `functions/professionalSubscriptions.js` | modifié (+4/−1) | `manageProfessionalSubscription` | P3 (reporté) |

Les fichiers « P3 reporté » sont **commités avec le reste** (une base de code) mais leurs fonctions ne sont **pas** déployées en P1/P2 ; la revue métier E-Kbine / partenaires reste à signer avant tout déploiement de ces fonctions.

### C. Nécessaires aux tests
| Fichier | État | Tests |
|---|---|---|
| `functions/test/accountDeletionHardening.test.js` | nouveau (397 l.) | 21 |
| `functions/test/accountQuarantineGuards.test.js` | nouveau (~220 l.) | 17 (dont 1 ajouté en 7E-71 : échec de lecture du tombstone au webhook) |
| `functions/test/accountQuarantineIndex.test.js` | nouveau (169 l.) | 11 |
| `functions/test/accountQuarantineConcurrency.emulator.test.js` | nouveau (247 l.) | 9 (émulateur Firestore ; ignorés sans émulateur) |
| `functions/test/passwordReset.test.js` | modifié (+2) | double étendu (`get`) |
| `functions/test/pilotCap.test.js` | modifié (+53) | +3 tests de plafond |
| `rules-tests/account-deletion.test.js`, `account-deletion-lifecycle.test.js`, `account-deletion-real.test.js` | modifiés (1 ligne chacun) | injectent `checkRateLimit` (le moteur refuse sans limiteur) — **sans ce changement ces 3 suites échouent** |

### D. Outillage de déploiement
| Fichier | État | Remarque |
|---|---|---|
| `test-env/deploy-account-deletion-preprod.ps1` | nouveau (221 l.) | jamais exécuté ; **commit séparé recommandé** (changeable sans toucher au code déployé) |

### E. Documentation
`docs/ACCOUNT_DELETION_7E66_*.md`, `7E67_*.md` (2), `7E68_LOCAL_HARDENING_REPORT.md`, `7E69_VALIDATION_REPORT.md`, `7E69_PREPROD_RUNBOOK.md`, `7E70_*.md` (4), `7E71_*.md` (6) — tous non suivis ; `docs/ACCOUNT_DELETION_RELEASE_CHECKLIST.md` modifié (+12). **Commit séparé** (documentation).

### F. À reporter (hors du commit de préparation)
| Fichier | Raison |
|---|---|
| `lib/services/account_deletion_service.dart` (+2) | message client pour deux motifs ; modifie l'application mobile → à livrer avec une version applicative, pas avec le pilote serveur |
| `web/legal/confidentialite.html`, `web/legal/delete-account.html` | contenu légal (durées de conservation à valider juridiquement) et déploiement Hosting ; hors de cette mission |

### G. À exclure (ne jamais ajouter)
`.firebase/hosting.YnVpbGRcd2Vi.cache` (cache de build) · `AZ_Express_*.aab` (4) · `AZ_Express_Windows_to_Mac_Validated.patch` · `az_splash_log.txt` · `functions_after_failed_deploy.txt` · `qr-release/` · `scripts/hosting/` · `scripts/maintenance/` · `test-env/.emulators.pid` · `web/downloads/` · tout fichier `.env*`, clé, keystore, `GoogleService-Info.plist` (déjà ignorés, rappel). Ces éléments étaient présents avant les missions 7E-66 à 7E-71 et sont **sans lien** avec la suppression de compte.

## 3. Changements non liés à la mission

Aucun des fichiers de la catégorie G ne concerne la suppression de compte. Dans les fichiers inclus, **aucune modification étrangère** n'a été constatée par la revue (diffs relus avec `-w --ignore-cr-at-eol`) ; le seul bruit est l'avertissement Git « LF will be replaced by CRLF » (fins de ligne du dépôt, sans effet sur le contenu).

## 4. Vérifications à refaire juste avant de stager (humain)

```bash
git status --short
git diff --stat -w --ignore-cr-at-eol -- functions rules-tests docs
cd functions && npm test            # attendu : 0 échec ; 166 ignorés (émulateurs)
```
Puis, après staging, `git diff --cached --stat` doit lister **exactement** les chemins des §5.1-5.3, rien d'autre.

## 5. Commandes Git exactes proposées (NON exécutées)

### 5.1 Commit 1 — code et tests (moteur + gardes + plafond)
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
  functions/passwordReset.js \
  functions/adminPartnerAccounts.js \
  functions/ekbineOrders.js \
  functions/professionalSubscriptions.js \
  functions/test/accountDeletionHardening.test.js \
  functions/test/accountQuarantineGuards.test.js \
  functions/test/accountQuarantineIndex.test.js \
  functions/test/accountQuarantineConcurrency.emulator.test.js \
  functions/test/passwordReset.test.js \
  functions/test/pilotCap.test.js \
  rules-tests/account-deletion.test.js \
  rules-tests/account-deletion-lifecycle.test.js \
  rules-tests/account-deletion-real.test.js
git diff --cached --stat
git commit -m "feat(account-deletion): quarantine guards, cleanup and preprod caps" \
  -m "Relit le tombstone dans les transactions financieres (paiement, retrait, confirmation AZ IA), met en attente les paiements tardifs (held_for_review), nettoie les donnees AZ IA, plafonne les demandes, protege les administrateurs, et plafonne les 4 fonctions de garde en preproduction uniquement." \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

### 5.2 Commit 2 — script de déploiement préproduction
```bash
git add -- test-env/deploy-account-deletion-preprod.ps1
git commit -m "chore(preprod): add dedicated account-deletion deploy script (not executed)" \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

### 5.3 Commit 3 — documentation
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
  docs/ACCOUNT_DELETION_7E71_HELD_FOR_REVIEW_RESOLUTION_PROPOSAL.md
git commit -m "docs(account-deletion): missions 7E-66 to 7E-71 reports and preprod plans" \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

### 5.4 Contrôle final
```bash
git status --short      # attendu : seuls les éléments des catégories F et G restent
git log --oneline -3
```
Si l'équipe préfère un seul commit, fusionner 5.1 et 5.2 ; ne pas fusionner avec la documentation. Pour exclure les fonctions « P3 reporté » du commit, retirer `functions/passwordReset.js`, `functions/adminPartnerAccounts.js`, `functions/ekbineOrders.js`, `functions/professionalSubscriptions.js` **et** `functions/test/passwordReset.test.js` du `git add` — mais alors `accountQuarantineGuards.test.js` doit être revérifié (il couvre ces gardes) et `npm test` relancé.

## 6. Après commit (autorisations distinctes, rien n'est lancé ici)

Pousser (`git push`), déployer, ou activer quoi que ce soit exige une autorisation propre. Le script de déploiement dédié refuse un arbre non propre : il ne passera qu'après ce commit.
