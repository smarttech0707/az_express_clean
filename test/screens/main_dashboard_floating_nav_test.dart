import 'package:az_express/l10n/app_text.dart';
import 'package:az_express/screens/main_dashboard.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

// ─────────────────────────────────────────────────────────────────────────
// LOT 3 — restyle de `_FloatingNav` (habillage uniquement, logique des
// onglets/Navigator/auth inchangée). `MainDashboard` complet nécessite
// Firebase Auth/Firestore/GoogleMap (via `ClientMap`, page 0) — hors de
// portée sans mocks dédiés (voir doc de `buildFloatingNavForTest`) ; ce
// fichier teste donc directement `_FloatingNav`, la seule pièce réellement
// restylée par ce lot dans `main_dashboard.dart`.
// ─────────────────────────────────────────────────────────────────────────

const _fr = AppText(Locale('fr'));

Future<Container> _pumpNavAndGetSurface(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  int currentIndex = 0,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
    home: Scaffold(
      bottomNavigationBar: buildFloatingNavForTest(
        currentIndex: currentIndex,
        text: _fr,
      ),
    ),
  ));
  await tester.pump();
  // Le second Container du widget (le premier n'a qu'un padding
  // transparent) porte la décoration de la "pilule" flottante.
  return tester.widgetList<Container>(find.byType(Container)).elementAt(1);
}

void main() {
  // `AppTheme.light`/`.dark` appellent `GoogleFonts.urbanist(...)` — réseau
  // indisponible dans cet environnement de test (même contournement que
  // test/theme/app_theme_test.dart), purement pour éviter une tentative de
  // téléchargement, sans rapport avec les assertions de ce fichier.
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  testWidgets('clair : surface premium blanche, bordure discrète',
      (tester) async {
    final container = await _pumpNavAndGetSurface(tester);
    final deco = container.decoration as BoxDecoration;
    expect(deco.color, AppColors.premiumSurfaceLight);
    expect(deco.border, isNotNull);
    expect(deco.boxShadow, AppShadow.navFloat);
  });

  testWidgets('sombre : surface bleu nuit premium (jamais blanc en dur)',
      (tester) async {
    final container =
        await _pumpNavAndGetSurface(tester, brightness: Brightness.dark);
    final deco = container.decoration as BoxDecoration;
    expect(deco.color, AppColors.premiumSurfaceDark);
    expect(deco.color, isNot(Colors.white));
  });

  testWidgets('onglet actif = orange AZ, quel que soit le thème',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        bottomNavigationBar:
            buildFloatingNavForTest(currentIndex: 0, text: _fr),
      ),
    ));
    await tester.pump();

    final icon = tester.widget<Icon>(find.byIcon(Icons.home_rounded));
    expect(icon.color, AppColors.primary);
  });

  testWidgets('les 5 éléments (4 onglets + bouton Commander) sont présents',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        bottomNavigationBar:
            buildFloatingNavForTest(currentIndex: 0, text: _fr),
      ),
    ));
    await tester.pump();

    expect(find.text('Accueil'), findsOneWidget);
    expect(find.text('Djassa'), findsOneWidget);
    expect(find.text('Suivi'), findsOneWidget);
    expect(find.text('Profil'), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget); // Commander
  });

  testWidgets(
      'tap sur un onglet déclenche bien le callback (logique '
      'inchangée)', (tester) async {
    int? tapped;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        bottomNavigationBar: buildFloatingNavForTest(
          currentIndex: 0,
          text: _fr,
          onTap: (i) => tapped = i,
        ),
      ),
    ));
    await tester.tap(find.text('Djassa'));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('320px de large : aucun overflow, light et dark', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          bottomNavigationBar:
              buildFloatingNavForTest(currentIndex: 0, text: _fr),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });
}
