import 'dart:io';
import 'dart:math' as math;

import 'package:az_express/event/screens/admin_event_screen.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

// Barre d'onglets de l'administration Événementiel : le libellé actif doit
// rester visible et lisible sur l'AppBar orange, la barre doit tenir ou
// défiler naturellement (jamais d'onglet coupé définitivement), et chaque
// onglet doit afficher le contenu de son titre.

const _labels = ['Prestataires', 'Réservations', 'Annonces', 'Signalements'];
const _sizes = [
  Size(320, 568), // iPhone SE 1re génération
  Size(375, 667), // iPhone SE / 8
  Size(390, 844),
  Size(430, 932),
];

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

Future<void> _pump(
  WidgetTester tester, {
  Size size = const Size(375, 667),
  Brightness brightness = Brightness.light,
  double textScale = 1,
  TargetPlatform platform = TargetPlatform.iOS,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final base = brightness == Brightness.light ? AppTheme.light : AppTheme.dark;
  await tester.pumpWidget(MaterialApp(
    theme: base.copyWith(platform: platform),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: AdminEventScreen(
      pages: [for (final l in _labels) Center(child: Text('page:$l'))],
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _label(String t) => find.descendant(
    of: find.byType(TabBar), matching: find.text(t));

TextStyle _style(WidgetTester tester, String t) => tester
    .widget<DefaultTextStyle>(find
        .ancestor(of: _label(t), matching: find.byType(DefaultTextStyle))
        .first)
    .style;

Color _barColor(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(TabBar))).appBarTheme.backgroundColor!;

Color _over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

bool _visibleInside(WidgetTester tester, String t, double width) {
  final r = tester.getRect(_label(t));
  return r.left >= 0 && r.right <= width;
}

double _hintOpacity(WidgetTester tester, IconData icon) => tester
    .widget<AnimatedOpacity>(find
        .ancestor(of: find.byIcon(icon), matching: find.byType(AnimatedOpacity))
        .first)
    .opacity;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  for (final size in _sizes) {
    for (final b in Brightness.values) {
      testWidgets('quatre onglets, sans overflow : $size $b', (tester) async {
        await _pump(tester, size: size, brightness: b);
        for (final l in _labels) {
          expect(_label(l), findsOneWidget, reason: l);
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('onglet actif toujours entièrement visible : $size $b',
          (tester) async {
        await _pump(tester, size: size, brightness: b);
        for (final l in _labels) {
          // Atteindre l'onglet comme un utilisateur : défiler la barre jusqu'à
          // le voir, puis le toucher.
          var guard = 0;
          while (!_visibleInside(tester, l, size.width) && guard++ < 6) {
            await tester.drag(find.byType(TabBar), const Offset(-120, 0));
            await tester.pumpAndSettle();
          }
          await tester.tap(_label(l));
          await tester.pumpAndSettle();
          expect(_visibleInside(tester, l, size.width), isTrue,
              reason: '« $l » doit être entièrement visible une fois actif');
          expect(find.text('page:$l'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final b in Brightness.values) {
    testWidgets('contraste actif / inactif ≥ 4,5:1 sur l\'AppBar ($b)',
        (tester) async {
      await _pump(tester, brightness: b);
      final bg = _barColor(tester);
      final active = _style(tester, 'Prestataires').color!;
      final inactive = _style(tester, 'Réservations').color!;
      expect(active, Colors.white);
      expect(_contrast(_over(active, bg), bg), greaterThanOrEqualTo(4.5));
      expect(_contrast(_over(inactive, bg), bg), greaterThanOrEqualTo(4.5));

      await tester.tap(_label('Réservations'));
      await tester.pumpAndSettle();
      expect(_style(tester, 'Réservations').color, Colors.white);
      expect(_style(tester, 'Prestataires').color, inactive);
    });
  }

  testWidgets('l\'onglet sélectionné se distingue : graisse et indicateur blanc',
      (tester) async {
    await _pump(tester);
    final bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.indicatorColor, Colors.white);
    expect(bar.labelStyle!.fontWeight, FontWeight.w700);
    expect(bar.unselectedLabelStyle!.fontWeight, FontWeight.w600);
    expect(bar.indicatorWeight, greaterThanOrEqualTo(3));
  });

  testWidgets('petit écran : défilement aligné à gauche, sans décalage de 52 px',
      (tester) async {
    await _pump(tester, size: const Size(320, 568));
    final bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.isScrollable, isTrue);
    expect(bar.tabAlignment, TabAlignment.start);
    // Premier libellé : marge d'onglet seulement (14 px), pas 52 + 16.
    expect(tester.getRect(_label('Prestataires')).left, lessThan(20));
  });

  testWidgets('grand écran : les onglets tiennent, répartis, sans indicateur',
      (tester) async {
    await _pump(tester, size: const Size(430, 932));
    final bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.isScrollable, isFalse);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    for (final l in _labels) {
      expect(_visibleInside(tester, l, 430), isTrue, reason: l);
    }
  });

  testWidgets('indicateurs de défilement : droite au début, gauche à la fin',
      (tester) async {
    await _pump(tester, size: const Size(320, 568));
    expect(_hintOpacity(tester, Icons.chevron_right_rounded), 1);
    expect(_hintOpacity(tester, Icons.chevron_left_rounded), 0);

    await tester.drag(find.byType(TabBar), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(_hintOpacity(tester, Icons.chevron_right_rounded), 0);
    expect(_hintOpacity(tester, Icons.chevron_left_rounded), 1);
  });

  testWidgets('les indicateurs ne bloquent pas les touches', (tester) async {
    await _pump(tester, size: const Size(320, 568));
    await tester.tap(_label('Réservations'));
    await tester.pumpAndSettle();
    expect(find.text('page:Réservations'), findsOneWidget);
  });

  testWidgets('glisser le contenu change d\'onglet et ramène l\'actif en vue',
      (tester) async {
    await _pump(tester, size: const Size(320, 568));
    for (final l in _labels.skip(1)) {
      await tester.drag(find.byType(TabBarView), const Offset(-250, 0));
      await tester.pumpAndSettle();
      expect(find.text('page:$l'), findsOneWidget);
      expect(_visibleInside(tester, l, 320), isTrue,
          reason: '« $l » doit rester visible quand on change de page');
    }
  });

  testWidgets('texte agrandi (x1,5) : pas d\'overflow, onglets atteignables',
      (tester) async {
    await _pump(tester, size: const Size(320, 568), textScale: 1.5);
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(TabBar), const Offset(-800, 0));
    await tester.pumpAndSettle();
    await tester.tap(_label('Signalements'));
    await tester.pumpAndSettle();
    expect(find.text('page:Signalements'), findsOneWidget);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('même comportement sur $platform', (tester) async {
      await _pump(tester, size: const Size(375, 667), platform: platform);
      await tester.tap(_label('Réservations'));
      await tester.pumpAndSettle();
      expect(find.text('page:Réservations'), findsOneWidget);
      expect(_visibleInside(tester, 'Réservations', 375), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  test('chaque onglet affiche le contenu de son titre (ordre + collection)',
      () {
    final src = File('lib/event/screens/admin_event_screen.dart')
        .readAsStringSync();
    expect(
        RegExp(r"_eventTabLabels = \[\s*'Prestataires',\s*'Réservations',\s*'Annonces',\s*'Signalements',\s*\]")
            .hasMatch(src),
        isTrue);
    // Même ordre dans le TabBarView.
    final pages = RegExp(r'_(ProvidersAdmin|ReservationsAdmin|OffersAdmin|ReportsAdmin)\(\),')
        .allMatches(src.substring(src.indexOf('TabBarView(')))
        .map((m) => m.group(1))
        .take(4)
        .toList();
    expect(pages,
        ['ProvidersAdmin', 'ReservationsAdmin', 'OffersAdmin', 'ReportsAdmin']);
    // Chaque page lit la collection de son titre.
    const expected = {
      'ProvidersAdmin': 'event_providers',
      'ReservationsAdmin': 'event_reservations',
      'OffersAdmin': 'event_offers',
      'ReportsAdmin': 'event_reports',
    };
    expected.forEach((cls, collection) {
      final start = src.indexOf('class _$cls ');
      final end = src.indexOf('\nclass ', start + 1);
      expect(src.substring(start, end), contains("collection('$collection')"),
          reason: cls);
    });
  });
}
