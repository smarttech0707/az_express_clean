import 'package:az_express/l10n/app_text.dart';
import 'package:az_express/screens/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('accueil défilable sans overflow sur un petit écran',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(AppLanguage(
      locale: const Locale('fr'),
      onLocaleChanged: (_) {},
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.text('E-Kbine Services'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('E-Kbine Services'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cartes accueil acceptent un texte agrandi', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      AppLanguage(
        locale: const Locale('fr'),
        onLocaleChanged: (_) {},
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.6),
            ),
            child: child!,
          ),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('E-Kbine Services'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });
}
