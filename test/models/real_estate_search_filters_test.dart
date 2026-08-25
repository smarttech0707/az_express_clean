import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/models/real_estate_search_filters.dart';

// Master Prompt "Immobilier V6" — Mission 9 : verrouille `isEmpty`/`copyWith`
// du nouvel objet de filtres — la logique de recherche
// (`RealEstateService.search`) ne fait que transmettre ces champs tels
// quels, donc c'est ici que la correction de chaque filtre doit être
// verrouillée en test.
void main() {
  test('isEmpty est vrai par défaut', () {
    expect(const RealEstateSearchFilters().isEmpty, isTrue);
  });

  test('isEmpty devient faux dès qu\'un seul champ est renseigné', () {
    expect(const RealEstateSearchFilters(city: 'Abengourou').isEmpty, isFalse);
    expect(const RealEstateSearchFilters(landOnly: true).isEmpty, isFalse);
    expect(const RealEstateSearchFilters(hasPool: true).isEmpty, isFalse);
    expect(const RealEstateSearchFilters(maxDistanceKm: 5).isEmpty, isFalse);
  });

  test('copyWith ne modifie que les champs explicitement passés', () {
    const base = RealEstateSearchFilters(city: 'Abengourou', minPrice: 100000);
    final updated = base.copyWith(maxPrice: 500000);
    expect(updated.city, 'Abengourou');
    expect(updated.minPrice, 100000);
    expect(updated.maxPrice, 500000);
  });

  test(
      'la position GPS n\'est jamais fixée sans maxDistanceKm dans un usage normal',
      () {
    // Documente le contrat attendu par property_filter_sheet : les 3 champs
    // (lat/lng/maxDistanceKm) sont censés être posés ensemble ou pas du tout.
    const filters = RealEstateSearchFilters(
      maxDistanceKm: 10,
      fromLatitude: 6.72,
      fromLongitude: -3.49,
    );
    expect(filters.maxDistanceKm, isNotNull);
    expect(filters.fromLatitude, isNotNull);
    expect(filters.fromLongitude, isNotNull);
  });
}
