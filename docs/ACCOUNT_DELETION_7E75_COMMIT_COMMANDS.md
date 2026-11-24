# Mission 7E-75 — Commandes Git exactes pour le commit P1 (NON EXÉCUTÉES)

Date : 2026-11-07 · À exécuter uniquement après autorisation humaine explicite et distincte. Aucune n'a été lancée. Jamais `git add .`, `git add -A`, `git commit -a`.

## 0. Préconditions
```bash
cd /d/az_express_clean
git rev-parse --short HEAD            # attendu : aa3d1b0 (sinon STOP et réévaluer)
git branch --show-current             # finalisation/az-express
git diff --cached --name-only         # attendu : vide (sinon STOP)
test -f test-env/runtime/7e73-patches/index_p1.patch || echo "PATCH ABSENT"
```
`index_p1.patch` est dans un dossier ignoré par Git (`.gitignore:83`) : ne sera pas committé. Il contient **uniquement** le hunk 3 d'`index.js` (une ligne). Si `functions/index.js` a changé depuis, régénérer/valider le patch avant usage.

## 1. Commit 1 — moteur P1 (backend)

### 1.1 Fichiers entiers (chemins explicites)
```bash
git add -- \
  functions/accountDeletion.js \
  functions/accountCleanup.js \
  functions/partnerAccountDeletion.js \
  functions/accountDeletionSupport.js \
  functions/test/accountDeletionHardening.test.js \
  rules-tests/account-deletion.test.js \
  rules-tests/account-deletion-lifecycle.test.js \
  rules-tests/account-deletion-real.test.js
```
### 1.2 Hunk 3 de `functions/index.js` (indexation partielle)
```bash
git apply --cached --check test-env/runtime/7e73-patches/index_p1.patch   # doit réussir sans sortie
git apply --cached test-env/runtime/7e73-patches/index_p1.patch
```
Le fichier de travail `index.js` garde ses 8 autres hunks (P2/P3) non indexés. Ne PAS faire `git add functions/index.js`.

### 1.3 Contrôles avant commit
```bash
git diff --cached --name-only                 # exactement 9 fichiers : les 8 ci-dessus + functions/index.js
git diff --cached --stat
git diff --cached --check                     # aucune erreur d'espaces (avertissements LF/CRLF attendus)
git diff --cached -- functions/index.js       # UNE ligne ajoutée : « …HttpsError,checkRateLimit,logAudit, »
git diff --cached --name-only | grep -E "(^|/)\.env|\.aab$|\.apk$|\.patch$|\.keystore$|key\.properties|GoogleService-Info|\.log$|\.pid$|runtime/|\.cache$" && echo "FICHIER SENSIBLE — STOP" || echo "aucun fichier sensible"
git diff --cached --name-only | grep -E "accountAdmission|feexpay|azia|pilotCap|ekbine|passwordReset|adminPartner|professionalSubscriptions" && echo "FICHIER P2/P3 — STOP" || echo "aucun fichier P2/P3"
```
### 1.4 Commit proposé
```bash
git commit -F - <<'EOF'
feat(account-deletion): P1 deletion engine with closed gateway refusal

- requestAccountDeletionCF refuses before any write when
  operations_control/account_deletion is absent, disabled, unreadable or
  has a wrong inventoryVersion (ACCOUNT_DELETION_NOT_ENABLED, details.reason)
- engine, cleanup allow-list, partner scope (closed), support helpers
- inject checkRateLimit and logAudit into the engine
- unit tests (26) and emulator rules tests (69 with the other deletion files)

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
```

## 2. Commit 1b — client Flutter (juste après validation du commit 1)
```bash
git add -- \
  lib/services/account_deletion_service.dart \
  lib/widgets/account_deletion_dialog.dart \
  test/services/account_deletion_service_test.dart \
  test/widgets/account_deletion_dialog_test.dart
git diff --cached --name-only                 # exactement ces 4 fichiers
git diff --cached --check
git commit -F - <<'EOF'
fix(account-deletion): never show a recorded confirmation when the gateway refused

- AccountDeletionUnavailableException for ACCOUNT_DELETION_NOT_ENABLED
  (details.reason first, message as fallback, failed-precondition only)
- no fallback to the last receipt for that refusal
- unauthenticated handled as a reauthentication error
- widget and service tests

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
```
(Si la décision humaine est un seul commit, ajouter ces 4 chemins à l'étape 1.1.)

## 3. Après chaque commit
```bash
git log --oneline -3
git show --stat --format=fuller HEAD
git show --check HEAD
git status --short          # seuls restent les fichiers des commits suivants et les « ne pas ajouter »
git diff --cached --stat    # vide
```
Voir `ACCOUNT_DELETION_7E75_POST_COMMIT_CHECKLIST.md`. Aucun `git push` sans autorisation distincte.

## 4. Si la procédure échoue
Avant commit : `git restore --staged <chemins>` (désindexation uniquement, après décision humaine). Ne pas utiliser `git reset --hard`, `git checkout .`, `git clean`. Après commit défectueux : nouveau commit correctif ou `git revert`, jamais de réécriture d'historique sans accord.
