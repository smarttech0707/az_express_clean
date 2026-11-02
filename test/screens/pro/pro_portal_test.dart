import 'dart:math' as math;

import 'package:az_express/event/screens/event_provider_portal.dart';
import 'package:az_express/screens/artisan/artisan_login.dart';
import 'package:az_express/screens/boulangerie/boulangerie_login.dart';
import 'package:az_express/screens/driver/driver_login.dart';
import 'package:az_express/screens/fleet/fleet_login.dart';
import 'package:az_express/screens/pharmacie/pharmacie_login.dart';
import 'package:az_express/screens/pro/pro_portal.dart';
import 'package:az_express/screens/restaurant/restaurant_owner_login.dart';
import 'package:az_express/screens/seller/seller_login.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

// Espace professionnel : huit accès conservés, trois catégories, routes
// inchangées, clair/sombre, petits écrans. Les pages de connexion ne sont pas
// montées (elles exigent Firebase) : on capture seulement la route poussée.

const _sizes = [Size(360, 640), Size(390, 844), Size(430, 932)];

class _Capture extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

Future<_Capture> _pump(WidgetTester tester,
    {Size size = const Size(390, 844),
    Brightness brightness = Brightness.light}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final capture = _Capture();
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
    navigatorObservers: [capture],
    home: const ProPortal(),
  ));
  await tester.pump();
  return capture;
}

double _contrast(Color a, Color b) {
  double lum(Color c) {
    double f(double v) => v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  }

  final l1 = lum(a), l2 = lum(b);
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

const _titles = [
  'Livreur',
  'Patron de Flotte',
  'Boutique / Vendeur',
  'Restaurant',
  'Pharmacie',
  'Boulangerie / Café',
  'Artisan / Mécanicien',
  'Prestataire événementiel',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  for (final size in _sizes) {
    for (final b in Brightness.values) {
      testWidgets('huit accès, trois catégories, sans overflow : $size $b',
          (tester) async {
        await _pump(tester, size: size, brightness: b);
        final list = find.byType(Scrollable).first;
        for (final t in _titles) {
          await tester.scrollUntilVisible(find.text(t), 120,
              scrollable: list);
          expect(find.text(t), findsOneWidget, reason: t);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('catégories dans l\'ordre demandé', (tester) async {
    await _pump(tester, size: const Size(430, 1400));
    double y(String s) => tester.getTopLeft(find.text(s)).dy;
    expect(y('LIVRAISON ET TRANSPORT'), lessThan(y('Livreur')));
    expect(y('Patron de Flotte'), lessThan(y('COMMERCE')));
    expect(y('COMMERCE'), lessThan(y('Boutique / Vendeur')));
    expect(y('Boulangerie / Café'), lessThan(y('SERVICES')));
    expect(y('SERVICES'), lessThan(y('Artisan / Mécanicien')));
    expect(y('Artisan / Mécanicien'),
        lessThan(y('Prestataire événementiel')));
    expect(find.text('Accès réservé aux partenaires'), findsOneWidget);
  });

  final routes = <String, Type>{
    'Livreur': DriverLogin,
    'Patron de Flotte': FleetLogin,
    'Boutique / Vendeur': SellerLogin,
    'Restaurant': RestaurantOwnerLogin,
    'Pharmacie': PharmacieLogin,
    'Boulangerie / Café': BoulangerieLogin,
    'Artisan / Mécanicien': ArtisanLogin,
    'Prestataire événementiel': EventProviderPortal,
  };
  routes.forEach((title, type) {
    testWidgets('« $title » ouvre la page de connexion de son rôle',
        (tester) async {
      final capture = await _pump(tester, size: const Size(430, 1400));
      await tester.tap(find.text(title));
      await tester.pump();
      // La page de connexion se monte réellement et exige Firebase : seule la
      // destination nous intéresse ici.
      tester.takeException();
      final route = capture.pushed.last as MaterialPageRoute;
      expect(route.builder(tester.element(find.byType(ProPortal).first)).runtimeType,
          type);
    });
  });

  for (final b in Brightness.values) {
    testWidgets('textes lisibles (≥ 4,5:1) sur les cartes : $b',
        (tester) async {
      await _pump(tester, size: const Size(430, 1400), brightness: b);
      final surface = AppColors.premiumSurface(b);
      for (final s in ['Livreur', 'Accès réservé aux partenaires']) {
        final style = tester.widget<Text>(find.text(s)).style!;
        final bg = s == 'Livreur' ? surface : AppColors.premiumBg(b);
        expect(_contrast(style.color!, bg), greaterThanOrEqualTo(4.5),
            reason: s);
      }
    });
  }

  testWidgets('zones tactiles ≥ 48 px et flèche de retour', (tester) async {
    await _pump(tester, size: const Size(360, 1400));
    for (final t in _titles) {
      final r = tester.getRect(find
          .ancestor(of: find.text(t), matching: find.byType(InkWell))
          .first);
      expect(r.height, greaterThanOrEqualTo(48), reason: t);
    }
    expect(find.byTooltip('Retour'), findsOneWidget);
  });
}
