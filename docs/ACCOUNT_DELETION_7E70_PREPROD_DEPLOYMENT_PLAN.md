# Mission 7E-70 — Plan de déploiement en préproduction (suppression de compte)

Date : 2026-11-06 · Projet **unique** : `az-express-preprod` (n° 306761725053). **Document de plan : rien n'est exécuté.** Chaque phase marquée **[AUTORISATION]** exige une autorisation distincte, explicite et propre à cette phase (une approbation ne s'étend pas d'une phase à l'autre). Constats détaillés : `ACCOUNT_DELETION_7E70_PREPROD_PREPARATION_REPORT.md`.

## 0. Règles communes

1. Toute commande `firebase` / `gcloud` porte `--project az-express-preprod`. Jamais de `firebase use`. `.firebaserc` et `gcloud config` désignent **la production** : ne jamais s'y fier.
2. Chaque déploiement : `--only functions:a,functions:b` (jamais `functions` seul, jamais sans `--only` : `firebase.json` contient aussi `hosting`), `--non-interactive`, **sans `--force`**.
3. Une seule phase par autorisation ; arrêt à la première erreur ; aucun nouvel essai avec un périmètre élargi sans nouvelle autorisation. Une erreur « total allowable CPU per project per region » signifie qu'il faut réduire la charge, pas insister.
4. Aucun secret affiché ou copié depuis la production. Le journal ne contient aucune valeur secrète.
5. Données synthétiques uniquement (préfixe `t7e-del-`). FeexPay reste `DISABLED`. Aucun paiement, retrait ou remboursement réel.
6. `operations_control/account_deletion` reste **absent** jusqu'à la phase P4.

## 1. Prérequis bloquants (avant toute autorisation de déploiement)

| # | Prérequis | Responsable / décision |
|---|---|---|
| R1 | **Quota** : levée de « QUOTA NON CONFIRMÉ » — relevé de la consommation réelle (console GCP → IAM et administration → Quotas → `CpuAllocPerProjectRegion`, `europe-west1`) par un humain habilité, ou décision explicite d'accepter le risque en P1 (marge théorique 1,25 vCPU) | exploitant |
| R2 | **Commit** du périmètre 7E-64/68/69 (17 fichiers déployables dont `accountCleanup.js` non suivi). Code déployé = code commité (principe du script Restaurant v2) | **[AUTORISATION]** distincte |
| R3 | Plafond préproduction des 4 fonctions de garde (patch A ci-dessous) — **requis pour P2 uniquement** | **[AUTORISATION]** modification de code |
| R4 | Script dédié `deploy-account-deletion-preprod.ps1` (patch B) | **[AUTORISATION]** création de fichier |
| R5 | Arbre propre sur `functions/`, `firestore.rules`, `firestore.indexes.json`, `firebase.json` ; `npm test` sans échec (2300 tests au 7E-69) ; essai complémentaire sous **Node 22** (runtime) si possible | exploitant |
| R6 | Vérification humaine que les 5 secrets préproduction ne contiennent **pas** de valeurs de production (impossible à contrôler sans lecture) | exploitant |
| R7 | `node test-env/verify-isolation.js --env functions/.env.az-express-preprod --defines test-env/dart-defines.test.json --google-services <chemin hors dépôt>` → code 0 | exploitant |

## 2. Phases

### P0 — Rien à déployer : règles, index, Storage (déjà identiques)

Constat 2026-11-06 : règles Firestore (hash `aa2310a88e99`), règles Storage (contenu identique), 93 index = local. **Aucun `firestore:rules`, `firestore:indexes`, `storage` n'est à lancer.** Si `firestore.rules`/`storage.rules`/`firestore.indexes.json` changent avant P1, refaire la comparaison (lecture) avant de décider.

### P1 — Les 4 fonctions de suppression **[AUTORISATION]**

| Fonction | Type | cpu × max | Rôle |
|---|---|---|---|
| `requestAccountDeletionCF` | callable | 0,5 × 1 | demande utilisateur |
| `getAccountDeletionStatusCF` | callable | 0,25 × 1 | suivi par jeton de récupération |
| `retryAccountDeletions` | scheduler (15 min) | 0,25 × 1 | reprise / réconciliation |
| `manageAccountDeletionCF` | callable super-admin | 0,25 × 1 | support (`list`, `claim`, `retry`) |

Coût 1,25 vCPU → 18,75 / 20 (théorique). Les 4 sont **nouvelles** dans le projet (pas de doublement transitoire de révision). Aucune ne déclare de secret propre ; elles embarquent `accountDeletion.js`, `accountDeletionSupport.js`, `accountCleanup.js`, `partnerAccountDeletion.js`, `accountAdmission.js`.
Effets distants du déploiement à connaître : création du service Cloud Run, de la fonction, et pour `retryAccountDeletions` d'un job Cloud Scheduler + sujet Pub/Sub (API déjà activées).

Commande type (proposée, non exécutée) :
```powershell
# Simulation d'abord (aucune commande distante)
powershell -ExecutionPolicy Bypass -File test-env\deploy-account-deletion-preprod.ps1 -Stage functions-deletion
# Réel, seulement après autorisation de P1 :
powershell -ExecutionPolicy Bypass -File test-env\deploy-account-deletion-preprod.ps1 -Stage functions-deletion -Execute -ConfirmProject az-express-preprod
# équivalent sous-jacent :
firebase deploy --project az-express-preprod --only functions:requestAccountDeletionCF,functions:getAccountDeletionStatusCF,functions:retryAccountDeletions,functions:manageAccountDeletionCF --non-interactive
```
Avec P1 déployé et config absente, le système reste **fermé** : les demandes restent `pending` / `server_rollout_not_enabled`.

### P2 — Les 4 fonctions de garde **[AUTORISATION]** (après patch A)

`initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction`, `feexPayWebhook`.
Condition : plafond préproduction `maxInstances=1`, `cpu=0,25`, `concurrency=1` → 1,0 vCPU au total → 19,75 / 20 (marge théorique **0,25 vCPU**). Sans patch A : 400 vCPU revendiqués → **déploiement refusé par le quota (ou pire : saturation)** → ne pas lancer.
Secrets déclarés : `FEEXPAY_TOKEN`, `FEEXPAY_WEBHOOK_SECRET` (+ secrets d'`aiConfirmAction`). Ils existent dans le projet ; le déploiement ajoute les droits d'accès du compte de service d'exécution (effet IAM distant, à mentionner dans l'autorisation). Valeurs `DISABLED` attendues : **aucun crédit réel possible** (le vérificateur serveur échoue fermé).
Variante si la marge de 0,25 vCPU est jugée insuffisante : déployer `aiConfirmAction` + `initiateWithdrawal` d'abord, puis `initiateFeexPayPayment` + `feexPayWebhook` (le webhook seul suffit pour les scénarios 15-17 en test d'écriture directe).

### P3 — Hors lot actuel (reporté)

Fonctions comptes / E-Kbine / partenaires / mots de passe / `azIaChat` (14 + 1 fonctions, liste dans le rapport §5). Elles **ne tiennent pas** dans les 2,5 vCPU de marge théorique restante même plafonnées. Leur déploiement exige une décision préalable sur la capacité (hausse de quota demandée par un humain, ou libération de capacité en retirant des fonctions du pilote — opération distante à décider séparément). Les validations métier restent couvertes par les tests locaux 7E-69.

### P4 — Création de la configuration en préproduction **[AUTORISATION]** distincte

Document `operations_control/account_deletion` = `{ enabled: true, inventoryVersion: 1 }` dans la base de **`az-express-preprod`** uniquement. `partnerInventoryVersion` **absent** (partenaires en revue manuelle). Préconditions : P1 (et P2 pour les scénarios 12-17) validés ; comptes synthétiques créés ; sauvegarde de l'état de `functions:list` ; script d'écriture à usage unique, refusant tout identifiant contenant `b0469` ou `clean`, projet fixé en dur. **Désactivation immédiate** possible (`enabled=false` ou suppression du document, voir plan de retour arrière).

### P5 — Scénarios

Exécution de la matrice (`ACCOUNT_DELETION_7E70_PREPROD_TEST_MATRIX.md`) dans l'ordre. Pas de test sur les comptes existants.

## 3. Photographie avant déploiement (lecture, à répéter avant chaque phase)

```powershell
firebase functions:list --project az-express-preprod --json > test-env\runtime\avant_P1.json   # dossier ignoré par Git
firebase firestore:indexes --project az-express-preprod > test-env\runtime\avant_P1_indexes.json
```
et noter : hash des règles publiées (GET `firebaserules.googleapis.com/v1/projects/az-express-preprod/releases/cloud.firestore`), version des 5 secrets (`gcloud secrets versions list <nom> --project az-express-preprod` — métadonnées seulement).

## 4. Vérifications après déploiement (par phase)

1. `firebase functions:list --project az-express-preprod --json` : les fonctions du lot sont `ACTIVE`, `europe-west1`, `nodejs22`, `maxInstances` et `cpu` attendus ; **les 20 fonctions existantes ont la même révision / date qu'avant**.
2. `firebase functions:log --project az-express-preprod --only <fonction>` : aucune erreur de chargement ni de secret manquant.
3. `gcloud run services list --project az-express-preprod --region europe-west1` : max scale/cpu conformes ; pas de service inattendu.
4. `account_tombstones` / `account_deletions` : toujours **vides** après P1/P2 (aucune écriture sans config).
5. Règles Firestore/Storage : hash inchangé.
6. Production : `firebase functions:list --project az-express-b0469 --json` (lecture) identique à l'état connu — preuve que rien n'a été touché.
7. Quota : relever à nouveau la consommation dans la console avant P2.

## 5. Critères d'arrêt immédiat

Erreur de quota ; cible ≠ `az-express-preprod` (id **ou** numéro) ; fonction hors liste blanche dans la commande ; apparition d'un document dans `account_*` avant P4 ; modification d'une des 20 fonctions existantes ; toute valeur secrète visible dans un journal ; doute sur le projet.

## 6. Patchs proposés (NON appliqués)

### Patch A — plafond préproduction des fonctions de garde (`pilotCap.js`, `index.js`, `azia/index.js`)

Principe : aucun effet hors préproduction (`pilotInstanceLimit` renvoie `null` sauf si `GCLOUD_PROJECT === 'az-express-preprod'`), donc **le comportement de production est inchangé**.

```diff
--- a/functions/pilotCap.js
+++ b/functions/pilotCap.js
@@
+// Fonctions légères de la validation « suppression de compte » : en préproduction seulement, 1 instance, 0,25 vCPU, 1 requête
+// par instance (cpu < 1 impose concurrency 1 en 2e génération). Ailleurs : options vides, donc inchangées.
+function pilotLightOptions(env = process.env) {
+  return pilotInstanceLimit(env) === null ? {} : { maxInstances: 1, cpu: 0.25, concurrency: 1 };
+}
-module.exports = { PREPROD_PROJECT, pilotInstanceLimit, capInstances, pilotOnlyInstanceOptions, pilotRetry };
+module.exports = { PREPROD_PROJECT, pilotInstanceLimit, capInstances, pilotOnlyInstanceOptions, pilotLightOptions, pilotRetry };
--- a/functions/index.js
+++ b/functions/index.js
-const { capInstances, pilotOnlyInstanceOptions, pilotRetry } = require('./pilotCap');
+const { capInstances, pilotOnlyInstanceOptions, pilotLightOptions, pilotRetry } = require('./pilotCap');
@@ exports.initiateFeexPayPayment = onCall({
   secrets: [FEEXPAY_TOKEN_SECRET, FEEXPAY_WEBHOOK_SECRET],
+  ...pilotLightOptions(),
@@ exports.feexPayWebhook = onRequest({
   secrets: [FEEXPAY_WEBHOOK_SECRET, FEEXPAY_TOKEN_SECRET],
+  ...pilotLightOptions(),
@@ exports.initiateWithdrawal = onCall({
   secrets: [FEEXPAY_TOKEN_SECRET],
+  ...pilotLightOptions(),
--- a/functions/azia/index.js    (aiConfirmAction : ajouter les mêmes options via buildConfirmAction / son onCall)
```
Tests à ajouter dans `functions/test/pilotCap.test.js` : renvoie `{}` pour `GCLOUD_PROJECT=az-express-b0469` et pour variable absente ; renvoie `{maxInstances:1,cpu:0.25,concurrency:1}` pour `az-express-preprod`. Vérification : relancer le calcul du manifeste (`GCLOUD_PROJECT=az-express-preprod`) → Σ des 4 = 1,0 ; et avec `GCLOUD_PROJECT=az-express-b0469` → options inchangées.
Risque : une mauvaise valeur de `cpu` rendrait la fonction trop lente (timeout) en préproduction seulement ; à observer en P2.

### Patch B — script dédié (`test-env/deploy-account-deletion-preprod.ps1`, à créer)

Calqué sur `deploy-restaurant-v2-preprod.ps1` (mêmes protections) avec :
```powershell
$Stages = [ordered]@{
  'functions-deletion' = @('requestAccountDeletionCF','getAccountDeletionStatusCF','retryAccountDeletions','manageAccountDeletionCF')
  'functions-guards'   = @('initiateFeexPayPayment','initiateWithdrawal','aiConfirmAction','feexPayWebhook')
}
# Préflight (hors ligne) : exportée par index.js, region europe-west1, maxInstances == 1 ET cpu <= 0.25 à l'analyse
#   avec GCLOUD_PROJECT=az-express-preprod ; arbre propre exigé en mode réel ; FEEXPAY_SHOP_ID == DISABLED ;
#   FEEXPAY_TOKEN / FEEXPAY_WEBHOOK_SECRET absents ou DISABLED dans les .env ; numéro 306761725053 vérifié ;
#   -ConfirmProject az-express-preprod obligatoire ; une étape par appel ; journal sans secret ; jamais --force.
# Étape distante (réel) : projects:list (id + numéro) -> firebase deploy --project az-express-preprod --only functions:... --non-interactive
```
Correctifs à reporter aussi dans `deploy-preprod.ps1` si ce script est conservé : contrôle de `$LASTEXITCODE` après `firebase deploy`, comparaison sensible à la casse (`-cne`), contrôle du numéro de projet.

### Patch C — commit (R2)

Hors dépôt de ce plan ; à demander explicitement. Périmètre : les 17 fichiers listés par `git status --porcelain -- functions firestore.rules firestore.indexes.json firebase.json` (hors `.env*`).

*Aucune de ces trois modifications n'a été appliquée ni commitée. Attendre une autorisation distincte.*
