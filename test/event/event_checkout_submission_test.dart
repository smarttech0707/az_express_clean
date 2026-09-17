import 'dart:async';

import 'package:az_express/event/event_constants.dart';
import 'package:az_express/event/models/event_models.dart';
import 'package:az_express/event/providers/event_provider.dart';
import 'package:az_express/event/screens/event_home_screen.dart';
import 'package:az_express/event/services/event_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ReservationService implements EventService {
  final responses = <Completer<String>>[];
  int calls = 0;

  @override
  Future<String> createReservation({
    required List<EventCartItem> items,
    required DateTime eventDate,
    required String eventTime,
    required String address,
    required String description,
    required EventPaymentMethod paymentMethod,
    required bool delivery,
    required bool installation,
    required bool dismantling,
    double? latitude,
    double? longitude,
  }) =>
      responses[calls++].future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _offer = EventOffer(
  id: 'chairs',
  providerId: 'p1',
  ownerId: 'owner',
  providerName: 'Location',
  title: 'Chaises',
  description: '',
  category: EventCategory.rental,
  subcategory: 'Chaises',
  unitPrice: 500,
  availableQuantity: 10,
  zone: 'Abengourou',
);

Future<void> _checkout(
  WidgetTester tester,
  _ReservationService service, {
  Future<bool> Function(BuildContext)? compatible,
}) async {
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final provider = EventProvider(service: service)..addToCart(_offer);
  addTearDown(provider.dispose);
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: provider,
    child: MaterialApp(
        home: EventCheckoutScreen(ensureWalletCompatible: compatible)),
  ));
  await tester.enterText(find.byType(TextFormField).first, 'Abengourou centre');
  await tester.pump();
}

VoidCallback _submit(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!;

void main() {
  testWidgets(
      'cash: two callbacks before rebuild submit once, failure unlocks and preserves the message',
      (tester) async {
    final service = _ReservationService()
      ..responses.addAll([Completer<String>(), Completer<String>()]);
    await _checkout(tester, service);
    final tap = _submit(tester);
    tap();
    tap(); // Same frame, same still-enabled button callback.
    expect(service.calls, 1);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    service.responses[0].completeError(StateError('SOLDE_INSUFFISANT:100:500'));
    await tester.pumpAndSettle();
    expect(find.text('Échec : Bad state: SOLDE_INSUFFISANT:100:500'),
        findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(EventCheckoutScreen)))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();
    _submit(tester)();
    expect(service.calls, 2);
    service.responses[1].complete('reservation');
    await tester.pumpAndSettle();
    expect(find.text('Réservation envoyée avec succès.'), findsOneWidget);
  });

  testWidgets(
      'wallet: saving and synchronous lock cover the compatibility await',
      (tester) async {
    final gate = Completer<bool>();
    var checks = 0;
    final service = _ReservationService()..responses.add(Completer<String>());
    await _checkout(tester, service, compatible: (_) {
      checks++;
      return gate.future;
    });
    await tester.tap(find.text('Wallet'));
    await tester.pump();
    final tap = _submit(tester);
    tap();
    tap();
    expect(checks, 1);
    expect(service.calls, 0);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    gate.complete(true);
    await tester.pump();
    expect(service.calls, 1);
    service.responses.single.complete('reservation');
    await tester.pumpAndSettle();
  });

  testWidgets('incompatible wallet releases the lock without submitting',
      (tester) async {
    final gate = Completer<bool>();
    final service = _ReservationService();
    await _checkout(tester, service, compatible: (_) => gate.future);
    await tester.tap(find.text('Wallet'));
    await tester.pump();
    _submit(tester)();
    gate.complete(false);
    await tester.pumpAndSettle();
    expect(service.calls, 0);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });
}
