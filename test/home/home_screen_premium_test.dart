import 'package:az_express/l10n/app_text.dart';
import 'package:az_express/screens/home/home_screen.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:az_express/widgets/premium_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

// ─────────────────────────────────────────────────────────────────────────
// LOT 3 — refonte visible de HomeScreen. Complète (sans les remplacer)
// test/home/home_screen_responsive_test.dart, déjà vert avant et après ce
// lot (structure `CustomScrollView`/texte 'E-Kbine Services' inchangés).
// ─────────────────────────────────────────────────────────────────────────

Future<void> _pumpHome(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(AppLanguage(
    locale: const Locale('fr'),
    onLocaleChanged: (_) {},
    child: MaterialApp(
      theme: brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: const HomeScreen(),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  testWidgets('clair : fond PremiumBackground (#FAFAF8), aucun overflow',
      (tester) async {
    await _pumpHome(tester);

    expect(find.byType(PremiumBackground), findsOneWidget);
    final container = tester.widget<Container>(find.byType(Container).first);
    final gradient =
        (container.decoration as BoxDecoration).gradient as LinearGradient;
    expect(gradient.colors.first, AppColors.premiumBgLight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sombre : fond PremiumBackground (#0B1220), aucun overflow',
      (tester) async {
    await _pumpHome(tester, brightness: Brightness.dark);

    expect(find.byType(PremiumBackground), findsOneWidget);
    final container = tester.widget<Container>(find.byType(Container).first);
    final gradient =
        (container.decoration as BoxDecoration).gradient as LinearGradient;
    expect(gradient.colors.first, AppColors.premiumBgDark);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'les deux cartes de service restent atteignables au scroll '
      '(structure conservée)', (tester) async {
    await _pumpHome(tester);
    await tester.scrollUntilVisible(
      find.text('E-Kbine Services'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('E-Kbine Services'), findsOneWidget);
    expect(find.text('Commander'), findsWidgets); // titre de la carte
    expect(tester.takeException(), isNull);
  });

  testWidgets('LOT 3.2 : halo hero statique et séparation locale des cartes',
      (tester) async {
    await _pumpHome(tester);

    final halo = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('home-hero-ambient-halo')),
    );
    expect((halo.decoration as BoxDecoration).gradient, isA<RadialGradient>());
    expect(find.byType(BackdropFilter), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('home-service-card-elevated')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    for (final key in const [
      ValueKey('home-service-card-elevated'),
      ValueKey('home-service-card-standard'),
    ]) {
      final card = tester.widget<Container>(find.byKey(key));
      final decoration = card.decoration as BoxDecoration;
      expect(decoration.boxShadow, hasLength(1));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('320px de large, light et dark : aucun overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final brightness in [Brightness.light, Brightness.dark]) {
      await _pumpHome(tester, brightness: brightness);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('E-Kbine Services'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    }
  });
}
