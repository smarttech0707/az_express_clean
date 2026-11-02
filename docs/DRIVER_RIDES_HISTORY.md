# Mes courses (livreur) — tranche 1 (développement local, non déployé)

Écran : `lib/screens/driver/driver_rides_page.dart` (ouvert par le bouton « Mes courses » du tableau de bord livreur).
Logique pure : `driver_rides_logic.dart` — accès Firestore (lecture seule) : `driver_rides_service.dart`.
Tests : `test/screens/driver/driver_rides_test.dart`, `rules-tests/driver-rides-access.rules.test.js`.

## Requêtes (toutes `orders` avec `driverId == <livreur>`, tri `createdAt` décroissant, 20 par page)
| Onglet | Filtre `status` | Mode |
|---|---|---|
| En cours | `in [accepted, picked_up]` | temps réel (`snapshots`) |
| Terminées | `== delivered` | pages (`startAfterDocument`) + tirer pour actualiser |
| Annulées | `== cancelled` | idem ; `cancelReason == no_driver_found` s'affiche « Expirée (aucun livreur) » |
| Toutes | aucun | idem ; `assigned` s'affiche « Proposée » |
| Refusées | aucune requête | message explicatif (voir ci-dessous) |

Index requis : `driverId+createdAt desc` (existait) et **`driverId+status+createdAt desc` (ajouté dans `firestore.indexes.json`, non déployé)**.
La règle de lecture de `orders` n'est pas modifiée : `driverId == uid()` impose elle-même qu'un livreur ne lise que ses courses.

## Refus : pourquoi l'onglet est vide
`functions/driverDecline.js` supprime `driverId` de la commande au refus d'une proposition `assigned` ; un refus de diffusion (`broadcast`)
n'écrit que `excludedDriverIds`. La commande n'est donc plus lisible par le livreur (règle ci-dessus) et aucune donnée fiable n'existe côté
lecture. Les anciens refus ne sont jamais reconstitués. Le suivi serveur (tranche 2 : `driverDecline.js` / `driverRelease.js`, événement lisible
par le livreur) reste à faire. Une expiration automatique n'est jamais présentée comme un refus.

## Gain : règle de fiabilité
Le gain provient uniquement du crédit `earning` du portefeuille du livreur (`livreurs/{id}/wallet_transactions`). Ce journal est
**inscriptible par son propriétaire** (règle existante), donc le crédit n'est retenu que s'il est unique pour la commande ET égal à
`orders.budget` (non modifiable par le livreur), et seulement si `shoppingBudget == 0` (avec achats, le serveur crédite `budget + shoppingBudget` :
gain mêlé à un remboursement d'avance). Sinon « — » (paiement espèces, transfert, ambiguïté…). Rien n'est calculé.
Un gain infalsifiable demande un champ écrit par le serveur sur la commande (à la livraison) : à décider en tranche 2.
