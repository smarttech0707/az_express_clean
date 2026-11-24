import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/fcm_policy.dart';

void main() {
  group('FcmPolicy', () {
    test('pure : jeton autorisé seulement hors émulateurs et sans DISABLE_FCM', () {
      expect(FcmPolicy.allowsRegistration(emulators: false, disable: false), isTrue);
      expect(FcmPolicy.allowsRegistration(emulators: true, disable: false), isFalse);
      expect(FcmPolicy.allowsRegistration(emulators: false, disable: true), isFalse);
      expect(FcmPolicy.allowsRegistration(emulators: true, disable: true), isFalse);
    });

    test('désactivé par défaut : un build ordinaire garde le comportement de production', () {
      // Sans --dart-define=DISABLE_FCM=true. Relancé avec le define dans la suite de validation (voir rapport 7E-55).
      const defined = bool.fromEnvironment('DISABLE_FCM');
      expect(FcmPolicy.disabled, defined);
      if (!defined) expect(FcmPolicy.allowsRegistration(emulators: false), isTrue);
      if (defined) expect(FcmPolicy.allowsRegistration(emulators: false), isFalse);
    });
  });

  group('chemins FCM identifiés (7E-54) tous protégés', () {
    String src(String p) => File(p).readAsStringSync();

    test('NotificationService : init, saveToken, getToken et renouvellement', () {
      final s = src('lib/services/notification_service.dart');
      expect(RegExp(r'Future<void> init\(\) async \{\s*//[^\n]*\n\s*if \(FcmPolicy\.disabled\) return;').hasMatch(s), isTrue);
      expect(RegExp(r'Future<void> saveToken\([^)]*\) async \{\s*if \(FcmPolicy\.disabled\) return;').hasMatch(s), isTrue);
      expect(s.contains('if (!FcmPolicy.allowsRegistration()) return null;'), isTrue);
      expect(RegExp(r'void _onTokenRefresh\(String token\) \{\s*if \(FcmPolicy\.disabled\) return;').hasMatch(s), isTrue);
    });

    test('GPS livreur : aucun champ fcmToken écrit', () {
      final s = src('lib/services/driver_location_service.dart');
      expect(s.contains("if (!FcmPolicy.disabled) 'fcmToken': _fcmToken"), isTrue);
      expect(RegExp(r"^\s*'fcmToken': _fcmToken", multiLine: true).hasMatch(s), isFalse);
    });

    test('démarrage : init FCM non lancée', () {
      expect(src('lib/main.dart').contains('!FcmPolicy.disabled) unawaited(NotificationService().init())'), isTrue);
    });

    test('aucune autre écriture de fcmToken hors des chemins protégés', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final p = f.path.replaceAll(r'\', '/');
        if (!f.readAsStringSync().contains("'fcmToken'")) continue;
        if (!{'lib/services/notification_service.dart', 'lib/services/driver_location_service.dart', 'lib/event/services/event_service.dart'}.contains(p)) {
          offenders.add(p);
        }
      }
      expect(offenders, isEmpty);
      // event_service obtient son jeton uniquement par getTokenWhenReady() (null sous DISABLE_FCM) et ne l'écrit que s'il existe.
      final e = src('lib/event/services/event_service.dart');
      expect(e.contains('getTokenWhenReady()'), isTrue);
      expect(e.contains('if (token != null)'), isTrue);
    });
  });
}
