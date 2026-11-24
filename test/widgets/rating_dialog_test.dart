import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:az_express/widgets/rating_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Note du livreur : la validation doit réussir, ou échouer VISIBLEMENT
// (message + bouton réactivé) — jamais rester en chargement sans fin.

Future<void> _open(
  WidgetTester tester,
  Future<void> Function(String, int) submit,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog(
            context: context,
            builder: (_) => RatingDialog(
              orderId: 'o1',
              driverName: 'Awa',
              submit: submit,
            ),
          ),
          child: const Text('ouvrir'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('ouvrir'));
  await tester.pumpAndSettle();
}

Future<void> _rate(WidgetTester tester, int stars) async {
  await tester.tap(find.byIcon(Icons.star_border).at(stars - 1));
  await tester.pump();
}

void main() {
  testWidgets(
      '« Envoyer » reste désactivé tant qu\'aucune étoile n\'est choisie',
      (tester) async {
    await _open(tester, (_, __) async {});
    final send = tester
        .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Envoyer'));
    expect(send.onPressed, isNull);
  });

  testWidgets('succès : envoie (commande, note), remercie et ferme',
      (tester) async {
    String? orderId;
    int? rating;
    await _open(tester, (o, r) async {
      orderId = o;
      rating = r;
    });
    await _rate(tester, 4);
    await tester.tap(find.text('Envoyer'));
    await tester.pumpAndSettle();

    expect(orderId, 'o1');
    expect(rating, 4);
    expect(find.byType(RatingDialog), findsNothing);
    expect(find.text('Merci pour votre note !'), findsOneWidget);
  });

  testWidgets('échec réseau : message clair, bouton réactivé, dialogue ouvert',
      (tester) async {
    await _open(tester, (_, __) async => throw Exception('offline'));
    await _rate(tester, 5);
    await tester.tap(find.text('Envoyer'));
    await tester.pumpAndSettle();

    expect(find.byType(RatingDialog), findsOneWidget);
    expect(find.textContaining('Impossible d\'enregistrer votre note'),
        findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final send = tester
        .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Envoyer'));
    expect(send.onPressed, isNotNull);
  });

  testWidgets('permission refusée : message spécifique', (tester) async {
    await _open(
        tester,
        (_, __) async => throw FirebaseException(
            plugin: 'cloud_firestore', code: 'permission-denied'));
    await _rate(tester, 3);
    await tester.tap(find.text('Envoyer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ne peut pas être notée'), findsOneWidget);
  });

  testWidgets('après un échec, un second essai peut réussir', (tester) async {
    var calls = 0;
    await _open(tester, (_, __) async {
      calls++;
      if (calls == 1) throw Exception('offline');
    });
    await _rate(tester, 5);
    await tester.tap(find.text('Envoyer'));
    await tester.pumpAndSettle();
    expect(find.byType(RatingDialog), findsOneWidget);

    await tester.tap(find.text('Envoyer'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(RatingDialog), findsNothing);
  });

  testWidgets('double appui : une seule écriture', (tester) async {
    var calls = 0;
    await _open(tester, (_, __) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await _rate(tester, 5);
    await tester.tap(find.text('Envoyer'));
    await tester.pump();
    final send = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(send.onPressed, isNull); // en cours : bouton inactif
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('« Plus tard » ferme sans écrire', (tester) async {
    var calls = 0;
    await _open(tester, (_, __) async => calls++);
    await tester.tap(find.text('Plus tard'));
    await tester.pumpAndSettle();
    expect(find.byType(RatingDialog), findsNothing);
    expect(calls, 0);
  });
}
