import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/auth_service.dart';

void main() {
  group('AuthService.toE164', () {
    test('conserve le zero du format national ivoirien a 10 chiffres', () {
      expect(AuthService.toE164('07 01 02 03 04'), '+2250701020304');
    });

    test('conserve un numero ivoirien deja au format E.164', () {
      expect(AuthService.toE164('+225 07 01 02 03 04'), '+2250701020304');
    });

    test('accepte le format historique a 8 chiffres', () {
      expect(AuthService.toE164('01 02 03 04'), '+22501020304');
    });
  });
}
