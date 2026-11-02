import 'dart:math' as math;

import 'package:az_express/l10n/app_text.dart';
import 'package:az_express/screens/main_dashboard.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:az_express/widgets/tap_effect.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

// Étape D : barre de navigation inférieure premium — cinq accès inchangés,
// indicateur d'onglet actif, bouton central, clair/sombre, tailles de
// téléphone et zones de sécurité. `_FloatingNav` est testé isolément (voir
// `buildFloatingNavForTest`) : `MainDashboard` complet exige Firebase + carte.

const _fr = AppText(Locale('fr'));
const _sizes = [Size(360, 640), Size(390, 844), Size(430, 932)];
const _tabs = ['Accueil', 'Djassa', 'Suivi', 'Profil'];

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

Future<void> _pumpNav(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
  int currentIndex = 0,
  double safeBottom = 0,
  ValueChanged<int>? onTap,
  VoidCallback? onCommander,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  tester.view.padding = FakeViewPadding(bottom: safeBottom * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
    home: Scaffold(
      bottomNavigationBar: buildFloatingNavForTest(
        currentIndex: currentIndex,
        text: _fr,
        onTap: onTap,
        onCommander: onCommander,
      ),
    ),
  ));
  await tester.pump();
}

Finder _barSurface() => find.byWidgetPredicate((w) =>
    w is Container &&
    w.decoration is BoxDecoration &&
    (w.decoration! as BoxDecoration).boxShadow == AppShadow.navFloat);

Finder _commanderBox() => find
    .ancestor(
        of: find.byIcon(Icons.add_rounded), matching: find.byType(Container))
    .first;

TextStyle _label(WidgetTester tester, String text) => tester
    .widget<AnimatedDefaultTextStyle>(find
        .ancestor(
            of: find.text(text),
            matching: find.byType(AnimatedDefaultTextStyle))
        .first)
    .style;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  for (final size in _sizes) {
    for (final b in Brightness.values) {
      testWidgets('cinq accès, sans overflow, zone de sécurité : $size $b',
          (tester) async {
        await _pumpNav(tester, size: size, brightness: b, safeBottom: 34);
        for (final label in _tabs) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.bySemanticsLabel('Commander'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // La barre reste au-dessus de la zone de sécurité (geste système)
        // et à l'intérieur de l'écran (encoches latérales comprises).
        final bar = tester.getRect(_barSurface());
        expect(bar.bottom, lessThanOrEqualTo(size.height - 34));
        expect(bar.left, greaterThanOrEqualTo(0));
        expect(bar.right, lessThanOrEqualTo(size.width));
      });
    }
  }

  testWidgets('chaque onglet renvoie son index, Commander son callback',
      (tester) async {
    final taps = <int>[];
    var commander = 0;
    await _pumpNav(tester, onTap: taps.add, onCommander: () => commander++);
    for (final label in _tabs) {
      await tester.tap(find.text(label));
    }
    expect(taps, [0, 1, 2, 3]);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump(const Duration(milliseconds: 50));
    expect(commander, 1);
  });

  for (final b in Brightness.values) {
    testWidgets('indicateur : seul l\'onglet actif a une pastille ($b)',
        (tester) async {
      await _pumpNav(tester, brightness: b, currentIndex: 2);
      double pillAlpha(IconData icon) {
        final c = tester.widget<AnimatedContainer>(find
            .ancestor(
                of: find.byIcon(icon), matching: find.byType(AnimatedContainer))
            .first);
        return ((c.decoration! as BoxDecoration).color ?? Colors.transparent).a;
      }

      expect(pillAlpha(Icons.receipt_long_rounded), greaterThan(0));
      expect(pillAlpha(Icons.home_outlined), 0);
      expect(pillAlpha(Icons.storefront_outlined), 0);
      expect(pillAlpha(Icons.person_outline_rounded), 0);

      expect(_label(tester, 'Suivi').fontWeight, FontWeight.w700);
      expect(_label(tester, 'Profil').fontWeight, FontWeight.w500);
    });

    testWidgets('libellés actif et inactif lisibles ≥ 4,5:1 ($b)',
        (tester) async {
      await _pumpNav(tester, brightness: b);
      final surface = AppColors.premiumSurface(b);
      expect(_contrast(_label(tester, 'Accueil').color!, surface),
          greaterThanOrEqualTo(4.5));
      expect(_contrast(_label(tester, 'Profil').color!, surface),
          greaterThanOrEqualTo(4.5));
    });
  }

  testWidgets('bouton central : orange d\'action, « + » ≥ 4,5:1, ≥ 48 px',
      (tester) async {
    for (final size in _sizes) {
      await _pumpNav(tester, size: size);
      final deco = tester.widget<Container>(_commanderBox()).decoration!
          as BoxDecoration;
      final colors = (deco.gradient! as LinearGradient).colors;
      expect(colors, [
        AppColors.primaryActionLight,
        AppColors.primaryAction,
      ]);
      for (final c in colors) {
        expect(_contrast(Colors.white, c), greaterThanOrEqualTo(4.5));
      }
      final rect = tester.getRect(_commanderBox());
      expect(rect.width, greaterThanOrEqualTo(48));
      expect(rect.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('zones tactiles des quatre onglets ≥ 48 px sur 360×640',
      (tester) async {
    await _pumpNav(tester, size: const Size(360, 640));
    for (final label in _tabs) {
      final r = tester.getRect(find
          .ancestor(of: find.text(label), matching: find.byType(TapEffect))
          .first);
      expect(r.width, greaterThanOrEqualTo(48), reason: label);
      expect(r.height, greaterThanOrEqualTo(48), reason: label);
    }
  });

  testWidgets('surface : claire en mode clair, bleu nuit en mode sombre',
      (tester) async {
    await _pumpNav(tester);
    expect(
        (tester.widget<Container>(_barSurface()).decoration! as BoxDecoration)
            .color,
        AppColors.premiumSurfaceLight);
    await _pumpNav(tester, brightness: Brightness.dark);
    await tester.pumpAndSettle(); // transition de thème
    expect(
        (tester.widget<Container>(_barSurface()).decoration! as BoxDecoration)
            .color,
        AppColors.premiumSurfaceDark);
  });
}
