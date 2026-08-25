import 'package:az_express/ekbine/widgets/ek_deposit_account_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('le formulaire reste défilable avec clavier sur petit écran',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 290);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showEkDepositAccountDialog(context),
            child: const Text('Ouvrir'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();

    expect(find.text('Ajouter un numéro'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.text('Valider'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Valider'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('le formulaire accepte une taille de texte agrandie',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: const TextScaler.linear(1.6),
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showEkDepositAccountDialog(context),
            child: const Text('Ouvrir'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
