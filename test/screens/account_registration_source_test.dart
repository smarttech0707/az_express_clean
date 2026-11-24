import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Gardes statiques sur les chaînes d'inscription : storage.rules exige image/* (ou video/*) et firestore.rules
// n'accepte la création d'un profil client qu'avec une liste exacte de champs.
String _read(String p) => File(p).readAsStringSync();

void main() {
  test('téléversements d\'inscription/livraison : type MIME déclaré explicitement', () {
    final checks = {
      'lib/screens/fleet/fleet_register.dart': ['putFile(\n          _selfieFile!, SettableMetadata(contentType: \'image/jpeg\'))'],
      'lib/screens/client/service_provider_register_page.dart': ['SettableMetadata(contentType: \'image/jpeg\')'],
      'lib/screens/driver/driver_dashboard.dart': ['putFile(File(file.path),'],
      'lib/event/services/event_service.dart': ['SettableMetadata(contentType: contentType)'],
    };
    checks.forEach((file, needles) {
      final src = _read(file).replaceAll('\r\n', '\n');
      for (final n in needles) {
        expect(src.contains(n), isTrue, reason: '$file : $n');
      }
    });
    final fleet = _read('lib/screens/fleet/fleet_register.dart');
    expect(RegExp(r'putFile\(\s*_idPhotoFile!,\s*SettableMetadata').hasMatch(fleet), isTrue);
  });

  test('profil client : la 1re sauvegarde crée le document avec les champs exacts exigés par les règles', () {
    final src = _read('lib/screens/client/profil_client.dart');
    final i = src.indexOf('(await ref.get()).exists');
    expect(i, greaterThan(0));
    final block = src.substring(i, i + 900);
    for (final k in ['"wallet": 0', '"cashOnDeliveryEnabled": true', '"fakeOrderCount": 0', '"createdAt"']) {
      expect(block.contains(k), isTrue, reason: k);
    }
  });
}
