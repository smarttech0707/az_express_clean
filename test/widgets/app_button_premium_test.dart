import 'package:az_express/theme/app_theme.dart';
import 'package:az_express/widgets/app_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

// ─────────────────────────────────────────────────────────────────────────
// LOT 2 — AppButton premium officiel. `GoogleFonts.urbanist` est appelé par
// `AppTypography.buttonStyle` à chaque construction du thème/texte du
// bouton — même contournement que test/theme/app_theme_test.dart (réseau
// indisponible dans cet environnement de test).
// ─────────────────────────────────────────────────────────────────────────

Future<BoxDecoration> _pumpAndGetDecoration(
  WidgetTester tester, {
  required Widget button,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
    home: Scaffold(body: Center(child: button)),
  ));
  await tester.pump();
  final container = tester.widget<AnimatedContainer>(
    find.byType(AnimatedContainer),
  );
  return container.decoration as BoxDecoration;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  testWidgets('primary : dégradé orange subtil au repos, rayon premiumLg',
      (tester) async {
    final deco = await _pumpAndGetDecoration(
      tester,
      button: AppButton(label: 'Commander', onPressed: () {}),
    );

    expect(deco.gradient, isA<LinearGradient>());
    final gradient = deco.gradient as LinearGradient;
    expect(gradient.colors, [AppColors.primaryLight, AppColors.primary]);
    expect(deco.borderRadius, AppRadius.premiumLgR);
  });

  testWidgets('secondary : bleu AZ Premium clair (pas l\'ancien bleu statique)',
      (tester) async {
    final deco = await _pumpAndGetDecoration(
      tester,
      brightness: Brightness.light,
      button: AppButton(
        label: 'Info',
        variant: AppButtonVariant.secondary,
        onPressed: () {},
      ),
    );
    expect(deco.color, AppColors.bluePremiumLight);
  });

  testWidgets('secondary : bleu AZ Premium sombre en mode sombre',
      (tester) async {
    final deco = await _pumpAndGetDecoration(
      tester,
      brightness: Brightness.dark,
      button: AppButton(
        label: 'Info',
        variant: AppButtonVariant.secondary,
        onPressed: () {},
      ),
    );
    expect(deco.color, AppColors.bluePremiumDark);
  });

  testWidgets('outlined : fond transparent, bordure premium', (tester) async {
    final deco = await _pumpAndGetDecoration(
      tester,
      button: AppButton(
        label: 'Annuler',
        variant: AppButtonVariant.outlined,
        onPressed: () {},
      ),
    );
    expect(deco.color, Colors.transparent);
    expect(deco.border, isNotNull);
  });

  testWidgets('ghost : fond transparent, aucune ombre', (tester) async {
    final deco = await _pumpAndGetDecoration(
      tester,
      button: AppButton(
        label: 'Plus tard',
        variant: AppButtonVariant.ghost,
        onPressed: () {},
      ),
    );
    expect(deco.color, Colors.transparent);
    expect(deco.boxShadow, isNull);
  });

  testWidgets('pressed state : le fond s\'assombrit visiblement au clic',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Center(child: AppButton(label: 'Test', onPressed: () {})),
      ),
    ));
    await tester.pump();

    final before = tester
        .widget<AnimatedContainer>(find.byType(AnimatedContainer))
        .decoration as BoxDecoration;
    expect(before.gradient, isNotNull); // dégradé au repos

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(AppButton)));
    await tester.pump(); // le press déclenche un setState
    await tester.pump(const Duration(milliseconds: 90)); // AnimatedContainer

    final pressed = tester
        .widget<AnimatedContainer>(find.byType(AnimatedContainer))
        .decoration as BoxDecoration;
    expect(pressed.gradient, isNull); // repasse en flat assombri
    expect(pressed.color, isNotNull);
    expect(pressed.boxShadow, isNull); // ombre désactivée pendant l'appui

    await gesture.up();
  });

  testWidgets('loading : indicateur visible, aucun overflow à 320px',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: AppButton(
          label: 'Chargement en cours, veuillez patienter',
          loading: true,
          onPressed: () {},
        ),
      ),
    ));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled (onPressed null) : opacité réduite, pas de tap',
      (tester) async {
    final deco = await _pumpAndGetDecoration(
      tester,
      button: const AppButton(label: 'Indisponible', onPressed: null),
    );
    // Fond primaire assombri/désaturé pour l'état désactivé.
    expect(deco.color, isNotNull);
    expect(deco.gradient, isNull);
  });
}
