import 'package:az_express/services/geo_cache_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('le cache géographique survit à une nouvelle lecture du stockage',
      () async {
    SharedPreferences.setMockInitialValues({});
    const value = {
      'commerce': {
        'createdAt': 123,
        'address': 'Commerce, Abengourou',
      },
    };

    await GeoCacheStore.write('geo_test_cache', value);
    final restored = await GeoCacheStore.read('geo_test_cache');

    expect(restored, value);
  });
}
