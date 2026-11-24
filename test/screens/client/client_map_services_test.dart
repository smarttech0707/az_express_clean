import 'dart:async';
import 'dart:math' as math;

import 'package:az_express/ekbine/screens/ek_home_screen.dart';
import 'package:az_express/event/screens/event_home_screen.dart';
import 'package:az_express/screens/client/client_map.dart';
import 'package:az_express/screens/client/courses_screen.dart';
import 'package:az_express/screens/client/livraison_screen.dart';
import 'package:az_express/screens/restaurant/restaurant_list.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:az_express/widgets/live_marker_cache.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Étape B de l'accueil client : les six cartes de services (Livraison en
// carte principale, Courses, Food, E-Kbine, Événementiel, Plus de services),
// leurs routes existantes, trois tailles de téléphone, débordements,
// contrastes et mode sombre. Aucun Firebase réel, aucun GPS réel.

const _sizes = [Size(360, 640), Size(390, 844), Size(430, 932)];

const _six = [
  'Livraison',
  'Courses',
  'Food',
  'E-Kbine',
  'Événementiel',
  'Plus de services',
];

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

Future<_Routes> _pump(
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
  routes.pushed.clear(); // ignore la route d'accueil
  return routes;
}

double _lum(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

double _contrast(Color a, Color b) {
  final l1 = _lum(a), l2 = _lum(b);
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

Color _textColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text).first).style!.color!;

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
    testWidgets('six cartes présentes, sans overflow, à $size', (tester) async {
      await _pump(tester, size);
      for (final label in _six) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // E-Kbine : icône de téléphone mobile (et non plus un portefeuille).
      expect(find.byIcon(Icons.phone_android_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('panneau agrandi : les six cartes sont atteignables à $size',
        (tester) async {
      await _pump(tester, size);
      await tester.dragFrom(
          Offset(size.width / 2, size.height * 0.7), Offset(0, -size.height));
      await tester.pumpAndSettle();
      for (final label in _six) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        expect(find.text(label).hitTestable(), findsOneWidget, reason: label);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Livraison est plus grande que les cartes secondaires',
      (tester) async {
    await _pump(tester, const Size(390, 844));
    final hero = tester.getSize(find
        .ancestor(
            of: find.text('Livraison'), matching: find.byType(AnimatedScale))
        .first);
    final tile = tester.getSize(find
        .ancestor(of: find.text('Food'), matching: find.byType(AnimatedScale))
        .first);
    expect(hero.width, greaterThan(tile.width * 1.6));
    expect(hero.height, greaterThan(tile.height));
  });

  testWidgets('les deux cartes d\'une même rangée ont la même hauteur',
      (tester) async {
    await _pump(tester, const Size(360, 640));
    Size of(String t) => tester.getSize(find
        .ancestor(of: find.text(t), matching: find.byType(AnimatedScale))
        .first);
    expect(of('Courses').height, of('Food').height);
    expect(of('E-Kbine').height, of('Événementiel').height);
  });

  group('routes existantes', () {
    final cases = <String, Type>{
      'Livraison': LivraisonScreen,
      'Courses': CoursesScreen,
      'Food': RestaurantList,
      'E-Kbine': EkHomeScreen,
      'Événementiel': EventHomeScreen,
    };
    cases.forEach((label, screen) {
      testWidgets('$label ouvre $screen', (tester) async {
        final routes = await _pump(tester, const Size(390, 844));
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        // Pas de pump : la route est poussée, son écran n'est pas construit.
        expect(routes.pushed, hasLength(1));
        final route = routes.pushed.single as MaterialPageRoute;
        expect(
            route.builder(tester.element(find.byType(ClientMap))).runtimeType,
            screen);
      });
    });

    testWidgets('Plus de services ouvre le menu avec les 13 services',
        (tester) async {
      await _pump(tester, const Size(390, 844));
      await tester.ensureVisible(find.text('Plus de services'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plus de services'));
      await tester.pumpAndSettle();
      for (final s in [
        'Boulangerie & Café',
        'Boutique',
        'Pharmacie',
        'Immobilier',
        'Taxi de nuit',
      ]) {
        expect(find.text(s), findsWidgets, reason: s);
      }
    });
  });

  group('contrastes', () {
    test('texte blanc de la carte principale ≥ 4,5:1 (repos et pressé)', () {
      for (final bg in [
        AppColors.primaryAction,
        AppColors.primaryActionPressed,
      ]) {
        expect(_contrast(Colors.white, bg), greaterThanOrEqualTo(4.5));
      }
    });

    test('titres, descriptions et icônes sur les cartes secondaires', () {
      final fills = {
        Brightness.light: AppColors.premiumBgLight,
        Brightness.dark: AppColors.premiumSurfaceElevatedDark,
      };
      fills.forEach((b, fill) {
        expect(_contrast(AppColors.premiumTextPrimary(b), fill),
            greaterThanOrEqualTo(4.5));
        expect(_contrast(AppColors.premiumTextSecondary(b), fill),
            greaterThanOrEqualTo(4.5));
      });
      // Accents (icônes : seuil 3:1 pour les composants d'interface).
      final accents = {
        Brightness.light: [
          AppColors.successStrong,
          AppColors.primaryAction,
          AppColors.blueAction,
          const Color(0xFF6D28D9),
        ],
        Brightness.dark: [
          const Color(0xFF4ADE80),
          AppColors.primary,
          AppColors.bluePremiumDark,
          const Color(0xFFA78BFA),
        ],
      };
      accents.forEach((b, list) {
        for (final c in list) {
          expect(_contrast(c, fills[b]!), greaterThanOrEqualTo(3.0),
              reason: '$b $c');
        }
      });
    });
  });

  group('mode sombre', () {
    testWidgets('textes des cartes clairs sur fond sombre, sans overflow',
        (tester) async {
      await _pump(tester, const Size(360, 640), theme: AppTheme.dark);
      expect(tester.takeException(), isNull);
      expect(_textColor(tester, 'Courses'),
          AppColors.premiumTextPrimary(Brightness.dark));
      expect(_textColor(tester, 'Livraison'), Colors.white);
      expect(
          _contrast(_textColor(tester, 'Courses'),
              AppColors.premiumSurfaceElevatedDark),
          greaterThanOrEqualTo(4.5));
    });

    testWidgets('mode clair : textes sombres', (tester) async {
      await _pump(tester, const Size(360, 640), theme: AppTheme.light);
      expect(_textColor(tester, 'Courses'),
          AppColors.premiumTextPrimary(Brightness.light));
    });
  });
}
