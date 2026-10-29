---
paths:
  - functions/dispatch.js
  - functions/staleDriverCleanup.js
  - lib/services/driver_location_service.dart
  - lib/services/*tracking*.dart
  - lib/services/google_routes_service.dart
  - lib/services/places*.dart
  - lib/screens/driver/**
  - lib/screens/customer_tracking_screen.dart
  - lib/screens/client/order_tracking_map.dart
---

# Dispatch, GPS, cartographie, preuves de livraison

Références : `docs/claude/INDEX.md` (prompts 26, 27, 77, 129, 130, 135), `docs/DELIVERY_PROOFS_PHASE2.md`, `docs/DELIVERY_PROOFS_PHASE3_SMS.md`.

- Dispatch **serveur uniquement** : `dispatchOrderToDriver` → `functions/dispatch.js`. Filtres : en ligne, non suspendu, non en course, `isAvailable` non faux, GPS < 3 min (`STALE_MINUTES`), wallet ≥ commission. Tri par distance à vol d'oiseau (haversine, choix de coût délibéré), top 5, rayon 2 km puis 5 km. 1 candidat = `assigned`, 2+ = `broadcast`. Écritures en transaction (statut `pending` relu). `acceptOrder()` revérifie suspension / en ligne / en course.
- `DriverLocationService` : throttle 5 s + 15 m, **plus un heartbeat de 90 s** (sinon `updatedAt` vieillit et le serveur exclut le livreur). `resumeIfNeeded()` appelé sur `AppLifecycleState.resumed`. Ne pas retirer.
- `staleDriverCleanupCheck` (toutes les 5 min) remet `isOnline:false` aux livreurs dont le GPS est périmé.
- `createOrder()` ne bloque pas sur le dispatch ; un échec est loggé. `autoExpireOrders` annule et rembourse après 10 min sans livreur.
- Pas de géoclôture ; transitions de statut manuelles du livreur. Photo de livraison + GPS = preuve par défaut. La fondation QR/PIN (`delivery_proofs`, opt-in `deliveryProofMode: 'qr_v1'`, secret `DELIVERY_PROOF_PEPPER`) est décrite dans `docs/DELIVERY_PROOFS_*.md` ; ne pas l'élargir sans décision.
- Google Maps : clé centralisée dans `MapsConfig.apiKey` (restriction côté Google Cloud Console). Directions : cache 100 m / 5 min, throttle 120 s côté suivi, Nominatim en premier. Ne jamais appeler Directions pour tous les livreurs.
- `create_order.dart` calcule l'itinéraire automatiquement (anti-rebond 500 ms) ; la recherche de lieux interroge d'abord la collection `places`.
- Deux services de suivi coexistent (`TrackingService`, `RealtimeTrackingService`) : duplication connue, ne pas en créer un troisième.
