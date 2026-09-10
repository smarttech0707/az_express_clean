import 'dart:async';

import 'package:az_express/screens/admin/admin_live_tracking_page.dart';
import 'package:az_express/widgets/live_marker_cache.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Tests widget AdminLiveTrackingPage — faux flux « livreurs en ligne » injecté
// via `driversFeed`. Aucun Firebase réel, aucune requête Firestore réelle.
// Les markers logiques sont lus sur `GoogleMap.markers` ; les données Admin
// (liste des livreurs) via les libellés rendus dans la liste.
// ─────────────────────────────────────────────────────────────────────────────

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
  String? name,
  bool fresh = true,
}) =>
    LiveDriverDoc(id, {
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      'name': name ?? 'Livreur $id',
      'phone': '0700000000',
      if (fresh) 'updatedAt': Timestamp.now(),
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

Set<String> markerIds(WidgetTester tester) {
  final gm = tester.widget<GoogleMap>(find.byType(GoogleMap));
  return gm.markers.map((m) => m.markerId.value).toSet();
}

Marker? markerById(WidgetTester tester, String id) {
  final gm = tester.widget<GoogleMap>(find.byType(GoogleMap));
  for (final m in gm.markers) {
    if (m.markerId.value == id) return m;
  }
  return null;
}

Future<_Feed> _pumpAdmin(WidgetTester tester) async {
  final feed = _Feed();
  addTearDown(feed.dispose);
  await tester.pumpWidget(
    MaterialApp(home: AdminLiveTrackingPage(driversFeed: feed.call)),
  );
  await tester.pumpAndSettle();
  return feed;
}

Future<void> disposeAdmin(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('initial : 3 livreurs valides -> 3 markers + 3 lignes Admin',
      (tester) async {
    final feed = await _pumpAdmin(tester);
    feed.emit(snap(
      [
        driver('a', name: 'Alice'),
        driver('b', name: 'Bob'),
        driver('c', name: 'Charlie'),
      ],
      [
        added(driver('a', name: 'Alice')),
        added(driver('b', name: 'Bob')),
        added(driver('c', name: 'Charlie')),
      ],
    ));
    await tester.pumpAndSettle();

    expect(markerIds(tester), {'a', 'b', 'c'});
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Charlie'), findsOneWidget);

    await disposeAdmin(tester);
  });

  testWidgets('modified : un livreur bouge, donnees Admin des autres conservees',
      (tester) async {
    final feed = await _pumpAdmin(tester);
    feed.emit(snap(
      [
        driver('a', name: 'Alice', lat: 6.70),
        driver('b', name: 'Bob', lat: 6.80),
        driver('c', name: 'Charlie', lat: 6.90),
      ],
      [
        added(driver('a', name: 'Alice', lat: 6.70)),
        added(driver('b', name: 'Bob', lat: 6.80)),
        added(driver('c', name: 'Charlie', lat: 6.90)),
      ],
    ));
    await tester.pumpAndSettle();
    final aBefore = markerById(tester, 'a');
    final cBefore = markerById(tester, 'c');

    feed.emit(snap(
      [
        driver('a', name: 'Alice', lat: 6.70),
        driver('b', name: 'Bob', lat: 7.25),
        driver('c', name: 'Charlie', lat: 6.90),
      ],
      [modified(driver('b', name: 'Bob', lat: 7.25))],
    ));
    await tester.pumpAndSettle();

    expect(markerIds(tester), {'a', 'b', 'c'});
    expect(markerById(tester, 'b')!.position.latitude, 7.25);
    // Markers non deplaces = non recreees (meme instance via le cache).
    expect(markerById(tester, 'a'), same(aBefore));
    expect(markerById(tester, 'c'), same(cBefore));
    // Donnees Admin conservees.
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Charlie'), findsOneWidget);

    await disposeAdmin(tester);
  });

  testWidgets('removed : marker et ligne Admin supprimes', (tester) async {
    final feed = await _pumpAdmin(tester);
    feed.emit(snap(
      [
        driver('a', name: 'Alice'),
        driver('b', name: 'Bob'),
        driver('c', name: 'Charlie'),
      ],
      [
        added(driver('a', name: 'Alice')),
        added(driver('b', name: 'Bob')),
        added(driver('c', name: 'Charlie')),
      ],
    ));
    await tester.pumpAndSettle();
    expect(markerIds(tester), {'a', 'b', 'c'});

    feed.emit(snap(
      [driver('a', name: 'Alice'), driver('b', name: 'Bob')],
      [removed(driver('c', name: 'Charlie'))],
    ));
    await tester.pumpAndSettle();

    expect(markerIds(tester), {'a', 'b'});
    expect(markerById(tester, 'c'), isNull);
    expect(find.text('Charlie'), findsNothing);
    expect(find.text('Alice'), findsOneWidget);

    await disposeAdmin(tester);
  });

  testWidgets(
      'coordonnees invalides : marker absent, ligne Admin conservee',
      (tester) async {
    final feed = await _pumpAdmin(tester);

    feed.emit(snap(
      [
        driver('a', name: 'Alice'),
        driver('b', name: 'Bob'),
        driver('c', name: 'Charlie', lat: null, lng: null),
      ],
      [
        added(driver('a', name: 'Alice')),
        added(driver('b', name: 'Bob')),
        added(driver('c', name: 'Charlie', lat: null, lng: null)),
      ],
    ));
    await tester.pumpAndSettle();

    expect(markerIds(tester), {'a', 'b'});
    expect(markerById(tester, 'c'), isNull);
    // Le livreur reste visible dans la liste Admin meme sans position.
    expect(find.text('Charlie'), findsOneWidget);

    // Un livreur valide perd sa position -> son marker disparait.
    feed.emit(snap(
      [
        driver('a', name: 'Alice', lat: null, lng: null),
        driver('b', name: 'Bob'),
      ],
      [modified(driver('a', name: 'Alice', lat: null, lng: null))],
    ));
    await tester.pumpAndSettle();
    expect(markerIds(tester), {'b'});
    expect(markerById(tester, 'a'), isNull);
    expect(find.text('Alice'), findsOneWidget);

    await disposeAdmin(tester);
  });

  testWidgets('dispose : emission post-destruction, aucune exception',
      (tester) async {
    final feed = await _pumpAdmin(tester);
    feed.emit(snap(
      [driver('a', name: 'Alice'), driver('b', name: 'Bob')],
      [added(driver('a', name: 'Alice')), added(driver('b', name: 'Bob'))],
    ));
    await tester.pumpAndSettle();
    expect(markerIds(tester), {'a', 'b'});

    await disposeAdmin(tester);
    expect(find.byType(AdminLiveTrackingPage), findsNothing);

    feed.emit(snap(
      [driver('a', name: 'Alice', lat: 7.9)],
      [modified(driver('a', name: 'Alice', lat: 7.9))],
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
  });

  testWidgets('aucun second listener sur le flux livreurs', (tester) async {
    final feed = await _pumpAdmin(tester);
    expect(feed.listenCount, 1);
    expect(feed.controller.hasListener, isTrue);

    feed.emit(snap([driver('a')], [added(driver('a'))]));
    await tester.pumpAndSettle();
    feed.emit(snap([driver('a'), driver('b')], [added(driver('b'))]));
    await tester.pumpAndSettle();

    expect(feed.listenCount, 1);
    expect(feed.controller.hasListener, isTrue);

    await disposeAdmin(tester);
  });
}
