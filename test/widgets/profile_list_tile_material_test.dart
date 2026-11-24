import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('un ListTile dans une carte décorée conserve une surface Material',
      (tester) async {
    var tapped = false;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [BoxShadow(blurRadius: 8)],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: ListTile(
              title: const Text('Modifier le mot de passe'),
              onTap: () => tapped = true,
            ),
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Modifier le mot de passe'));
    await tester.pump();
    expect(tapped, isTrue);
    expect(tester.takeException(), isNull);
  });
}
