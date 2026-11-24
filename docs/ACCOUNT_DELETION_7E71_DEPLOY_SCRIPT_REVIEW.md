# Mission 7E-71 — Revue du script de déploiement dédié (suppression de compte, préproduction)

Date : 2026-11-06 · Fichier : `test-env/deploy-account-deletion-preprod.ps1` (nouveau, non suivi par Git, 221 lignes) · **Préparé, jamais exécuté.** Aucune commande `firebase` ni `gcloud` n'a été lancée *par* ce script. Modèle : `test-env/deploy-restaurant-v2-preprod.ps1` (utilisé en préproduction du 04 au 06/11) ; différences et raisons en §5.

## 1. Ce qui a (et n'a pas) été vérifié

| Vérification | Résultat |
|---|---|
| Analyse syntaxique PowerShell (`Parser.ParseFile`, sans exécution) | **PASS** — 0 erreur ; fonctions définies : `Log`, `Fail`, `Plan`, `Invoke-Firebase` |
| Commandes appelées (analyse de l'arbre syntaxique) | `firebase`, `git`, `node`, cmdlets de lecture/journal ; **aucun** `gcloud`, `curl`, `Invoke-WebRequest`, `Invoke-RestMethod` |
| Occurrences de `--force`, `firebase use` | uniquement dans les **refus** (L161-L162) et un commentaire |
| Contrôle de capacité (même code d'analyse que le script, exécuté à part) | **PASS** — avec `GCLOUD_PROJECT=az-express-preprod` les 8 fonctions de la liste blanche passent (max 1, concurrence 1, cpu ≤ limite, région `europe-west1`, empreinte 2,25 vCPU) ; avec l'identifiant de production les 4 gardes seraient **refusées** (aucune option) |
| Exécution du script (simulation comprise) | **NON FAIT** (consigne : ne pas exécuter) → le déroulé complet, les chemins d'erreur et le journal sont **NON VÉRIFIÉS** par exécution |
| Compatibilité Windows PowerShell 5.1 (`powershell.exe`, interpréteur du dépôt) | analyse syntaxique faite avec l'analyseur de la session (5.1) ; comportement d'exécution **NON VÉRIFIÉ** |
| ASCII uniquement | oui (évite la mauvaise lecture d'accents par PowerShell 5.1 sans BOM) |

## 2. Exigences de la mission et couverture

| Exigence | Où / comment | État |
|---|---|---|
| Exiger explicitement `az-express-preprod` | `-Project` par défaut ; `-ConfirmProject az-express-preprod` obligatoire en réel | codé |
| Refuser toute autre cible, et la production | refus si identifiant ∈ {`az-express-b0469`, `az-express-clean`} ou contient `b0469` / `clean`, différent de `az-express-preprod` (comparaison sensible à la casse), numéro `697217052961` refusé, numéro attendu `306761725053` | codé |
| Vérifier le projet avant toute opération | identifiant + numéro hors ligne ; en réel `firebase projects:list --json` (id **et** numéro) avant toute commande de déploiement ; refus si `GCLOUD_PROJECT`/`GOOGLE_CLOUD_PROJECT`/`FIREBASE_PROJECT` désignent un autre projet | codé |
| Liste blanche stricte | 8 noms en dur par étape (`functions-deletion`, `functions-guards`) ; `Invoke-Firebase` re-vérifie chaque cible `--only` contre la liste | codé |
| Déployer uniquement les fonctions demandées | une étape par appel ; `--only functions:a,functions:b` construit depuis la table, validé par expression régulière | codé |
| Jamais Hosting / jamais global | refus de tout `deploy` sans `--only` ou dont une cible n'est pas `functions:<nom>` ; pas de Firestore/Storage/index dans les étapes | codé |
| Refuser les fonctions inconnues | `ValidateSet` sur `-Stage` ; liste blanche ; contrôle d'export dans `functions/index.js` | codé |
| Afficher les fonctions ciblées avant exécution | journal `Fonctions ciblees: …` avant toute commande, en simulation comme en réel | codé |
| Confirmation explicite avant déploiement | `-Execute` **et** `-ConfirmProject` **et** `-ConfirmStage <étape>` **et** `-QuotaConfirmedByHuman` | codé |
| Arrêt immédiat en cas d'erreur | `$ErrorActionPreference='Stop'`, `Fail` lève une exception, `$LASTEXITCODE` contrôlé après chaque `firebase`, `finally { Pop-Location }` | codé |
| Journal d'exécution | `test-env\runtime\deploy-account-deletion-<horodatage>.log` (dossier ignoré par Git), sans secret | codé |
| Option de simulation sans commande distante | **comportement par défaut** : sans `-Execute`, aucune commande `firebase`/`gcloud` (seulement `git`, `node` local, lecture de fichiers) | codé, non exécuté |
| Ne pas créer `operations_control/account_deletion` | le script n'écrit jamais dans Firestore ; il le rappelle dans le journal | codé |

## 3. Contrôles locaux ajoutés (par rapport au script Restaurant v2)

1. **Plafond de capacité vérifié par fonction** : `maxInstances == 1`, `concurrency == 1`, `cpu` défini et ≤ limite (0,5 pour `requestAccountDeletionCF`, 0,25 pour les autres), région `europe-west1`, à l'analyse de `index.js` avec le projet préproduction.
2. **Projection de quota** (réel seulement) : somme actuelle Σ(cpu × maxInstances) lue dans `functions:list` (maximum plateforme 100 si absent, cpu 1 si absent) + coût de l'étape ; refus si le total dépasse `QuotaLimitVcpu − MinMarginVcpu` (défauts 20 et **0,5**). P1 : 18,75 → accepté. **P2 : 19,75 → refusé par défaut** ; l'accepter exige de passer explicitement `-MinMarginVcpu 0.25` (décision humaine consignée dans la commande).
3. **`-QuotaConfirmedByHuman`** : le script rappelle que l'usage réel du quota n'est pas lisible par API ; il oblige à confirmer qu'un humain l'a relevé dans la console.
4. **Contrôle de l'environnement préproduction** : `FEEXPAY_SHOP_ID=DISABLED`, `PILOT_MAX_INSTANCES=1`, `FEEXPAY_TOKEN`/`FEEXPAY_WEBHOOK_SECRET` absents ou `DISABLED`, aucun secret dans le `.env` (pepper, clés IA), aucune valeur référençant la production. Seules des **comparaisons** sont faites ; aucune valeur n'est journalisée.
5. **Après déploiement** : relecture de `functions:list` et refus si l'ensemble de fonctions diffère de « avant + étape ».
6. **Arbre propre exigé en réel** (code déployé = code commité) — voir le manifeste : actuellement **refusé** (17 fichiers non commités), ce qui est le comportement voulu.

## 4. Défauts et limites connus du script

| # | Sujet | Gravité | Détail |
|---|---|---|---|
| 1 | Jamais exécuté | élevée | Les chemins `-Execute` (`projects:list`, `functions:list`, projection, `deploy`, relecture) n'ont jamais tourné. Premier essai réel = premier test. Mitigation : simulation d'abord, étapes séparées, aucune écriture hors `firebase deploy`. |
| 2 | Noms de propriétés de `functions:list --json` | moyenne | `cpu` / `maxInstances` / `maxInstanceCount` / `id` lus d'après la sortie observée en 7E-70 (champs présents) ; une évolution du CLI les changerait → capacité sous-estimée ou refus. Le script prend le pire cas (100 / cpu 1) quand un champ manque. |
| 3 | Marge de quota | élevée | Le modèle Σ(cpu×max) est le modèle de travail du projet, **non prouvé** ; l'usage réel n'est pas lisible. Le script ne remplace pas le relevé humain. |
| 4 | `--non-interactive` | moyenne | Le CLI peut demander une confirmation (ex. IAM des secrets, ancrage de nettoyage) : en mode non interactif il échoue plutôt que de supposer ; arrêt sûr, mais à anticiper. |
| 5 | Effets distants du déploiement | informative | création de services Cloud Run, job Cloud Scheduler + sujet Pub/Sub pour `retryAccountDeletions`, liaisons IAM d'accès aux secrets des fonctions de garde : à citer dans l'autorisation. |
| 6 | Fonction `Plan` appelée deux fois | faible | recalcule la même chaîne ; sans effet. |
| 7 | `aiConfirmAction` non détectée dans `azia/` | faible | exportée par `index.js` (`exports.aiConfirmAction = azIa.aiConfirmAction`) ; le contrôle d'export passe. |
| 8 | Pas de contrôle des secrets Secret Manager | moyenne | volontaire (pas de commande `gcloud`/`secrets`) ; `functions:secrets:get` (métadonnées) peut être ajouté à l'étape P2 si souhaité. |
| 9 | `-Stage preflight` en réel refusé | faible | volontaire : un déploiement exige une étape précise. |

## 5. Écarts assumés avec `deploy-restaurant-v2-preprod.ps1`

Supprimés : variables spécifiques au pilote (`DELIVERY_PROOFS_ENABLED`, `PARTNER_ORDERS_V2`), vérification des règles/index, étapes `rules`, `indexes`, `functions-proofs`, contrôle du secret de preuve. Ajoutés : confirmation d'étape, projection de quota, contrôle de concurrence et de cpu, contrôle du jeu de fonctions après déploiement, refus des variables d'environnement de projet divergentes. Conservés : identité par id + numéro, liste blanche, `--project` explicite à chaque commande, aucun `--force`, journal.

## 6. Anciens script et correctifs recommandés (non appliqués)

`test-env/deploy-preprod.ps1` n'est **pas modifié**. Correctifs recommandés si ce script est conservé : contrôle de `$LASTEXITCODE` après `firebase deploy`, comparaison de projet sensible à la casse, vérification du numéro 306761725053. La liste blanche de ce script ne couvre pas le périmètre ; ne pas l'étendre.

## 7. Utilisation prévue (après autorisations distinctes)

```powershell
# 1. Simulation (aucune commande distante)
powershell -ExecutionPolicy Bypass -File test-env\deploy-account-deletion-preprod.ps1
# 2. Réel, une étape, après autorisation écrite et commit du périmètre :
powershell -ExecutionPolicy Bypass -File test-env\deploy-account-deletion-preprod.ps1 -Stage functions-deletion -Execute `
  -ConfirmProject az-express-preprod -ConfirmStage functions-deletion -QuotaConfirmedByHuman
# 3. Gardes (P2), seulement après décision sur la marge de quota :
powershell -ExecutionPolicy Bypass -File test-env\deploy-account-deletion-preprod.ps1 -Stage functions-guards -Execute `
  -ConfirmProject az-express-preprod -ConfirmStage functions-guards -QuotaConfirmedByHuman -MinMarginVcpu 0.25
```
*Aucune de ces commandes n'a été lancée.*
