import 'package:az_express/event/screens/admin_event_screen.dart';
import 'package:az_express/partner_qr/partner_qr_page.dart';
import 'package:az_express/screens/admin/account_deletion_support_page.dart';
import 'package:az_express/screens/admin/admin_billing_reviews_page.dart';
import 'package:az_express/screens/admin/admin_menu.dart';
import 'package:az_express/screens/admin/admin_security_dashboard.dart';
import 'package:az_express/screens/admin/admin_service_requests_page.dart';
import 'package:az_express/screens/admin/admin_sub_admins_page.dart';
import 'package:az_express/screens/admin/admin_transfer_settlements_page.dart';
import 'package:az_express/screens/admin/admin_vehicle_moderation_page.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

// Réorganisation du menu admin : aucune page perdue, mêmes permissions que
// l'ancienne grille, entrées réservées au super-admin jamais montrées aux
// sous-admins (dont la carte QR, auparavant affichée à tous par une accolade
// manquante).

const _allPerms = [
  'livreurs', 'commandes', 'gains', 'classement', 'carte', 'zones', 'demandes',
  'restaurants', 'demandes_resto', 'demandes_vendeurs', 'demandes_boulangeries',
  'demandes_pharmacies', 'pharmacies', 'boutique', 'recharges', 'flottes',
  'locations', 'residences', 'services', 'eventiel', 'tricycle', 'sos',
  'anti_fraude', 'cash_marchand', 'support', 'ai_dashboard', 'boulangeries',
  'ekbine', 'purger',
];

const _superOnly = {
  'deletions', 'vehicles', 'partner_qr', 'transfers', 'billing', 'sub_admins',
  'security',
};

List<AdminMenuItem> _items(bool isSuper, List<String> perms) => [
      for (final c in buildAdminMenu(isSuper: isSuper, permissions: perms))
        ...c.items,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  test('super-admin : 8 catégories, 41 fonctions, identifiants uniques', () {
    final cats = buildAdminMenu(isSuper: true, permissions: const []);
    expect(cats.map((c) => c.title), [
      'Tableau de bord et statistiques',
      'Commandes et livraisons',
      'Livreurs et flottes',
      'Partenaires et commerces',
      'Centre de demandes',
      'Finances',
      'Services',
      'Paramètres et sécurité',
    ]);
    final ids = _items(true, const []).map((i) => i.id).toList();
    expect(ids.length, 41);
    expect(ids.toSet().length, ids.length);
  });

  test('aucune page de l\'ancienne grille n\'a disparu', () {
    final types = _items(true, const [])
        .map((i) => i.page().runtimeType.toString())
        .toList();
    expect(types.toSet().length, 41, reason: 'une page distincte par entrée');
    for (final required in [
      'AdminOrders', 'AdminMap', 'AdminLiveTrackingPage', 'AdminRechargePage',
      'AdminPharmaciesPage', 'DriverRequestsPage',
      'AdminRestaurantRequestsPage', 'AdminSellerRequestsPage',
      'AdminBoulangerieRequestsPage', 'AdminPharmacieRequestsPage',
      'AdminEarnings', 'AdminCommissionsPage', 'AdminTransferSettlementsPage',
      'AdminCashSettlementPage', 'DriversPage', 'AdminFleetPage',
      'AdminEkbinePage', 'AdminPurgePage', 'AdminSosPage',
    ]) {
      expect(types, contains(required));
    }
  });

  test('Centre de demandes : les cinq catégories existantes + prestataires',
      () {
    final c = buildAdminMenu(isSuper: true, permissions: const [])
        .firstWhere((c) => c.id == 'requests');
    expect(c.items.map((i) => i.page().runtimeType.toString()), [
      'DriverRequestsPage',
      'AdminRestaurantRequestsPage',
      'AdminSellerRequestsPage',
      'AdminBoulangerieRequestsPage',
      'AdminPharmacieRequestsPage',
      'AdminServiceRequestsPage',
    ]);
  });

  test('Recharges : accès au menu principal conservé (Finances)', () {
    final fin = buildAdminMenu(isSuper: true, permissions: const [])
        .firstWhere((c) => c.id == 'finance');
    expect(fin.items.map((i) => i.id), contains('recharges'));
  });

  test('sous-admin avec toutes les permissions : jamais les entrées super',
      () {
    final ids = _items(false, _allPerms).map((i) => i.id).toSet();
    expect(ids.intersection(_superOnly), isEmpty);
    expect(ids.length, 41 - _superOnly.length);
  });

  test('carte QR des établissements : réservée au super-admin', () {
    expect(_items(false, _allPerms).map((i) => i.id),
        isNot(contains('partner_qr')));
    expect(_items(false, const []).map((i) => i.id),
        isNot(contains('partner_qr')));
    final qr = _items(true, const []).firstWhere((i) => i.id == 'partner_qr');
    expect(qr.page(), isA<AdminPartnerQrPage>());
  });

  test('entrées super-admin : bonnes pages', () {
    final byId = {for (final i in _items(true, const [])) i.id: i.page()};
    expect(byId['deletions'], isA<AccountDeletionSupportPage>());
    expect(byId['vehicles'], isA<AdminVehicleModerationPage>());
    expect(byId['transfers'], isA<AdminTransferSettlementsPage>());
    expect(byId['billing'], isA<AdminBillingReviewsPage>());
    expect(byId['sub_admins'], isA<AdminSubAdminsPage>());
    expect(byId['security'], isA<AdminSecurityDashboard>());
    expect(byId['events'], isA<AdminEventScreen>());
    expect(byId['req_providers'], isA<AdminServiceRequestsPage>());
  });

  test('sous-admin limité : seulement ses permissions, catégories vides masquées',
      () {
    final perms = ['livreurs', 'commandes'];
    expect(_items(false, perms).map((i) => i.id).toSet(), {'drivers', 'orders'});
    expect(buildAdminMenu(isSuper: false, permissions: perms).map((c) => c.id),
        ['orders', 'drivers']);
    expect(buildAdminMenu(isSuper: false, permissions: const []), isEmpty);
  });

  Future<void> pump(WidgetTester tester,
      {bool isSuper = true,
      List<String> perms = const [],
      Brightness b = Brightness.light,
      Size size = const Size(360, 640)}) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: b == Brightness.light ? AppTheme.light : AppTheme.dark,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: AdminMenu(isSuper: isSuper, permissions: perms),
        ),
      ),
    ));
    await tester.pump();
  }

  for (final b in Brightness.values) {
    testWidgets('catégories visibles, sans overflow ($b, 360x640)',
        (tester) async {
      await pump(tester, b: b);
      expect(find.text('Tableau de bord et statistiques'), findsOneWidget);
      expect(find.text('Commandes et livraisons'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('une catégorie se déplie et montre ses fonctions',
      (tester) async {
    await pump(tester);
    expect(find.text('Carte live'), findsNothing);
    await tester.tap(find.text('Commandes et livraisons'));
    await tester.pumpAndSettle();
    expect(find.text('Carte live'), findsOneWidget);
    expect(find.text('Tracking Live'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('la recherche trouve une fonction dans toutes les catégories',
      (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'recharge');
    await tester.pumpAndSettle();
    expect(find.text('Recharges'), findsOneWidget);
    expect(find.text('Finances'), findsOneWidget);
    expect(find.text('Commandes et livraisons'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.text('Aucune fonction ne correspond.'), findsOneWidget);

    await tester.tap(find.byTooltip('Effacer'));
    await tester.pumpAndSettle();
    expect(find.text('Commandes et livraisons'), findsOneWidget);
  });

  testWidgets('sous-admin : la recherche ne révèle pas les fonctions super',
      (tester) async {
    await pump(tester, isSuper: false, perms: _allPerms);
    await tester.enterText(find.byType(TextField), 'QR');
    await tester.pumpAndSettle();
    expect(find.text('QR des établissements'), findsNothing);
  });
}
