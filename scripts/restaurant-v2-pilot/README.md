# Lot de test Restaurant v2 — scripts (Mission 7E-36)

Préparation et nettoyage des comptes et documents **fictifs** des essais Restaurant v2 en préproduction.
**Ne rien exécuter contre le cloud sans autorisation explicite de la mission en cours.** Production (`az-express-b0469`) refusée par le code.

| Fichier | Rôle |
|---|---|
| `lot.js` | Définition pure : 4 identités, documents de départ, montants attendus (modules réels), plan du pilote, inventaire |
| `guard.js` | Refus de la production, contrôle du numéro de projet, confirmations exactes, dossier de sortie hors dépôt |
| `prepare.js` | DRY-RUN par défaut ; `--check-collisions` (lecture) ; `--execute` ; `--refresh-driver-gps` |
| `cleanup.js` | DRY-RUN par défaut (inventaire + empreinte) ; `--execute` seulement avec l'empreinte relue |

Tests : `functions/test/restaurantV2Pilot.test.js` (local) et `restaurantV2Pilot.emulator.test.js` (émulateur Firestore, projet `demo-*`,
rejoue le parcours complet avec les vrais modules de `functions/`).

## Ce que les scripts ne font jamais
- Ils ne créent pas `config/partnerOrdersV2` : l'ouverture du pilote passe par `partnerOrderActionCF` (`lot.pilotConfigPlan()`), avec audit.
- Aucun jeton FCM, téléphone, paiement, SMS ; aucun accès aux secrets ; aucune règle ni fonction modifiée.
- Aucune suppression sur la base du seul préfixe `t7e-`.

## Préparation (mission autorisée seulement)
Prérequis : identifiants Google par défaut (`gcloud auth application-default login`), aucune variable `GCLOUD_PROJECT` contradictoire.

```
# 1. DRY-RUN (hors ligne) : inventaire des ressources prévues
node scripts/restaurant-v2-pilot/prepare.js --project az-express-preprod --project-number 306761725053
# 2. Collisions (lecture seule)
node scripts/restaurant-v2-pilot/prepare.js --project az-express-preprod --project-number 306761725053 --check-collisions
# 3. Création : confirmation exacte + dossier HORS du dépôt (identifiants, manifeste)
node scripts/restaurant-v2-pilot/prepare.js --project az-express-preprod --project-number 306761725053 --execute \
  --out <dossier hors dépôt> --confirm "CREATE t7e-lot-1 az-express-preprod 306761725053"
```
Sortie : `credentials.json` (mots de passe, mode 0600, à ne jamais committer) et `manifest.json` (liste exacte des ressources créées + instantané
des commandes existantes, qui devient la protection du nettoyage). Création tout-ou-rien côté Firestore (`create()` : refus si un document existe).
Avant chaque dispatch : `--refresh-driver-gps --confirm "REFRESH t7e-lot-1 az-express-preprod 306761725053"` (le GPS doit dater de moins de 3 min).

## Nettoyage (mission autorisée seulement)
```
# 1. DRY-RUN (lecture seule) : inventaire exact, conflits, empreinte
node scripts/restaurant-v2-pilot/cleanup.js --project az-express-preprod --project-number 306761725053 --manifest <dossier>/manifest.json
# 2. Relire l'inventaire, puis exécuter avec l'empreinte affichée
node scripts/restaurant-v2-pilot/cleanup.js ... --execute --inventory-hash <empreinte> --confirm "DELETE t7e-lot-1 az-express-preprod 306761725053"
```
Garanties : tout conflit (commande liée à un autre compte, commande non terminée, commande historique du manifeste, jeton FCM sur un document du
lot, écriture de wallet sans commande du lot, pilote désignant d'autres partenaires, compte Auth différent) bloque toute suppression ;
l'inventaire est relu à l'exécution et doit avoir l'empreinte validée ; le pilote est fermé avant toute suppression puis son document supprimé
en dernier ; `audit_logs` et `rate_limits` sont conservés.
