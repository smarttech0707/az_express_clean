import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:az_express/widgets/app_button.dart';
import 'package:az_express/widgets/app_loading.dart';
import 'package:az_express/widgets/app_snack.dart';

double _lum(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

double contrast(Color a, Color b) {
  final l1 = _lum(a), l2 = _lum(b);
  final hi = math.max(l1, l2), lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('Contraste WCAG AA', () {
    test('texte blanc sur les fonds d\'action ≥ 4,5:1', () {
      for (final bg in [
        AppColors.primaryAction,
        AppColors.primaryActionLight,
        AppColors.primaryActionPressed,
        AppColors.successStrong,
        AppColors.errorStrong,
        AppColors.blueAction,
      ]) {
        expect(contrast(Colors.white, bg), greaterThanOrEqualTo(4.5),
            reason: '$bg');
      }
    });

    test('snackbars : chaque paire fond/texte ≥ 4,5:1', () {
      for (final t in AppSnackType.values) {
        final s = AppSnack.styleOf(t);
        expect(contrast(s.foreground, s.background), greaterThanOrEqualTo(4.5),
            reason: '$t');
      }
    });
  });

  for (final size in const [Size(360, 640), Size(390, 844), Size(430, 932)]) {
    testWidgets('composants sans overflow à $size', (tester) async {
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Column(children: [
            const SizedBox(
                height: 100, child: AppLoading(message: 'Chargement…')),
            const Expanded(child: AppListSkeleton()),
            AppButton(label: 'Confirmer la commande', onPressed: () {}),
            Builder(
                builder: (c) => TextButton(
                    onPressed: () => AppSnack.show(c,
                        'Un message assez long pour vérifier le retour à la ligne sur petit écran',
                        type: AppSnackType.error),
                    child: const Text('go'))),
          ]),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Un message'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('squelette figé si animations désactivées', (tester) async {
    await tester.pumpWidget(const MediaQuery(
      data: MediaQueryData(disableAnimations: true),
      child: MaterialApp(home: Scaffold(body: AppListSkeleton())),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.hasRunningAnimations, isFalse);
  });

  test('Urbanist embarquée avec sa licence', () {
    for (final f in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      expect(
          // ignore: avoid_slow_async_ops
          _exists('assets/google_fonts/Urbanist-$f.ttf'),
          isTrue);
    }
    expect(_exists('assets/google_fonts/OFL.txt'), isTrue);
  });
}

bool _exists(String p) => FileSystemEntity.isFileSync(p);
