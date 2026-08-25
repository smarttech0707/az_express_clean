import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import 'geo_cache_store.dart';

const String _mapsKey = MapsConfig.apiKey;

/// Reverse geocoding only. Search/autocomplete lives in PlacesSearchService.
class PlacesService {
  static const _googleBase = 'https://maps.googleapis.com/maps/api';
  static const _nominatimBase = 'https://nominatim.openstreetmap.org';

  static final Map<String, _CachedAddress> _reverseCache = {};
  static const _reverseTtl = Duration(hours: 2);
  static const _reverseCacheStorageKey = 'geo_cache_reverse_v2';
  static Future<void>? _cacheLoadFuture;

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

    if (address == null || address.isEmpty) {
      try {
        final uri = Uri.parse('$_googleBase/geocode/json').replace(
          queryParameters: {
            'latlng': '$lat,$lng',
            'language': 'fr',
            'key': _mapsKey,
          },
        );
        final response =
            await http.get(uri).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final results = data['results'] as List?;
          if (results != null && results.isNotEmpty) {
            address = results.first['formatted_address'] as String?;
            if (address != null && address.isNotEmpty) source = 'google';
          }
        }
      } catch (_) {}
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
