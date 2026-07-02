import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import '../models/local_place.dart';

const _mapsKey       = MapsConfig.apiKey;
const _googleBase    = 'https://maps.googleapis.com/maps/api';
const _nominatimBase = 'https://nominatim.openstreetmap.org';
// Zone Abengourou (~100 km)
const _nominatimViewbox = '-4.2,6.0,-2.8,7.6';

/// Service de recherche de lieux — 3 sources par priorité :
/// 1. Firestore `places` (local, toujours en premier)
/// 2. Nominatim / OpenStreetMap (gratuit, couverture locale)
/// 3. Google Places API (fallback)
class PlacesSearchService {
  static final _db = FirebaseFirestore.instance;

  // ── Cache Nominatim (requête → résultats, TTL 5 min) ─────────────────────
  static final Map<String, _NominatimCache> _nominatimCache = {};
  static const _nominatimTtl = Duration(minutes: 5);

  // ═══════════════════════════════════════════════════════════════════════
  // RECHERCHE PRINCIPALE
  // ═══════════════════════════════════════════════════════════════════════

  static Future<List<LocalPlace>> search(String query) async {
    final q = LocalPlace.normalize(query.trim());
    if (q.length < 3) return [];

    // 1. Firestore local (prioritaire)
    final local = await _searchFirestore(q);
    if (local.length >= 5) return local.take(7).toList();

    // 2. OSM Nominatim (complète si peu de résultats locaux)
    final osm = await _searchNominatim(query.trim());

    // 3. Google Places (si encore trop peu)
    final combined = [...local, ...osm];
    if (combined.length < 3) {
      final google = await _searchGoogle(query.trim());
      combined.addAll(google);
    }

    // Déduplique par nom normalisé
    final seen   = <String>{};
    final result = <LocalPlace>[];
    for (final p in combined) {
      final key = LocalPlace.normalize(p.name);
      if (seen.add(key)) result.add(p);
    }
    return result.take(8).toList();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MOTEUR 1 — Firestore
  // ═══════════════════════════════════════════════════════════════════════

  static Future<List<LocalPlace>> _searchFirestore(String q) async {
    try {
      final results = <LocalPlace>[];
      final seen    = <String>{};

      // Recherche 1 : préfixe sur `nameSearch` (champ pré-calculé lowercase)
      final snap1 = await _db
          .collection('places')
          .where('nameSearch', isGreaterThanOrEqualTo: q)
          .where('nameSearch', isLessThanOrEqualTo: '$q')
          .limit(10)
          .get();

      for (final doc in snap1.docs) {
        if (seen.add(doc.id)) {
          results.add(LocalPlace.fromMap(doc.id, doc.data()));
        }
      }

      // Recherche 2 : array-contains sur `keywords`
      final snap2 = await _db
          .collection('places')
          .where('keywords', arrayContains: q)
          .limit(6)
          .get();

      for (final doc in snap2.docs) {
        if (seen.add(doc.id)) {
          results.add(LocalPlace.fromMap(doc.id, doc.data()));
        }
      }

      // Tri : lieux vérifiés d'abord, puis par searchCount décroissant
      results.sort((a, b) {
        if (a.verified && !b.verified) return -1;
        if (!a.verified && b.verified) return 1;
        return b.searchCount.compareTo(a.searchCount);
      });

      return results;
    } catch (e) {
      debugPrint('[PlacesSearch] Firestore error: $e');
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MOTEUR 2 — Nominatim / OpenStreetMap
  // ═══════════════════════════════════════════════════════════════════════

  static Future<List<LocalPlace>> _searchNominatim(String query) async {
    // Vérifier le cache avant l'appel réseau
    final cacheKey = query.toLowerCase().trim();
    final cached = _nominatimCache[cacheKey];
    if (cached != null && !cached.isExpired(_nominatimTtl)) {
      return cached.results;
    }

    try {
      final q = query.contains('abengourou') ? query : '$query, Abengourou';
      final uri = Uri.parse('$_nominatimBase/search').replace(
        queryParameters: {
          'q':                q,
          'format':           'json',
          'addressdetails':   '1',
          'countrycodes':     'ci',
          'viewbox':          _nominatimViewbox,
          'bounded':          '0',
          'limit':            '6',
          'accept-language':  'fr',
        },
      );
      final resp = await http.get(uri, headers: {
        'User-Agent': 'AZExpress/1.0',
        'Accept-Language': 'fr',
      }).timeout(const Duration(seconds: 5));

      if (resp.statusCode != 200) return [];
      final list = jsonDecode(resp.body) as List? ?? [];

      final result = list.map((item) {
        final name    = (item['name'] as String?)?.trim() ?? '';
        final display = (item['display_name'] as String?)?.trim() ?? '';
        final lat     = double.tryParse(item['lat'] as String? ?? '') ?? 0;
        final lon     = double.tryParse(item['lon'] as String? ?? '') ?? 0;
        final address = item['address'] as Map<String, dynamic>? ?? {};

        final district = (address['suburb']   as String?) ??
                         (address['city']     as String?) ??
                         (address['town']     as String?) ??
                         (address['village']  as String?) ??
                         'Abengourou';

        final category = _osmCategoryFrom(item['type'] as String? ?? '',
            item['class'] as String? ?? '');

        return LocalPlace.fromExternal(
          name:      name.isNotEmpty ? name : display.split(',').first.trim(),
          address:   display,
          latitude:  lat,
          longitude: lon,
          category:  category,
          district:  district,
          source:    'osm',
        );
      }).where((p) => p.name.isNotEmpty && p.hasCoords).toList();

      // Mettre en cache
      _nominatimCache[cacheKey] = _NominatimCache(result);
      if (_nominatimCache.length > 100) {
        _nominatimCache.removeWhere((_, v) => v.isExpired(_nominatimTtl));
      }
      return result;
    } catch (e) {
      debugPrint('[PlacesSearch] Nominatim error: $e');
      return [];
    }
  }

  static String _osmCategoryFrom(String type, String cls) {
    if (cls == 'amenity') {
      if (type == 'pharmacy')      return 'pharmacie';
      if (type == 'hospital' || type == 'clinic') return 'hopital';
      if (type == 'school')        return 'ecole';
      if (type == 'restaurant' || type == 'cafe') return 'restaurant';
      if (type == 'place_of_worship') return 'mosquee';
      if (type == 'bank')          return 'banque';
      if (type == 'bus_station')   return 'gare';
    }
    if (cls == 'tourism') {
      if (type == 'hotel' || type == 'motel') return 'hotel';
    }
    if (cls == 'shop') return 'marche';
    if (cls == 'highway') return 'carrefour';
    if (cls == 'place')   return 'quartier';
    return 'other';
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MOTEUR 3 — Google Places
  // ═══════════════════════════════════════════════════════════════════════

  static Future<List<LocalPlace>> _searchGoogle(String query) async {
    try {
      final q = query.contains('abengourou') ? query : '$query, Abengourou';
      final uri = Uri.parse('$_googleBase/place/autocomplete/json').replace(
        queryParameters: {
          'input':      q,
          'location':   '6.7273,-3.4961',
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
        final sf       = p['structured_formatting'] as Map? ?? {};
        final name     = sf['main_text'] as String? ?? '';
        final subtitle = sf['secondary_text'] as String? ?? '';
        return LocalPlace.fromExternal(
          name:     name,
          address:  p['description'] as String? ?? name,
          latitude:  0, longitude: 0, // sera résolu si sélectionné
          district: subtitle.split(',').first.trim(),
          source:   'google',
        );
      }).where((p) => p.name.isNotEmpty).toList();
    } catch (e) {
      debugPrint('[PlacesSearch] Google error: $e');
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // RÉSOLUTION COORDONNÉES
  // ═══════════════════════════════════════════════════════════════════════

  /// Résout les coordonnées d'un lieu (si pas encore disponibles).
  static Future<LocalPlace?> resolve(LocalPlace place) async {
    if (place.hasCoords) return place;

    // Géocodage via Google
    try {
      final uri = Uri.parse('$_googleBase/geocode/json').replace(
        queryParameters: {
          'address':  '${place.name}, Abengourou, Côte d\'Ivoire',
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
      final lat = (loc['lat'] as num).toDouble();
      final lng = (loc['lng'] as num).toDouble();

      return LocalPlace(
        id:       place.id,
        name:     place.name,
        category: place.category,
        district: place.district,
        address:  results.first['formatted_address'] as String? ?? place.address,
        latitude: lat, longitude: lng,
        keywords: place.keywords,
        source:   place.source,
      );
    } catch (_) {
      return null;
    }
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
        'updatedAt':   FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  /// Sauvegarde automatiquement un lieu validé dans Firestore.
  /// Si déjà existant → incrémente searchCount.
  static Future<void> autoLearn(LocalPlace place) async {
    if (!place.hasCoords || place.name.isEmpty) return;
    try {
      // Vérifier si ce lieu existe déjà (par nom normalisé + position approximative)
      final norm = LocalPlace.normalize(place.name);
      final snap = await _db
          .collection('places')
          .where('nameSearch', isEqualTo: norm)
          .limit(1)
          .get();

      if (snap.docs.isNotEmpty) {
        // Lieu existant → incrémenter
        await _db.collection('places').doc(snap.docs.first.id).update({
          'searchCount': FieldValue.increment(1),
          'updatedAt':   FieldValue.serverTimestamp(),
        });
      } else {
        // Nouveau lieu → créer
        final now = FieldValue.serverTimestamp();
        await _db.collection('places').add({
          'name':        place.name,
          'nameSearch':  norm,
          'category':    place.category,
          'district':    place.district,
          'address':     place.address,
          'latitude':    place.latitude,
          'longitude':   place.longitude,
          'keywords':    [norm, ...place.name.toLowerCase().split(' ')
              .where((w) => w.length >= 2).map(LocalPlace.normalize)],
          'searchCount': 1,
          'verified':    false,
          'source':      place.source,
          'createdAt':   now,
          'updatedAt':   now,
        });
      }
    } catch (e) {
      debugPrint('[PlacesSearch] autoLearn error: $e');
    }
  }

  /// Met à jour les coordonnées GPS d'un lieu si le chauffeur a une position plus précise.
  static Future<void> updateGPSAccuracy(
      String placeId, double driverLat, double driverLng) async {
    if (placeId.isEmpty) return;
    try {
      final doc = await _db.collection('places').doc(placeId).get();
      if (!doc.exists) return;
      final data     = doc.data()!;
      final savedLat = (data['latitude']  as num?)?.toDouble() ?? 0;
      final savedLng = (data['longitude'] as num?)?.toDouble() ?? 0;

      // Mise à jour si le livreur est très proche (< 30 m) du lieu enregistré
      // et que les coordonnées diffèrent significativement
      final dist = _haversineMeters(savedLat, savedLng, driverLat, driverLng);
      if (dist < 30 && dist > 5) {
        // Le livreur est arrivé précisément → mettre à jour
        await _db.collection('places').doc(placeId).update({
          'latitude':  driverLat,
          'longitude': driverLng,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (_) {}
  }

  static double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * 3.14159 / 180;
    final dLng = (lng2 - lng1) * 3.14159 / 180;
    final a = dLat * dLat + dLng * dLng;
    return r * (a < 0 ? 0 : a < 1 ? a : 1);
  }
}

// ── Cache Nominatim interne ────────────────────────────────────────────────

class _NominatimCache {
  final List<LocalPlace> results;
  final DateTime         createdAt;
  _NominatimCache(this.results) : createdAt = DateTime.now();
  bool isExpired(Duration ttl) => DateTime.now().difference(createdAt) > ttl;
}
