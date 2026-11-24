# Mission 7E-73 — Carte des dépendances des commits

Date : 2026-11-07 · HEAD `aa3d1b0` · Aucun commit fait. La scission de 7E-72 est affinée : l'ancien commit 1 devient **1 (P1)** et **2 (gardes P2)**, d'où six commits ; la correspondance avec les « cinq commits » de 7E-72 est : ancien 1 → 1 + 2 ; ancien 2 → 3 ; ancien 3 → 4 ; ancien 4 → 5 ; ancien 5 → 6.

## 1. Vue d'ensemble

| # | Intitulé | Dépend de | Déployable seul | Reportable |
|---|---|---|---|---|
| 1 | Moteur de suppression P1 | HEAD | oui | non (cœur du pilote) |
| 2 | Gardes financières / AZ IA (P2) et plafonds préproduction | 1 (pour le câblage de `index.js`) | oui | oui, sans effet sur P1 mais **laisse l'écart du §3 de la revue du commit 1** |
| 3 | E-Kbine seul (`ekbineOrders.js` + son test) | **HEAD uniquement** (n'utilise que `assertNewAccountActivity`, déjà à HEAD) | oui | oui, tant que la revue métier n'est pas signée |
| 3b | Gardes P3 (mots de passe, administration partenaires, abonnements, `setPharmaciePassword`) | 2 (`assertTargetNotClosing`) | oui | oui |
| 4 | Correctif de test Node 22 | rien | oui | oui |
| 5 | Script de déploiement | rien (code) | oui | non (requis pour déployer) |
| 6 | Documentation | rien | oui | oui |

Ordre conservé : 1 → 2 → 3 → 3b → 4 → 5 → 6. Contraintes réelles : 2 après 1 (même fichier `index.js`, patchs empilés) ; 3b après 2 ; **3 (E-Kbine) peut être fait n'importe quand après HEAD**, y compris sans 1 ni 2 ; 4, 5, 6 libres.

## 2. Détail par commit

### Commit 1 — P1
- **Fichiers** : `functions/accountDeletion.js`, `functions/accountCleanup.js` (nouveau), `functions/partnerAccountDeletion.js`, `functions/accountDeletionSupport.js`, `functions/index.js` (hunk n° 3 via `index_p1.patch`), `functions/test/accountDeletionHardening.test.js` (nouveau), `rules-tests/account-deletion.test.js`, `account-deletion-lifecycle.test.js`, `account-deletion-real.test.js`.
- **Dépendances techniques** : `accountDeletion` → `accountCleanup`, `accountDeletionIdentity`, `partnerAccountDeletion` ; `partnerAccountDeletion` → `accountCleanup`, `accountDeletionScope`, `accountRelatedPersonalData` (déjà à HEAD) ; `index.js` → `accountDeletion`.
- **Fonctions concernées** : `requestAccountDeletionCF`, `getAccountDeletionStatusCF`, `retryAccountDeletions`, `manageAccountDeletionCF`.
- **Tests obligatoires** : `accountDeletionHardening` (21), `accountDeletionSupport`, règles de suppression 4 fichiers (63), chargement de `index.js`, suite sans émulateur.
- **Risques** : moyen (nouveau comportement du moteur, `requestAccountDeletionCF` n'est pas encore fermé par la passerelle côté demande — voir décision §7 de la revue).
- **Préalables** : décision sur le correctif « passerelle fermée » ; aucune autre.
- **Raisons de reporter** : aucune.

### Commit 2 — gardes P2, AZ IA, plafonds préproduction
- **Fichiers** : `functions/accountAdmission.js`, `functions/feexpayPayments.js`, `functions/azia/index.js`, `functions/azia/pendingActions.js`, `functions/pilotCap.js`, `functions/index.js` (hunks 1, 2, 4-8 via `index_p2.patch`), tests `accountQuarantineGuards`, `accountQuarantineIndex`, `accountQuarantineConcurrency.emulator`, `pilotCap`.
- **Dépendances** : `index.js` → `accountAdmission` (import), `pilotCap` (`pilotLightOptions`) ; `azia/index.js` → `pilotCap` ; `azia/pendingActions.js` → `accountAdmission` ; `feexpayPayments.js` autonome.
- **Fonctions** : `initiateFeexPayPayment`, `initiateWithdrawal`, `feexPayWebhook`, `aiConfirmAction` (plafonnées en préproduction uniquement : 1 vCPU au total).
- **Tests obligatoires** : `accountQuarantineGuards` (17), `accountQuarantineIndex` (11), `pilotCap` (10), concurrence émulateur (9), paiements (`feexpay*`, wallet, recharges : 178), AZ IA (174), règles Firestore principales (470).
- **Risques** : moyen-élevé (chemins d'argent). Aucun déploiement P2 tant que le quota n'est pas confirmé.
- **Préalables** : commit 1.
- **Raisons de reporter** : quota (P1 + P2 = 19,75 vCPU théorique, marge 0,25 < 1,0) ; absence d'outil `held_for_review` pour l'activation complète.

### Commit 3 — E-Kbine seul
- **Fichiers** : `functions/ekbineOrders.js`, `functions/test/ekbineQuarantineGuards.test.js` (nouveau).
- **Dépendances** : `ekbineOrders.js` importe `assertNewAccountActivity` de `accountAdmission.js`, **déjà présent à HEAD** ; le test n'importe que `ekbineOrders` et `fakeFirestore`. Aucune dépendance envers les commits 1 et 2 (à vérifier par le contrôle de la checklist). Aucun fichier du commit 1 n'importe `ekbineOrders`. **Vérifié** : reconstitution `HEAD` + ces deux seuls fichiers → `index.js` se charge, 54/54 tests E-Kbine.
- **Fonctions** : `ekCreateOrderCF`, `ekClientConfirmOrder`, `ekbineAcceptOrder`.
- **Tests obligatoires** : `ekbineQuarantineGuards` (11), `ekbineOrders`/`ekbineDepositFlow`/`ekbineReconciliation` (43), `financialConcurrency.emulator` (voir la décision sur le test des 8 appels).
- **Risques** : faible à moyen ; revue métier E-Kbine non signée.
- **Raisons de reporter** : revue métier ; ne bloque pas P1.

### Commit 3b — gardes P3
- **Fichiers** : `functions/passwordReset.js`, `functions/adminPartnerAccounts.js`, `functions/professionalSubscriptions.js`, `functions/index.js` (hunk n° 9 via `index_p3.patch`), `functions/test/passwordReset.test.js`.
- **Dépendances** : `passwordReset.js`, `adminPartnerAccounts.js` et le hunk 9 utilisent `assertTargetNotClosing` (commit 2, import du hunk 2) ; `professionalSubscriptions.js` n'importe pas `accountAdmission`.
- **Fonctions** : `resetAccountPassword`, `manageAdminPartnerAccount`, `manageProfessionalSubscription`, `setPharmaciePassword`.
- **Tests obligatoires** : `passwordReset`, `adminPartnerAccounts`, `professionalSubscriptions`.
- **Risques** : faible. **Raisons de reporter** : revue métier partenaires ; ne bloque pas P1.

### Commit 4 — correctif de test
- `functions/test/restaurantV2Preprod.test.js` (1 ligne). Aucune dépendance. Test : le fichier lui-même (12/12 sous Node 22 et 24). Indépendant de la suppression de compte.

### Commit 5 — script de déploiement
- `test-env/deploy-account-deletion-preprod.ps1`. Aucune dépendance de code ; ne modifie pas ce qui est déployé. Tests : analyse syntaxique + simulations (production refusée, ancien identifiant refusé, numéro de production refusé). Jamais exécuté en réel. **Séparé du moteur** : modifiable sans changer le code déployé.

### Commit 6 — documentation
- `docs/ACCOUNT_DELETION_RELEASE_CHECKLIST.md` (modifié) et `docs/ACCOUNT_DELETION_7E66…7E73_*.md`. Aucun code. Sans dépendance.

## 3. Contrôles de contenu

| Contrôle | Résultat |
|---|---|
| Fichier `.env`, secret, APK/AAB, patch, clé, keystore, `GoogleService-Info.plist` dans les listes | **aucun** |
| `.firebase/hosting.*.cache`, `qr-release/`, `scripts/hosting/`, `scripts/maintenance/`, `web/downloads/`, `test-env/.emulators.pid`, `functions_after_failed_deploy.txt`, `az_splash_log.txt` | exclus |
| `lib/services/account_deletion_service.dart`, `web/legal/*.html` | exclus (application mobile / contenu légal à valider) |
| Couverture | tous les fichiers modifiés ou non suivis de `functions/`, `rules-tests/` sont dans exactement un commit (`index.js` réparti en 3 patchs) |
| Les patchs `index_p1/p2/p3` | appliqués dans l'ordre à HEAD : **identiques** à l'`index.js` actuel |
| Les patchs sont dans un dossier **ignoré** par Git (`test-env/runtime/`) | ne seront pas committés |

## 4. Règles de fin de ligne

Dépôt en `autocrlf=true` : plusieurs fichiers de travail sont en CRLF alors que l'index est en LF (par exemple `index.js`, `accountDeletion.js`) ; Git normalise à l'ajout. Les patchs (LF) s'appliquent à l'index sans conflit (vérifié par `git apply --cached --check`).
