import 'dart:convert';
import 'package:az_express/delivery_proofs/delivery_proof_service.dart';
import 'package:az_express/delivery_proofs/proof_presentation.dart';
import 'package:az_express/delivery_proofs/proof_scanner_page.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

DeliveryProof proof({String type = 'pickup', bool expired = false}) =>
    DeliveryProof({
      'orderId': 'o1',
      'type': type,
      'token': 'a' * 43,
      'pin': '012345',
      'expiresAt': DateTime.now()
          .add(Duration(minutes: expired ? -1 : 5))
          .millisecondsSinceEpoch,
    });

class RecordingService extends DeliveryProofService {
  String? name;
  Map<String, dynamic>? payload;
  @override
  Future<Map<String, dynamic>> call(
      String name, Map<String, dynamic> data) async {
    this.name = name;
    payload = data;
    return {'success': true};
  }
}

void main() {
  test('recipient link contains only locator and rejects unsafe origins', () {
    final link = recipientLink('a' * 32, 'https://staging.example.test');
    expect(link, 'https://staging.example.test/#/reception/${'a' * 32}');
    expect(Uri.parse(link).query, isEmpty);
    expect(() => recipientLink('a' * 32, 'http://example.test'),
        throwsFormatException);
    expect(() => recipientLink('a' * 32, 'https://user:password@example.test'),
        throwsFormatException);
  });
  test('QR binds both order and step, without the PIN', () {
    final p = proof();
    expect(jsonDecode(p.qr)['pin'], isNull);
    expect(ProofCredential.parse(p.qr, 'o1', 'pickup').token, p.token);
    expect(() => ProofCredential.parse(p.qr, 'o2', 'pickup'),
        throwsFormatException);
    expect(() => ProofCredential.parse(p.qr, 'o1', 'delivery'),
        throwsFormatException);
    expect(() => ProofCredential.parse('https://invalid/', 'o1', 'pickup'),
        throwsFormatException);
  });
  test(
      'pickup and delivery use distinct callable contracts and preserve settlement',
      () async {
    final service = RecordingService();
    await service.confirm('o1', 'pickup', const ProofCredential(pin: '012345'));
    expect(service.name, 'confirmOrderPickupWithProof');
    expect(service.payload, {'orderId': 'o1', 'pin': '012345'});
    await service.confirm(
        'o1', 'delivery', const ProofCredential(token: 'secret'),
        delivery: {
          'markCashPaid': true,
          'deliveredLat': 5.0,
          'deliveredLng': -4.0,
          'deliveryPhotoUrl': 'photo'
        });
    expect(service.name, 'confirmOrderDeliveryWithProof');
    expect(service.payload!['proofToken'], 'secret');
    expect(service.payload!['markCashPaid'], true);
    expect(service.payload!['deliveredLat'], 5.0);
    expect(service.payload!['deliveryPhotoUrl'], 'photo');
  });
  test('errors never echo arbitrary server messages or secrets', () {
    final e = FirebaseFunctionsException(
        code: 'permission-denied', message: 'sensitive-token');
    expect(proofError(e), isNot(contains('sensitive-token')));
    expect(
        proofError(
            FirebaseFunctionsException(code: 'unavailable', message: 'offline')),
        contains('Connexion'));
    expect(
        proofError(FirebaseFunctionsException(
            code: 'failed-precondition', message: 'Code expiré')),
        contains('expiré'));
    expect(
        proofError(FirebaseFunctionsException(
            code: 'failed-precondition', message: 'Code déjà utilisé')),
        contains('déjà utilisé'));
  });
  for (final type in ['pickup', 'delivery']) {
    testWidgets('$type presentation displays QR and PIN', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ProofDisplay(proof: proof(type: type)))));
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text('PIN : 012345'), findsOneWidget);
    });
  }
  testWidgets('expired proof hides both secrets', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ProofDisplay(proof: proof(expired: true)))));
    expect(find.byType(QrImageView), findsNothing);
    expect(find.textContaining('012345'), findsNothing);
    expect(find.textContaining('expiré'), findsOneWidget);
  });
  testWidgets('manual PIN preserves leading zero and returns without mutation',
      (tester) async {
    ProofCredential? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                  onPressed: () async {
                    result = await Navigator.push<ProofCredential>(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ProofScannerPage(
                                orderId: 'o1', type: 'pickup')));
                  },
                  child: const Text('scan'),
                ))));
    await tester.tap(find.text('scan'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '12');
    await tester.tap(find.text('Utiliser ce PIN'));
    await tester.pump();
    expect(find.text('Saisissez les 6 chiffres.'), findsOneWidget);
    expect(result, isNull);
    await tester.enterText(find.byType(TextField), '012345');
    await tester.tap(find.text('Utiliser ce PIN'));
    await tester.pumpAndSettle();
    expect(result!.pin, '012345');
    expect(result!.token, isNull);
  });
  testWidgets('disabled rollout does not touch Firebase on historical cards',
      (tester) async {
    if (deliveryProofUiEnabled) return;
    await tester.pumpWidget(
        const MaterialApp(home: ProofActions(orderId: 'historical')));
    expect(find.byType(OutlinedButton), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'recipient page is gated and needs separate recovery code when enabled',
      (tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: RecipientProofPage(grantId: 'public-id')));
    expect(find.byType(TextField),
        deliveryProofUiEnabled ? findsOneWidget : findsNothing);
    expect(find.byType(QrImageView), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
