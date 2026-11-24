# Mission 7E-70 — Rapport de préparation du déploiement en préproduction (suppression de compte)

Date : 2026-11-06 · Cible unique : `az-express-preprod` (n° 306761725053) · Production `az-express-b0469` (n° 697217052961) : **jamais ciblée**.
**Mission exclusivement préparatoire.** Aucune fonction, règle, site, secret, document distant ni configuration n'a été déployé, créé, modifié ou supprimé. `operations_control/account_deletion` n'a pas été créé. Aucun commit. Toutes les interrogations distantes ci-dessous sont des **lectures** (GET / `list` / `describe`).
Documents associés : `..._7E70_PREPROD_DEPLOYMENT_PLAN.md`, `..._7E70_PREPROD_TEST_MATRIX.md`, `..._7E70_PREPROD_ROLLBACK_PLAN.md`.

## 1. Verdict

**PRÊT SOUS CONDITIONS** — le dossier de préparation est complet et fondé sur des lectures réelles, mais **aucun déploiement ne peut être autorisé sur sa seule base** :

| # | Condition bloquante | État |
|---|---|---|
| C1 | **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE** (limite lue, usage CPU illisible, voir §4) | ouvert |
| C2 | Le code à déployer n'est **pas commité** (17 fichiers déployables modifiés / non suivis ; HEAD `aa3d1b0` ne contient pas 7E-64/68/69) | ouvert |
| C3 | 4 fonctions de garde (`initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction`, `feexPayWebhook`) n'ont **aucun `maxInstances`** : en préproduction elles revendiqueraient jusqu'à 100 vCPU chacune (quota : 20) | correctif **proposé**, non appliqué |
| C4 | Aucun script ne couvre ces fonctions (liste blanche de `deploy-preprod.ps1` ≠ périmètre) | script **proposé**, non créé |
| C5 | Les scénarios 3 à 22 exigent la création de `operations_control/account_deletion` en préproduction : **autorisation distincte** | ouvert |
| C6 | Le mécanisme de résolution de `held_for_review` n'existe pas (non terminé) | ouvert, hors périmètre de cette mission |

## 2. Projet, outils, environnement (§3 de la mission)

| Contrôle | Résultat |
|---|---|
| Outils locaux | Node **v24.22.1** (runtime déployé et `engines` = **22**) · firebase-tools **15.18.0** · Google Cloud SDK **575.0.1** |
| `.firebaserc` | `default` = **`az-express-b0469` (production)** → jamais utilisé comme source de cible |
| `gcloud config` | `project = az-express-b0469` (**production**), région `europe-west1`, compte `znm0905@gmail.com` → **piège réel** : toute commande `gcloud` sans `--project` viserait la production |
| `firebase projects:list` | `az-express-b0469` (697217052961) et `az-express-preprod` visibles pour ce compte |
| `gcloud projects describe az-express-preprod` | `306761725053`, `ACTIVE` |
| Convention appliquée | `--project az-express-preprod` / `--project=az-express-preprod` sur **chaque** commande ; appels REST avec le projet dans le chemin d'URL **et** l'en-tête `x-goog-user-project`; jeton d'accès jamais affiché |
| Région des fonctions / Cloud Run | `europe-west1` pour les 20 fonctions préproduction (`functions:list`) |
| `firebase.json` | contient aussi une section `hosting` et une section `flutter` (identifiants de **production**, utilisés seulement par FlutterFire) → tout `firebase deploy` sans `--only` déploierait aussi Hosting : **`--only` obligatoire** |

Commandes de lecture exécutées : `firebase projects:list --json` ; `firebase functions:list --project az-express-preprod --json` ; `firebase firestore:indexes --project az-express-preprod` ; `gcloud projects describe / services list --enabled / run services list / alpha quotas info list|describe / alpha quotas preferences list / secrets list / secrets versions list` (toutes avec le projet préproduction) ; GET REST `firestore.googleapis.com` (documents), `firebaserules.googleapis.com` (releases/rulesets), `monitoring.googleapis.com` (séries).
Génération **locale** du manifeste des fonctions avec `GCLOUD_PROJECT=az-express-preprod` (aucun réseau, `.env` non chargé) pour calculer les options effectivement déployées.

## 3. État distant lu (préproduction)

| Élément | Résultat |
|---|---|
| Fonctions déployées | **20**, toutes `ACTIVE`, `nodejs22`, `europe-west1` : pilote Restaurant v2 (`acceptOrderCF`, `deliverOrderCF`, `cancelOrderCF`, `dispatchOrderToDriver`, `syncDriverOrderLifecycle`, `releaseOrderBeforePickupCF`, `quote*`, `create*FromQuoteCF`, `partnerOrderActionCF`, `admin*CF`, `autoExpireOrders`, `prepareOrderProof`, `confirmOrder*WithProof`, 3 `notify*`). **Aucune des 4 fonctions de suppression ni des fonctions de garde n'y est déployée.** (Ma note du 05/11 « 8 fonctions » est obsolète.) |
| Règles Firestore | publiées le 2026-11-05 17:56 UTC ; hash **identique** à `firestore.rules` local ; contiennent `account_tombstones`. **Rien à redéployer.** |
| Règles Storage | publiées le 2026-11-05 18:02 UTC ; contenu **identique** au `storage.rules` local (écart de hash = fins de ligne uniquement, `diff` vide après normalisation). **Rien à redéployer.** |
| Index | 93 distants / 93 locaux ; les deux index utiles à la suppression existent (`ai_pending_actions` status+expiresAt, `wallet_transactions` userId+createdAt). L'information « 2 index manquants » de ma mémoire du 05/11 est **obsolète**. |
| API requises | `cloudscheduler`, `pubsub`, `secretmanager`, `eventarc`, `cloudbuild`, `artifactregistry`, `run` : **activées** (Secret Manager n'est plus désactivé). |
| `operations_control/account_deletion` | **HTTP 404 : absent.** Le système de suppression est donc fermé (fail-closed). |
| `account_tombstones`, `account_deletions` | **0 document.** |
| Données présentes | `clients` : `t7e-client`, `t7e-intrus` + 0 autre · `livreurs` : `t7e-driver` + **2 profils non `t7e-`** (`P67dbF…`, `lPVA5…`) · `admins` : `t7e-admin` · `restaurants` : `t7e-resto` · `orders` : 12 · `wallet_transactions`, `ai_pending_actions`, `ekbine_agents`, `pharmacies`, `sellers` : 0. Les 2 livreurs non `t7e-` et tous les comptes existants (pilote Restaurant v2, fermé en config v4) ne doivent **pas** servir aux tests. |
| Comptes Auth | **Non vérifié** (aucune lecture d'export Auth, qui exposerait des données personnelles). |

## 4. Quotas Cloud Run (§4 de la mission)

Lu avec `gcloud alpha quotas info describe … --project=az-express-preprod` :

| Quota | `europe-west1` |
|---|---|
| `CpuAllocPerProjectRegion` (milli-vCPU) | **20 000 = 20 vCPU** |
| `MemAllocPerProjectRegion` | 42 949 672 960 octets (40 GiB) |
| `ActiveRevisionsPerProject` | 4 000 |
| `ServicesPerProject` | 1 000 |
| Demandes de hausse (`quotas preferences list`) | **aucune** (liste vide) ; aucune demande n'a été envoyée |

Distinctions exigées :
- **Quota CPU disponible (limite)** : 20 vCPU — **confirmé** (lecture API).
- **Quota CPU utilisé (réel)** : **NON LISIBLE**. La métrique `serviceruntime.googleapis.com/quota/allocation/usage` ne renvoie aucune série `run.googleapis.com` (8 séries, toutes `compute`/`eventarc`). Aucun chiffre de consommation n'est inventé.
- **Maximum théorique déployé** : Σ(cpu × maxInstances) des 20 fonctions = **17,5 vCPU** (13 fonctions à cpu 1 / max 1 = 13 ; 7 fonctions à cpu 0,5 dont 2 à max 2 = 4,5 ; `functions:list`). Marge théorique = 2,5 vCPU. C'est le modèle de travail du projet (lié à l'erreur de déploiement « total allowable CPU per project per region » de la production) ; **il n'est pas prouvé** que le quota décompte exactement ainsi.
- **Limites de déploiement** : `InlinedSourceDeploy…`, `SourceUpload…`, `WritePerMinute…` existent ; valeurs non relevées (non déterminantes pour 4-8 fonctions).
- **Quota d'instances** (`InstancesPerProject`) : valeur non exposée par l'API (dimension absente) → **non confirmé**.

Coût du périmètre (calcul du manifeste local, projet=préproduction, avec plafond `maxInstances=1` appliqué là où le code le fait) :

| Lot | Fonctions | Σ(cpu×max) tel que codé | Σ avec max=1 | Total projet (17,5 +) |
|---|---|---|---|---|
| P1 — suppression | 4 (`requestAccountDeletionCF` 0,5 ; `getAccountDeletionStatusCF` 0,25 ; `retryAccountDeletions` 0,25 ; `manageAccountDeletionCF` 0,25) | 1,25 | 1,25 | **18,75 ≤ 20** |
| P2 — gardes | 4 (`initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction`, `feexPayWebhook`) | **400** (aucun `maxInstances`, cpu 1) | 4,0 à cpu 1 / **1,0 à cpu 0,25** | 22,75 ✗ / **19,75 ≤ 20** |
| Lots B + C (7 + 7 fonctions comptes / E-Kbine / partenaires) | 14 | ≈ 319 (3 sans plafond : `ekbineAcceptOrder`, `ekbineAgentDepositAction`, `ekbineSubmitDepositProof`) | 12,5 | ✗ (dépasse 20) |

Conclusion : **QUOTA NON CONFIRMÉ — DÉPLOIEMENT NON AUTORISÉ SUR CETTE BASE.** Même le lot P1 seul (18,75 sur 20) repose sur le modèle théorique. P2 ne tient dans la limite qu'avec un plafonnement préproduction (instances **et** cpu) non encore codé. Lots B et C ne tiennent pas sans libérer de la capacité ou obtenir une décision explicite (hausse de quota, retrait de fonctions du pilote), hors périmètre de cette mission.

## 5. Audit du script `test-env/deploy-preprod.ps1` (§5 de la mission)

Le script **n'a pas été modifié.**

**Points sûrs** : refuse `az-express-b0469` / `az-express-clean` ; n'accepte que `az-express-preprod` ; liste blanche stricte ; `verify-isolation.js` obligatoire (échec = arrêt) ; vérifie que le projet apparaît dans le compte ; `--project` toujours passé ; aucun `--force`, aucun `firebase use` ; simulation par défaut (`-Execute` requis).

**Faiblesses** (par gravité) :
1. **Liste blanche sans rapport avec le périmètre** : elle n'autorise que `firestore:rules/indexes`, `storage` et 4 fonctions de commande déjà déployées. Aucune des 4 fonctions de suppression ni des 4 fonctions de garde n'est autorisée → toute tentative est **refusée** (comportement sûr, mais le script est inutilisable pour cette mission).
2. **Pas de contrôle du plafond `cpu` / `maxInstances`** (le script Restaurant v2 `deploy-restaurant-v2-preprod.ps1` le fait pour `maxInstances`) : les fonctions de garde seraient déployées sans plafond.
3. **Pas d'exigence d'arbre propre / de commit** : déploie ce que contient `$Source`, sans traçabilité du commit. (Restaurant v2 l'exige en mode réel.)
4. **Identité du projet par identifiant seulement** (pas de contrôle du n° 306761725053 ni de `-ConfirmProject`), comparaison insensible à la casse (`-ne`).
5. **Code de sortie de `firebase deploy` non vérifié** : en cas d'échec le script peut terminer comme réussi.
6. **Pas d'étape unique** : un seul appel peut mélanger règles, index, Storage et fonctions ; pas de journal, pas de photographie de l'état avant (`functions:list`).
7. `firebase` appelé via le PATH, version non épinglée ; `ConvertFrom-Json` sur la sortie brute de `projects:list` fragile.
8. Si `$Source` = dépôt, le CLI charge `functions/.env` (contient `FEEXPAY_SHOP_ID` de production et `GEMINI_MODEL`) puis `.env.az-express-preprod` le **surcharge** : valeur `FEEXPAY_SHOP_ID=DISABLED` constatée dans le fichier préproduction (conforme), mais le contrôle n'est vérifié que par `verify-isolation.js`.

Recommandation : **ne pas étendre `deploy-preprod.ps1`** ; créer, après autorisation, un script dédié modelé sur `deploy-restaurant-v2-preprod.ps1` (voir le plan de déploiement, §Patchs proposés). Liste blanche précise proposée :

- **P1 (suppression)** : `requestAccountDeletionCF`, `getAccountDeletionStatusCF`, `retryAccountDeletions`, `manageAccountDeletionCF`
- **P2 (gardes — scénarios 12 à 17)** : `initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction`, `feexPayWebhook`
- **Reporté (hors lot actuel, décision quota préalable)** : `resetAccountPassword`, `setPharmaciePassword`, `pharmacieLogin`, `setArtisanPin`, `artisanLogin`, `manageProfessionalSubscription`, `createEventReservationCF`, `ekClientConfirmOrder`, `ekbineAcceptOrder`, `ekbineAgentDepositAction`, `ekbineSubmitDepositProof`, `ekCreateOrderCF`, `ekCancelOrderCF`, `manageAdminPartnerAccount`, `azIaChat`.
- Règles, index, Storage : **rien à déployer** (identiques).

## 6. Isolation des secrets et configurations (§6 de la mission)

| Contrôle | Résultat |
|---|---|
| Secrets préproduction (Secret Manager, noms et métadonnées seulement) | `ANTHROPIC_API_KEY` v1 enabled · `DELIVERY_PROOF_PEPPER` v1 enabled · `FEEXPAY_TOKEN` v1 enabled · `FEEXPAY_WEBHOOK_SECRET` v2 enabled (v1 disabled) · `GEMINI_API_KEY` v1 enabled ; tous créés le 2026-11-05 |
| Valeurs des secrets | **Jamais lues, affichées ni copiées.** Impossible de prouver sans lecture qu'elles ne sont pas des copies de production ; seul indice : métadonnées propres au projet préproduction. **NON VÉRIFIABLE** → vérification à faire par l'exploitant (valeurs factices `DISABLED` exigées par le runbook). |
| `functions/.env.az-express-preprod` | noms de variables : `DELIVERY_SMS_ENABLED=false`, `DELIVERY_SMS_PROVIDER=none`, `DELIVERY_PROOFS_ENABLED=true`, `FEEXPAY_SHOP_ID=DISABLED` (conforme), `PARTNER_ORDERS_V2=on`, `PILOT_MAX_INSTANCES=1`, `NOTIFICATIONS_SEND=off`, `NOTIFICATIONS_ALLOWED_RECIPIENTS` vide (0 destinataire). **0 occurrence** de `b0469` / `az-express-clean`. |
| `functions/.env` (production) | contient `FEEXPAY_SHOP_ID` et `GEMINI_MODEL` ; gitignoré. Chargé avant le fichier préproduction, qui le surcharge pour `FEEXPAY_SHOP_ID`. Risque résiduel : toute **nouvelle** variable ajoutée plus tard à `.env` serait héritée par la préproduction. |
| Références à la production dans les scripts de préproduction | présentes uniquement comme **listes de refus** (`deploy-preprod.ps1`, `deploy-restaurant-v2-preprod.ps1`, `lib/guards.js`, `README.md`) ; aucune ne désigne la production comme cible. |
| Fichiers secrets/clés | `.env*` ignorés par Git (règles `.gitignore:57-58`). `GoogleService-Info`/`google-services` non requis pour les fonctions. |
| Autorisations IAM des secrets pour les fonctions | **Non vérifié** ; le déploiement de fonctions déclarant des secrets modifie les liaisons IAM (effet distant propre au déploiement, à signaler dans l'autorisation). |

## 7. Configuration de suppression (§9 de la mission)

`operations_control/account_deletion` : **absent (404)** en préproduction ; non créé. Tant qu'il est absent, le moteur est fermé : toute demande reste `pending` / `server_rollout_not_enabled` (comportement testé en local). Les scénarios 3 à 22 exigent `{enabled:true, inventoryVersion:1}` en préproduction : **autorisation distincte** requise (plan de déploiement, phase P4).

## 8. Stratégie de comptes synthétiques (§7 de la mission)

Détail dans la matrice de tests. Principe : préfixe **`t7e-del-`** pour éviter toute collision avec les comptes existants (`t7e-client`, `t7e-intrus`, `t7e-driver`, `t7e-admin`, `t7e-resto`) ; **ne pas réutiliser `t7e-admin`** pour le scénario 6 (si une régression le traitait, le compte du pilote serait détruit) ; deux profils livreurs non `t7e-` à ne jamais toucher. Aucune création distante dans cette mission.

## 9. Corrections proposées, non appliquées

1. Plafond préproduction (`maxInstances`, `cpu`, `concurrency`) pour les 4 fonctions de garde (`index.js`, `azia/index.js`, `pilotCap.js` + tests).
2. Script `test-env/deploy-account-deletion-preprod.ps1` (modèle Restaurant v2).
3. Commit préalable du périmètre 7E-64/68/69 (autorisation distincte).
Détail et extraits : plan de déploiement, §Patchs proposés.

## 10. Bilan

- **Vérifications effectuées** : outils, projets, ciblage, scripts, quotas (limites), fonctions déployées, règles Firestore/Storage (hash), index, API, secrets (métadonnées), configuration de suppression, comptes présents, calcul de coût du périmètre, code de la demande de suppression (limites).
- **Confirmé** : cible exacte ; règles/index/Storage identiques au local ; config de suppression absente ; aucune donnée de suppression ; 20 fonctions Restaurant v2 actives ; secrets présents ; quota CPU limite 20 vCPU ; absence de toute demande de quota.
- **Non confirmé** : usage CPU réel ; quota d'instances ; valeurs des secrets ; comptes Auth ; liaisons IAM des secrets ; comportement du déploiement réel (nouvelles fonctions + Cloud Scheduler) ; tests sous Node 22 (suite exécutée sous Node 24.22.1).
- **Risques ouverts** : quota ; code non commité ; gardes sans plafond ; `held_for_review` sans outil de résolution (items `needsReview` bloquent la suppression, état à nettoyer à la main en préproduction) ; durée des essais réels (quarantaine 15 min, reprises toutes les 15 min) ; piège `gcloud`/`.firebaserc` pointant la production.
- **Fichiers locaux créés** : les 4 documents `docs/ACCOUNT_DELETION_7E70_*`. Aucun autre fichier du dépôt modifié (fichiers temporaires dans le dossier de session hors dépôt).
- **Prochaine étape recommandée** : décision sur C1-C4 (quota / commit / plafonds / script), puis autorisation distincte et séparée pour P1, P2, P4.

*Aucun déploiement, aucune activation, aucun commit, aucune modification distante. Attente d'une autorisation distincte.*
