import 'dart:async';

import 'package:az_express/screens/client/client_map.dart';
import 'package:az_express/widgets/live_marker_cache.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Poignée FIXE du panneau de services : reste visible quand les cartes
// défilent, change la position par appui, suit le doigt au glissement, et
// n'empêche ni le défilement des services ni le glissement par le contenu.

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

Finder _handle() => find.bySemanticsLabel(RegExp('Panneau des services'));

Finder _panelScrollView() => find.descendant(
      of: find.byType(DraggableScrollableSheet),
      matching: find.byType(SingleChildScrollView),
    );

double _panelTop(WidgetTester tester) =>
    tester.getTopLeft(_panelScrollView()).dy;

ScrollPosition _content(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(Scrollable)))
    .position;

/// Appuie deux fois sur la poignée : moyen → agrandi.
Future<void> _expand(WidgetTester tester) async {
  await tester.tap(_handle());
  await tester.pumpAndSettle();
}

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

  for (final size in _sizes) {
    testWidgets(
        'poignée immobile, visible et cliquable après défilement : $size',
        (tester) async {
      await _pump(tester, size);
      await _expand(tester);
      final before = tester.getTopLeft(_handle());

      _content(tester).jumpTo(_content(tester).maxScrollExtent);
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(_handle()), before);
      expect(_handle().hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('la poignée est au-dessus du contenu, sans le recouvrir',
      (tester) async {
    await _pump(tester, const Size(360, 640));
    final handleBottom = tester.getBottomLeft(_handle()).dy;
    // La zone défilante commence juste sous la poignée.
    expect(_panelTop(tester), greaterThanOrEqualTo(handleBottom - 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('appui sur la poignée : change de position après défilement',
      (tester) async {
    await _pump(tester, const Size(390, 844));
    await _expand(tester);
    _content(tester).jumpTo(_content(tester).maxScrollExtent);
    await tester.pumpAndSettle();
    final scrolledTop = _panelTop(tester);

    await tester.tap(_handle()); // agrandi → réduit
    await tester.pumpAndSettle();
    expect(_panelTop(tester), greaterThan(scrolledTop));
  });

  testWidgets('glisser la poignée vers le haut agrandit, vers le bas réduit',
      (tester) async {
    await _pump(tester, const Size(390, 844));
    final start = _panelTop(tester);

    await tester.drag(_handle(), const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(_panelTop(tester), lessThan(start));

    await tester.drag(_handle(), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(_panelTop(tester), greaterThan(start));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lancer la poignée vers le haut atteint une position cible',
      (tester) async {
    await _pump(tester, const Size(390, 844));
    final start = _panelTop(tester);
    await tester.fling(_handle(), const Offset(0, -300), 2500);
    await tester.pumpAndSettle();
    expect(_panelTop(tester), lessThan(start));
  });

  testWidgets('les services restent défilables quand le panneau est agrandi',
      (tester) async {
    await _pump(tester, const Size(360, 640));
    await _expand(tester);
    expect(_content(tester).maxScrollExtent, greaterThan(0));

    final y = tester.getTopLeft(find.text('Livraison')).dy;
    await tester.dragFrom(const Offset(180, 450), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(_content(tester).pixels, greaterThan(0));
    expect(tester.getTopLeft(find.text('Livraison')).dy, lessThan(y));
  });

  testWidgets('glisser le contenu déplace toujours le panneau', (tester) async {
    await _pump(tester, const Size(390, 844));
    final start = _panelTop(tester);
    // Dans le panneau (carte Livraison), pas sur la carte.
    await tester.dragFrom(const Offset(195, 640), const Offset(0, -320));
    await tester.pumpAndSettle();
    expect(_panelTop(tester), lessThan(start));
  });
}
