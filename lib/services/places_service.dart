import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../constants/app_constants.dart';

const String _mapsKey = MapsConfig.apiKey;

// ═══════════════════════════════════════════════════════════════════════════
// MODÈLE — Suggestion de lieu
// source : 'google' | 'osm'
// ═══════════════════════════════════════════════════════════════════════════
class PlaceSuggestion {
  final String  placeId;
  final String  description;
  final String  mainText;
  final String  secondaryText;
  // Coordonnées directes (Nominatim les fournit sans second appel)
  final double? latitude;
  final double? longitude;
  final String  source; // 'google' | 'osm'

  const PlaceSuggestion({
    required this.placeId,
    required this.description,
    required this.mainText,
    required this.secondaryText,
    this.latitude,
    this.longitude,
    this.source = 'google',
  });

  bool get hasCoords => latitude != null && longitude != null;
}

// ═══════════════════════════════════════════════════════════════════════════
// SERVICE — Recherche de lieux
// Stratégie : Nominatim/OSM en premier (gratuit), Google en fallback uniquement
// ═══════════════════════════════════════════════════════════════════════════
class PlacesService {
  static const _googleBase    = 'https://maps.googleapis.com/maps/api';
  static const _nominatimBase = 'https://nominatim.openstreetmap.org';

  // Centre et zone d'Abengourou
  static const _lat     = 6.7273;
  static const _lng     = -3.4961;
  static const _viewbox = '-4.2,6.1,-3.0,7.5';

  // ── Cache autocomplete (requête → résultats, TTL 10 min) ─────────────────
  static final Map<String, _CachedSuggestions> _autocompleteCache = {};
  static const _autocompleteTtl = Duration(minutes: 10);

  // ── Cache reverse geocode (clé position → adresse, TTL 2h) ───────────────
  // Clé arrondie à 3 décimales ≈ 111m → évite les doublons pour positions proches
  static final Map<String, _CachedAddress> _reverseCache = {};
  static const _reverseTtl = Duration(hours: 2);

  // ═══════════════════════════════════════════════════════════════════════
  // AUTOCOMPLETE — Nominatim d'abord, Google en fallback si < 3 résultats
  // ═══════════════════════════════════════════════════════════════════════
  static Future<List<PlaceSuggestion>> autocomplete(String input) async {
    final q = input.trim();
    if (q.length < 3) return [];

    // Vérifier le cache
    final cacheKey = q.toLowerCase();
    final cached = _autocompleteCache[cacheKey];
    if (cached != null && !cached.isExpired(_autocompleteTtl)) {
      return cached.suggestions;
    }

    // 1. Nominatim (gratuit) en priorité
    final nominatim = await _nominatimSearch(q);

    List<PlaceSuggestion> result;

    if (nominatim.length >= 3) {
      // Résultats suffisants — pas d'appel Google
      result = nominatim.take(7).toList();
    } else {
      // Fallback Google si OSM insuffisant
      final google = await _googleAutocomplete(q);

      final seen   = <String>{};
      final merged = <PlaceSuggestion>[];
      for (final s in [...nominatim, ...google]) {
        final key = s.mainText.toLowerCase().trim();
        if (seen.add(key)) merged.add(s);
      }
      result = merged.take(7).toList();
    }

    // Mettre en cache
    _autocompleteCache[cacheKey] = _CachedSuggestions(result);
    if (_autocompleteCache.length > 100) {
      _autocompleteCache.removeWhere(
          (_, v) => v.isExpired(_autocompleteTtl));
    }

    return result;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MOTEUR 1 — Nominatim / OpenStreetMap (gratuit, couverture locale)
  // ═══════════════════════════════════════════════════════════════════════
  static Future<List<PlaceSuggestion>> _nominatimSearch(String input) async {
    try {
      final query = _addContext(input);

      final uri = Uri.parse('$_nominatimBase/search').replace(
        queryParameters: {
          'q':                query,
          'format':           'json',
          'addressdetails':   '1',
          'countrycodes':     'ci',
          'viewbox':          _viewbox,
          'bounded':          '0',
          'limit':            '6',
          'accept-language':  'fr',
        },
      );

      final resp = await http.get(uri, headers: {
        'User-Agent': 'AZExpress/1.0 (livraison.abengourou@azexpress.ci)',
        'Accept-Language': 'fr',
      }).timeout(const Duration(seconds: 5));

      if (resp.statusCode != 200) return [];

      final list = jsonDecode(resp.body) as List? ?? [];
      return list.map((item) {
        final name    = item['name']         as String? ?? '';
        final display = item['display_name'] as String? ?? '';
        final lat     = double.tryParse(item['lat'] as String? ?? '') ?? 0;
        final lon     = double.tryParse(item['lon'] as String? ?? '') ?? 0;
        final address = item['address'] as Map<String, dynamic>? ?? {};

        final parts = <String>[
          if (address['suburb']  != null) address['suburb']  as String,
          if (address['city']    != null) address['city']    as String
          else if (address['town']    != null) address['town']    as String
          else if (address['village'] != null) address['village'] as String,
          if (address['country'] != null) address['country'] as String,
        ].where((s) => s.isNotEmpty).toList();

        final main      = name.isNotEmpty ? name : display.split(',').first.trim();
        final secondary = parts.join(', ').isNotEmpty ? parts.join(', ') : display;

        return PlaceSuggestion(
          placeId:       'osm_${item["osm_id"] ?? display.hashCode}',
          description:   display,
          mainText:      main,
          secondaryText: secondary,
          latitude:      lat != 0 ? lat : null,
          longitude:     lon != 0 ? lon : null,
          source:        'osm',
        );
      }).where((s) => s.mainText.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MOTEUR 2 — Google Places Autocomplete (fallback uniquement)
  // ═══════════════════════════════════════════════════════════════════════
  static Future<List<PlaceSuggestion>> _googleAutocomplete(String input) async {
    try {
      final query = _addContext(input);

      final uri = Uri.parse('$_googleBase/place/autocomplete/json').replace(
        queryParameters: {
          'input':      query,
          'location':   '$_lat,$_lng',
          'radius':     '100000',
          'components': 'country:ci',
          'language':   'fr',
          'types':      'geocode|establishment',
          'key':        _mapsKey,
        },
      );

      final resp = await http.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return [];

      final data        = jsonDecode(resp.body) as Map<String, dynamic>;
      final predictions = data['predictions'] as List? ?? [];

      return predictions.map((p) {
        final sf = p['structured_formatting'] as Map? ?? {};
        return PlaceSuggestion(
          placeId:       p['place_id'] as String? ?? '',
          description:   p['description'] as String? ?? '',
          mainText:      sf['main_text'] as String? ?? p['description'] as String? ?? '',
          secondaryText: sf['secondary_text'] as String? ?? '',
          source:        'google',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // OBTENIR COORDONNÉES
  // ═══════════════════════════════════════════════════════════════════════

  /// Si la suggestion vient d'OSM, les coordonnées sont déjà disponibles.
  /// Sinon, appel Place Details (Google).
  static Future<LatLng?> getCoordinates(String placeId, {
    PlaceSuggestion? suggestion,
  }) async {
    // Coordonnées directes depuis OSM
    if (suggestion != null && suggestion.hasCoords) {
      return LatLng(suggestion.latitude!, suggestion.longitude!);
    }

    // Géocodage via Google Place Details
    if (!placeId.startsWith('osm_')) {
      return _googlePlaceDetails(placeId);
    }

    // Fallback : géocodage texte via Google
    if (suggestion != null) {
      return geocode(suggestion.description);
    }
    return null;
  }

  static Future<LatLng?> _googlePlaceDetails(String placeId) async {
    try {
      final uri = Uri.parse('$_googleBase/place/details/json').replace(
        queryParameters: {
          'place_id': placeId,
          'fields':   'geometry',
          'key':      _mapsKey,
        },
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;

      final data     = jsonDecode(resp.body) as Map<String, dynamic>;
      final result   = data['result']   as Map<String, dynamic>?;
      final geometry = result?['geometry'] as Map<String, dynamic>?;
      final location = geometry?['location'] as Map<String, dynamic>?;
      if (location == null) return null;

      return LatLng(
        (location['lat'] as num).toDouble(),
        (location['lng'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // GÉOCODAGE INVERSE : coordonnées → adresse
  // Stratégie : Nominatim d'abord (gratuit), Google en fallback
  // Cache en mémoire par position (arrondie à 3 décimales ≈ 111m)
  // ═══════════════════════════════════════════════════════════════════════
  static Future<String?> reverseGeocode(double lat, double lng) async {
    final cacheKey = '${lat.toStringAsFixed(3)}_${lng.toStringAsFixed(3)}';
    final cached = _reverseCache[cacheKey];
    if (cached != null && !cached.isExpired(_reverseTtl)) {
      return cached.address;
    }

    String? address;

    // 1. Nominatim (gratuit)
    try {
      final uri = Uri.parse('$_nominatimBase/reverse').replace(
        queryParameters: {
          'lat':             '$lat',
          'lon':             '$lng',
          'format':          'json',
          'accept-language': 'fr',
        },
      );
      final resp = await http.get(uri, headers: {
        'User-Agent': 'AZExpress/1.0',
      }).timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        address = data['display_name'] as String?;
      }
    } catch (_) {}

    // 2. Fallback Google si Nominatim échoue
    if (address == null || address.isEmpty) {
      try {
        final uri = Uri.parse('$_googleBase/geocode/json').replace(
          queryParameters: {
            'latlng':   '$lat,$lng',
            'language': 'fr',
            'key':      _mapsKey,
          },
        );
        final resp = await http.get(uri).timeout(const Duration(seconds: 5));
        if (resp.statusCode == 200) {
          final data    = jsonDecode(resp.body) as Map<String, dynamic>;
          final results = data['results'] as List?;
          if (results != null && results.isNotEmpty) {
            address = results.first['formatted_address'] as String?;
          }
        }
      } catch (_) {}
    }

    if (address != null && address.isNotEmpty) {
      _reverseCache[cacheKey] = _CachedAddress(address);
      if (_reverseCache.length > 200) {
        _reverseCache.removeWhere((_, v) => v.isExpired(_reverseTtl));
      }
    }

    return address;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // GÉOCODAGE DIRECT : texte → coordonnées
  // ═══════════════════════════════════════════════════════════════════════
  static Future<LatLng?> geocode(String address) async {
    try {
      final uri = Uri.parse('$_googleBase/geocode/json').replace(
        queryParameters: {
          'address':  '$address, Abengourou, Côte d\'Ivoire',
          'language': 'fr',
          'key':      _mapsKey,
        },
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;

      final data    = jsonDecode(resp.body) as Map<String, dynamic>;
      final results = data['results'] as List?;
      if (results == null || results.isEmpty) return null;

      final loc = results.first['geometry']['location'] as Map<String, dynamic>;
      return LatLng(
        (loc['lat'] as num).toDouble(),
        (loc['lng'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  // ── Helper : enrichit la requête si pas de contexte géographique ──────────
  static String _addContext(String input) {
    const geoKeywords = [
      'abengourou', 'côte', 'ivoire', 'bondoukou', 'agnibilekrou',
    ];
    final lower = input.toLowerCase();
    for (final kw in geoKeywords) {
      if (lower.contains(kw)) return input;
    }
    return '$input, Abengourou';
  }
}

// ── Entrées de cache internes ──────────────────────────────────────────────

class _CachedSuggestions {
  final List<PlaceSuggestion> suggestions;
  final DateTime createdAt;
  _CachedSuggestions(this.suggestions) : createdAt = DateTime.now();
  bool isExpired(Duration ttl) => DateTime.now().difference(createdAt) > ttl;
}

class _CachedAddress {
  final String   address;
  final DateTime createdAt;
  _CachedAddress(this.address) : createdAt = DateTime.now();
  bool isExpired(Duration ttl) => DateTime.now().difference(createdAt) > ttl;
}
