# Mission 7E-70 — Plan de retour arrière en préproduction (suppression de compte)

Date : 2026-11-06 · Projet `az-express-preprod` uniquement. **Aucun retour arrière n'a été lancé.** Chaque action ci-dessous est **[AUTORISATION]** distincte et ne concerne jamais la production. Contexte : `ACCOUNT_DELETION_7E70_PREPROD_DEPLOYMENT_PLAN.md`.

## 1. Principe

Les 4 fonctions de suppression (P1) et les 4 fonctions de garde (P2) sont **nouvelles** en préproduction : l'état précédent est **leur absence**. Les 20 fonctions existantes (pilote Restaurant v2), les règles Firestore/Storage et les 93 index ne sont **pas modifiés** par le plan : leur retour arrière est sans objet tant que les photographies « avant » confirment qu'ils n'ont pas bougé. Le moyen le plus rapide et le plus sûr d'arrêter la suppression de compte est la **fermeture de la configuration**, pas la suppression de code.

## 2. Versions précédentes à conserver (relevé du 2026-11-06, lecture)

| Élément | État actuel à conserver |
|---|---|
| 20 fonctions `ACTIVE` `nodejs22` `europe-west1` | `acceptOrderCF`, `adminConfirmDeliveryCF`, `adminOrderDisputeCF`, `autoExpireOrders`, `cancelOrderCF`, `confirmOrderDeliveryWithProof`, `confirmOrderPickupWithProof`, `createOrderFromQuoteCF`, `createPartnerOrderFromQuoteCF`, `deliverOrderCF`, `dispatchOrderToDriver`, `notifyClientOnOrderUpdate`, `notifyDriversOnNewOrder`, `notifyRestaurantOnOrder`, `partnerOrderActionCF`, `prepareOrderProof`, `quoteDeliveryCF`, `quotePartnerOrderCF`, `releaseOrderBeforePickupCF`, `syncDriverOrderLifecycle` (cpu/max : voir rapport §4, Σ 17,5) |
| Règles Firestore | release `cloud.firestore`, publiée 2026-11-05 17:56 UTC, hash `aa2310a88e99` |
| Règles Storage | release `firebase.storage/az-express-preprod.firebasestorage.app`, publiée 2026-11-05 18:02 UTC |
| Index | 93 |
| Secrets | `ANTHROPIC_API_KEY` v1, `DELIVERY_PROOF_PEPPER` v1, `FEEXPAY_TOKEN` v1, `FEEXPAY_WEBHOOK_SECRET` v2 (v1 désactivée), `GEMINI_API_KEY` v1 |
| `operations_control/account_deletion` | **absent** (404) ; `account_tombstones`, `account_deletions` : vides |

Avant chaque phase, enregistrer ces mêmes données dans `test-env/runtime/avant_<phase>.*` (dossier ignoré par Git) pour comparer après.

## 3. Niveaux de retour arrière (du plus léger au plus lourd)

### N1 — Fermer la suppression de compte (immédiat, réversible)

Action : en préproduction, mettre `operations_control/account_deletion.enabled = false` (ou supprimer le document).
Effet (testé en local) : le moteur est fermé par défaut ; chaque passage remet les dossiers à `pending` / `server_rollout_not_enabled` et replanifie à +60 min. **Aucune nouvelle quarantaine ni suppression Auth.**
Limites : les dossiers déjà en `quarantined` conservent leur tombstone et leur profil `isSuspended:true` (voir §4) ; un compte dont l'Auth est déjà supprimé (`authDeleted:true`) n'est **pas** restaurable.

### N2 — Retirer les fonctions déployées (P2 puis P1)

Les fonctions n'ayant pas d'état précédent, le retour arrière = suppression de la fonction dans `az-express-preprod` :
```powershell
# Exemple (NON exécuté). Confirmation interactive requise ; ne JAMAIS utiliser --force.
firebase functions:delete feexPayWebhook --region europe-west1 --project az-express-preprod
```
Ordre : gardes (`feexPayWebhook`, `initiateFeexPayPayment`, `initiateWithdrawal`, `aiConfirmAction`) puis suppression (`manageAccountDeletionCF`, `retryAccountDeletions`, `getAccountDeletionStatusCF`, `requestAccountDeletionCF`). Après N2 les dossiers existants cessent d'être traités (plus de scheduler) : traiter §4 avant.
Contrôle : `firebase functions:list --project az-express-preprod --json` → seulement les 20 d'origine ; `gcloud run services list` ; vérifier (lecture) que le job Cloud Scheduler et le sujet Pub/Sub de `retryAccountDeletions` ont disparu (sinon nettoyage manuel autorisé séparément).
Alternative sans suppression : redéployer l'ancienne révision n'a pas de sens ici (aucune révision antérieure).

### N3 — Règles / index / Storage

Non modifiés par le plan → aucun retour arrière. Si, malgré tout, un déploiement de règles a eu lieu (non prévu) : republier le ruleset archivé (release et hash du §2) puis comparer le hash (GET `firebaserules`).

### N4 — Données synthétiques

Suppression manuelle des documents `t7e-del-*` et des utilisateurs Auth correspondants par un exploitant préproduction autorisé, après décision (pas d'automatisme, pas de `--force`). Les 5 comptes `t7e-*` existants et les deux livreurs non `t7e-` ne sont jamais concernés.

## 4. Risques sur les dossiers de suppression déjà créés

| État du dossier à l'arrêt | Risque | Traitement |
|---|---|---|
| `pending` / `server_rollout_not_enabled`, `reauthentication_required`, `blocked` | aucun effet sur le compte | rien à faire ; supprimer le dossier de test si besoin |
| `quarantined` (tombstone + `isSuspended:true`, `isOnline:false`, `isAvailable:false`) | **le compte reste suspendu** et le tombstone refuse toute nouvelle opération financière (`Compte supprime ou en cours de suppression`) ; le tombstone **n'expire pas** | décision humaine par compte synthétique : soit laisser aller jusqu'au bout (N1 fermé = pas de reprise), soit lever manuellement : supprimer `account_tombstones/{uid}`, remettre `isSuspended:false` (le champ `isOnline/isAvailable` est rétabli par l'utilisateur), et décider du sort du dossier (aucun état « annulé » n'existe dans le moteur : ne pas en inventer sans plan dédié). Le support ordinaire **ne peut pas** finaliser ni annuler : action d'exploitant autorisé. |
| `cleanup_pending` / `authDeleted:true` | **irréversible** : l'utilisateur Auth n'existe plus ; données personnelles partiellement effacées | compte synthétique : le traiter comme perdu ; si une reprise est voulue, rouvrir N1 temporairement (config ouverte) pour laisser le moteur finir, puis refermer. Jamais pour un compte réel. |
| `completed` | compte anonymisé ; aucune restauration | conserver comme preuve ; ne pas rejouer |
| `failed` / `max_attempts_reached` | plus de reprise automatique | `manageAccountDeletionCF` (super-admin) `retry` avec motif, ou laisser en l'état |

## 5. Risques sur les opérations financières

- **Retraits** : un `withdrawal_requests` non terminal ou un champ `pendingWithdrawal` bloque la suppression et n'est jamais modifié par le retour arrière. Aucune compensation automatique n'est déclenchée en préproduction (aucun appel réel de paiement).
- **Paiements `held_for_review`** (`needsReview:true`, `credited:false`) : **aucun outil de résolution n'existe**. Après retrait des fonctions, ces documents restent en l'état et bloquent la suppression de l'UID concerné ; nettoyage manuel par l'exploitant préproduction (documenté dans le journal), jamais par crédit manuel du portefeuille.
- **Gardes retirées** (N2) : après suppression de `initiateFeexPayPayment` / `initiateWithdrawal` / `aiConfirmAction` / `feexPayWebhook` du projet, ces opérations n'existent plus du tout en préproduction (elles n'y étaient pas déployées avant). Aucun risque de régression d'une version antérieure.
- **Soldes** : la somme des `wallet` des comptes `t7e-del-*` doit rester égale à l'instantané « avant » (hors opérations volontaires) ; tout écart arrête le retour arrière et déclenche une revue.

## 6. Contrôles après retour arrière

1. `firebase functions:list --project az-express-preprod --json` : retour aux 20 fonctions d'origine, mêmes dates de mise à jour que l'instantané.
2. `operations_control/account_deletion` : absent ou `enabled:false` (GET).
3. `account_tombstones` / `account_deletions` : conformes à la décision §4 (aucun tombstone orphelin sans dossier connu).
4. Règles Firestore/Storage : hash inchangés ; index : 93.
5. Secrets : mêmes versions (métadonnées).
6. Quota : Σ(cpu×max) théorique redevenue 17,5 ; aucune erreur de quota dans les journaux.
7. Invariants financiers : comparaison des instantanés de soldes.
8. **Production inchangée** : `firebase functions:list --project az-express-b0469 --json` (lecture) identique à l'état connu.

## 7. Déclencheurs d'un retour arrière

Erreur de quota au déploiement ; document inattendu dans `account_*` avant P4 ; une des 20 fonctions existantes modifiée ; suppression Auth sur un compte hors `t7e-del-*` ; écart de solde non expliqué ; valeur secrète visible dans un journal ; doute sur le projet ciblé (arrêt, aucune correction tant que la cible n'est pas certaine).

*Procédure seulement : rien exécuté. Attendre une autorisation distincte.*
