import 'package:az_express/services/places_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('le seuil de recherche partagé reste fixé à trois caractères', () {
    expect(PlacesSearchService.minQueryLength, 3);
  });
}
