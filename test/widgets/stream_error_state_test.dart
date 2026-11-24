import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/widgets/stream_error_state.dart';

/// `StreamErrorState` est le widget affiché dans les branches `hasError`
/// ajoutées aux écrans Firestore. Son contrat : dire qu'un chargement a
/// échoué, ne jamais faire croire à une liste vide, et ne jamais exposer un
/// détail technique Firebase à l'utilisateur.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) {
    return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  }

  testWidgets('affiche le message d\'échec fourni', (tester) async {
    await pump(
        tester,
        const StreamErrorState(
            message: 'Impossible de charger vos commandes.'));
    expect(find.text('Impossible de charger vos commandes.'), findsOneWidget);
  });

  testWidgets(
      'le message par défaut signale un échec, pas une absence de données',
      (tester) async {
    await pump(tester, const StreamErrorState());
    final text = tester.widget<Text>(find.byType(Text)).data!;
    expect(text.toLowerCase(), contains('impossible'));
    // Un échec ne doit jamais emprunter le vocabulaire d'un état vide.
    for (final forbidden in ['aucun', 'aucune', 'vide']) {
      expect(text.toLowerCase(), isNot(contains(forbidden)));
    }
  });

  testWidgets('aucun bouton Réessayer si aucun callback n\'est fourni',
      (tester) async {
    await pump(tester, const StreamErrorState());
    expect(find.text('Réessayer'), findsNothing);
  });

  testWidgets('le bouton Réessayer invoque bien le callback', (tester) async {
    var retries = 0;
    await pump(tester, StreamErrorState(onRetry: () => retries++));
    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    expect(retries, 1);
  });

  testWidgets('le message est annoncé aux lecteurs d\'écran', (tester) async {
    await pump(
        tester, const StreamErrorState(message: 'Erreur de chargement.'));
    final semantics = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.text('Erreur de chargement.'),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(semantics.properties.liveRegion, isTrue);
  });
}
