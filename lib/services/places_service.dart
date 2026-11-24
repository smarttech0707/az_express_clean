import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'geo_cache_store.dart';
import 'maps_proxy_client.dart';

/// Reverse geocoding only. Search/autocomplete lives in PlacesSearchService.
/// Lot 1.2.1 — proxy uniquement pour le géocodage Google : plus aucun appel
/// Google direct depuis Flutter (Nominatim, sans clé, reste tenté en premier).
class PlacesService {
  static const _nominatimBase = 'https://nominatim.openstreetmap.org';

  static final Map<String, _CachedAddress> _reverseCache = {};
  static const _reverseTtl = Duration(hours: 2);
  static const _reverseCacheStorageKey = 'geo_cache_reverse_v2';
  static Future<void>? _cacheLoadFuture;

  /// Première adresse non vide de la réponse de `mapsGeocodeCF`, sinon `null`.
  @visibleForTesting
  static String? addressFromProxyData(Map<String, dynamic>? data) {
    final results = data?['results'];
    if (results is! List) return null;
    for (final item in results) {
      if (item is! Map) continue;
      final address = item['formattedAddress'];
      if (address is String && address.trim().isNotEmpty) return address;
    }
    return null;
  }

  static Future<String?> reverseGeocode(double lat, double lng) async {
    await (_cacheLoadFuture ??= _loadReverseCache());
    final cacheKey = '${lat.toStringAsFixed(3)}_${lng.toStringAsFixed(3)}';
    final cached = _reverseCache[cacheKey];
    if (cached != null && !cached.isExpired(_reverseTtl)) {
      return cached.address;
    }

    String? address;
    String? source;

    try {
      final uri = Uri.parse('$_nominatimBase/reverse').replace(
        queryParameters: {
          'lat': '$lat',
          'lon': '$lng',
          'format': 'json',
          'accept-language': 'fr',
        },
      );
      final response = await http.get(uri, headers: {
        'User-Agent': 'AZExpress/1.0',
      }).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        address = data['display_name'] as String?;
        if (address != null && address.isNotEmpty) source = 'nominatim';
      }
    } catch (_) {}

    // Nominatim sans résultat : géocodage inverse par le proxy serveur.
    // Lot 1.2.1 — plus de repli Google direct si le proxy est indisponible
    // ou refusé : `address` reste alors `null`, comportement déjà géré par
    // les appelants (message adapté ou no-op).
    if (address == null || address.isEmpty) {
      final result = await MapsProxyClient.call(
        MapsProxyClient.geocode,
        {'location': MapsProxyClient.point(lat, lng)},
        timeout: const Duration(seconds: 6),
      );
      final proxied =
          result.hasData ? addressFromProxyData(result.data) : null;
      if (proxied != null) {
        address = proxied;
        source = 'google';
      }
    }

    if (address != null && address.isNotEmpty) {
      _reverseCache[cacheKey] = _CachedAddress(address, source: source!);
      if (_reverseCache.length > 200) {
        _reverseCache.removeWhere((_, value) => value.isExpired(_reverseTtl));
      }
      _trimOldest(_reverseCache, 200, (entry) => entry.createdAt);
      await _persistReverseCache();
    }

    return address;
  }

  @visibleForTesting
  static Future<void> debugReloadCaches() async {
    _reverseCache.clear();
    _cacheLoadFuture = _loadReverseCache();
    await _cacheLoadFuture;
  }

  @visibleForTesting
  static bool debugHasReverseCacheKey(String key) =>
      _reverseCache.containsKey(key);

  @visibleForTesting
  static Future<void> debugPersistReverseEntry({
    required String key,
    required String address,
    required String source,
  }) async {
    _reverseCache[key] = _CachedAddress(address, source: source);
    await _persistReverseCache();
  }

  static Future<void> _loadReverseCache() async {
    final stored = await GeoCacheStore.read(_reverseCacheStorageKey);
    for (final entry in stored.entries) {
      try {
        final data = Map<String, dynamic>.from(entry.value as Map);
        final cached = _CachedAddress(
          data['address'] as String,
          source: data['source'] as String,
          createdAt:
              DateTime.fromMillisecondsSinceEpoch(data['createdAt'] as int),
        );
        if (!cached.isExpired(_reverseTtl)) _reverseCache[entry.key] = cached;
      } catch (_) {}
    }
    _trimOldest(_reverseCache, 200, (entry) => entry.createdAt);
  }

  static Future<void> _persistReverseCache() => GeoCacheStore.write(
        _reverseCacheStorageKey,
        Map.fromEntries(
          _reverseCache.entries
              .where((entry) => entry.value.source == 'nominatim')
              .map((entry) => MapEntry(entry.key, {
                    'createdAt': entry.value.createdAt.millisecondsSinceEpoch,
                    'address': entry.value.address,
                    'source': entry.value.source,
                  })),
        ),
      );

  static void _trimOldest<T>(
    Map<String, T> cache,
    int maxEntries,
    DateTime Function(T entry) createdAt,
  ) {
    if (cache.length <= maxEntries) return;
    final oldest = cache.entries.toList()
      ..sort((a, b) => createdAt(a.value).compareTo(createdAt(b.value)));
    for (final entry in oldest.take(cache.length - maxEntries)) {
      cache.remove(entry.key);
    }
  }
}

class _CachedAddress {
  final String address;
  final String source;
  final DateTime createdAt;

  _CachedAddress(this.address, {required this.source, DateTime? createdAt})
      : createdAt = createdAt ?? DateTime.now();

  bool isExpired(Duration ttl) => DateTime.now().difference(createdAt) > ttl;
}
