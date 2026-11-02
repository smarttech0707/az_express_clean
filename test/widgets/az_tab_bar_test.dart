import 'dart:math' as math;

import 'package:az_express/theme/app_theme.dart';
import 'package:az_express/widgets/az_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

// Barre d'onglets partagée des écrans admin : mêmes jeux de libellés que les
// vraies pages, tailles 320→430, clair/sombre, texte agrandi, iOS/Android.

const _widths = [320.0, 360.0, 375.0, 390.0, 430.0];

// Libellés réels (voir test/screens/admin/admin_tabs_adoption_test.dart).
const _sets = <String, List<String>>{
  'deux courts (demandes)': ['En attente', 'Traitées'],
  'deux longs (support)': ['Tickets support', 'Signalements produits'],
  'trois (boutique)': ['Produits', 'Commandes', 'Recharges'],
  'quatre (e-kbine)': ['En attente', 'Approuvés', 'Rejetés', 'Commandes'],
  'quatre longs (stats géo)': [
    'Zones actives',
    'Routes fréquentes',
    'Horaires de pointe',
    'Évolution',
  ],
  'quatre très longs (recharges)': [
    'Recharge livreur',
    'Retraits en attente',
    'Traités',
    'Échoués / Rejetés',
  ],
  'cinq (zones)': ['Tout', 'Villes', 'Quartiers', 'Villages', 'Secteurs'],
};

const _bg = Color(0xFF1565C0);

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

class _Host extends StatefulWidget {
  const _Host({required this.labels, this.bg = _bg});
  final List<String> labels;
  final Color bg;
  @override
  State<_Host> createState() => _HostState();
}

// Même structure que les pages : TabController créé par la page (avec
// `controller:`), pas de DefaultTabController.
class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final TabController _c =
      TabController(length: widget.labels.length, vsync: this);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Page'),
          backgroundColor: widget.bg,
          bottom: AzTabBar(
              labels: widget.labels, controller: _c, backgroundColor: widget.bg),
        ),
        body: TabBarView(controller: _c, children: [
          for (final l in widget.labels) Center(child: Text('contenu:$l')),
        ]),
      );
}

Future<void> _pump(
  WidgetTester tester,
  List<String> labels, {
  required double width,
  Brightness brightness = Brightness.light,
  double textScale = 1,
  TargetPlatform platform = TargetPlatform.iOS,
  Color bg = _bg,
}) async {
  tester.view.physicalSize = Size(width, 700) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final base = brightness == Brightness.light ? AppTheme.light : AppTheme.dark;
  await tester.pumpWidget(MaterialApp(
    theme: base.copyWith(platform: platform),
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: _Host(labels: labels, bg: bg),
  ));
  await tester.pumpAndSettle();
}

Finder _tab(String l) =>
    find.descendant(of: find.byType(TabBar), matching: find.text(l));

bool _inside(WidgetTester tester, String l, double width) {
  final r = tester.getRect(_tab(l));
  return r.left >= -0.1 && r.right <= width + 0.1;
}

Future<void> _reach(WidgetTester tester, String l, double width) async {
  var guard = 0;
  while (!_inside(tester, l, width) && guard++ < 8) {
    await tester.drag(find.byType(TabBar), const Offset(-100, 0));
    await tester.pumpAndSettle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  _sets.forEach((name, labels) {
    for (final width in _widths) {
      for (final b in Brightness.values) {
        for (final scale in [1.0, 1.5]) {
          testWidgets(
              '$name — ${width.toInt()} px, $b, texte x$scale : onglets '
              'atteignables, actif visible, contenu correspondant',
              (tester) async {
            await _pump(tester, labels,
                width: width, brightness: b, textScale: scale);
            expect(tester.takeException(), isNull);
            for (final l in labels) {
              await _reach(tester, l, width);
              await tester.tap(_tab(l));
              await tester.pumpAndSettle();
              expect(_inside(tester, l, width), isTrue,
                  reason: '« $l » doit être entièrement visible une fois actif');
              expect(find.text('contenu:$l'), findsOneWidget);
              final p = tester.renderObject<RenderParagraph>(_tab(l));
              expect(p.didExceedMaxLines, isFalse, reason: l);
              // Zone tactile : au moins 48 px de haut.
              final cell = tester.getRect(find
                  .ancestor(of: _tab(l), matching: find.byType(InkWell))
                  .first);
              expect(cell.height, greaterThanOrEqualTo(48), reason: l);
              expect(cell.width, greaterThanOrEqualTo(48), reason: l);
            }
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  });

  testWidgets('quand tout tient, onglets répartis et aucun indicateur',
      (tester) async {
    await _pump(tester, _sets['deux courts (demandes)']!, width: 320);
    expect(tester.widget<TabBar>(find.byType(TabBar)).isScrollable, isFalse);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    // Parts égales : les libellés sont centrés à 1/4 et 3/4 de la largeur.
    expect(tester.getCenter(_tab('En attente')).dx, closeTo(80, 1));
    expect(tester.getCenter(_tab('Traitées')).dx, closeTo(240, 1));
  });

  testWidgets('quand ça ne tient pas, défilement + indicateur de bord',
      (tester) async {
    await _pump(tester, _sets['quatre très longs (recharges)']!, width: 320);
    expect(tester.widget<TabBar>(find.byType(TabBar)).isScrollable, isTrue);
    double hint(IconData i) => tester
        .widget<AnimatedOpacity>(find
            .ancestor(of: find.byIcon(i), matching: find.byType(AnimatedOpacity))
            .first)
        .opacity;
    expect(hint(Icons.chevron_right_rounded), 1);
    expect(hint(Icons.chevron_left_rounded), 0);
    await tester.drag(find.byType(TabBar), const Offset(-900, 0));
    await tester.pumpAndSettle();
    expect(hint(Icons.chevron_right_rounded), 0);
    expect(hint(Icons.chevron_left_rounded), 1);
  });

  testWidgets('glisser le contenu change d\'onglet et garde l\'actif visible',
      (tester) async {
    final labels = _sets['cinq (zones)']!;
    await _pump(tester, labels, width: 320);
    for (final l in labels.skip(1)) {
      await tester.drag(find.byType(TabBarView), const Offset(-250, 0));
      await tester.pumpAndSettle();
      expect(find.text('contenu:$l'), findsOneWidget);
      expect(_inside(tester, l, 320), isTrue, reason: l);
    }
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('même comportement sur $platform', (tester) async {
      await _pump(tester, _sets['quatre (e-kbine)']!,
          width: 360, platform: platform);
      await tester.tap(_tab('Rejetés'));
      await tester.pumpAndSettle();
      expect(find.text('contenu:Rejetés'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('inactif et actif lisibles (≥ 4,5:1) sur chaque fond d\'AppBar admin',
      () {
    // Fonds réellement utilisés par les pages (voir test d'adoption).
    const backgrounds = {
      'brun boulangerie': Color(0xFF5D4037),
      'bleu': Color(0xFF1565C0),
      'vert': Color(0xFF2E7D32),
      'violet flotte': Color(0xFF6A1B9A),
      'rouge pharmacie': Color(0xFFD32F2F),
      'turquoise': Color(0xFF00695C),
      'orange action': AppColors.primaryAction,
    };
    const inactive = Color(0xFAFFFFFF); // blanc à 98 %, comme AzTabBar
    backgrounds.forEach((name, bg) {
      expect(_contrast(Colors.white, bg), greaterThanOrEqualTo(4.5),
          reason: 'actif sur $name');
      expect(_contrast(Color.alphaBlend(inactive, bg), bg),
          greaterThanOrEqualTo(4.5),
          reason: 'inactif sur $name');
    });
    // Le orange vif de marque ne convient PAS (2,9:1) : c'est pourquoi la page
    // Boutique est passée à `primaryAction`.
    expect(_contrast(Colors.white, AppColors.primary), lessThan(4.5));
  });
}
