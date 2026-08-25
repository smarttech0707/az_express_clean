import 'dart:convert';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import '../models/local_place.dart';
import 'active_city_service.dart';
import 'geo_cache_store.dart';

const _mapsKey = MapsConfig.apiKey;
const _googleBase = 'https://maps.googleapis.com/maps/api';
const _nominatimBase = 'https://nominatim.openstreetmap.org';

class PlaceSuggestion {
  final String placeId;
  final String description;
  final String mainText;
  final String secondaryText;
  final double? latitude;
  final double? longitude;
  final String source;

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

enum LocalPlacesQueryKind { prefix, alias }

enum LocalPlacesSearchStatus { resolved, cityUnavailable }

enum PlacesSearchState {
  idle,
  cityUnavailable,
  localResults,
  externalResults,
  awaitingExpansion,
  expanded,
}

enum PlaceLearningStatus {
  created,
  updated,
  skippedInvalidPlace,
  skippedCityUnavailable,
  failed,
}

typedef LocalPlacesQueryExecutor = Future<List<LocalPlace>> Function({
  required String cityId,
  required String query,
  required LocalPlacesQueryKind kind,
});

typedef LearnedPlaceLookup = Future<LocalPlace?> Function({
  required String cityId,
  required String normalizedName,
});

typedef LearnedPlaceWriter = Future<void> Function(
  Map<String, dynamic> data,
);

typedef PopularPlacesQueryExecutor = Future<List<LocalPlace>> Function(
  String cityId,
);

class _LocalSearchOutcome {
  const _LocalSearchOutcome(this.results, {required this.exactMatch});

  final List<LocalPlace> results;
  final bool exactMatch;
}

class _ActiveCityContext {
  const _ActiveCityContext({
    required this.cityId,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.radiusKm,
  });

  final String cityId;
  final String name;
  final double latitude;
  final double longitude;
  final double radiusKm;
}

/// Service de recherche de lieux — 3 sources par priorité :
/// 1. Firestore `places` (local, toujours en premier)
/// 2. Nominatim / OpenStreetMap (gratuit, couverture locale)
/// 3. Google Places API (fallback)
class PlacesSearchService {
  static final _db = FirebaseFirestore.instance;
  static http.Client _httpClient = http.Client();
  static const minQueryLength = 3;
  static final _defaultCityService = ActiveCityService();
  static LocalPlacesSearchStatus _lastLocalSearchStatus =
      LocalPlacesSearchStatus.cityUnavailable;
  static PlacesSearchState _lastSearchState = PlacesSearchState.idle;

  static LocalPlacesSearchStatus get lastLocalSearchStatus =>
      _lastLocalSearchStatus;
  static PlacesSearchState get lastSearchState => _lastSearchState;

  // ── Cache de recherche externe (ville + requête, TTL 5 min) ─────────────
  static final Map<String, _NominatimCache> _nominatimCache = {};
  static const _nominatimTtl = Duration(minutes: 5);
  static const _maxNominatimCacheEntries = 100;
  static const _nominatimCacheStorageKey = 'geo_cache_nominatim_v1';
  static Future<void>? _cacheLoadFuture;

  static ActiveCityService get defaultCityService => _defaultCityService;

  /// Les lieux les plus utilisés de la ville active, sans repli inter-ville.
  static Future<List<LocalPlace>> popularPlaces({
    required ActiveCityService cityService,
    PopularPlacesQueryExecutor? queryExecutor,
  }) async {
    final cityId = await _resolvedCityId(cityService);
    if (cityId == null) return const [];
    if (queryExecutor != null) {
      final places = await queryExecutor(cityId);
      final filtered = places
          .where((place) => place.cityId == cityId && place.verified)
          .toList(growable: false)
        ..sort((left, right) => right.searchCount.compareTo(left.searchCount));
      return filtered.take(8).toList(growable: false);
    }

    final snapshot = await _db
        .collection('places')
        .where('cityId', isEqualTo: cityId)
        .where('verified', isEqualTo: true)
        .orderBy('searchCount', descending: true)
        .limit(8)
        .get();
    return snapshot.docs
        .map((document) => LocalPlace.fromMap(document.id, document.data()))
        .toList(growable: false);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // RECHERCHE PRINCIPALE
  // ═══════════════════════════════════════════════════════════════════════

  static Future<List<LocalPlace>> search(
    String query, {
    ActiveCityService? cityService,
    bool expandSearch = false,
    LocalPlacesQueryExecutor? queryExecutor,
  }) async {
    final q = LocalPlace.normalize(query.trim());
    if (q.length < minQueryLength) {
      _lastSearchState = PlacesSearchState.idle;
      return [];
    }

    final service = cityService ?? _defaultCityService;
    final context = await _activeCityContext(service);
    if (context == null) {
      _lastSearchState = PlacesSearchState.cityUnavailable;
      return [];
    }

    // 1. Firestore local (prioritaire)
    final localOutcome = await _searchFirestore(
      q,
      cityService: service,
      queryExecutor: queryExecutor,
    );
    if (localOutcome == null) {
      _lastSearchState = PlacesSearchState.cityUnavailable;
      return [];
    }
    final local = localOutcome.results;
    if (localOutcome.exactMatch || local.length >= 5) {
      _lastSearchState = PlacesSearchState.localResults;
      return local.take(8).toList();
    }

    final cacheKey = '${context.cityId}|$q';
    await (_cacheLoadFuture ??= _loadCache());
    final cached = _nominatimCache[cacheKey];
    if (cached != null &&
        !cached.isExpired(_nominatimTtl) &&
        cached.results.isNotEmpty) {
      _lastSearchState = PlacesSearchState.externalResults;
      return _mergePlaces(local, cached.results);
    }

    // 2. OSM Nominatim (complète si peu de résultats locaux)
    final osm = await _searchNominatim(query.trim(), context);
    if (osm.isNotEmpty) {
      _lastSearchState = PlacesSearchState.externalResults;
      return _mergePlaces(local, osm);
    }

    if (!expandSearch || q.length < 5) {
      _lastSearchState = PlacesSearchState.awaitingExpansion;
      return local.take(8).toList();
    }

    // 3. Google uniquement après demande explicite d'élargissement.
    final google = await _searchGoogle(query.trim(), context);
    _lastSearchState = PlacesSearchState.expanded;
    return _mergePlaces(local, google);
  }

  static Future<List<PlaceSuggestion>> autocomplete(
    String input, {
    ActiveCityService? cityService,
    bool expandSearch = false,
    LocalPlacesQueryExecutor? queryExecutor,
  }) async {
    final places = await search(
      input,
      cityService: cityService,
      expandSearch: expandSearch,
      queryExecutor: queryExecutor,
    );
    return places.map(_toSuggestion).toList(growable: false);
  }

  static Future<List<PlaceSuggestion>> expandSearch(
    String input, {
    ActiveCityService? cityService,
    LocalPlacesQueryExecutor? queryExecutor,
  }) =>
      autocomplete(
        input,
        cityService: cityService,
        expandSearch: true,
        queryExecutor: queryExecutor,
      );

  static Future<LatLng?> getCoordinates(
    String placeId, {
    PlaceSuggestion? suggestion,
  }) async {
    if (suggestion != null && suggestion.hasCoords) {
      return LatLng(suggestion.latitude!, suggestion.longitude!);
    }
    if (placeId.startsWith('osm_')) {
      return suggestion == null ? null : _geocode(suggestion.description);
    }
    return _googlePlaceDetails(placeId);
  }

  static List<LocalPlace> _mergePlaces(
    List<LocalPlace> local,
    List<LocalPlace> external,
  ) {
    final seen = <String>{};
    final result = <LocalPlace>[];
    for (final place in [...local, ...external]) {
      final key = LocalPlace.normalize(place.name);
      if (seen.add(key)) result.add(place);
    }
    return result.take(8).toList();
  }

  static PlaceSuggestion _toSuggestion(LocalPlace place) => PlaceSuggestion(
        placeId: place.id,
        description: place.address.isEmpty ? place.name : place.address,
        mainText: place.name,
        secondaryText: place.district,
        latitude: place.hasCoords ? place.latitude : null,
        longitude: place.hasCoords ? place.longitude : null,
        source: place.source,
      );

  static Future<_ActiveCityContext?> _activeCityContext(
    ActiveCityService cityService,
  ) async {
    final state = await cityService.initialize();
    if (!cityService.hasUsableActiveCity || state.activeCityId == null) {
      return null;
    }
    for (final city in cityService.activeCities) {
      if (city.cityId == state.activeCityId &&
          city.name != null &&
          city.lat != null &&
          city.lng != null &&
          city.radiusKm != null &&
          city.radiusKm! > 0) {
        return _ActiveCityContext(
          cityId: state.activeCityId!,
          name: city.name!,
          latitude: city.lat!,
          longitude: city.lng!,
          radiusKm: city.radiusKm!,
        );
      }
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MOTEUR 1 — Firestore
  // ═══════════════════════════════════════════════════════════════════════

  static Future<_LocalSearchOutcome?> _searchFirestore(
    String q, {
    required ActiveCityService cityService,
    LocalPlacesQueryExecutor? queryExecutor,
  }) async {
    try {
      final cityId = await _resolvedCityId(cityService);
      if (cityId == null) {
        _lastLocalSearchStatus = LocalPlacesSearchStatus.cityUnavailable;
        return null;
      }
      _lastLocalSearchStatus = LocalPlacesSearchStatus.resolved;

      final results = <LocalPlace>[];
      final seen = <String>{};

      final prefixResults = await _runLocalQuery(
        cityId: cityId,
        query: q,
        kind: LocalPlacesQueryKind.prefix,
        queryExecutor: queryExecutor,
      );
      for (final place in prefixResults) {
        if (seen.add(place.id)) results.add(place);
      }

      var exactMatch = prefixResults.any(
        (place) => place.normalizedName == q,
      );
      if (!exactMatch) {
        final aliasResults = await _runLocalQuery(
          cityId: cityId,
          query: q,
          kind: LocalPlacesQueryKind.alias,
          queryExecutor: queryExecutor,
        );
        for (final place in aliasResults) {
          if (seen.add(place.id)) results.add(place);
        }
        exactMatch = aliasResults.any((place) => place.aliases.contains(q));
      }

      return _LocalSearchOutcome(results, exactMatch: exactMatch);
    } catch (e) {
      debugPrint('[PlacesSearch] Firestore error: $e');
      return const _LocalSearchOutcome([], exactMatch: false);
    }
  }

  static Future<List<LocalPlace>> _runLocalQuery({
    required String cityId,
    required String query,
    required LocalPlacesQueryKind kind,
    LocalPlacesQueryExecutor? queryExecutor,
  }) async {
    if (queryExecutor != null) {
      return queryExecutor(cityId: cityId, query: query, kind: kind);
    }

    if (kind == LocalPlacesQueryKind.prefix) {
      final snapshot = await _db
          .collection('places')
          .where('cityId', isEqualTo: cityId)
          .where('verified', isEqualTo: true)
          .orderBy('normalizedName')
          .startAt([query])
          .endAt(['$query\uf8ff'])
          .limit(8)
          .get();
      return snapshot.docs
          .map((doc) => LocalPlace.fromMap(doc.id, doc.data()))
          .toList(growable: false);
    }

    final snapshot = await _db
        .collection('places')
        .where('cityId', isEqualTo: cityId)
        .where('verified', isEqualTo: true)
        .where('aliases', arrayContains: query)
        .limit(8)
        .get();
    return snapshot.docs
        .map((doc) => LocalPlace.fromMap(doc.id, doc.data()))
        .toList(growable: false);
  }

  static Future<String?> _resolvedCityId(
    ActiveCityService cityService,
  ) async {
    final state = await cityService.initialize();
    if (!cityService.hasUsableActiveCity) return null;
    return state.activeCityId;
  }

  @visibleForTesting
  static Future<List<LocalPlace>> debugSearchLocal(
    String query, {
    required ActiveCityService cityService,
    required LocalPlacesQueryExecutor queryExecutor,
  }) async {
    final q = LocalPlace.normalize(query.trim());
    if (q.length < minQueryLength) return [];
    final outcome = await _searchFirestore(
      q,
      cityService: cityService,
      queryExecutor: queryExecutor,
    );
    return outcome?.results ?? [];
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MOTEUR 2 — Nominatim / OpenStreetMap
  // ═══════════════════════════════════════════════════════════════════════

  static Future<List<LocalPlace>> _searchNominatim(
    String query,
    _ActiveCityContext context,
  ) async {
    try {
      final q = '$query, ${context.name}';
      final viewbox = _viewboxFor(context);
      final uri = Uri.parse('$_nominatimBase/search').replace(
        queryParameters: {
          'q': q,
          'format': 'json',
          'addressdetails': '1',
          'countrycodes': 'ci',
          'viewbox': viewbox,
          'bounded': '1',
          'limit': '6',
          'accept-language': 'fr',
        },
      );
      final resp = await _httpClient.get(uri, headers: {
        'User-Agent': 'AZExpress/1.0',
        'Accept-Language': 'fr',
      }).timeout(const Duration(seconds: 5));

      if (resp.statusCode != 200) return [];
      final list = jsonDecode(resp.body) as List? ?? [];

      final result = list
          .map((item) {
            final name = (item['name'] as String?)?.trim() ?? '';
            final display = (item['display_name'] as String?)?.trim() ?? '';
            final lat = double.tryParse(item['lat'] as String? ?? '') ?? 0;
            final lon = double.tryParse(item['lon'] as String? ?? '') ?? 0;
            final address = item['address'] as Map<String, dynamic>? ?? {};

            final district = (address['suburb'] as String?) ??
                (address['city'] as String?) ??
                (address['town'] as String?) ??
                (address['village'] as String?) ??
                context.name;

            final category = _osmCategoryFrom(
                item['type'] as String? ?? '', item['class'] as String? ?? '');

            return LocalPlace(
              id: 'osm_${item['osm_id'] ?? display.hashCode}',
              name: name.isNotEmpty ? name : display.split(',').first.trim(),
              address: display,
              latitude: lat,
              longitude: lon,
              category: category,
              district: district,
              source: 'osm',
            );
          })
          .where((p) => p.name.isNotEmpty && p.hasCoords)
          .toList();

      // Mettre en cache sous cityId|requête normalisée.
      final cacheKey = '${context.cityId}|${LocalPlace.normalize(query)}';
      _nominatimCache[cacheKey] = _NominatimCache(result);
      if (_nominatimCache.length > _maxNominatimCacheEntries) {
        _nominatimCache.removeWhere((_, v) => v.isExpired(_nominatimTtl));
      }
      _trimCache();
      await _persistCache();
      return result;
    } catch (e) {
      debugPrint('[PlacesSearch] Nominatim error: $e');
      return [];
    }
  }

  static String _osmCategoryFrom(String type, String cls) {
    if (cls == 'amenity') {
      if (type == 'pharmacy') return 'pharmacie';
      if (type == 'hospital' || type == 'clinic') return 'hopital';
      if (type == 'school') return 'ecole';
      if (type == 'restaurant' || type == 'cafe') return 'restaurant';
      if (type == 'place_of_worship') return 'mosquee';
      if (type == 'bank') return 'banque';
      if (type == 'bus_station') return 'gare';
    }
    if (cls == 'tourism') {
      if (type == 'hotel' || type == 'motel') return 'hotel';
    }
    if (cls == 'shop') return 'marche';
    if (cls == 'highway') return 'carrefour';
    if (cls == 'place') return 'quartier';
    return 'other';
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MOTEUR 3 — Google Places
  // ═══════════════════════════════════════════════════════════════════════

  static Future<List<LocalPlace>> _searchGoogle(
    String query,
    _ActiveCityContext context,
  ) async {
    try {
      final q = '$query, ${context.name}, Côte d\'Ivoire';
      final uri = Uri.parse('$_googleBase/place/autocomplete/json').replace(
        queryParameters: {
          'input': q,
          'location': '${context.latitude},${context.longitude}',
          'radius': '${(context.radiusKm * 1000).round()}',
          'components': 'country:ci',
          'language': 'fr',
          'types': 'geocode|establishment',
          'key': _mapsKey,
        },
      );
      final resp =
          await _httpClient.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return [];

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final predictions = data['predictions'] as List? ?? [];

      return predictions
          .map((p) {
            final sf = p['structured_formatting'] as Map? ?? {};
            final name = sf['main_text'] as String? ?? '';
            final subtitle = sf['secondary_text'] as String? ?? '';
            return LocalPlace(
              id: p['place_id'] as String? ?? '',
              name: name,
              address: p['description'] as String? ?? name,
              latitude: 0, longitude: 0, // sera résolu si sélectionné
              category: 'other',
              district: subtitle.split(',').first.trim(),
              source: 'google',
            );
          })
          .where((p) => p.name.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[PlacesSearch] Google error: $e');
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // RÉSOLUTION COORDONNÉES
  // ═══════════════════════════════════════════════════════════════════════

  /// Résout les coordonnées d'un lieu (si pas encore disponibles).
  static Future<LocalPlace?> resolve(
    LocalPlace place, {
    ActiveCityService? cityService,
  }) async {
    if (place.hasCoords) return place;

    // Géocodage via Google
    try {
      final context = await _activeCityContext(
        cityService ?? _defaultCityService,
      );
      if (context == null) return null;
      final uri = Uri.parse('$_googleBase/geocode/json').replace(
        queryParameters: {
          'address': '${place.name}, ${context.name}, Côte d\'Ivoire',
          'language': 'fr',
          'key': _mapsKey,
        },
      );
      final resp =
          await _httpClient.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final results = data['results'] as List?;
      if (results == null || results.isEmpty) return null;

      final loc = results.first['geometry']['location'] as Map<String, dynamic>;
      final lat = (loc['lat'] as num).toDouble();
      final lng = (loc['lng'] as num).toDouble();

      return LocalPlace(
        id: place.id,
        name: place.name,
        category: place.category,
        district: place.district,
        address: results.first['formatted_address'] as String? ?? place.address,
        latitude: lat,
        longitude: lng,
        keywords: place.keywords,
        source: place.source,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<LatLng?> _geocode(String address) async {
    final context = await _activeCityContext(_defaultCityService);
    if (context == null) return null;
    try {
      final uri = Uri.parse('$_googleBase/geocode/json').replace(
        queryParameters: {
          'address': '$address, ${context.name}, Côte d\'Ivoire',
          'language': 'fr',
          'key': _mapsKey,
        },
      );
      final resp =
          await _httpClient.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final results = data['results'] as List?;
      if (results == null || results.isEmpty) return null;
      final location = results.first['geometry']['location'] as Map;
      return LatLng(
        (location['lat'] as num).toDouble(),
        (location['lng'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<LatLng?> _googlePlaceDetails(String placeId) async {
    try {
      final uri = Uri.parse('$_googleBase/place/details/json').replace(
        queryParameters: {
          'place_id': placeId,
          'fields': 'geometry',
          'key': _mapsKey,
        },
      );
      final resp =
          await _httpClient.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final location = (data['result']?['geometry']?['location']) as Map?;
      if (location == null) return null;
      return LatLng(
        (location['lat'] as num).toDouble(),
        (location['lng'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  static String _viewboxFor(_ActiveCityContext context) {
    const degreesPerKm = 1 / 111.0;
    final latDelta = context.radiusKm * degreesPerKm;
    final lngDelta = context.radiusKm /
        (111.0 * math.cos(context.latitude * math.pi / 180).abs());
    return '${context.longitude - lngDelta},${context.latitude - latDelta},'
        '${context.longitude + lngDelta},${context.latitude + latDelta}';
  }

  // ═══════════════════════════════════════════════════════════════════════
  // AUTO-APPRENTISSAGE
  // ═══════════════════════════════════════════════════════════════════════

  /// Appelé quand un lieu est sélectionné : incrémente searchCount.
  static Future<void> incrementSearchCount(String placeId) async {
    if (placeId.isEmpty) return;
    try {
      await _db.collection('places').doc(placeId).update({
        'searchCount': FieldValue.increment(1),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  /// Sauvegarde automatiquement un lieu validé dans Firestore.
  /// Si déjà existant → incrémente searchCount.
  static Future<PlaceLearningStatus> autoLearn(
    LocalPlace place, {
    ActiveCityService? cityService,
    LearnedPlaceLookup? existingPlaceLookup,
    LearnedPlaceWriter? createPlace,
    LearnedPlaceWriter? updatePlace,
  }) async {
    if (!place.hasCoords || place.name.isEmpty) {
      return PlaceLearningStatus.skippedInvalidPlace;
    }
    try {
      final activeCityId = await _resolvedCityId(
        cityService ?? ActiveCityService(),
      );
      if (activeCityId == null) {
        return PlaceLearningStatus.skippedCityUnavailable;
      }

      final norm = LocalPlace.normalize(place.name);
      final existing = existingPlaceLookup == null
          ? await _findLearnedPlace(activeCityId, norm)
          : await existingPlaceLookup(
              cityId: activeCityId,
              normalizedName: norm,
            );

      if (existing != null) {
        // Lieu existant → incrémenter
        final data = {
          'searchCount': FieldValue.increment(1),
          'updatedAt': FieldValue.serverTimestamp(),
        };
        if (updatePlace != null) {
          await updatePlace(data);
        } else {
          await _db.collection('places').doc(existing.id).update(data);
        }
        return PlaceLearningStatus.updated;
      } else {
        // Nouveau lieu → créer
        final now = FieldValue.serverTimestamp();
        final data = <String, dynamic>{
          'name': place.name,
          'nameSearch': norm,
          'normalizedName': norm,
          'cityId': activeCityId,
          'aliases': place.aliases,
          'category': place.category,
          'district': place.district,
          'address': place.address,
          'latitude': place.latitude,
          'longitude': place.longitude,
          'keywords': [
            norm,
            ...place.name
                .toLowerCase()
                .split(' ')
                .where((w) => w.length >= 2)
                .map(LocalPlace.normalize)
          ],
          'searchCount': 1,
          'verified': false,
          'source': place.source,
          'createdAt': now,
          'updatedAt': now,
        };
        if (createPlace != null) {
          await createPlace(data);
        } else {
          await _db.collection('places').add(data);
        }
        return PlaceLearningStatus.created;
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[PlacesSearch] AUTO-LEARN FAILED: $error\n$stackTrace',
      );
      return PlaceLearningStatus.failed;
    }
  }

  static Future<LocalPlace?> _findLearnedPlace(
    String cityId,
    String normalizedName,
  ) async {
    final snapshot = await _db
        .collection('places')
        .where('cityId', isEqualTo: cityId)
        .where('normalizedName', isEqualTo: normalizedName)
        .limit(1)
        .get();
    if (snapshot.docs.isEmpty) return null;
    final document = snapshot.docs.first;
    return LocalPlace.fromMap(document.id, document.data());
  }

  /// Met à jour les coordonnées GPS d'un lieu si le chauffeur a une position plus précise.
  static Future<void> updateGPSAccuracy(
      String placeId, double driverLat, double driverLng) async {
    if (placeId.isEmpty) return;
    try {
      final doc = await _db.collection('places').doc(placeId).get();
      if (!doc.exists) return;
      final data = doc.data()!;
      final savedLat = (data['latitude'] as num?)?.toDouble() ?? 0;
      final savedLng = (data['longitude'] as num?)?.toDouble() ?? 0;

      // Mise à jour si le livreur est très proche (< 30 m) du lieu enregistré
      // et que les coordonnées diffèrent significativement
      final dist = _haversineMeters(savedLat, savedLng, driverLat, driverLng);
      if (dist < 30 && dist > 5) {
        // Le livreur est arrivé précisément → mettre à jour
        await _db.collection('places').doc(placeId).update({
          'latitude': driverLat,
          'longitude': driverLng,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (_) {}
  }

  static double _haversineMeters(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * 3.14159 / 180;
    final dLng = (lng2 - lng1) * 3.14159 / 180;
    final a = dLat * dLat + dLng * dLng;
    return r *
        (a < 0
            ? 0
            : a < 1
                ? a
                : 1);
  }

  static Future<void> _loadCache() async {
    final stored = await GeoCacheStore.read(_nominatimCacheStorageKey);
    for (final entry in stored.entries) {
      try {
        final data = Map<String, dynamic>.from(entry.value as Map);
        final cached = _NominatimCache(
          (data['results'] as List).map((item) {
            final place = Map<String, dynamic>.from(item as Map);
            return LocalPlace(
              id: '',
              name: place['name'] as String,
              category: place['category'] as String,
              district: place['district'] as String,
              address: place['address'] as String,
              latitude: (place['latitude'] as num).toDouble(),
              longitude: (place['longitude'] as num).toDouble(),
              keywords: List<String>.from(place['keywords'] as List),
              searchCount: place['searchCount'] as int,
              verified: place['verified'] as bool,
              source: 'osm',
            );
          }).toList(),
          createdAt:
              DateTime.fromMillisecondsSinceEpoch(data['createdAt'] as int),
        );
        if (!cached.isExpired(_nominatimTtl)) {
          _nominatimCache[entry.key] = cached;
        }
      } catch (_) {}
    }
    _trimCache();
  }

  @visibleForTesting
  static Future<void> debugReloadCache() async {
    _nominatimCache.clear();
    _cacheLoadFuture = _loadCache();
    await _cacheLoadFuture;
  }

  @visibleForTesting
  static void debugSetHttpClient(http.Client client) {
    _httpClient = client;
  }

  @visibleForTesting
  static void debugResetSearchState() {
    _nominatimCache.clear();
    _cacheLoadFuture = null;
    _lastSearchState = PlacesSearchState.idle;
    _httpClient = http.Client();
  }

  @visibleForTesting
  static bool debugHasNominatimCacheKey(String key) =>
      _nominatimCache.containsKey(key);

  static void _trimCache() {
    if (_nominatimCache.length <= _maxNominatimCacheEntries) return;
    final oldest = _nominatimCache.entries.toList()
      ..sort((a, b) => a.value.createdAt.compareTo(b.value.createdAt));
    for (final entry
        in oldest.take(_nominatimCache.length - _maxNominatimCacheEntries)) {
      _nominatimCache.remove(entry.key);
    }
  }

  static Future<void> _persistCache() => GeoCacheStore.write(
        _nominatimCacheStorageKey,
        _nominatimCache.map((key, value) => MapEntry(key, {
              'createdAt': value.createdAt.millisecondsSinceEpoch,
              'results': value.results
                  .map((place) => {
                        'name': place.name,
                        'category': place.category,
                        'district': place.district,
                        'address': place.address,
                        'latitude': place.latitude,
                        'longitude': place.longitude,
                        'keywords': place.keywords,
                        'searchCount': place.searchCount,
                        'verified': place.verified,
                      })
                  .toList(),
            })),
      );
}

// ── Cache Nominatim interne ────────────────────────────────────────────────

class _NominatimCache {
  final List<LocalPlace> results;
  final DateTime createdAt;
  _NominatimCache(this.results, {DateTime? createdAt})
      : createdAt = createdAt ?? DateTime.now();
  bool isExpired(Duration ttl) => DateTime.now().difference(createdAt) > ttl;
}
