# Itinéraire Google : limitation connue (29 octobre 2026)

Diagnostic en lecture seule. Aucune clé, aucun tarif, aucun calcul de distance ni le suivi GPS n'ont été modifiés.

## Constat
- La clé Dart (`lib/constants/maps_key.dart`, `MapsConfig.apiKey`) sert aux appels REST de `google_routes_service.dart`, `places_search_service.dart` et `places_service.dart`.
- Son projet propriétaire n'est pas `az-express-b0469` (aucune des 5 clés de ce projet ne correspond) et n'était pas accessible au diagnostic.
- Essais externes : les API historiques Directions, Geocoding et Places ne sont pas activées pour ce projet ; Static Maps est refusé ; Routes, Places et Geocoding (nouvelles versions) répondent « Requests from this Android client application <empty> are blocked ». La clé est donc restreinte à des applications Android, et le code n'envoie ni `X-Android-Package` ni `X-Android-Cert`.
- Les cartes natives utilisent d'autres clés (Android : `local.properties` → `MAPS_API_KEY` ; iOS : `AppDelegate.swift`), limitées au SDK Maps et à `com.azexpress.app`. Elles ne sont pas concernées.

## Effets réels (tous dégradés sans erreur visible)
| Fonction | Comportement |
|---|---|
| `GoogleRoutesService.getRouteModel` | `_fallback` : ligne droite, distance à vol d'oiseau (haversine), durée estimée |
| `GoogleRoutesService.getPoints` | ligne droite (aucun appelant actuel) |
| Recherche de lieux | Firestore puis Nominatim ; l'élargissement Google renvoie une liste vide |
| Géocodage inverse | Nominatim ; secours Google refusé |
| Suivi GPS des livreurs | `geolocator` + Firestore, sans clé Maps : non affecté |

## Correction ultérieure (non faite, décision requise)
1. Identifier le projet propriétaire de la clé Dart, ou créer une clé dédiée dans un projet maîtrisé.
2. Activer l'API Routes et Places (nouvelles versions) sur ce projet, avec quotas et budget d'alerte.
3. Appeler ces API depuis une Cloud Function (clé serveur restreinte par API), jamais depuis le client, ou envoyer les en-têtes d'application si la clé reste côté client.
4. Ne changer ni `tarif_service.dart` ni `functions/tarifService.js` : le prix ne dépend pas de cet itinéraire.
