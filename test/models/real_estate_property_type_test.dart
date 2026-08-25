import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/models/real_estate_property_type.dart';

// Master Prompt "Immobilier V6" — Mission 9 : verrouille la classification
// par type — canonique ET texte libre hérité (une annonce créée avant cette
// passe utilise encore l'ancien libellé français en dur, jamais un des
// nouveaux identifiants canoniques) — "ne jamais casser les anciennes
// annonces" doit rester vrai après tout refactor futur de ce fichier.
void main() {
  group('RealEstatePropertyType.isLand', () {
    test('reconnaît le type canonique', () {
      expect(
          RealEstatePropertyType.isLand(RealEstatePropertyType.land), isTrue);
    });

    test('reconnaît un ancien texte libre français', () {
      expect(RealEstatePropertyType.isLand('Terrain'), isTrue);
      expect(RealEstatePropertyType.isLand('terrain agricole'), isTrue);
    });

    test('rejette un autre type', () {
      expect(
          RealEstatePropertyType.isLand(RealEstatePropertyType.villa), isFalse);
      expect(RealEstatePropertyType.isLand('Villa'), isFalse);
    });
  });

  group('RealEstatePropertyType.hasRooms', () {
    test('un terrain n\'a jamais de pièces', () {
      expect(RealEstatePropertyType.hasRooms(RealEstatePropertyType.land),
          isFalse);
    });

    test('une maison a des pièces', () {
      expect(RealEstatePropertyType.hasRooms(RealEstatePropertyType.house),
          isTrue);
    });
  });

  group('RealEstatePropertyType.isCommercialType', () {
    test('magasin/bureau/entrepôt sont commerciaux', () {
      expect(
          RealEstatePropertyType.isCommercialType(RealEstatePropertyType.shop),
          isTrue);
      expect(
          RealEstatePropertyType.isCommercialType(
              RealEstatePropertyType.office),
          isTrue);
      expect(
          RealEstatePropertyType.isCommercialType(
              RealEstatePropertyType.warehouse),
          isTrue);
      expect(
          RealEstatePropertyType.isCommercialType(
              RealEstatePropertyType.commercial),
          isTrue);
    });

    test('une villa n\'est pas commerciale', () {
      expect(
          RealEstatePropertyType.isCommercialType(RealEstatePropertyType.villa),
          isFalse);
    });

    test('reconnaît un ancien texte libre "Local commercial"', () {
      expect(
          RealEstatePropertyType.isCommercialType('Local commercial'), isTrue);
    });
  });

  group('RealEstatePropertyType.isFurnishedResidenceType', () {
    test('reconnaît le type canonique', () {
      expect(
          RealEstatePropertyType.isFurnishedResidenceType(
              RealEstatePropertyType.furnishedResidence),
          isTrue);
    });

    test('reconnaît un ancien texte libre "Résidence meublée"', () {
      expect(
          RealEstatePropertyType.isFurnishedResidenceType('Résidence meublée'),
          isTrue);
    });

    test('une maison classique n\'est pas une résidence meublée', () {
      expect(
          RealEstatePropertyType.isFurnishedResidenceType(
              RealEstatePropertyType.house),
          isFalse);
    });
  });

  group('RealEstatePropertyType.label', () {
    test('donne un libellé français pour chaque type canonique', () {
      for (final t in RealEstatePropertyType.all) {
        expect(RealEstatePropertyType.label(t), isNotEmpty);
      }
    });

    test('renvoie tel quel un ancien texte libre inconnu', () {
      expect(
          RealEstatePropertyType.label('Château médiéval'), 'Château médiéval');
    });
  });
}
