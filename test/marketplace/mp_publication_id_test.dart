import 'package:az_express/marketplace/services/mp_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('identifiant de publication: 20 caractères alphanumériques, sans Firebase',
      () {
    final id = MpService.newPublicationId();
    expect(RegExp(r'^[A-Za-z0-9]{20}$').hasMatch(id), isTrue);
  });

  test('deux publications distinctes ont des identifiants différents', () {
    final ids = {for (var i = 0; i < 200; i++) MpService.newPublicationId()};
    expect(ids.length, 200);
  });
}
