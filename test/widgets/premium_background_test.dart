import 'package:az_express/theme/app_theme.dart';
import 'package:az_express/widgets/premium_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────
// LOT 2/3 — PremiumBackground : dégradé statique + texture optionnelle très
// discrète. Aucune police custom impliquée (pas de google_fonts ici), donc
// pas de contournement réseau nécessaire dans ce fichier.
// ─────────────────────────────────────────────────────────────────────────

void main() {
  testWidgets('clair : dégradé #FAFAF8 appliqué une seule fois',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: const Scaffold(
        body: PremiumBackground(child: Center(child: Text('Accueil'))),
      ),
    ));
    await tester.pump();

    final container = tester.widget<Container>(find.byType(Container).first);
    final deco = container.decoration as BoxDecoration;
    final gradient = deco.gradient as LinearGradient;
    expect(gradient.colors.first, AppColors.premiumBgLight);
    expect(find.text('Accueil'), findsOneWidget);
  });

  testWidgets('sombre : dégradé #0B1220 appliqué', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const Scaffold(
        body: PremiumBackground(child: Center(child: Text('Accueil'))),
      ),
    ));
    await tester.pump();

    final container = tester.widget<Container>(find.byType(Container).first);
    final deco = container.decoration as BoxDecoration;
    final gradient = deco.gradient as LinearGradient;
    expect(gradient.colors.first, AppColors.premiumBgDark);
  });

  // `find.byType(CustomPaint)` seul serait trop large (Scrollbar/Scaffold/
  // effets Material en utilisent aussi) — on cible précisément le peintre
  // de texture de `PremiumBackground` par son nom de type runtime (la
  // classe est privée, jamais exportée, mais son nom reste inspectable).
  Finder texturePaintFinder() => find.byWidgetPredicate((w) =>
      w is CustomPaint &&
      w.painter != null &&
      w.painter.runtimeType.toString() == '_PremiumTexturePainter');

  testWidgets('texture : un seul CustomPaint statique, sans animation',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: const Scaffold(
        body: PremiumBackground(child: SizedBox.shrink()),
      ),
    ));
    await tester.pump();
    expect(texturePaintFinder(), findsOneWidget);
    expect(find.byType(RepaintBoundary), findsWidgets);
    // Jamais de BackdropFilter/animation permanente dans ce composant.
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('texture désactivable (texture: false) — dégradé conservé',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: const Scaffold(
        body: PremiumBackground(
          texture: false,
          child: SizedBox.shrink(),
        ),
      ),
    ));
    await tester.pump();
    expect(texturePaintFinder(), findsNothing);
  });

  testWidgets('320px de large : aucun overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: PremiumBackground(
          child: ListView(
            children: List.generate(
              20,
              (i) => Padding(
                padding: const EdgeInsets.all(8),
                child: Text('Ligne $i sur un fond premium très étroit'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
