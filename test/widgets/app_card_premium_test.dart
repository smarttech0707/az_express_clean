import 'package:az_express/theme/app_theme.dart';
import 'package:az_express/widgets/app_card.dart';
import 'package:az_express/widgets/glass_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

// ─────────────────────────────────────────────────────────────────────────
// LOT 2 — AppCard.standard / AppCard.elevated / AppCard.semantic.
// ─────────────────────────────────────────────────────────────────────────

Future<Container> _pumpAndGetContainer(
  WidgetTester tester, {
  required Widget card,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
    home: Scaffold(body: Center(child: card)),
  ));
  await tester.pump();
  // PremiumCard construit un seul Container décoré — le premier trouvé.
  return tester.widget<Container>(find.byType(Container).first);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  testWidgets(
      'AppCard.standard : surface premium, bordure 1px, rayon premiumXl',
      (tester) async {
    final container = await _pumpAndGetContainer(
      tester,
      card: const AppCard.standard(child: Text('Contenu')),
    );
    final deco = container.decoration as BoxDecoration;
    expect(deco.color, AppColors.premiumSurfaceLight);
    expect(deco.borderRadius, AppRadius.premiumXlR);
    expect((deco.border as Border).top.width, 1);
    expect(deco.boxShadow, AppShadow.card);
  });

  testWidgets('AppCard.elevated : dégradé 2 tons + glow, aucun BackdropFilter',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const Scaffold(
        body: Center(child: AppCard.elevated(child: Text('Premium'))),
      ),
    ));
    await tester.pump();

    final container = tester.widget<Container>(find.byType(Container).first);
    final deco = container.decoration as BoxDecoration;
    expect(deco.gradient, isA<LinearGradient>());
    expect((deco.gradient as LinearGradient).colors,
        const [AppColors.premiumSurfaceElevatedDark, Color(0xFF131C30)]);
    expect(deco.boxShadow!.length, AppShadow.card.length + 1);
    // Jamais de blur — aucun BackdropFilter nulle part dans l'arbre.
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('AppCard.semantic(error) : teinte rouge, jamais glass',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Center(
          child: AppCard.semantic(
            type: AppCardSemanticType.error,
            child: const Text('Erreur'),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('Erreur'), findsOneWidget);
  });

  testWidgets(
      'AppCard.glass reste construit sur GlassCard (jamais la carte '
      'par défaut)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: const Scaffold(
        body: Center(
          child: AppCard(
            variant: AppCardVariant.glass,
            child: Text('Verre'),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(GlassCard), findsOneWidget);

    // Mais AppCard.standard (la carte PAR DÉFAUT du Design System) n'utilise
    // jamais GlassCard/BackdropFilter.
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: const Scaffold(
        body: Center(child: AppCard.standard(child: Text('Standard'))),
      ),
    ));
    await tester.pump();
    expect(find.byType(GlassCard), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('onTap déclenche le callback (carte cliquable)', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Center(
          child: AppCard.standard(
            onTap: () => tapped = true,
            child: const Text('Tap moi'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Tap moi'));
    await tester.pump();
    expect(tapped, isTrue);
  });
}
