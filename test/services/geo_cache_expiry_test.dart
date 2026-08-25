import 'dart:convert';

import 'package:az_express/services/places_search_service.dart';
import 'package:az_express/services/places_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('la recherche locale ignore une entrée Nominatim expirée', () async {
    SharedPreferences.setMockInitialValues({
      'geo_cache_nominatim_v1': jsonEncode({
        'agnibilekrou|commerce': {
          'createdAt': _expired(minutes: 11),
          'suggestions': [
            {
              'placeId': 'osm_1',
              'description': 'Commerce',
              'mainText': 'Commerce',
              'secondaryText': 'Abengourou',
              'latitude': 6.72,
              'longitude': -3.49,
              'source': 'osm',
            }
          ],
        }
      }),
    });

    await PlacesSearchService.debugReloadCache();

    expect(
      PlacesSearchService.debugHasNominatimCacheKey('agnibilekrou|commerce'),
      isFalse,
    );
  });

  test('Nominatim ignore aussi une autre entrée persistée expirée', () async {
    SharedPreferences.setMockInitialValues({
      'geo_cache_nominatim_v1': jsonEncode({
        'agnibilekrou|commerce': {
          'createdAt': _expired(minutes: 6),
          'results': [
            {
              'name': 'Commerce',
              'category': 'quartier',
              'district': 'Abengourou',
              'address': 'Commerce, Abengourou',
              'latitude': 6.72,
              'longitude': -3.49,
              'keywords': ['commerce'],
              'searchCount': 0,
              'verified': false,
            }
          ],
        }
      }),
    });

    await PlacesSearchService.debugReloadCache();

    expect(
      PlacesSearchService.debugHasNominatimCacheKey('agnibilekrou|commerce'),
      isFalse,
    );
  });

  test('reverse geocoding ignore une entrée persistée expirée', () async {
    SharedPreferences.setMockInitialValues({
      'geo_cache_reverse_v2': jsonEncode({
        '6.720_-3.490': {
          'createdAt': _expired(hours: 3),
          'address': 'Commerce, Abengourou',
          'source': 'nominatim',
        }
      }),
    });

    await PlacesService.debugReloadCaches();

    expect(
      PlacesService.debugHasReverseCacheKey('6.720_-3.490'),
      isFalse,
    );
  });
}

int _expired({int minutes = 0, int hours = 0}) => DateTime.now()
    .subtract(Duration(minutes: minutes, hours: hours))
    .millisecondsSinceEpoch;
