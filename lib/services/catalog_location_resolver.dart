import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'maps_proxy_client.dart';
import 'permission_primer.dart';

/// Correction release readiness (SEC-01 / Lot A Phase 4) : `createCatalogOrderFromQuoteCF`
/// (Blanchisserie, Colis, Eau & Boissons) écrivait auparavant `latitude: 0, longitude: 0` —
/// jamais exploitable par le dispatch serveur (`assertValidDispatchPoint` les refuse), donc
/// aucune de ces commandes n'était jamais proposée à un livreur. Ce service résout un point
/// réel AVANT la création de la commande : GPS d'abord (patron déjà utilisé par
/// `boulangerie_order_page.dart::_getGPS`), puis géocodage de l'adresse saisie via le proxy
/// serveur `mapsGeocodeCF` (déjà déployé) si le GPS est refusé/indisponible. Jamais de repli
/// arbitraire sur (0,0) — l'absence de point exploitable est un refus explicite, pas une valeur
/// par défaut silencieuse.
enum CatalogLocationSource { gps, google }

class CatalogLocationResult {
  final double lat;
  final double lng;
  final CatalogLocationSource source;
  const CatalogLocationResult(this.lat, this.lng, this.source);

  /// Nom de source attendu par `createCatalogOrderFromQuoteCF` (`COORDINATE_SOURCES`, catalogQuote.js).
  String get serverSourceName =>
      source == CatalogLocationSource.gps ? 'gps' : 'google';
}

class CatalogLocationResolver {
  CatalogLocationResolver._();

  /// Tente le GPS (avec demande de permission si nécessaire), puis, en cas d'échec,
  /// géocode [address] via le proxy serveur. Retourne `null` si aucun point exploitable
  /// n'a pu être obtenu — l'appelant doit alors bloquer la commande, jamais utiliser (0,0).
  static Future<CatalogLocationResult?> resolve({
    required BuildContext context,
    required String address,
  }) async {
    final gps = await _tryGps(context);
    if (gps != null) return gps;
    if (address.trim().isEmpty) return null;
    return _tryGeocode(address.trim());
  }

  static Future<CatalogLocationResult?> _tryGps(BuildContext context) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await PermissionPrimer.requestLocation(
          context: context.mounted ? context : null,
        );
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      if (pos.latitude == 0 && pos.longitude == 0) return null;
      return CatalogLocationResult(
          pos.latitude, pos.longitude, CatalogLocationSource.gps);
    } catch (_) {
      // Permission refusée, GPS désactivé, délai dépassé... : on bascule sur le géocodage,
      // jamais une position fabriquée.
      return null;
    }
  }

  static Future<CatalogLocationResult?> _tryGeocode(String address) async {
    final result = await MapsProxyClient.call(
      MapsProxyClient.geocode,
      {'address': address},
      timeout: const Duration(seconds: 8),
    );
    if (!result.hasData) return null;
    return pointFromGeocodeData(result.data);
  }

  /// Extraction pure (testable sans réseau) : première coordonnée exploitable de la réponse
  /// `{results: [{lat, lng, formattedAddress}, ...]}` de `mapsGeocodeCF`.
  @visibleForTesting
  static CatalogLocationResult? pointFromGeocodeData(
      Map<String, dynamic>? data) {
    final results = data?['results'];
    if (results is! List) return null;
    for (final item in results) {
      if (item is! Map) continue;
      final lat = item['lat'];
      final lng = item['lng'];
      if (lat is num && lng is num) {
        final la = lat.toDouble(), ln = lng.toDouble();
        if (la == 0 && ln == 0) continue;
        return CatalogLocationResult(la, ln, CatalogLocationSource.google);
      }
    }
    return null;
  }
}
