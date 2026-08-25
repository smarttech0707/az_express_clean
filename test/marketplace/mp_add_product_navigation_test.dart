import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/marketplace/screens/mp_add_product.dart';

void main() {
  Future<void> openAddProduct(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const MpAddProductScreen(),
                ),
              ),
              child: const Text('Ouvrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();
  }

  testWidgets('le bouton retour quitte directement sans saisie',
      (tester) async {
    await openAddProduct(tester);

    expect(find.byTooltip('Retour'), findsOneWidget);
    await tester.tap(find.byTooltip('Retour'));
    await tester.pumpAndSettle();

    expect(find.text('Ouvrir'), findsOneWidget);
    expect(find.text('Abandonner cette annonce ?'), findsNothing);
  });

  testWidgets('le bouton retour demande confirmation avec saisie',
      (tester) async {
    await openAddProduct(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Téléphone');

    await tester.tap(find.byTooltip('Retour'));
    await tester.pumpAndSettle();

    expect(find.text('Abandonner cette annonce ?'), findsOneWidget);
    expect(find.text('Continuer la saisie'), findsOneWidget);
    expect(find.text('Abandonner'), findsOneWidget);

    await tester.tap(find.text('Continuer la saisie'));
    await tester.pumpAndSettle();
    expect(find.text('Nouvelle annonce'), findsOneWidget);
  });

  testWidgets('le retour système fonctionne et confirme le brouillon',
      (tester) async {
    await openAddProduct(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Téléphone');
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Abandonner cette annonce ?'), findsOneWidget);

    await tester.tap(find.text('Abandonner'));
    await tester.pumpAndSettle();
    expect(find.text('Ouvrir'), findsOneWidget);
  });
}
