import 'package:az_express/screens/admin/admin_security_dashboard.dart';
// ignore: depend_on_referenced_packages
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart'
    as platform;
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late platform.FirebaseFirestorePlatform original;
  final store = _Store();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    original = platform.FirebaseFirestorePlatform.instance;
    platform.FirebaseFirestorePlatform.instance = store;
  });
  tearDownAll(() => platform.FirebaseFirestorePlatform.instance = original);
  setUp(() {
    store.aggregateError = null;
    store.streamError = null;
    store.paths.clear();
    store.filters.clear();
  });
  Future<void> show(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 2400);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const MaterialApp(home: AdminSecurityDashboard()));
    await tester.pumpAndSettle();
  }

  testWidgets('loads real order-limit events without reading private counters',
      (tester) async {
    await show(tester);
    expect(store.paths, isNot(contains('rate_limits')));
    expect(store.filters, contains(contains('order_rate_limit_exceeded')));
    expect(find.text('Commandes limitées\n(1h)'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  final errors = <Object>[
    FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
        message: 'PRIVATE_DIAGNOSTIC'),
    PlatformException(
        code: 'firebase_firestore',
        message: 'PERMISSION_DENIED PRIVATE_DIAGNOSTIC'),
    FirebaseException(
        plugin: 'cloud_firestore',
        code: 'failed-precondition',
        message: 'PRIVATE_DIAGNOSTIC'),
  ];
  for (var i = 0; i < errors.length; i++) {
    testWidgets('aggregate error $i is safe and refresh recovers',
        (tester) async {
      store.aggregateError = errors[i];
      await show(tester);
      expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
      expect(
          find.text(i < 2
              ? 'Accès sécurité non autorisé ou règles non configurées.'
              : 'Impossible de charger les données de sécurité. Réessayez.'),
          findsOneWidget);
      store.aggregateError = null;
      await tester.tap(find.byTooltip('Actualiser'));
      await tester.pumpAndSettle();
      expect(find.text('Commandes limitées\n(1h)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'stream permission errors are not displayed as empty healthy logs',
      (tester) async {
    store.streamError = errors.first;
    await show(tester);
    expect(find.text('Accès sécurité non autorisé ou règles non configurées.'),
        findsNWidgets(3));
    expect(find.text('Aucun événement suspect'), findsNothing);
    expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _Store extends platform.FirebaseFirestorePlatform {
  Object? aggregateError;
  Object? streamError;
  final paths = <String>[];
  final filters = <String>[];
  @override
  platform.FirebaseFirestorePlatform delegateFor(
          {required FirebaseApp app, required String databaseId}) =>
      this;
  @override
  platform.CollectionReferencePlatform collection(String path) {
    paths.add(path);
    if (path == 'rate_limits') throw StateError('Server-only collection');
    return _Collection(this, path);
  }
}

class _Collection extends platform.CollectionReferencePlatform {
  _Collection(this.store, String path) : super(store, path) {
    parameters.addAll({
      'where': <List<dynamic>>[],
      'orderBy': <List<dynamic>>[],
      'limit': null,
      'limitToLast': null,
      'startAt': null,
      'startAfter': null,
      'endAt': null,
      'endBefore': null
    });
  }
  final _Store store;
  final queryFilters = <List<dynamic>>[];
  bool get orderLimit =>
      queryFilters.toString().contains('order_rate_limit_exceeded');
  @override
  platform.QueryPlatform where(List<List<dynamic>> conditions) {
    store.filters.add(conditions.toString());
    queryFilters.addAll(conditions);
    return this;
  }

  @override
  platform.QueryPlatform orderBy(Iterable<List<dynamic>> orders) => this;
  @override
  platform.QueryPlatform limit(int limit) => this;
  @override
  platform.AggregateQueryPlatform count() => _Count(this);
  @override
  Stream<platform.QuerySnapshotPlatform> snapshots(
          {bool includeMetadataChanges = false,
          required platform.ListenSource listenSource}) =>
      store.streamError != null
          ? Stream.error(store.streamError!)
          : Stream.value(platform.QuerySnapshotPlatform(
              [], [], platform.SnapshotMetadataPlatform(false, false)));
}

class _Count extends platform.AggregateQueryPlatform {
  _Count(this.collection) : super(collection);
  final _Collection collection;
  @override
  Future<platform.AggregateQuerySnapshotPlatform> get(
      {required platform.AggregateSource source}) async {
    if (collection.store.aggregateError case final error?) throw error;
    return platform.AggregateQuerySnapshotPlatform(
        count: collection.orderLimit ? 7 : 0, sum: [], average: []);
  }
}
