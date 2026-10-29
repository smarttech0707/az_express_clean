import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:az_express/models/order_model.dart';
import 'package:az_express/services/firestore_service.dart';
import 'package:az_express/screens/driver/driver_dashboard.dart';

// Acceptation d'une course par un livreur SANS photo de profil (champ `photoUrl` absent de livreurs/{uid}).
// Régression : `driverDoc["photoUrl"]` levait « Bad state: field "photoUrl" does not exist » après l'envoi du
// selfie, donc acceptOrderCF n'était jamais appelée. Ces tests ne remplacent pas le parcours sur téléphone :
// FirebaseStorage / Firestore ne sont pas simulables ici (aucun paquet de simulation dans le dépôt).

class _FakeService implements FirestoreService {
  int acceptCalls = 0;
  @override
  Future<void> acceptOrder(String orderId, String driverId,
      {String? acceptanceSelfieUrl, String? driverPhotoUrl}) async {
    acceptCalls++;
  }

  @override
  int calculateDriverGain(int budget) => 400;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePicker extends ImagePickerPlatform {
  _FakePicker(this.result);
  final XFile? result;
  int calls = 0;
  @override
  Future<XFile?> getImageFromSource(
      {required ImageSource source,
      ImagePickerOptions options = const ImagePickerOptions()}) async {
    calls++;
    return result;
  }
}

void main() {
  Future<void> open(WidgetTester t, _FakeService service) async {
    await t.binding.setSurfaceSize(const Size(1000, 1400));
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () {
                      showDialog<void>(
                          context: context,
                          builder: (_) => OrderRequestDialog(
                              order: OrderModel(
                                  id: 'o',
                                  description: 'Course',
                                  budget: 500,
                                  status: 'assigned',
                                  latitude: 6,
                                  longitude: -3,
                                  type: 'delivery',
                                  driverId: 'd'),
                              driverId: 'd',
                              driverLat: 6,
                              driverLng: -3,
                              firestore: service,
                              onDone: () {},
                              orderUpdates: const Stream.empty()));
                    },
                    child: const Text('open'))))));
    await t.tap(find.text('open'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  test('la photo de profil est lue sans exception quand le champ est absent', () {
    // Garde statique : l'accès `doc["champ"]` sur un DocumentSnapshot lève une exception si le champ manque.
    final source = File('lib/screens/driver/driver_dashboard.dart').readAsStringSync();
    expect(source.contains('driverDoc["photoUrl"]'), isFalse);
    expect(source.contains("driverDoc.data()?['photoUrl'] as String?"), isTrue);
    // Équivalent sur une Map (ce que renvoie data()) : champ absent => null, pas d'exception.
    final data = <String, dynamic>{'name': 'Livreur A Test', 'wallet': 5000};
    expect(data['photoUrl'] as String?, isNull);
  });

  testWidgets('selfie annulé : acceptation jamais lancée, le livreur peut réessayer', (t) async {
    final service = _FakeService();
    final picker = _FakePicker(null);
    ImagePickerPlatform.instance = picker;
    await open(t, service);

    await t.tap(find.text('Accepter'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));

    expect(picker.calls, 1);
    expect(service.acceptCalls, 0);
    expect(t.takeException(), isNull);
    // Le bouton redevient actif : l'acceptation reste possible, mais seulement avec un selfie.
    expect(find.text('Accepter'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('selfie pris mais envoi impossible : pas d\'acceptation, erreur affichée', (t) async {
    final service = _FakeService();
    final picker = _FakePicker(XFile('selfie-test.jpg'));
    ImagePickerPlatform.instance = picker;
    await open(t, service);

    await t.tap(find.text('Accepter'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    // Firebase n'est pas initialisé dans ce test : l'envoi du selfie échoue, acceptOrderCF ne doit pas être appelée.
    expect(picker.calls, 1);
    expect(service.acceptCalls, 0);
    expect(find.textContaining('Erreur'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
