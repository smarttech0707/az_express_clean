import 'package:az_express/widgets/firebase_startup_failure.dart';
import 'package:az_express/widgets/az_ia/az_ia_floating_assistant.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('startup fallback renders without any Firebase app',
      (tester) async {
    await tester.pumpWidget(const FirebaseStartupFailure());
    expect(find.text('AZ Express ne peut pas démarrer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider lookup failure is confined to the assistant bubble',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      builder: (_, child) => AzIaFloatingAssistant(child: child!),
      home: const Scaffold(body: Text('Accueil')),
    ));
    // Deliberately omit the provider: the Selector must fail inside the bounds.
    expect(tester.takeException(), isNotNull);
    expect(find.text('Accueil'), findsOneWidget);
    expect(tester.getSize(find.byType(ErrorWidget)), const Size(64, 64));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
