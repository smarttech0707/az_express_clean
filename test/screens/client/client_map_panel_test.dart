import 'dart:async';

import 'package:az_express/screens/client/client_map.dart';
import 'package:az_express/widgets/live_marker_cache.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// Panneau de services déplaçable de l'accueil client : positions, absence de
// débordement sur 3 tailles de téléphone, accès aux services conservé, et
// carte/GPS inchangés. Aucun Firebase réel, aucun GPS réel.

const _sizes = [Size(360, 640), Size(390, 844), Size(430, 932)];

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final feed = StreamController<LiveDriverSnapshot>();
  addTearDown(feed.close);
  await tester.pumpWidget(
    MaterialApp(home: ClientMap(driversFeed: () => feed.stream)),
  );
  await tester.pumpAndSettle();
}

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text).first).dy;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'),
      (call) async {
        switch (call.method) {
          case 'isLocationServiceEnabled':
            return true;
          case 'checkPermission':
          case 'requestPermission':
            return 3;
        }
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'),
      null,
    );
  });

  group('clientPanelSizes', () {
    for (final size in _sizes) {
      test('positions ordonnées et valides à ${size.width}×${size.height}', () {
        final s = clientPanelSizes(
          height: size.height,
          topInset: 24,
          bottomInset: 100,
        );
        expect(s.collapsed, lessThan(s.mid));
        expect(s.mid, lessThan(s.expanded));
        expect(s.collapsed, greaterThanOrEqualTo(0.12));
        expect(s.expanded, lessThanOrEqualTo(0.92));
        // Agrandi, le panneau laisse la barre de recherche entièrement visible.
        expect(size.height * (1 - s.expanded), greaterThanOrEqualTo(24 + 110));
      });
    }

    test('ne lève pas pour des valeurs extrêmes', () {
      for (final h in [1.0, 300.0, 2000.0]) {
        for (final b in [0.0, 34.0, 200.0]) {
          final s = clientPanelSizes(height: h, topInset: 60, bottomInset: b);
          expect(s.collapsed < s.mid && s.mid < s.expanded, isTrue,
              reason: 'h=$h b=$b');
        }
      }
    });
  });

  for (final size in _sizes) {
    testWidgets('accueil sans overflow, services accessibles à $size',
        (tester) async {
      await _pump(tester, size);
      expect(tester.takeException(), isNull);
      expect(find.byType(GoogleMap), findsOneWidget);
      expect(find.text('Où allez-vous ?'), findsOneWidget);

      // Panneau agrandi : tous les services principaux sont atteignables.
      await tester.dragFrom(
          Offset(size.width / 2, size.height * 0.7), Offset(0, -size.height));
      await tester.pumpAndSettle();
      for (final label in ['Livraison', 'Courses', 'Food', 'Événementiel']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.text('Plus de services'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('glisser le panneau vers le bas libère la carte', (tester) async {
    await _pump(tester, const Size(390, 844));
    final before = _top(tester, 'Livraison');

    await tester.dragFrom(const Offset(195, 600), const Offset(0, 500));
    await tester.pumpAndSettle();

    // Réduit : les cartes sont sorties de l'écran visible ou descendues.
    final collapsed = tester.getTopLeft(find.text('Livraison').first).dy;
    expect(collapsed, greaterThan(before));
    expect(find.byType(GoogleMap), findsOneWidget);
  });

  testWidgets('appui sur la poignée : passe à la position suivante',
      (tester) async {
    await _pump(tester, const Size(390, 844));
    final mid = _top(tester, 'Livraison');

    await tester.tap(find.bySemanticsLabel(RegExp('Panneau des services')));
    await tester.pumpAndSettle();
    final expanded = _top(tester, 'Livraison');
    expect(expanded, lessThan(mid));

    await tester.tap(find.bySemanticsLabel(RegExp('Panneau des services')));
    await tester.pumpAndSettle();
    final collapsed = _top(tester, 'Livraison');
    expect(collapsed, greaterThan(mid));
  });

  testWidgets('un geste au-dessus du panneau atteint la carte', (tester) async {
    await _pump(tester, const Size(390, 844));
    // Zone haute centrale (hors en-tête, hors panneau) : la carte reçoit le toucher.
    final map = find.byType(GoogleMap);
    expect(map.hitTestable(at: const Alignment(0, -0.3)), findsOneWidget);
  });

  testWidgets('encoche + barre flottante (inset bas 100) : sans overflow',
      (tester) async {
    tester.view.padding = const FakeViewPadding(top: 96, bottom: 200);
    addTearDown(tester.view.resetPadding);
    await _pump(tester, const Size(360, 640));
    expect(tester.takeException(), isNull);
    expect(find.text('Livraison'), findsWidgets);
  });
}
