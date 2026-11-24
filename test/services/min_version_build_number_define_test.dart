import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/min_version_service.dart';

// Vérification M2.1 de la chaîne d'injection : `scripts/build_mobile.py` écrit APP_BUILD_NUMBER (chaîne) dans le
// fichier de défines, `int.fromEnvironment` le lit dans `min_version_service.dart`. Sans EXPECTED_APP_BUILD_NUMBER
// (cas normal de `flutter test`), le test est ignoré :
//   flutter test --dart-define-from-file=<defines.json> --dart-define=EXPECTED_APP_BUILD_NUMBER=<n> <ce fichier>
// Ce test s'exécute dans la VM de test, il ne remplace pas la vérification d'un APK/IPA (voir docs/ACCOUNT_DELETION_M2_1_VERIFICATION.md).
const _expected = String.fromEnvironment('EXPECTED_APP_BUILD_NUMBER');

void main() {
  test('appBuildNumber vaut la valeur injectée par --dart-define', () {
    expect(appBuildNumber, int.parse(_expected));
  }, skip: _expected.isEmpty ? 'EXPECTED_APP_BUILD_NUMBER non fourni' : false);

  test("une valeur 0, absente ou invalide ne bloque jamais, même avec enforce", () {
    if (_expected.isEmpty) return;
    if (appBuildNumber <= 0) {
      expect(MinVersionService.evaluate({'minBuild': 99, 'enforce': true}, appBuildNumber), MinVersionStatus.ok);
    }
  });
}
