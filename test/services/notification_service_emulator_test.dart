import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Hors réseau (APK de test en mode avion), chaque demande de jeton FCM échoue puis boucle en créant des threads
  // jusqu'au plantage : en mode émulateurs, aucun chemin ne doit appeler `getToken`.
  test('getTokenWhenReady ne demande aucun jeton FCM en mode émulateurs', () {
    final src = File('lib/services/notification_service.dart').readAsStringSync();
    final start = src.indexOf('Future<String?> getTokenWhenReady()');
    expect(start, greaterThan(0));
    final body = src.substring(start);
    final guard = body.indexOf('if (FirebaseEmulatorConfig.enabled) return null;');
    expect(guard, greaterThan(0));
    expect(guard, lessThan(body.indexOf('_fcm.getToken()')));
    // Seul getTokenWhenReady appelle getToken ; les autres chemins passent par lui.
    expect(RegExp(r'\.getToken\(\)').allMatches(src).length, 2);
    expect(src.contains('onTokenRefresh.listen'), isTrue);
    expect(RegExp(r'if \(!FirebaseEmulatorConfig\.enabled\) unawaited\(NotificationService\(\)\.init\(\)\)')
        .hasMatch(File('lib/main.dart').readAsStringSync()), isTrue);
  });
}
