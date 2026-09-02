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

    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('Ouvrir'), findsOneWidget);
    expect(find.text('Abandonner cette annonce ?'), findsNothing);
  });

  testWidgets('le bouton retour demande confirmation avec saisie',
      (tester) async {
    await openAddProduct(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Téléphone');

    await tester.tap(find.byType(BackButton));
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

  testWidgets('les menus gardent un contraste lisible en thème sombre',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData.dark(),
      home: Scaffold(body: MpAddProductScreen()),
    ));

    final menus = find.byType(DropdownButtonFormField<String>);
    const firstOptions = ['16 Go', '2 Go', 'Noir', 'Abidjan'];

    expect(menus, findsNWidgets(4));
    for (var index = 0; index < firstOptions.length; index++) {
      final menu = menus.at(index);
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();

      final option = find.text(firstOptions[index]).last;
      expect(option, findsOneWidget);
      final text = tester.widget<Text>(option);
      expect(text.style?.color, isNotNull);
      expect(text.style?.color, isNot(equals(Colors.white)));

      await tester.tap(option);
      await tester.pumpAndSettle();
    }
  });
}
