import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

/// Résultat d'une tentative de localisation du CLIENT lui-même (jamais celle
/// de l'annonce) — voir Mission 6. Jamais persisté, jamais journalisé,
/// jamais envoyé à l'agent : uniquement gardé en mémoire le temps de
/// calculer une distance ou de lancer un itinéraire.
enum ClientGpsState {
  granted,
  denied,
  deniedForever,
  serviceOff,
  timeout,
  error,
}

class ClientGpsResult {
  final ClientGpsState state;
  final double? latitude;
  final double? longitude;
  const ClientGpsResult(this.state, {this.latitude, this.longitude});

  bool get isGranted => state == ClientGpsState.granted;
}

/// Service centralisé pour l'itinéraire/ouverture Maps/distance du module
/// Immobilier (Mission 7/8 du chantier "Activation UI carte/itinéraire").
///
/// Réutilise exactement le pattern URL déjà éprouvé ailleurs dans l'app
/// (`driver_map.dart:_navigateTo()`/`driver_tracking_screen.dart`, mêmes
/// deux fichiers, même URL Google Maps universelle `api=1`) plutôt que
/// d'inventer un nouveau format — Directions API n'est JAMAIS appelée ici :
/// c'est une distance à vol d'oiseau + un lien externe, pas un calcul
/// d'itinéraire facturé côté serveur (voir Mission 7 : "ne pas appeler
/// Google Routes pour une simple distance à vol d'oiseau").
class MapNavigationService {
  const MapNavigationService._();

  // ── Validation ─────────────────────────────────────────────────────────

  /// Même garde-fou que `functions/scripts/migrateRealEstateLocations.js`
  /// côté serveur (0,0 rejeté, plage lat/lng valide) — jamais dupliqué à la
  /// légère, mais ici côté client uniquement pour éviter d'ouvrir Maps sur
  /// une coordonnée structurellement invalide.
  static bool isValidCoordinate(double? lat, double? lng) {
    if (lat == null || lng == null) return false;
    if (!lat.isFinite || !lng.isFinite) return false;
    if (lat == 0 && lng == 0) return false;
    return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
  }

  // ── Construction d'URL (pures, testables sans launchUrl) ────────────────

  static Uri buildGoogleMapsViewUri(double lat, double lng) =>
      Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');

  static Uri buildGoogleMapsDirectionsUri(double lat, double lng) => Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving');

  static Uri buildAppleMapsDirectionsUri(double lat, double lng) =>
      Uri.parse('https://maps.apple.com/?daddr=$lat,$lng&dirflg=d');

  static Uri buildWazeUri(double lat, double lng) =>
      Uri.parse('https://waze.com/ul?ll=$lat,$lng&navigate=yes');

  // ── Actions réelles ──────────────────────────────────────────────────────

  /// « Ouvrir dans Maps » — repère statique, jamais l'itinéraire. Ne demande
  /// jamais la position actuelle du client (Mission 9).
  static Future<bool> openInMaps(
      {required double latitude, required double longitude}) async {
    if (!isValidCoordinate(latitude, longitude)) return false;
    return _tryLaunch(buildGoogleMapsViewUri(latitude, longitude));
  }

  /// « Itinéraire » — propose Google Maps / Waze / Apple Maps (iOS) via une
  /// feuille de choix minimale, puis retombe sur le navigateur si aucune
  /// app ne peut être lancée (Mission 8 : "fallback web en dernier recours").
  static Future<bool> navigate(
    BuildContext context, {
    required double latitude,
    required double longitude,
  }) async {
    if (!isValidCoordinate(latitude, longitude)) return false;

    final choice = await _pickNavigationApp(context);
    if (choice == null) return false; // annulé par l'utilisateur

    final uri = switch (choice) {
      _NavApp.googleMaps => buildGoogleMapsDirectionsUri(latitude, longitude),
      _NavApp.waze => buildWazeUri(latitude, longitude),
      _NavApp.appleMaps => buildAppleMapsDirectionsUri(latitude, longitude),
    };

    if (await _tryLaunch(uri)) return true;
    // Repli — l'URL Google Maps universelle fonctionne aussi dans un
    // navigateur classique sans app installée.
    return _tryLaunch(buildGoogleMapsDirectionsUri(latitude, longitude));
  }

  static Future<bool> _tryLaunch(Uri uri) async {
    try {
      if (await canLaunchUrl(uri)) {
        return launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // Application absente / URL non supportée sur la plateforme — géré
      // silencieusement, l'appelant affiche déjà un message d'erreur générique.
    }
    return false;
  }

  static Future<_NavApp?> _pickNavigationApp(BuildContext context) {
    return showModalBottomSheet<_NavApp>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: const Text('Google Maps'),
              onTap: () => Navigator.pop(ctx, _NavApp.googleMaps),
            ),
            ListTile(
              leading: const Icon(Icons.directions_outlined),
              title: const Text('Waze'),
              onTap: () => Navigator.pop(ctx, _NavApp.waze),
            ),
            if (Theme.of(context).platform == TargetPlatform.iOS)
              ListTile(
                leading: const Icon(Icons.map_outlined),
                title: const Text('Plans (Apple Maps)'),
                onTap: () => Navigator.pop(ctx, _NavApp.appleMaps),
              ),
          ],
        ),
      ),
    );
  }

  // ── Position du client (Mission 6) ──────────────────────────────────────
  //
  // Jamais appelé automatiquement à l'affichage de la fiche — uniquement
  // sur action explicite de l'utilisateur (bouton "Calculer la distance"/
  // "Itinéraire"), voir `listing_detail_screen.dart`. Le résultat n'est
  // jamais écrit dans Firestore, jamais envoyé à l'agent, jamais journalisé.
  static Future<ClientGpsResult> requestClientPosition({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return const ClientGpsResult(ClientGpsState.serviceOff);
      }
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        return const ClientGpsResult(ClientGpsState.deniedForever);
      }
      if (perm == LocationPermission.denied) {
        return const ClientGpsResult(ClientGpsState.denied);
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.medium),
      ).timeout(timeout);
      return ClientGpsResult(ClientGpsState.granted,
          latitude: pos.latitude, longitude: pos.longitude);
    } on TimeoutException {
      return const ClientGpsResult(ClientGpsState.timeout);
    } catch (_) {
      return const ClientGpsResult(ClientGpsState.error);
    }
  }

  static Future<bool> openLocationSettings() =>
      Geolocator.openLocationSettings();
  static Future<bool> openAppSettings() => Geolocator.openAppSettings();

  // ── Distance locale (Mission 7) ──────────────────────────────────────────

  /// Distance à vol d'oiseau uniquement — `Geolocator.distanceBetween`,
  /// jamais un appel réseau. Retourne des mètres.
  static double distanceMeters({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) =>
      Geolocator.distanceBetween(fromLat, fromLng, toLat, toLng);

  /// < 1 km : mètres arrondis ("650 m"). ≥ 1 km : kilomètres à une décimale,
  /// virgule française ("2,4 km", "12,0 km").
  static String formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    final km = meters / 1000;
    return '${km.toStringAsFixed(1).replaceAll('.', ',')} km';
  }

  /// Libellé complet — jamais de durée de trajet ici (nécessiterait un vrai
  /// appel Directions, hors périmètre d'une distance à vol d'oiseau).
  static String distanceLabel(
      {required double meters, required bool isApproximate}) {
    final formatted = formatDistance(meters);
    return isApproximate
        ? 'Environ $formatted jusqu\'à la zone indiquée'
        : 'À $formatted de votre position';
  }
}

enum _NavApp { googleMaps, waze, appleMaps }
