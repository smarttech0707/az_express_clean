import 'dart:io';

import 'package:az_express/services/notification_service.dart';
import 'package:az_express/services/permission_primer.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
// ignore: depend_on_referenced_packages
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mission M2.9 : une explication précède chaque invite système, un refus ne bloque rien, rien au lancement.
class _FakeGeolocator extends GeolocatorPlatform with MockPlatformInterfaceMixin {
  _FakeGeolocator(this.current);
  LocationPermission current;
  int requests = 0;
  @override
  Future<LocationPermission> checkPermission() async => current;
  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return current = LocationPermission.whileInUse;
  }
}

void main() {
  late BuildContext ctx;

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: NotificationService.navigatorKey,
      home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold(body: SizedBox());
      }),
    ));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PermissionPrimer.debugReset();
  });

  Finder dialog(PermissionKind k) => find.byKey(Key('permission_primer_${k.name}'));

  group('explication avant l\'invite', () {
    for (final kind in PermissionKind.values) {
      testWidgets('${kind.name} : texte affiché avant tout accord, Continuer autorise', (tester) async {
        await pumpHost(tester);
        var done = false;
        bool? result;
        PermissionPrimer.prepare(kind, context: ctx).then((r) {
          result = r;
          done = true;
        });
        await tester.pumpAndSettle();
        expect(dialog(kind), findsOneWidget);
        expect(find.text(PermissionPrimer.copy[kind]!.title), findsOneWidget);
        expect(find.text(PermissionPrimer.copy[kind]!.body), findsOneWidget);
        expect(done, isFalse, reason: 'l\'invite système ne peut pas partir avant la réponse');
        await tester.tap(find.byKey(const Key('permission_primer_continue')));
        await tester.pumpAndSettle();
        expect(result, isTrue);
        // Déjà expliqué : plus d'explication, l'invite système suit directement.
        expect(await PermissionPrimer.prepare(kind, context: ctx), isTrue);
        await tester.pumpAndSettle();
        expect(dialog(kind), findsNothing);
      });
    }

    testWidgets('« Plus tard » : refus sans blocage, pas de nouvelle explication pendant la session', (tester) async {
      await pumpHost(tester);
      bool? result;
      PermissionPrimer.prepare(PermissionKind.camera, context: ctx).then((r) => result = r);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('permission_primer_later')));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      expect(await PermissionPrimer.prepare(PermissionKind.camera, context: ctx), isFalse);
      await tester.pumpAndSettle();
      expect(dialog(PermissionKind.camera), findsNothing);
      // Les autres autorisations ne sont pas affectées.
      PermissionPrimer.prepare(PermissionKind.microphone, context: ctx);
      await tester.pumpAndSettle();
      expect(dialog(PermissionKind.microphone), findsOneWidget);
    });

    testWidgets('autorisation déjà accordée : aucune explication', (tester) async {
      await pumpHost(tester);
      expect(
          await PermissionPrimer.prepare(PermissionKind.camera, context: ctx, alreadyGranted: () async => true),
          isTrue);
      await tester.pumpAndSettle();
      expect(dialog(PermissionKind.camera), findsNothing);
    });

    testWidgets('appels simultanés : une seule explication', (tester) async {
      await pumpHost(tester);
      final a = PermissionPrimer.prepare(PermissionKind.location, context: ctx);
      final b = PermissionPrimer.prepare(PermissionKind.location, context: ctx);
      await tester.pumpAndSettle();
      expect(dialog(PermissionKind.location), findsOneWidget);
      await tester.tap(find.byKey(const Key('permission_primer_continue')));
      await tester.pumpAndSettle();
      expect(await a, isTrue);
      expect(await b, isTrue);
    });

    testWidgets('sans écran disponible : pas d\'invite sans explication', (tester) async {
      expect(await PermissionPrimer.prepare(PermissionKind.camera, context: null), isFalse);
    });

    test('texte livreur : iPhone, arrière-plan seulement pendant une livraison', () {
      final body = PermissionPrimer.copy[PermissionKind.driverLocation]!.body;
      expect(body, contains('iPhone'));
      expect(body, contains('pendant une livraison en cours'));
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('même parcours sur ${platform.name} (aucune différence de logique côté Dart)', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await pumpHost(tester);
          PermissionPrimer.prepare(PermissionKind.photos, context: ctx);
          await tester.pumpAndSettle();
          expect(dialog(PermissionKind.photos), findsOneWidget);
          await tester.tap(find.byKey(const Key('permission_primer_later')));
          await tester.pumpAndSettle();
          expect(dialog(PermissionKind.photos), findsNothing);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });

  group('localisation', () {
    testWidgets('permission existante : pas d\'explication, état renvoyé tel quel', (tester) async {
      await pumpHost(tester);
      for (final state in [LocationPermission.whileInUse, LocationPermission.always, LocationPermission.deniedForever]) {
        final fake = _FakeGeolocator(state);
        GeolocatorPlatform.instance = fake;
        expect(await PermissionPrimer.requestLocation(context: ctx), state);
        expect(fake.requests, 0);
      }
      await tester.pumpAndSettle();
      expect(dialog(PermissionKind.location), findsNothing);
    });

    testWidgets('denied + « Plus tard » : aucune invite système, l\'écran continue sans position', (tester) async {
      await pumpHost(tester);
      final fake = _FakeGeolocator(LocationPermission.denied);
      GeolocatorPlatform.instance = fake;
      LocationPermission? result;
      PermissionPrimer.requestLocation(context: ctx).then((r) => result = r);
      await tester.pumpAndSettle();
      expect(dialog(PermissionKind.location), findsOneWidget);
      expect(fake.requests, 0, reason: 'invite système interdite avant l\'accord');
      await tester.tap(find.byKey(const Key('permission_primer_later')));
      await tester.pumpAndSettle();
      expect(result, LocationPermission.denied);
      expect(fake.requests, 0);
    });

    testWidgets('denied + Continuer : l\'invite système est demandée une fois', (tester) async {
      await pumpHost(tester);
      final fake = _FakeGeolocator(LocationPermission.denied);
      GeolocatorPlatform.instance = fake;
      LocationPermission? result;
      PermissionPrimer.requestLocation(context: ctx, driver: true).then((r) => result = r);
      await tester.pumpAndSettle();
      expect(dialog(PermissionKind.driverLocation), findsOneWidget);
      await tester.tap(find.byKey(const Key('permission_primer_continue')));
      await tester.pumpAndSettle();
      expect(fake.requests, 1);
      expect(result, LocationPermission.whileInUse);
    });
  });

  group('notifications', () {
    testWidgets('explication puis invite ; demandées une seule fois', (tester) async {
      await pumpHost(tester);
      var system = 0;
      PermissionPrimer.requestNotifications(
          isAuthorized: () async => false, requestSystem: () async => system++, context: ctx);
      await tester.pumpAndSettle();
      expect(dialog(PermissionKind.notifications), findsOneWidget);
      expect(system, 0);
      await tester.tap(find.byKey(const Key('permission_primer_continue')));
      await tester.pumpAndSettle();
      expect(system, 1);
      await PermissionPrimer.requestNotifications(
          isAuthorized: () async => false, requestSystem: () async => system++, context: ctx);
      await tester.pumpAndSettle();
      expect(system, 1);
      expect(dialog(PermissionKind.notifications), findsNothing);
    });

    testWidgets('refus de l\'explication : aucune invite, jamais redemandé automatiquement', (tester) async {
      await pumpHost(tester);
      var system = 0;
      PermissionPrimer.requestNotifications(
          isAuthorized: () async => false, requestSystem: () async => system++, context: ctx);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('permission_primer_later')));
      await tester.pumpAndSettle();
      expect(system, 0);
      PermissionPrimer.debugReset(); // simule une nouvelle session
      await PermissionPrimer.requestNotifications(
          isAuthorized: () async => false, requestSystem: () async => system++, context: ctx);
      await tester.pumpAndSettle();
      expect(dialog(PermissionKind.notifications), findsNothing);
      expect(system, 0);
    });

    testWidgets('déjà autorisées : rien', (tester) async {
      await pumpHost(tester);
      var system = 0;
      await PermissionPrimer.requestNotifications(
          isAuthorized: () async => true, requestSystem: () async => system++, context: ctx);
      await tester.pumpAndSettle();
      expect(system, 0);
      expect(dialog(PermissionKind.notifications), findsNothing);
    });

    testWidgets('pas d\'écran disponible : on réessaiera plus tard, rien n\'est marqué comme demandé', (tester) async {
      var system = 0;
      await PermissionPrimer.requestNotifications(
          isAuthorized: () async => false, requestSystem: () async => system++);
      expect((await SharedPreferences.getInstance()).getBool('perm_primer_notifications_asked'), isNull);
      expect(system, 0);
    });
  });

  group('aucune demande prématurée (gardes de source)', () {
    String read(String p) => File(p).readAsStringSync();
    final svc = read('lib/services/notification_service.dart');

    test('notifications : requestPermission uniquement dans requestPermissionWithExplanation, jamais dans init()', () {
      final init = svc.substring(svc.indexOf('Future<void> init()'), svc.indexOf('Future<void> saveToken'));
      expect(init.contains('requestPermission('), isFalse);
      expect(svc, contains('unawaited(requestPermissionWithExplanation())'));
      final after = svc.substring(svc.indexOf('requestPermissionWithExplanation() {'));
      expect(after, contains('_fcm.requestPermission('));
    });

    test('lancement : main.dart ne demande aucune autorisation', () {
      final main = read('lib/main.dart');
      expect(main.contains('requestPermission('), isFalse);
      expect(main.contains('Permission.'), isFalse);
      expect(main.contains('_speech.initialize'), isFalse);
    });

    test('localisation : plus aucun Geolocator.requestPermission() hors amorce, outils d\'admin et code mort', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        final path = f.path.replaceAll('\\', '/');
        if (!path.endsWith('.dart') || path.contains('/screens/admin/')) continue;
        if (path.endsWith('services/permission_primer.dart') || path.endsWith('screens/driver/driver_map.dart')) {
          continue;
        }
        if (f.readAsStringSync().contains('Geolocator.requestPermission(')) offenders.add(path);
      }
      expect(offenders, isEmpty);
    });

    test('caméra/photos : tout écran non admin qui ouvre un sélecteur d\'image passe par prepareImage', () {
      final missing = <String>[];
      final pickers = RegExp(r'\.(pickImage|pickMultiImage|pickVideo)\(');
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        final path = f.path.replaceAll('\\', '/');
        if (!path.endsWith('.dart') || path.contains('/screens/admin/') || path.endsWith('permission_primer.dart')) {
          continue;
        }
        final src = f.readAsStringSync();
        if (!pickers.hasMatch(src)) continue;
        if (!src.contains('PermissionPrimer.prepareImage(')) missing.add(path);
      }
      expect(missing, isEmpty);
    });

    test('micro : enregistrement et dictée passent par prepareMicrophone, sans initialisation à l\'ouverture', () {
      for (final p in ['lib/screens/chat/chat_page.dart', 'lib/marketplace/screens/mp_chat_page.dart']) {
        final src = read(p);
        expect(src.indexOf('PermissionPrimer.prepareMicrophone'), lessThan(src.indexOf('_recorder.hasPermission()')));
      }
      for (final p in ['lib/screens/client/courses_screen.dart', 'lib/screens/ai/az_ia_chat_screen.dart']) {
        final src = read(p);
        expect(RegExp(r'^\s+_initSpeech\(\);', multiLine: true).hasMatch(src), isFalse, reason: p);
        expect(src.indexOf('PermissionPrimer.prepareMicrophone'), lessThan(src.lastIndexOf('await _initSpeech();')));
      }
    });
  });
}
