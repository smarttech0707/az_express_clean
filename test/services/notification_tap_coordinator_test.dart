import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/services/notification_tap_coordinator.dart';

void main() {
  const supportedTypes = {
    'client_order',
    'admin_request',
    'vehicle_chat_message',
  };

  test('conserve le tap app fermée jusqu’au handler prêt', () {
    final coordinator =
        NotificationTapCoordinator(supportedTypes: supportedTypes);
    final received = <String>[];

    coordinator.receive(const NotificationTap(
      type: 'client_order',
      orderId: 'order-1',
      dedupeKey: 'message-1',
    ));
    expect(coordinator.pendingTap?.orderId, 'order-1');

    coordinator.registerHandler(
      (type, orderId, status) => received.add('$type:$orderId'),
      acceptedTypes: const {'client_order'},
    );

    expect(received, ['client_order:order-1']);
    expect(coordinator.pendingTap, isNull);
  });

  test('consomme un message une seule fois', () {
    final coordinator =
        NotificationTapCoordinator(supportedTypes: supportedTypes);
    var calls = 0;
    coordinator.registerHandler(
      (type, orderId, status) => calls++,
      acceptedTypes: const {'client_order'},
    );
    const tap = NotificationTap(
      type: 'client_order',
      dedupeKey: 'same-fcm-message',
    );

    coordinator.receive(tap);
    coordinator.receive(tap);

    expect(calls, 1);
  });

  test('onMessageOpenedApp est remis immédiatement au handler actif', () {
    final coordinator =
        NotificationTapCoordinator(supportedTypes: supportedTypes);
    String? openedOrderId;
    coordinator.registerHandler(
      (type, orderId, status) => openedOrderId = orderId,
      acceptedTypes: const {'client_order'},
    );

    coordinator.receive(const NotificationTap(
      type: 'client_order',
      orderId: 'background-order',
      dedupeKey: 'background-message',
    ));

    expect(openedOrderId, 'background-order');
  });

  test('getInitialMessage et onMessageOpenedApp ne naviguent pas deux fois',
      () {
    final coordinator =
        NotificationTapCoordinator(supportedTypes: supportedTypes);
    var calls = 0;
    coordinator.receive(const NotificationTap(
      type: 'client_order',
      dedupeKey: 'firebase-message-id',
    ));
    coordinator.registerHandler(
      (type, orderId, status) => calls++,
      acceptedTypes: const {'client_order'},
    );
    coordinator.receive(const NotificationTap(
      type: 'client_order',
      dedupeKey: 'firebase-message-id',
    ));

    expect(calls, 1);
  });

  test('ignore un type sans destination connue', () {
    final coordinator =
        NotificationTapCoordinator(supportedTypes: supportedTypes);
    var calls = 0;
    coordinator.registerHandler(
      (type, orderId, status) => calls++,
      acceptedTypes: supportedTypes,
    );

    coordinator.receive(const NotificationTap(type: 'unknown'));

    expect(calls, 0);
    expect(coordinator.pendingTap, isNull);
  });

  test('un rôle incompatible ne consomme pas le tap en attente', () {
    final coordinator =
        NotificationTapCoordinator(supportedTypes: supportedTypes);
    final received = <String>[];
    coordinator.receive(const NotificationTap(
      type: 'admin_request',
      dedupeKey: 'admin-message',
    ));
    coordinator.registerHandler(
      (type, orderId, status) => received.add('client'),
      acceptedTypes: const {'client_order'},
    );
    expect(received, isEmpty);
    expect(coordinator.pendingTap?.type, 'admin_request');

    coordinator.registerHandler(
      (type, orderId, status) => received.add('admin'),
      acceptedTypes: const {'admin_request'},
    );

    expect(received, ['admin']);
    expect(coordinator.pendingTap, isNull);
  });

  test('chat véhicule cold start est conservé puis dédoublonné', () {
    final coordinator =
        NotificationTapCoordinator(supportedTypes: supportedTypes);
    final conversations = <String?>[];
    const tap = NotificationTap(
      type: 'vehicle_chat_message',
      orderId: 'vc_listing_buyer',
      dedupeKey: 'vehicle-fcm-1',
    );
    coordinator.receive(tap);
    coordinator.registerHandler(
      (type, conversationId, status) => conversations.add(conversationId),
      acceptedTypes: const {'vehicle_chat_message'},
    );
    coordinator.receive(tap);
    expect(conversations, ['vc_listing_buyer']);
  });
}
