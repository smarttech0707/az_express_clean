import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/screens/admin/admin_disputes_page.dart';
import 'package:az_express/screens/admin/admin_stuck_alerts_page.dart';

// Firebase n'est pas initialisé dans ce test : l'appel serveur échoue, l'écran doit
// dégrader proprement (message + « Réessayer ») au lieu d'un spinner infini ni d'un crash.
void main() {
  testWidgets('litiges : erreur de chargement → état d\'erreur avec réessai', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AdminDisputesPage()));
    await tester.pumpAndSettle();
    expect(find.text('Impossible de charger les litiges.'), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('alertes : erreur de chargement → état d\'erreur avec réessai', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AdminStuckAlertsPage()));
    await tester.pumpAndSettle();
    expect(find.text('Impossible de charger les alertes.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
