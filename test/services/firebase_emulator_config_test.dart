import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/firebase_emulator_config.dart';

void main() {
  test('adresses autorisées : réseau local uniquement', () {
    for (final h in ['192.168.1.20', '10.0.2.2', '10.1.2.3', '172.16.0.5', '172.31.9.9', '127.0.0.2']) {
      expect(FirebaseEmulatorConfig.isSafeHost(h), isTrue, reason: h);
    }
  });

  test('adresses refusées : domaines publics, localhost, IP publiques, vide', () {
    for (final h in [
      '', 'localhost', '127.0.0.1', '127.0.0.2.evil.com', '127.0.0.3', '8.8.8.8', '172.32.0.1', '192.169.1.1',
      'europe-west1-az-express-b0469.cloudfunctions.net', '192.168.1.1.evil.com',
    ]) {
      expect(FirebaseEmulatorConfig.isSafeHost(h), isFalse, reason: h);
    }
  });

  test('projet factice requis, jamais la production', () {
    expect(FirebaseEmulatorConfig.isDemoProject('demo-az-express'), isTrue);
    expect(FirebaseEmulatorConfig.isDemoProject('az-express-b0469'), isFalse);
    expect(FirebaseEmulatorConfig.options.projectId, 'demo-az-express');
    // Format exigé par firebase-installations, mais chaîne synthétique reconnaissable (jamais une clé réelle).
    expect(RegExp(r'^A[\w-]{38}$').hasMatch(FirebaseEmulatorConfig.options.apiKey), isTrue);
    expect(FirebaseEmulatorConfig.options.apiKey.contains('DEMO'), isTrue);
    expect(FirebaseEmulatorConfig.options.appId.contains('000000000000'), isTrue);
  });

  test('mode désactivé par défaut (aucun dart-define)', () {
    expect(FirebaseEmulatorConfig.enabled, isFalse);
  });
}
