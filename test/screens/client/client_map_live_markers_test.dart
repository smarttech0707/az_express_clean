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

// ─────────────────────────────────────────────────────────────────────────────
// Tests widget ClientMap — faux flux « livreurs en ligne » injecté via
// `driversFeed`. Aucun Firebase réel, aucune requête Firestore réelle, aucun
// GPS réel (seul le canal plateforme geolocator est simulé dans le test).
// Les « markers logiques » sont lus directement sur `GoogleMap.markers`, qui
// reflète l'état `_markers` de l'écran.
// ─────────────────────────────────────────────────────────────────────────────

/// Fabrique de flux injectable + compteur d'abonnements (item F).
/// Contrôleur mono-abonnement : une seconde écoute lèverait une exception,
/// ce qui prouve directement qu'aucun second listener n'est créé.
class _Feed {
  final controller = StreamController<LiveDriverSnapshot>();
  int listenCount = 0;

  Stream<LiveDriverSnapshot> call() {
    listenCount++;
    return controller.stream;
  }

  void emit(LiveDriverSnapshot snap) => controller.add(snap);
  Future<void> dispose() async {
    if (!controller.isClosed) await controller.close();
  }
}

LiveDriverDoc driver(
  String id, {
  double? lat = 6.70,
  double? lng = -3.49,
  String name = 'Livreur',
}) =>
    LiveDriverDoc(id, {
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      'name': name,
      'isOnline': true,
    });

LiveDriverDocChange added(LiveDriverDoc d) =>
    LiveDriverDocChange(LiveMarkerChangeType.added, d);
LiveDriverDocChange modified(LiveDriverDoc d) =>
    LiveDriverDocChange(LiveMarkerChangeType.modified, d);
LiveDriverDocChange removed(LiveDriverDoc d) =>
    LiveDriverDocChange(LiveMarkerChangeType.removed, d);

LiveDriverSnapshot snap(
  List<LiveDriverDoc> docs,
  List<LiveDriverDocChange> changes,
) =>
    LiveDriverSnapshot(docs: docs, docChanges: changes);

Set<Marker> driverMarkers(WidgetTester tester) {
  final gm = tester.widget<GoogleMap>(find.byType(GoogleMap));
  return gm.markers.where((m) => m.markerId.value != 'client').toSet();
}

Set<String> driverMarkerIds(WidgetTester tester) =>
    driverMarkers(tester).map((m) => m.markerId.value).toSet();

Marker? markerById(WidgetTester tester, String id) {
  final gm = tester.widget<GoogleMap>(find.byType(GoogleMap));
  for (final m in gm.markers) {
    if (m.markerId.value == id) return m;
  }
  return null;
}

Future<_Feed> _pumpMap(WidgetTester tester) async {
  final feed = _Feed();
  addTearDown(feed.dispose);
  await tester.pumpWidget(MaterialApp(home: ClientMap(driversFeed: feed.call)));
  await tester.pumpAndSettle();
  return feed;
}

Future<void> disposeMap(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    // GPS mocké : service actif + permission accordée. Aucune modification
    // du code GPS de production — uniquement le canal plateforme du test.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'),
      (call) async {
        switch (call.method) {
          case 'isLocationServiceEnabled':
            return true;
          case 'checkPermission':
          case 'requestPermission':
            return 3; // LocationPermission.always
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

  testWidgets('A. snapshot initial : 3 livreurs valides -> 3 markers logiques',
      (tester) async {
    final feed = await _pumpMap(tester);
    feed.emit(snap(
      [driver('a', lat: 6.70), driver('b', lat: 6.80), driver('c', lat: 6.90)],
      [
        added(driver('a', lat: 6.70)),
        added(driver('b', lat: 6.80)),
        added(driver('c', lat: 6.90)),
      ],
    ));
    await tester.pumpAndSettle();

    expect(driverMarkerIds(tester), {'a', 'b', 'c'});
    expect(markerById(tester, 'b')!.position.latitude, 6.80);

    await disposeMap(tester);
  });

  testWidgets('B. modified : un seul livreur bouge, les autres inchanges',
      (tester) async {
    final feed = await _pumpMap(tester);
    feed.emit(snap(
      [driver('a', lat: 6.70), driver('b', lat: 6.80), driver('c', lat: 6.90)],
      [
        added(driver('a', lat: 6.70)),
        added(driver('b', lat: 6.80)),
        added(driver('c', lat: 6.90)),
      ],
    ));
    await tester.pumpAndSettle();

    final aBefore = markerById(tester, 'a');
    final cBefore = markerById(tester, 'c');

    feed.emit(snap(
      [driver('a', lat: 6.70), driver('b', lat: 7.10), driver('c', lat: 6.90)],
      [modified(driver('b', lat: 7.10))],
    ));
    await tester.pumpAndSettle();

    expect(driverMarkerIds(tester), {'a', 'b', 'c'});
    expect(markerById(tester, 'b')!.position.latitude, 7.10);
    // Les autres markers ne sont pas recreees (meme instance renvoyee par le cache).
    expect(markerById(tester, 'a'), same(aBefore));
    expect(markerById(tester, 'c'), same(cBefore));

    await disposeMap(tester);
  });

  testWidgets('C. removed : le marker est supprime', (tester) async {
    final feed = await _pumpMap(tester);
    feed.emit(snap(
      [driver('a'), driver('b'), driver('c')],
      [added(driver('a')), added(driver('b')), added(driver('c'))],
    ));
    await tester.pumpAndSettle();
    expect(driverMarkerIds(tester), {'a', 'b', 'c'});

    feed.emit(snap(
      [driver('a'), driver('b')],
      [removed(driver('c'))],
    ));
    await tester.pumpAndSettle();

    expect(driverMarkerIds(tester), {'a', 'b'});
    expect(markerById(tester, 'c'), isNull);

    await disposeMap(tester);
  });

  testWidgets('D. coordonnees invalides : marker absent puis supprime',
      (tester) async {
    final feed = await _pumpMap(tester);

    // Invalide des la premiere emission -> jamais de marker.
    feed.emit(snap(
      [driver('a'), driver('b'), driver('c', lat: 0)],
      [added(driver('a')), added(driver('b')), added(driver('c', lat: 0))],
    ));
    await tester.pumpAndSettle();
    expect(driverMarkerIds(tester), {'a', 'b'});

    // Un livreur valide devient invalide -> son marker est retire.
    feed.emit(snap(
      [driver('a', lat: 0), driver('b')],
      [modified(driver('a', lat: 0))],
    ));
    await tester.pumpAndSettle();
    expect(driverMarkerIds(tester), {'b'});
    expect(markerById(tester, 'a'), isNull);

    await disposeMap(tester);
  });

  testWidgets('E. dispose : une emission post-destruction ne casse rien',
      (tester) async {
    final feed = await _pumpMap(tester);
    feed.emit(snap(
      [driver('a'), driver('b'), driver('c')],
      [added(driver('a')), added(driver('b')), added(driver('c'))],
    ));
    await tester.pumpAndSettle();
    expect(driverMarkerIds(tester), {'a', 'b', 'c'});

    // Destruction du widget.
    await disposeMap(tester);
    expect(find.byType(ClientMap), findsNothing);

    // Nouvelle emission apres dispose : ni setState, ni exception.
    feed.emit(snap([driver('a', lat: 7.5)], [modified(driver('a', lat: 7.5))]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
  });

  testWidgets('F. aucun second listener sur le flux livreurs', (tester) async {
    final feed = await _pumpMap(tester);
    expect(feed.listenCount, 1);
    expect(feed.controller.hasListener, isTrue);

    feed.emit(snap([driver('a')], [added(driver('a'))]));
    await tester.pumpAndSettle();
    feed.emit(snap([driver('a'), driver('b')], [added(driver('b'))]));
    await tester.pumpAndSettle();

    // Toujours une seule fabrique appelee, un seul abonnement.
    expect(feed.listenCount, 1);
    expect(feed.controller.hasListener, isTrue);

    await disposeMap(tester);
  });
}
