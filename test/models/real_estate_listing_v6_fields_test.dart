import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/models/real_estate_listing.dart';

// Master Prompt "Immobilier V6" — Mission 9 : verrouille le comportement
// additif exigé par la Mission 2 — "ne jamais casser les anciennes
// annonces". `toMap()` est pur (aucune dépendance Firestore réelle
// nécessaire) : une annonce sans les nouveaux champs ne doit jamais écrire
// de valeur inventée, et les booléens gardent toujours une valeur neutre
// explicite (jamais absents, contrairement aux champs numériques optionnels).
void main() {
  test('toMap() n\'écrit jamais un champ optionnel non renseigné', () {
    const listing = RealEstateListing(
      id: 'l1',
      agentId: 'a1',
      title: 'T',
      description: 'd',
      price: 1000,
      propertyType: 'house',
      city: 'Abengourou',
    );
    final map = listing.toMap();
    expect(map.containsKey('surface'), isFalse);
    expect(map.containsKey('surfaceTerrain'), isFalse);
    expect(map.containsKey('rooms'), isFalse);
    expect(map.containsKey('bedrooms'), isFalse);
    expect(map.containsKey('bathrooms'), isFalse);
    expect(map.containsKey('floor'), isFalse);
    expect(map.containsKey('pricePerDay'), isFalse);
    expect(map.containsKey('pricePerWeek'), isFalse);
    expect(map.containsKey('pricePerMonth'), isFalse);
    expect(map.containsKey('availabilityDate'), isFalse);
    expect(map.containsKey('videos'), isFalse);
    // Les booléens ont toujours une valeur neutre explicite (jamais absents).
    expect(map['hasGarage'], isFalse);
    expect(map['hasParking'], isFalse);
    expect(map['hasPool'], isFalse);
    expect(map['chargesIncluded'], isFalse);
    expect(map['isAvailable'], isTrue);
  });

  test('toMap() inclut chaque champ renseigné avec sa vraie valeur', () {
    const listing = RealEstateListing(
      id: 'l1',
      agentId: 'a1',
      title: 'T',
      description: 'd',
      price: 1000,
      propertyType: 'house',
      city: 'Abengourou',
      surface: 90,
      surfaceTerrain: 300,
      rooms: 4,
      bedrooms: 2,
      bathrooms: 1,
      floor: 2,
      hasGarage: true,
      hasPool: true,
      hasInternet: true,
      pricePerDay: 5000,
      pricePerWeek: 30000,
      pricePerMonth: 100000,
      isAvailable: false,
      videos: ['https://x/vid.mp4'],
    );
    final map = listing.toMap();
    expect(map['surface'], 90);
    expect(map['surfaceTerrain'], 300);
    expect(map['rooms'], 4);
    expect(map['bedrooms'], 2);
    expect(map['bathrooms'], 1);
    expect(map['floor'], 2);
    expect(map['hasGarage'], isTrue);
    expect(map['hasPool'], isTrue);
    expect(map['hasInternet'], isTrue);
    expect(map['pricePerDay'], 5000);
    expect(map['pricePerWeek'], 30000);
    expect(map['pricePerMonth'], 100000);
    expect(map['isAvailable'], isFalse);
    expect(map['videos'], ['https://x/vid.mp4']);
  });

  test(
      'un terrain a des champs de construction sans rapport tous null par défaut',
      () {
    const listing = RealEstateListing(
      id: 'l1',
      agentId: 'a1',
      title: 'Grand terrain',
      description: 'd',
      price: 2000000,
      propertyType: 'land',
      city: 'Abengourou',
      surfaceTerrain: 1200,
    );
    expect(listing.surfaceTerrain, 1200);
    expect(listing.rooms, isNull);
    expect(listing.bedrooms, isNull);
    expect(listing.surface, isNull);
  });

  test('hasPublicLocation reste indépendant des nouveaux champs V6', () {
    const listing = RealEstateListing(
      id: 'l1',
      agentId: 'a1',
      title: 'T',
      description: 'd',
      price: 1000,
      propertyType: 'house',
      city: 'Abengourou',
      surface: 100,
    );
    expect(listing.hasPublicLocation, isFalse);
  });
}
