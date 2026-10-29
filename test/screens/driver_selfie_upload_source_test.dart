import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// storage.rules (acceptance_selfies) exige `image/*` : le selfie d'acceptation doit déclarer son type MIME.
void main() {
  test('selfie d\'acceptation envoyé avec contentType image/jpeg', () {
    final src = File('lib/screens/driver/driver_dashboard.dart').readAsStringSync();
    final i = src.indexOf('acceptance_selfies/');
    expect(i, greaterThan(0));
    final block = src.substring(i, i + 700);
    expect(block.contains("SettableMetadata(contentType: 'image/jpeg')"), isTrue);
    expect(File('storage.rules').readAsStringSync().contains("matches('image/.*')"), isTrue);
  });
}
