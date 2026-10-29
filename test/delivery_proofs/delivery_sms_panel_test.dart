import 'package:az_express/delivery_proofs/delivery_proof_service.dart';
import 'package:az_express/delivery_proofs/delivery_sms_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class SmsService extends DeliveryProofService {
  final calls = <String>[];
  final payloads = <Map<String, dynamic>>[];
  String status = 'not_configured';
  @override
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> data) async {
    calls.add(name);
    payloads.add(data);
    return {'status': status, 'canRetry': status == 'failed'};
  }
}

void main() {
  test('provider acceptance is never labelled receipt or simulation delivery', () {
    expect(smsStatusLabel('accepted'), contains('Réception non confirmée'));
    expect(smsStatusLabel('simulated'), contains('aucun SMS réel'));
    expect(smsStatusLabel('unknown'), contains('Résultat inconnu'));
    expect(smsStatusLabel('failed'), contains('Échec'));
  });
  testWidgets('default SMS gate makes no Firebase calls', (tester) async {
    if (deliveryProofUiEnabled && deliverySmsUiEnabled) return;
    final service = SmsService();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DeliverySmsPanel(orderId: 'o1', service: service))));
    expect(service.calls, isEmpty);
    expect(find.text('Code de réception par SMS'), findsNothing);
  });
  if (deliveryProofUiEnabled && deliverySmsUiEnabled) {
    testWidgets('client selects saved destination, no phone/PIN input', (tester) async {
      final service = SmsService();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DeliverySmsPanel(orderId: 'o1', service: service))));
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Choisir le SMS pour mon proche'));
      await tester.pump();
      expect(service.calls, contains('configureDeliverySms'));
      expect(service.payloads.every((data) => data.length == 1 && data['orderId'] == 'o1'), isTrue);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('failed message offers controlled retry', (tester) async {
      final service = SmsService()..status = 'failed';
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DeliverySmsPanel(orderId: 'o1', service: service))));
      await tester.pump();
      await tester.tap(find.text('Demander un nouveau SMS'));
      await tester.pump();
      expect(service.calls, contains('retryDeliverySms'));
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('driver signals arrival only after confirmation; no destination input', (tester) async {
      final service = SmsService();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DeliverySmsPanel(orderId: 'o1', driver: true, service: service))));
      expect(service.calls, isEmpty);
      await tester.tap(find.text('Signaler mon arrivée pour le SMS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirmer'));
      await tester.pumpAndSettle();
      expect(service.calls, ['markDeliverySmsArrival']);
      expect(service.payloads.single, {'orderId': 'o1'});
      expect(find.byType(TextField), findsNothing);
    });
  }
}
