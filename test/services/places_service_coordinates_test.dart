import 'package:az_express/services/places_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('getCoordinates réutilise les coordonnées de la suggestion OSM',
      () async {
    const suggestion = PlaceSuggestion(
      placeId: 'osm_123',
      description: 'Commerce, Abengourou',
      mainText: 'Commerce',
      secondaryText: 'Abengourou',
      latitude: 6.72,
      longitude: -3.49,
      source: 'osm',
    );

    final result = await PlacesSearchService.getCoordinates(
      suggestion.placeId,
      suggestion: suggestion,
    );

    expect(result?.latitude, 6.72);
    expect(result?.longitude, -3.49);
  });
}
