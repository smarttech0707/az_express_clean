import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/models/real_estate_property_field_policy.dart';
import 'package:az_express/models/real_estate_property_type.dart';

// Master Prompt "Immobilier V6.2" — Mission 12 : verrouille la politique de
// champs par type (Mission 5) et le nettoyage lors d'un changement de type
// (Mission 6), sur les exemples exacts donnés par la mission — Maison →
// Terrain, Villa → Local commercial.
void main() {
  group('RealEstatePropertyFieldPolicy.allowedFields', () {
    test('terrain : uniquement surfaceTerrain + tarifs universels', () {
      final allowed = RealEstatePropertyFieldPolicy.allowedFields(
          RealEstatePropertyType.land);
      expect(allowed, contains('surfaceTerrain'));
      expect(allowed, isNot(contains('surface')));
      expect(allowed, isNot(contains('rooms')));
      expect(allowed, isNot(contains('hasPool')));
      expect(
          allowed, containsAll(RealEstatePropertyFieldPolicy.universalFields));
    });

    test('local commercial : surface/parking/vitrine, jamais de résidentiel',
        () {
      final allowed = RealEstatePropertyFieldPolicy.allowedFields(
          RealEstatePropertyType.commercial);
      expect(allowed, contains('surface'));
      expect(allowed, contains('hasParking'));
      expect(allowed, contains('hasTerrace')); // vitrine
      expect(allowed, isNot(contains('rooms')));
      expect(allowed, isNot(contains('bedrooms')));
      expect(allowed, isNot(contains('hasPool')));
      expect(allowed, isNot(contains('hasGarage')));
      expect(allowed, isNot(contains('surfaceTerrain')));
    });

    test('résidence meublée et maison ont le même ensemble de champs', () {
      final furnished = RealEstatePropertyFieldPolicy.allowedFields(
          RealEstatePropertyType.furnishedResidence);
      final house = RealEstatePropertyFieldPolicy.allowedFields(
          RealEstatePropertyType.house);
      expect(furnished, house);
    });

    test('reconnaît les anciens libellés français hérités', () {
      expect(
          RealEstatePropertyFieldPolicy.allowedFields('Terrain'),
          RealEstatePropertyFieldPolicy.allowedFields(
              RealEstatePropertyType.land));
      expect(
          RealEstatePropertyFieldPolicy.allowedFields('Local commercial'),
          RealEstatePropertyFieldPolicy.allowedFields(
              RealEstatePropertyType.commercial));
    });
  });

  group('RealEstatePropertyFieldPolicy.cleanupFieldsForTypeChange', () {
    test('Maison → Terrain (exemple exact de la mission)', () {
      final cleanup = RealEstatePropertyFieldPolicy.cleanupFieldsForTypeChange(
          RealEstatePropertyType.land);
      for (final field in [
        'rooms',
        'bedrooms',
        'bathrooms',
        'floor',
        'hasBalcony',
        'hasTerrace',
        'hasPool',
        'hasGarage',
        'hasElevator',
        'hasKitchen',
        'hasAirConditioning',
        'hasInternet',
        'surface',
      ]) {
        expect(cleanup[field], isA<FieldValue>(),
            reason: '$field doit être supprimé pour un terrain');
      }
      // Jamais nettoyé : le seul champ réellement pertinent pour un terrain.
      expect(cleanup.containsKey('surfaceTerrain'), isFalse);
      // Jamais nettoyé : universel, pertinent pour tout type.
      expect(cleanup.containsKey('pricePerDay'), isFalse);
    });

    test('Villa → Local commercial (exemple exact de la mission)', () {
      final cleanup = RealEstatePropertyFieldPolicy.cleanupFieldsForTypeChange(
          RealEstatePropertyType.commercial);
      for (final field in [
        'rooms',
        'bedrooms',
        'bathrooms',
        'floor',
        'hasBalcony',
        'hasPool',
        'hasGarage',
        'hasElevator',
        'surfaceTerrain',
      ]) {
        expect(cleanup[field], isA<FieldValue>(),
            reason: '$field doit être supprimé pour un local commercial');
      }
      // Conservés pour un local commercial.
      expect(cleanup.containsKey('surface'), isFalse);
      expect(cleanup.containsKey('hasParking'), isFalse);
      expect(cleanup.containsKey('hasTerrace'), isFalse);
    });

    test(
        'un changement vers un type résidentiel ne nettoie rien de résidentiel',
        () {
      final cleanup = RealEstatePropertyFieldPolicy.cleanupFieldsForTypeChange(
          RealEstatePropertyType.villa);
      expect(cleanup.containsKey('rooms'), isFalse);
      expect(cleanup.containsKey('hasPool'), isFalse);
      // surfaceTerrain reste autorisé (optionnel) pour le résidentiel.
      expect(cleanup.containsKey('surfaceTerrain'), isFalse);
    });
  });

  group('RealEstatePropertyFieldPolicy.isFieldAllowed', () {
    test('cohérence avec allowedFields', () {
      expect(
          RealEstatePropertyFieldPolicy.isFieldAllowed(
              RealEstatePropertyType.land, 'surfaceTerrain'),
          isTrue);
      expect(
          RealEstatePropertyFieldPolicy.isFieldAllowed(
              RealEstatePropertyType.land, 'hasPool'),
          isFalse);
    });
  });
}
