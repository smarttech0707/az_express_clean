import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Charge et met en cache les icônes personnalisées pour les marqueurs de carte.
class DriverMarkerIcon {
  static BitmapDescriptor? _motoIcon;
  static BitmapDescriptor? _clientIcon;
  static BitmapDescriptor? _destIcon;

  /// Icône moto (livreur) — charge depuis assets/motorbike.png
  static Future<BitmapDescriptor> getMotoIcon({double size = 52}) async {
    _motoIcon ??= await _load('assets/motorbike.png', size);
    return _motoIcon!;
  }

  /// Marqueur client (position GPS)
  static BitmapDescriptor getClientIcon() {
    _clientIcon ??=
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
    return _clientIcon!;
  }

  /// Marqueur destination
  static BitmapDescriptor getDestIcon() {
    _destIcon ??=
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
    return _destIcon!;
  }

  /// Marqueur livreur fallback (quand image non disponible)
  static BitmapDescriptor getDriverFallback() =>
      BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);

  static Future<BitmapDescriptor> _load(String asset, double size) async {
    try {
      return await BitmapDescriptor.asset(
        ImageConfiguration(size: Size(size, size)),
        asset,
      );
    } catch (_) {
      return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    }
  }
}

// ── Builder de set de marqueurs ───────────────────────────────────────────────

class MapMarkersBuilder {
  /// Construit l'ensemble complet des marqueurs pour la vue client.
  static Set<Marker> buildForClient({
    required LatLng clientPos,
    LatLng? driverPos,
    LatLng? destination,
    BitmapDescriptor? driverIcon,
    required BitmapDescriptor clientIcon,
    required BitmapDescriptor destIcon,
    String? driverName,
    double driverHeading = 0,
  }) {
    final markers = <Marker>{
      // Marqueur client (bleu)
      Marker(
        markerId: const MarkerId('client'),
        position: clientPos,
        icon: clientIcon,
        infoWindow: const InfoWindow(title: 'Votre position'),
        zIndexInt: 2,
        anchor: const Offset(0.5, 1),
      ),
    };

    // Marqueur destination (rouge)
    if (destination != null) {
      markers.add(Marker(
        markerId: const MarkerId('destination'),
        position: destination,
        icon: destIcon,
        infoWindow: const InfoWindow(title: 'Destination'),
        zIndexInt: 1,
        anchor: const Offset(0.5, 1),
      ));
    }

    // Marqueur livreur (moto) — animé + orienté dans la direction de déplacement
    if (driverPos != null) {
      markers.add(Marker(
        markerId: const MarkerId('driver'),
        position: driverPos,
        icon: driverIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(title: driverName ?? 'Livreur en route'),
        zIndexInt: 3,
        anchor: const Offset(0.5, 0.5),
        flat: true,
        rotation: driverHeading,
      ));
    }

    return markers;
  }

  /// Construit les marqueurs pour la vue livreur.
  static Set<Marker> buildForDriver({
    required LatLng driverPos,
    required LatLng clientPos,
    LatLng? destination,
    BitmapDescriptor? driverIcon,
    required BitmapDescriptor clientIcon,
    required BitmapDescriptor destIcon,
    String? clientName,
    String? clientPhone,
  }) {
    final markers = <Marker>{
      // Le livreur lui-même
      Marker(
        markerId: const MarkerId('driver'),
        position: driverPos,
        icon: driverIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: const InfoWindow(title: 'Vous'),
        zIndexInt: 3,
        flat: true,
        anchor: const Offset(0.5, 0.5),
      ),
      // Position client
      Marker(
        markerId: const MarkerId('client'),
        position: clientPos,
        icon: clientIcon,
        infoWindow: InfoWindow(
            title: clientName ?? 'Client', snippet: clientPhone ?? ''),
        zIndexInt: 2,
        anchor: const Offset(0.5, 1),
      ),
    };

    // Destination finale
    if (destination != null) {
      markers.add(Marker(
        markerId: const MarkerId('destination'),
        position: destination,
        icon: destIcon,
        infoWindow: const InfoWindow(title: 'Destination finale'),
        zIndexInt: 1,
        anchor: const Offset(0.5, 1),
      ));
    }

    return markers;
  }
}
