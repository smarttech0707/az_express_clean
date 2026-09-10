import 'package:az_express/screens/ai/az_ia_chat_app_bar_title.dart';
import 'package:az_express/theme/az_ia_theme.dart';
import 'package:az_express/widgets/az_ia/az_ia_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Reproduit le RenderFlex overflow « … on the right » observé sur appareil
// Android réel (Samsung SM-A115F) dans l'AppBar du chat AZ IA :
// logo + « AZ IA » / « Assistant AZ Express », suivi de 2 actions.
//
// Sur écran étroit (ou avec une taille d'affichage/police système agrandie),
// la `Column` de texte de largeur intrinsèque non contrainte, à l'intérieur
// d'un `Row(mainAxisSize: MainAxisSize.min)`, ne pouvait pas rétrécir et
// débordait dans la zone des `actions`.
//
// Correctif : `AzIaChatAppBarTitle` rend la partie texte `Flexible` +
// ellipse. Les tests ci-dessous vérifient, aux largeurs 320 / 360 / 390 /
// 430 (+ largeur logique de l'appareil réel) :
//   • aucun overflow ;
//   • les textes essentiels restent visibles ;
//   • les callbacks des actions de l'AppBar restent inchangés.
// ─────────────────────────────────────────────────────────────────────────────

/// AppBar fidèle à celle du chat : back button en `leading`, bouton volume +
/// menu « ⋮ » en `actions` (ce qui contraint la largeur du titre).
Widget _chatScaffold({
  required Widget title,
  VoidCallback? onVolume,
}) {
  return MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(
        backgroundColor: AzIaTheme.deepBlue,
        foregroundColor: Colors.white,
        centerTitle: false,
        leading: const BackButton(),
        title: title,
        actions: [
          IconButton(
            tooltip: 'Activer les réponses vocales',
            icon: const Icon(Icons.volume_up),
            onPressed: onVolume,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'clear_history',
                child: Text("Effacer l'historique"),
              ),
            ],
          ),
        ],
      ),
      body: const SizedBox.shrink(),
    ),
  );
}

Future<void> _pumpAt(WidgetTester tester, double logicalWidth, Widget widget) async {
  tester.view.physicalSize = Size(logicalWidth, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(widget);
  await tester.pump();
}

void main() {
  // Largeurs demandées + largeur logique réelle du SM-A115F (720 px / 1.75).
  const widths = <double>[320, 360, 390, 411, 430];

  for (final w in widths) {
    testWidgets('titre AppBar AZ IA : aucun overflow a ${w.toInt()} px',
        (tester) async {
      await _pumpAt(tester, w, _chatScaffold(title: const AzIaChatAppBarTitle()));

      // Aucun RenderFlex overflow (ni autre exception de layout).
      expect(tester.takeException(), isNull);

      // Le titre reste rendu et l'identité « AZ IA » visible.
      expect(find.byType(AzIaChatAppBarTitle), findsOneWidget);
      expect(find.text('AZ IA'), findsOneWidget);
      expect(find.byType(AzIaLogo), findsOneWidget);
      // Le sous-titre est présent dans l'arbre (tronqué en ellipse si besoin,
      // jamais masqué ni source d'overflow).
      expect(find.text('Assistant AZ Express'), findsOneWidget);
    });
  }

  // Ancienne structure, reproduite telle quelle (Column NON `Flexible`,
  // textes sans ellipse) : c'est la source du débordement observé.
  const oldTitle = Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      AzIaLogo(size: 38, variant: AzIaLogoVariant.avatar),
      SizedBox(width: 10),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AZ IA',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text('Assistant AZ Express',
              style: TextStyle(fontSize: 11, color: AzIaTheme.textSecondary)),
        ],
      ),
    ],
  );

  for (final w in widths) {
    testWidgets(
        'a ${w.toInt()} px : l ancienne structure deborde a droite, '
        'la corrigee non', (tester) async {
      await _pumpAt(tester, w, _chatScaffold(title: oldTitle));
      final oldException = tester.takeException();
      expect(oldException, isNotNull,
          reason: 'la structure d origine deborde a $w px');
      expect(oldException.toString(), contains('overflowed'));
      expect(oldException.toString(), contains('on the right'));

      // Même largeur, structure corrigée : plus aucun overflow.
      await _pumpAt(
          tester, w, _chatScaffold(title: const AzIaChatAppBarTitle()));
      expect(tester.takeException(), isNull);
      expect(find.text('AZ IA'), findsOneWidget);
    });
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('theme ${mode.name} : rendu correct, sous-titre inchange',
        (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        darkTheme: ThemeData.dark(useMaterial3: true),
        themeMode: mode,
        home: Scaffold(
          appBar: AppBar(
            leading: const BackButton(),
            title: const AzIaChatAppBarTitle(),
            actions: [
              IconButton(icon: const Icon(Icons.volume_up), onPressed: () {}),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'x', child: Text('x')),
                ],
              ),
            ],
          ),
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('AZ IA'), findsOneWidget);
      expect(find.text('Assistant AZ Express'), findsOneWidget);
      // Couleur du sous-titre = constante AZ IA (indépendante du thème app).
      final subtitle = tester.widget<Text>(find.text('Assistant AZ Express'));
      expect(subtitle.style?.color, AzIaTheme.textSecondary);
    });
  }

  testWidgets('les callbacks des actions de l AppBar restent inchanges',
      (tester) async {
    var volumeTaps = 0;
    await _pumpAt(
      tester,
      320,
      _chatScaffold(
        title: const AzIaChatAppBarTitle(),
        onVolume: () => volumeTaps++,
      ),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Activer les réponses vocales'));
    await tester.pump();
    expect(volumeTaps, 1);

    // Le menu « ⋮ » s ouvre toujours.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text("Effacer l'historique"), findsOneWidget);
  });
}
