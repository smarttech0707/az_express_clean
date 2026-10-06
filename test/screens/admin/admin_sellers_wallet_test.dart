import 'package:az_express/screens/admin/admin_sellers_page.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
// ignore: depend_on_referenced_packages
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart'
    as platform;
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _payload({bool create = false}) => buildSellerProfileData(
      isCreating: create,
      name: 'Boutique modifiée',
      phone: '0700000000',
      type: 'boutique',
      isActive: true,
      latitude: 6.7273,
      longitude: -3.4961,
    );

const _profileKeys = {'name', 'phone', 'type', 'isActive', 'lat', 'lng'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SellerStore store;
  late platform.FirebaseFirestorePlatform originalPlatform;

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    originalPlatform = platform.FirebaseFirestorePlatform.instance;
    store = _SellerStore();
    platform.FirebaseFirestorePlatform.instance = store;
  });
  tearDownAll(() {
    platform.FirebaseFirestorePlatform.instance = originalPlatform;
  });

  test('CREATE initialise uniquement wallet à zéro, sans crédit initial', () {
    final data = _payload(create: true);
    expect(data['wallet'], 0);
    expect(data['createdAt'], isA<FieldValue>());
    expect(data.keys.toSet(), {..._profileKeys, 'wallet', 'createdAt'});
  });

  for (final field in ['wallet', 'walletBalance', 'balance']) {
    test('UPDATE omet complètement $field', () {
      expect(_payload().containsKey(field), isFalse);
    });
  }

  test('UPDATE contient exclusivement les six champs du formulaire', () {
    expect(_payload(), {
      'name': 'Boutique modifiée',
      'phone': '0700000000',
      'type': 'boutique',
      'isActive': true,
      'lat': 6.7273,
      'lng': -3.4961,
    });
  });

  test('UPDATE préserve aussi la date de création du vendeur', () {
    expect(_payload().containsKey('createdAt'), isFalse);
  });

  Future<void> openEditor(WidgetTester tester, num balance) async {
    store.seed(balance);
    // Diagnostic visuel préexistant du SwitchListTile, hors correctif wallet.
    // On le comptabilise explicitement ; toute autre erreur reste fatale.
    final previousErrorHandler = FlutterError.onError;
    var knownVisualDiagnostics = 0;
    FlutterError.onError = (details) {
      if (details.exception is FlutterError &&
          details.exceptionAsString().startsWith(
              'ListTile background color or ink splashes may be invisible.')) {
        knownVisualDiagnostics++;
      } else {
        previousErrorHandler!(details);
      }
    };
    addTearDown(() {
      FlutterError.onError = previousErrorHandler;
      expect(knownVisualDiagnostics, greaterThan(0),
          reason: 'retirer cette attente lorsque le défaut visuel sera corrigé');
    });
    await tester.pumpWidget(const MaterialApp(home: AdminSellersPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Modifier'));
    await tester.pumpAndSettle();
    expect(find.text('Modifier vendeur'), findsOneWidget);
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, 'Enregistrer'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Vendeur modifié'), findsOneWidget);
    // Le vrai _save() doit produire une seule écriture, limitée au profil.
    expect(store.writes, hasLength(1));
    expect(store.writes.single.keys.toSet(), _profileKeys);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  for (final balance in <num>[5000, 0, 12735, 12735.5]) {
    testWidgets('édition réelle du nom conserve exactement wallet=$balance',
        (tester) async {
      await openEditor(tester, balance);
      await tester.enterText(find.byType(TextField).first, 'Nouveau nom');
      await save(tester);
      expect(store.server['name'], 'Nouveau nom');
      expect(store.server['wallet'], balance);
      expect(store.server['wallet'].runtimeType, balance.runtimeType);
    });
  }

  testWidgets('édition réelle des coordonnées conserve le wallet',
      (tester) async {
    await openEditor(tester, 5000);
    await tester.enterText(find.byType(TextField).at(2), '7.1');
    await tester.enterText(find.byType(TextField).at(3), '-3.2');
    await save(tester);
    expect(store.server['lat'], 7.1);
    expect(store.server['lng'], -3.2);
    expect(store.server['wallet'], 5000);
  });

  testWidgets('adresse modifiée sur le serveur conservée avec le wallet',
      (tester) async {
    await openEditor(tester, 5000);
    // Cet écran n'édite pas l'adresse : on vérifie sa préservation, sans
    // inventer un nouveau champ de formulaire pour les besoins du test.
    store.server['address'] = 'Nouvelle adresse';
    await save(tester);
    expect(store.server['address'], 'Nouvelle adresse');
    expect(store.server['wallet'], 5000);
    expect(store.writes.single.containsKey('address'), isFalse);
  });

  testWidgets('aucune transaction créée ni supprimée lors de l\'édition',
      (tester) async {
    await openEditor(tester, 5000);
    final transactions = Map<String, Object>.from(store.transactions);
    await save(tester);
    expect(store.transactions, transactions);
    // Toute autre collection, sous-collection, suppression, update ou batch
    // échoue dans ce faux transport : rien ne peut être silencieusement ignoré.
    expect(store.collectionPaths, everyElement('sellers'));
  });

  testWidgets('autres champs financiers et abonnement restent intacts',
      (tester) async {
    await openEditor(tester, 5000);
    final untouched = Map<String, dynamic>.from(store.server)
      ..removeWhere((key, _) => _profileKeys.contains(key));
    await save(tester);
    for (final entry in untouched.entries) {
      expect(store.server[entry.key], entry.value, reason: entry.key);
    }
  });

  testWidgets('T0 lu 5000, T1 crédit 2000, T2 édition : solde 7000',
      (tester) async {
    await openEditor(tester, 5000);
    // L'écran possède déjà son snapshot à 5000. Le serveur change ensuite.
    store.server['wallet'] = 7000;
    await tester.enterText(find.byType(TextField).first, 'Après crédit');
    await save(tester);
    expect(store.server['wallet'], 7000);
    expect(store.server['name'], 'Après crédit');
  });
}

/// Transport intégralement en mémoire. Aucun SDK natif, réseau ou émulateur.
/// Seule l'écriture merge du document vendeur est autorisée ; les opérations
/// non implémentées lèvent une erreur au lieu de simuler un succès.
class _SellerStore extends platform.FirebaseFirestorePlatform {
  final server = <String, dynamic>{};
  final transactions = <String, Object>{};
  final writes = <Map<String, dynamic>>[];
  final collectionPaths = <String>[];

  void seed(num wallet) {
    server
      ..clear()
      ..addAll({
        ..._payload(),
        'name': 'Ancien nom',
        'wallet': wallet,
        'walletBalance': 321,
        'balance': 123,
        'address': 'Adresse existante',
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(1000),
        'subscriptionStatus': 'active',
        'subscriptionExpiresAt': Timestamp.fromMillisecondsSinceEpoch(9000),
        'vipStatus': 'none',
        'vipExpiresAt': null,
        'vipStartedAt': null,
        'plan': 'standard',
        'priorityLevel': 1,
        'paymentStatus': 'paid',
        // Sentinelles de non-écrasement, sans supposer leur usage en production.
        'earnings': 9000,
        'commissions': 250,
      });
    transactions
      ..clear()
      ..addAll({'credit-existant': 5000, 'debit-existant': -250});
    writes.clear();
    collectionPaths.clear();
  }

  @override
  platform.FirebaseFirestorePlatform delegateFor({
    required FirebaseApp app,
    required String databaseId,
  }) => this;

  @override
  platform.CollectionReferencePlatform collection(String collectionPath) {
    collectionPaths.add(collectionPath);
    expect(collectionPath, 'sellers');
    return _Sellers(this);
  }
}

class _Sellers extends platform.CollectionReferencePlatform {
  _Sellers(this.store) : super(store, 'sellers') {
    parameters.addAll({
      'where': <List<dynamic>>[],
      'orderBy': <List<dynamic>>[],
      'limit': null,
      'limitToLast': null,
      'startAt': null,
      'startAfter': null,
      'endAt': null,
      'endBefore': null,
    });
  }
  final _SellerStore store;

  @override
  platform.QueryPlatform orderBy(Iterable<List<dynamic>> orders) => this;

  @override
  Stream<platform.QuerySnapshotPlatform> snapshots({
    bool includeMetadataChanges = false,
    required platform.ListenSource listenSource,
  }) => Stream.value(platform.QuerySnapshotPlatform([
        platform.DocumentSnapshotPlatform(
          store,
          'sellers/test-seller',
          Map<String, dynamic>.from(store.server),
          platform.InternalSnapshotMetadata(
            hasPendingWrites: false,
            isFromCache: false,
          ),
        ),
      ], [], platform.SnapshotMetadataPlatform(false, false)));

  @override
  platform.DocumentReferencePlatform doc([String? path]) {
    expect(path, 'test-seller');
    return _SellerDocument(store);
  }
}

class _SellerDocument extends platform.DocumentReferencePlatform {
  _SellerDocument(this.store) : super(store, 'sellers/test-seller');
  final _SellerStore store;

  @override
  Stream<platform.DocumentSnapshotPlatform> snapshots({
    bool includeMetadataChanges = false,
    required platform.ListenSource listenSource,
  }) => Stream.value(platform.DocumentSnapshotPlatform(
        store,
        path,
        Map<String, dynamic>.from(store.server),
        platform.InternalSnapshotMetadata(
          hasPendingWrites: false,
          isFromCache: false,
        ),
      ));

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    expect(options?.merge, isTrue);
    store.writes.add(Map<String, dynamic>.from(data));
    store.server.addAll(data);
  }
}
