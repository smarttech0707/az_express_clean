import 'dart:async';
import 'dart:math' as math;

import 'package:az_express/ekbine/screens/ek_home_screen.dart';
import 'package:az_express/l10n/app_text.dart';
import 'package:az_express/screens/client/blanchisserie_page.dart';
import 'package:az_express/screens/client/boulangeries_list.dart';
import 'package:az_express/screens/client/boutique_page.dart';
import 'package:az_express/screens/client/client_map.dart';
import 'package:az_express/screens/client/colis_page.dart';
import 'package:az_express/screens/client/eau_boissons_page.dart';
import 'package:az_express/screens/client/pharmacie_garde.dart';
import 'package:az_express/screens/client/services_hub_page.dart';
import 'package:az_express/screens/client/simple_service_page.dart';
import 'package:az_express/screens/immobilier/immobilier_home_screen.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:az_express/widgets/live_marker_cache.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Étape C : menu « Plus de services » groupé en 4 catégories. Les 13 services
// d'origine restent atteignables par leurs routes existantes, E-Kbine y est un
// raccourci supplémentaire. Aucun Firebase réel, aucun GPS réel.

const _sizes = [Size(360, 640), Size(390, 844), Size(430, 932)];
const _fr = AppText(Locale('fr'));

String _t(String key) => _fr.t(key);

/// (catégorie, [clé de route, titre affiché, type de page attendu]).
final _expected = <String, List<(String, Type)>>{
  _t('plus_cat_commerce'): [
    (_t('boulangerie'), BoulangeriesList),
    (_t('boutique'), BoutiquePage),
    (_t('pharmacy'), PharmacieGardePage),
    (_t('cave'), SimpleServicePage),
    (_t('water'), EauBoissonsPage),
  ],
  _t('plus_cat_home'): [
    (_t('houses'), ImmobilierHomeScreen),
    (_t('furnished'), ImmobilierHomeScreen),
    (_t('real_estate'), ImmobilierHomeScreen),
  ],
  _t('plus_cat_daily'): [
    (_t('laundry'), BlanchisseriePage),
    (_t('parcel'), ColisPage),
    (_t('local_services'), ServicesHubPage),
  ],
  _t('plus_cat_transport'): [
    (_t('tricycle'), SimpleServicePage),
    (_t('night_taxi'), SimpleServicePage),
    ('E-Kbine', EkHomeScreen),
  ],
};

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

Future<_Routes> _openMenu(
  WidgetTester tester,
  Size size, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final feed = StreamController<LiveDriverSnapshot>();
  addTearDown(feed.close);
  final routes = _Routes();
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    navigatorObservers: [routes],
    home: ClientMap(driversFeed: () => feed.stream),
  ));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Plus de services'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Plus de services'));
  await tester.pumpAndSettle();
  routes.pushed.clear();
  return routes;
}

Finder _inMenu(String text) =>
    find.descendant(of: find.byType(BottomSheet), matching: find.text(text));

double _lum(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

double _contrast(Color a, Color b) {
  final l1 = _lum(a), l2 = _lum(b);
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
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

  test('les 4 catégories contiennent 14 entrées : 13 services + E-Kbine', () {
    final all = _expected.values.expand((e) => e).toList();
    expect(all, hasLength(14));
    expect(all.map((e) => e.$1).toSet(), hasLength(14));
  });

  for (final size in _sizes) {
    testWidgets('catégories, 14 entrées, sans overflow, tactile ≥ 48 à $size',
        (tester) async {
      await _openMenu(tester, size);
      for (final cat in _expected.keys) {
        expect(_inMenu(cat), findsOneWidget, reason: cat);
      }
      for (final entry in _expected.entries) {
        for (final (title, _) in entry.value) {
          final f = _inMenu(title);
          expect(f, findsOneWidget, reason: title);
          await tester.ensureVisible(f);
          await tester.pumpAndSettle();
          expect(f.hitTestable(), findsOneWidget, reason: title);
          final card = tester.getSize(
              find.ancestor(of: f, matching: find.byType(AnimatedScale)).first);
          expect(card.height, greaterThanOrEqualTo(48), reason: title);
          expect(card.width, greaterThanOrEqualTo(48), reason: title);
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('chaque service est rangé sous sa catégorie', (tester) async {
    await _openMenu(tester, const Size(390, 844));
    final titles = _expected.keys.toList();
    double y(String t) => tester.getTopLeft(_inMenu(t)).dy;
    for (var i = 0; i < titles.length; i++) {
      final lower = y(titles[i]);
      final upper = i + 1 < titles.length ? y(titles[i + 1]) : double.infinity;
      for (final (title, _) in _expected[titles[i]]!) {
        expect(y(title), greaterThan(lower), reason: title);
        expect(y(title), lessThan(upper), reason: title);
      }
    }
  });

  group('routes existantes', () {
    _expected.forEach((cat, items) {
      for (final (title, type) in items) {
        testWidgets('$title ouvre $type', (tester) async {
          final routes = await _openMenu(tester, const Size(390, 844));
          final f = _inMenu(title);
          await tester.ensureVisible(f);
          await tester.pumpAndSettle();
          await tester.tap(f);
          // Pas de pump : la route est poussée, son écran n'est pas construit.
          final pages = routes.pushed.whereType<MaterialPageRoute>().toList();
          expect(pages, hasLength(1));
          final built =
              pages.single.builder(tester.element(find.byType(ClientMap)));
          expect(built.runtimeType, type);
        });
      }
    });

    // Un service par test : la page poussée n'est jamais construite.
    Future<Widget> pageFor(WidgetTester tester, String title) async {
      final routes = await _openMenu(tester, const Size(390, 844));
      final f = _inMenu(title);
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      return routes.pushed
          .whereType<MaterialPageRoute>()
          .single
          .builder(tester.element(find.byType(ClientMap)));
    }

    testWidgets('Maisons : location de maison', (tester) async {
      final page = await pageFor(tester, _t('houses')) as ImmobilierHomeScreen;
      expect(page.initialPriceType, 'rent');
      expect(page.initialPropertyType, 'Maison');
    });

    testWidgets('Meublés : résidences meublées', (tester) async {
      final page =
          await pageFor(tester, _t('furnished')) as ImmobilierHomeScreen;
      expect(page.initialFurnished, isTrue);
      expect(page.initialPropertyType, 'Résidence meublée');
    });

    for (final (key, type) in [
      ('cave', 'cave'),
      ('tricycle', 'tricycle'),
      ('night_taxi', 'taxi_nuit'),
    ]) {
      testWidgets('$key : type de service $type', (tester) async {
        final page = await pageFor(tester, _t(key)) as SimpleServicePage;
        expect(page.serviceType, type);
      });
    }
  });

  group('ouverture et fermeture', () {
    testWidgets('croix : ferme le menu', (tester) async {
      await _openMenu(tester, const Size(390, 844));
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tap(find.byTooltip('Fermer'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('retour Android : ferme le menu sans quitter l\'accueil',
        (tester) async {
      await _openMenu(tester, const Size(390, 844));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(ClientMap), findsOneWidget);
    });

    testWidgets('appui hors du menu : le ferme', (tester) async {
      await _openMenu(tester, const Size(390, 844));
      await tester.tapAt(const Offset(195, 30));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('glisser le titre vers le bas : le ferme', (tester) async {
      await _openMenu(tester, const Size(390, 844));
      await tester.fling(
          find.text('Plus de services').last, const Offset(0, 500), 1500);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('après fermeture, le panneau reste déplaçable', (tester) async {
      await _openMenu(tester, const Size(390, 844));
      await tester.tap(find.byTooltip('Fermer'));
      await tester.pumpAndSettle();
      // Haut du panneau (et non d'une carte : le contenu est calé en bas).
      double panelTop() => tester
          .getTopLeft(find.descendant(
              of: find.byType(DraggableScrollableSheet),
              matching: find.byType(SingleChildScrollView)))
          .dy;
      // Le menu a demandé de faire défiler le contenu : on revient en haut,
      // où se trouve la poignée.
      tester
          .state<ScrollableState>(find.descendant(
              of: find.byType(DraggableScrollableSheet),
              matching: find.byType(Scrollable)))
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      final before = panelTop();
      await tester.tap(find.bySemanticsLabel(RegExp('Panneau des services')));
      await tester.pumpAndSettle();
      expect(panelTop(), lessThan(before));
      expect(tester.takeException(), isNull);
    });
  });

  group('mode sombre et contrastes', () {
    testWidgets('mode sombre : surface sombre, textes clairs, sans overflow',
        (tester) async {
      await _openMenu(tester, const Size(360, 640), theme: AppTheme.dark);
      expect(tester.takeException(), isNull);
      final sheet = tester.widget<Container>(find
          .descendant(
              of: find.byType(BottomSheet), matching: find.byType(Container))
          .first);
      final deco = sheet.decoration as BoxDecoration;
      expect(deco.color, AppColors.premiumSurfaceDark);
      final style = tester.widget<Text>(_inMenu(_t('boutique'))).style!;
      expect(style.color, AppColors.premiumTextPrimaryDark);
      expect(_contrast(style.color!, AppColors.premiumSurfaceElevatedDark),
          greaterThanOrEqualTo(4.5));
    });

    testWidgets('mode clair : surface claire, textes sombres', (tester) async {
      await _openMenu(tester, const Size(360, 640), theme: AppTheme.light);
      final style = tester.widget<Text>(_inMenu(_t('boutique'))).style!;
      expect(style.color, AppColors.premiumTextPrimaryLight);
    });

    test('contrastes des textes et accents de catégorie', () {
      const fills = {
        Brightness.light: AppColors.premiumBgLight,
        Brightness.dark: AppColors.premiumSurfaceElevatedDark,
      };
      fills.forEach((b, fill) {
        expect(_contrast(AppColors.premiumTextPrimary(b), fill),
            greaterThanOrEqualTo(4.5));
      });
      for (final c in [
        AppColors.primaryAction,
        AppColors.blueAction,
        AppColors.successStrong,
        AppColors.eventAccent,
      ]) {
        expect(_contrast(c, AppColors.premiumBgLight), greaterThanOrEqualTo(3));
      }
      for (final c in [
        AppColors.primary,
        AppColors.bluePremiumDark,
        const Color(0xFF4ADE80),
        AppColors.eventAccentDark,
      ]) {
        expect(_contrast(c, AppColors.premiumSurfaceElevatedDark),
            greaterThanOrEqualTo(3));
      }
    });
  });
}
