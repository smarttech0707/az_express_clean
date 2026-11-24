# Mission 7E-69 — Runbook de validation en préproduction (suppression de compte)

Date : 2026-11-06 · Projet cible **unique** : `az-express-preprod` (n° 306761725053, vérifié par `firebase projects:list`, lecture seule). Projet de production `az-express-b0469` : **jamais une cible**.
**Ce document est une procédure. Rien n'a été exécuté, déployé, créé ni activé.** Chaque étape marquée « [AUTORISATION] » exige une autorisation distincte et explicite de l'équipe avant exécution.

## 0. Règles de sécurité communes

1. Toute commande `firebase` porte `--project az-express-preprod`. **Ne jamais** lancer `firebase use`, ni compter sur `default` de `.firebaserc` (= production). Vérifier avant chaque commande : `firebase projects:list` (le projet marqué « current » est la production).
2. Aucun secret de production dans la préproduction ; valeurs factices (`DISABLED`) ou clés de test à plafond bas. Aucun secret affiché ni journalisé.
3. Données exclusivement synthétiques (comptes `t7e-*`, téléphones fictifs, soldes fictifs). Aucun paiement réel : FeexPay reste `DISABLED` ; les paiements sont simulés par écriture directe de documents en préproduction et par appel du webhook avec le vérificateur désactivé/refus attendu (voir §6).
4. `operations_control/account_deletion` n'est créé qu'à l'étape 7, en préproduction seulement, après validation des étapes précédentes. Sa création en **production** est hors périmètre.
5. Arrêt immédiat au moindre doute sur le projet ciblé.

## 1. Préconditions (à vérifier, lecture seule)

| Contrôle | Commande / source | Attendu |
|---|---|---|
| Branche et arbre propres sur le périmètre | `git status --short` | modifications 7E-64/68/69 identifiées ; aucun `.env`/clé versionné |
| Tests locaux | `cd functions && npm test` (2299 tests au 7E-68) | 0 échec |
| Tests de règles | voir `docs/ACCOUNT_DELETION_7E69_VALIDATION_REPORT.md` §4 | 0 échec |
| Isolation | `node test-env/verify-isolation.js --env functions/.env.az-express-preprod --defines test-env/dart-defines.test.json --google-services <chemin>` | code 0 |
| Projet existe | `firebase projects:list` | `az-express-preprod` présent |
| Quota Cloud Run de la préproduction | console GCP du projet préproduction (Quotas : `CpuAllocPerProjectRegion`, `europe-west1`) | **NON CONFIRMÉ à ce jour** (le projet n'a pas été interrogé) ; à relever avant déploiement |
| État de la préproduction | `firebase functions:list --project az-express-preprod --json` | noter les fonctions actives (mémoire du 05/11 : 8 fonctions, Secret Manager désactivé, 2 index manquants) |
| Sauvegarde des règles actuelles | `firebase firestore:...` via console (export du ruleset) ou `curl` GET de l'API Rules (lecture) | ruleset archivé hors dépôt |

## 2. Périmètre à déployer en préproduction

Déploiement **ciblé** (jamais `--only functions` global, jamais `--force`) :

1. **Règles** : `firestore:rules` (fichier `firestore.rules` du dépôt = règles à valider) et `storage` (`storage.rules`). Index : `firestore:indexes` seulement si l'étape 1 révèle des index manquants.
2. **Lot A — financier / IA** : `initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction`, `azIaChat`, `feexPayWebhook`.
3. **Lot B — comptes** : `resetAccountPassword`, `setPharmaciePassword`, `pharmacieLogin`, `setArtisanPin`, `artisanLogin`, `manageProfessionalSubscription`, `createEventReservationCF`.
4. **Lot C — E-Kbine et partenaires** (revue métier, voir rapport §8-9) : `ekClientConfirmOrder`, `ekbineAcceptOrder`, `ekbineAgentDepositAction`, `ekbineSubmitDepositProof`, `ekCreateOrderCF`, `ekCancelOrderCF`, `manageAdminPartnerAccount`. À déployer **ensemble avec les règles locales** (les règles E-Kbine locales exigent la création serveur).
5. **Lot D — suppression** : `requestAccountDeletionCF`, `getAccountDeletionStatusCF`, `retryAccountDeletions`, `manageAccountDeletionCF`.

Ordre : règles → lot A → lot B → lot C → lot D. Le script `test-env/deploy-preprod.ps1` n'autorise qu'une liste blanche de cibles et pour d'autres fonctions il faut **modifier explicitement ce script** [AUTORISATION]. La commande type, après autorisation et modification de la liste blanche :

```powershell
# D'abord à blanc (affiche la commande, n'exécute rien)
powershell -ExecutionPolicy Bypass -File test-env\deploy-preprod.ps1 -Source D:\az_express_clean -GoogleServices <chemin hors dépôt> -Only "functions:initiateFeexPayPayment,functions:initiateWithdrawal,functions:aiConfirmAction,functions:azIaChat,functions:feexPayWebhook"
# Puis, SEULEMENT après autorisation : même commande avec -Execute
```
Avant chaque lot : relever `firebase functions:list --project az-express-preprod --json > avant_lotX.json` (hash et date des révisions) pour le retour arrière.

## 3. Paramètres et secrets de la préproduction

| Élément | Valeur |
|---|---|
| `FEEXPAY_TOKEN`, `FEEXPAY_WEBHOOK_SECRET`, `GEMINI_API_KEY` | `DISABLED` ou valeur factice (`functions:secrets:set … --project az-express-preprod`) |
| `ANTHROPIC_API_KEY` | `DISABLED` (le test AZ IA ne requiert pas d'appel modèle : les actions en attente sont posées directement) |
| `DELIVERY_PROOF_PEPPER` | GUID de test |
| `FEEXPAY_SHOP_ID` | `DISABLED` dans `functions/.env.az-express-preprod` (l'héritage de `functions/.env` doit être surchargé) |
| `operations_control/account_deletion` | **absent** jusqu'à l'étape 7 |
| `GCLOUD_PROJECT` (webhook) | `az-express-preprod` (jamais la production) |

Contrôler (lecture seule) que `FEEXPAY_*` ne contient aucune valeur de production : `node test-env/verify-isolation.js …`.

## 4. Comptes synthétiques

À créer par script de préproduction **[AUTORISATION]** (écriture en préproduction) ; aucun n'est créé par ce document :
`t7e-client-1` (solde 0), `t7e-client-2` (solde 5000), `t7e-livreur-1` (solde 0), `t7e-ek-agent-1`, `t7e-pharmacie-1` (avec `pharmacy_owners`), `t7e-artisan-1`, `t7e-seller-1`, `t7e-restaurant-1`, `t7e-admin-1` (super-administrateur actif, pour D3), `t7e-support-1` (sous-administrateur sans permission de suppression). Un profil par rôle, UID synthétiques, téléphones `+2250700000xxx`.

## 5. Scénarios de test (ordre)

| # | Scénario | Résultat attendu |
|---|---|---|
| S1 | Config absente : `requestAccountDeletionCF` par `t7e-client-1` | dossier `pending`, motif `server_rollout_not_enabled`, aucune quarantaine, Auth intact |
| S2 | Parcours normal avant activation : recharge, retrait, confirmation AZ IA, connexion pharmacie/artisan, E-Kbine | inchangé, aucun blocage |
| S3 | Activation (étape 7) puis demande de `t7e-client-1` (solde 0) | tombstone posé, profil suspendu, état `quarantined` |
| S4 | Pendant la quarantaine : recharge, retrait, confirmation d'une action AZ IA préparée avant, acceptation E-Kbine, changement de mot de passe cible | tous refusés (`ACCOUNT_DELETION_IN_PROGRESS` / « suppression ») ; aucun document créé |
| S5 | Paiement simulé : document `wallet_transactions` pending **créé avant** la quarantaine puis webhook après | crédité, suppression bloquée (`balance_regularization_required`) |
| S6 | Paiement simulé créé **après** le tombstone (écriture directe) puis webhook | `held_for_review`, solde inchangé, security_event et audit présents |
| S7 | `t7e-admin-1` demande sa suppression | refus `ADMIN_ACCOUNT_MANUAL_PROCESS`, aucun dossier |
| S8 | Après 15 min (horloge réelle) : seconde inspection | suppression Auth + anonymisation, ou blocage motivé selon l'état |
| S9 | Compte non concerné (`t7e-client-2`) pendant la quarantaine d'un autre | aucune dégradation, recharge/retrait normaux |
| S10 | Support : `t7e-support-1` appelle `manageAccountDeletionCF` ; `t7e-admin-1` liste, `claim`, `retry` avec motif | sous-admin refusé ; super-admin audité (`support_events`) |
| S11 | Rejeu du même webhook, deux webhooks concurrents | un seul crédit |
| S12 | Quota : relever `functions:list` et la consommation Cloud Run avant/après chaque lot | aucune erreur « total allowable CPU per project per region » |

## 6. Webhook en préproduction (sans API réelle)

FeexPay est `DISABLED` : `createStatusVerifier` ne peut pas confirmer un paiement, donc **le crédit réel est impossible par construction** (fail-closed). Pour S5/S6, les cas sont validés par les tests d'émulateur locaux (`accountQuarantineGuards.test.js`, `accountQuarantineConcurrency.emulator.test.js`) ; en préproduction on vérifie uniquement : réponse `503/400` du webhook sans secret valide, absence de crédit, et le statut `held_for_review` obtenu en forçant le cas par écriture directe du statut dans un document synthétique **[AUTORISATION]**. Ne pas appeler l'API FeexPay réelle.

## 7. Activation de la configuration (préproduction seulement) [AUTORISATION]

Uniquement après S1-S2 verts. Script préparé hors dépôt (ne jamais l'exécuter sans `--project`) :
`operations_control/account_deletion` = `{ enabled: true, inventoryVersion: 1 }` dans **la base de `az-express-preprod`**. `partnerInventoryVersion` reste absent (les partenaires restent en revue manuelle). Vérifier l'ID du projet dans le script avant exécution ; refuser tout ID contenant `b0469` ou `clean`.

## 8. Vérifications après déploiement

1. `firebase functions:list --project az-express-preprod --json` : les fonctions du lot sont `ACTIVE`, région `europe-west1`, révision nouvelle ; les autres inchangées (comparer aux fichiers `avant_lot*.json`).
2. Journaux : `firebase functions:log --project az-express-preprod --only <fonction>` sans erreur de chargement ni de secret manquant.
3. Règles : `firebase deploy --only firestore:rules --dry-run --project az-express-preprod` puis comparaison du ruleset publié avec le fichier du dépôt.
4. Aucun document inattendu dans `account_tombstones` / `account_deletions` (comptes `t7e-*` uniquement).
5. Production inchangée : `firebase functions:list --project az-express-b0469 --json` (lecture) identique à l'état connu (95 fonctions, mêmes révisions).

## 9. Retour arrière (préproduction)

| Situation | Action [AUTORISATION] |
|---|---|
| Mauvais comportement d'un lot | redéployer la révision précédente du lot depuis le dépôt à l'état antérieur, ou `firebase functions:delete <fn> --project az-express-preprod` pour les 4 fonctions de suppression (nouvelles) |
| Suppression de compte à arrêter immédiatement | mettre `operations_control/account_deletion.enabled=false` (ou supprimer le document) en préproduction : le moteur est fermé par défaut (testé) |
| Règles défectueuses | republier le ruleset archivé à l'étape 1 |
| Compte synthétique dans un état bloqué | résolution par `manageAccountDeletionCF` (super-admin synthétique) ou suppression manuelle du document en préproduction |
| Doute sur le projet ciblé | arrêt ; contrôler `firebase projects:list` ; ne rien corriger tant que le projet n'est pas certain |

Aucune opération de retour arrière ne touche la production.

## 10. Critères de passage vers une décision production

Tous les scénarios S1-S12 verts en préproduction, revue métier E-Kbine / partenaires / AZ IA signée, outil de résolution des paiements `held_for_review` conçu (voir rapport §7), quota Cloud Run de la production **confirmé**, validation juridique des durées de conservation. La production n'est pas couverte par ce runbook.
