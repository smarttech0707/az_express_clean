import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/utils/partner_location_validator.dart';

void main() {
  for (final partnerType in [
    'restaurant',
    'boulangerie',
    'pharmacie',
    'seller',
  ]) {
    group(partnerType, () {
      test('refuse des coordonnées absentes', () {
        expect(PartnerLocationValidator.validate(null, null), isNotNull);
        expect(PartnerLocationValidator.validateText('', ''), isNotNull);
      });

      test('refuse le point 0/0', () {
        expect(PartnerLocationValidator.validate(0, 0), isNotNull);
      });

      test('refuse les coordonnées hors des bornes terrestres', () {
        expect(PartnerLocationValidator.validate(-91, -3.4), isNotNull);
        expect(PartnerLocationValidator.validate(91, -3.4), isNotNull);
        expect(PartnerLocationValidator.validate(6.7, -181), isNotNull);
        expect(PartnerLocationValidator.validate(6.7, 181), isNotNull);
      });

      test('accepte un point valide', () {
        expect(PartnerLocationValidator.validate(6.7298, -3.4964), isNull);
      });
    });
  }

  test('le message explique le blocage des commandes et le guidage', () {
    expect(PartnerLocationValidator.requiredMessage, contains('livreur'));
    expect(PartnerLocationValidator.requiredMessage, contains('guidé'));
    expect(PartnerLocationValidator.requiredMessage, contains('refusées'));
  });
}
