import 'dart:async';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/screens/admin/admin_cash_payment_review_page.dart';
import 'package:az_express/screens/driver/driver_cash_remittance_page.dart' show CashOrderRow;
import 'package:az_express/services/partner_cash_service.dart';
import 'package:az_express/widgets/app_button.dart';

import '../../widgets/cash_remittance_panel_test.dart' show cashOrder;

// Mission 7E-2 — incidents de paiement cash à examiner : visibles jusqu'à leur examen, même reversement clos ; pagination ;
// examen distinct de la résolution ; aucune écriture directe.

const pending = {'status': 'non_payment_declared', 'verification': 'pending_review', 'reason': 'Client parti sans payer', 'declaredAtMs': 100};
const confirmedUnpaid = {'status': 'non_payment_declared', 'verification': 'confirmed_unpaid', 'declaredAtMs': 100};

Map<String, dynamic> incident({
  Map<String, dynamic> cp = pending,
  String status = 'pending',
  int? confirmed,
  bool settled = false,
  String name = 'Chez Test',
  int declaredAtMs = 100,
}) =>
    {
      ...cashOrder(isPaid: false, status: status, confirmed: confirmed, handedOver: confirmed, cashPayment: {...cp, 'declaredAtMs': declaredAtMs}),
      'sellerName': name,
      'driverId': 'driver12345',
      'merchantCashSettled': settled,
    };

Finder button(String label) => find.widgetWithText(AppButton, label);

/// Simule la requête Firestore : filtre sur cashPayment.verification et fenêtre de [limit] documents (ordre d'identifiant).
CashReviewSource fakeFirestore(Map<String, Map<String, dynamic>> docs, {List<int>? limits}) => (limit) {
      limits?.add(limit);
      final ids = docs.keys.toList()..sort();
      return Stream.value([
        for (final id in ids)
          if ((docs[id]!['cashPayment'] as Map)['verification'] == 'pending_review') (id: id, data: docs[id]!)
      ].take(limit).toList());
    };

Future<void> pump(WidgetTester tester, CashReviewSource source, {int pageSize = 50}) async {
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: AdminCashPaymentReviewPage(source: source, pageSize: pageSize)));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => PartnerCashService.callFunction = (n, d) async => {});

  testWidgets('un incident reste visible même si le reversement est clos et merchantCashSettled=true', (tester) async {
    final docs = {
      'o1': incident(status: 'confirmed', confirmed: 5500, settled: true, name: 'Reversement clos'),
      'o2': incident(name: 'Reversement ouvert'),
      'o3': incident(cp: confirmedUnpaid, name: 'Déjà examiné'),
    };
    await pump(tester, fakeFirestore(docs));
    expect(find.text('Reversement clos'), findsOneWidget);
    expect(find.text('Reversement ouvert'), findsOneWidget);
    expect(find.text('Déjà examiné'), findsNothing); // examiné : sort de la liste
    // Dossier clos : l'examen du paiement reste possible, la résolution du reversement ne l'est plus.
    expect(button('Examiner le non-paiement'), findsNWidgets(2));
    expect(button('Régulariser'), findsOneWidget);
    expect(find.textContaining('Réglé intégralement'), findsOneWidget);
  });

  testWidgets('l\'explication distingue examen du paiement et résolution du reversement', (tester) async {
    await pump(tester, fakeFirestore({'o1': incident()}));
    expect(find.textContaining('ne règle pas le reversement'), findsOneWidget);
    expect(find.textContaining('Régulariser'), findsWidgets);
  });

  testWidgets('aucun incident : message vide ; erreur de flux : état d\'erreur sans spinner infini', (tester) async {
    await pump(tester, fakeFirestore({}));
    expect(find.text('Aucun non-paiement à examiner.'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(home: AdminCashPaymentReviewPage(key: const ValueKey('e'), source: (_) => Stream.error(StateError('x')))));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Impossible de charger'), findsOneWidget);
  });

  testWidgets('au-delà de 50 incidents : fenêtres successives 50, 100, 150 ; aucun dossier perdu', (tester) async {
    final docs = {for (var i = 0; i < 120; i++) 'o${i.toString().padLeft(3, '0')}': incident(name: 'Resto $i', declaredAtMs: 1000 - i)};
    final limits = <int>[];
    await pump(tester, fakeFirestore(docs, limits: limits));
    expect(limits, [50]);
    Future<void> more() async {
      final more = find.text('Afficher plus d’incidents');
      await tester.scrollUntilVisible(more, 3000);
      await tester.tap(more);
      await tester.pumpAndSettle();
    }

    await more();
    await more();
    expect(limits, [50, 100, 150]);
    // 120 dossiers reçus < 150 : plus de bouton.
    await tester.scrollUntilVisible(find.text('Resto 0'), 3000); // le plus récent est en fin de liste (plus anciens d’abord)
    expect(find.text('Afficher plus d’incidents'), findsNothing);
  });

  testWidgets('petite fenêtre : « Afficher plus » retrouve le dossier au-delà de la première page', (tester) async {
    final docs = {'a': incident(name: 'Premier'), 'b': incident(name: 'Deuxième'), 'c': incident(name: 'Ancien dossier')};
    await pump(tester, fakeFirestore(docs), pageSize: 2);
    expect(find.text('Ancien dossier'), findsNothing);
    await tester.tap(find.text('Afficher plus d’incidents'));
    await tester.pumpAndSettle();
    expect(find.text('Ancien dossier'), findsOneWidget);
  });

  testWidgets('examen : reviewCashNonPayment seul (jamais resolve), rien de modifié avant le flux serveur', (tester) async {
    final sent = <Map<String, dynamic>>[];
    PartnerCashService.callFunction = (n, d) async {
      expect(n, 'partnerOrderActionCF');
      sent.add({...d});
      return {'success': true, 'message': 'Non-paiement confirmé', 'data': {'replay': false}};
    };
    final stream = StreamController<List<CashOrderRow>>();
    addTearDown(stream.close);
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: AdminCashPaymentReviewPage(source: (_) => stream.stream)));
    stream.add([(id: 'o1', data: incident())]);
    await tester.pumpAndSettle();
    await tester.tap(button('Examiner le non-paiement'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Appel du client : aveu de non-paiement');
    await tester.tap(find.text('Continuer'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Confirmer le non-paiement'));
    await tester.pumpAndSettle();
    expect(sent.single['action'], 'reviewCashNonPayment');
    expect(sent.single['decision'], 'confirm_unpaid');
    expect(sent.single['requestId'], hasLength(36));
    expect(sent.single.containsKey('finalAmount'), isFalse);
    expect(sent.single.containsKey('amount'), isFalse);
    // Pas de retrait optimiste : le dossier reste listé tant que le flux ne l'a pas retiré.
    expect(find.text('Chez Test'), findsOneWidget);
    stream.add(const []);
    await tester.pumpAndSettle();
    expect(find.text('Chez Test'), findsNothing);
    expect(find.text('Aucun non-paiement à examiner.'), findsOneWidget);
  });

  testWidgets('refus serveur (non super-administrateur) : message, dossier conservé', (tester) async {
    PartnerCashService.callFunction = (n, d) async => throw FirebaseFunctionsException(code: 'permission-denied', message: 'Réservé');
    await pump(tester, fakeFirestore({'o1': incident()}));
    await tester.tap(button('Examiner le non-paiement'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Appel du client : aveu de non-paiement');
    await tester.tap(find.text('Continuer'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Confirmer le non-paiement'));
    await tester.pumpAndSettle();
    expect(find.textContaining('autorisation requise'), findsOneWidget);
    expect(find.text('Chez Test'), findsOneWidget);
  });

  test('requête : une égalité sur cashPayment.verification, sans filtre merchantCashSettled ni index composite ; lecture seule', () {
    final src = File('lib/screens/admin/admin_cash_payment_review_page.dart').readAsStringSync();
    expect(src.contains("'cashPayment.verification', isEqualTo: 'pending_review'"), isTrue);
    expect(src.contains("where('merchantCashSettled'"), isFalse);
    expect(src.contains('.orderBy('), isFalse);
    for (final forbidden in ['.set(', '.update(', '.delete(', 'runTransaction', "'wallet'", 'wallet:', 'finalAmount']) {
      expect(src.contains(forbidden), isFalse, reason: forbidden);
    }
  });
}
