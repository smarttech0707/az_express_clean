import 'dart:async';

import 'package:az_express/event/services/event_reservation_attempts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> basket({int quantity = 1, String payment = 'wallet'}) => {
      'items': [
        {'offerId': 'chairs', 'quantity': quantity},
      ],
      'eventDateMs': 1800000000000,
      'paymentMethod': payment,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final method in ['wallet', 'cash']) {
    test('$method: two immediate submissions share one transport call',
        () async {
      final response = Completer<String>();
      var calls = 0;
      Future<String> send(Map<String, dynamic> request) {
        calls++;
        return response.future;
      }

      final first = EventReservationAttempts().submit(
        uid: 'client',
        payload: basket(payment: method),
        send: send,
      );
      final second = EventReservationAttempts().submit(
        uid: 'client',
        payload: basket(payment: method),
        send: send,
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      response.complete('reservation');
      expect(await first, 'reservation');
      expect(await second, 'reservation');
    });

    test('$method: timeout retains the key across service recreation',
        () async {
      String? originalKey;
      final first = EventReservationAttempts().submit(
        uid: 'client',
        payload: basket(payment: method),
        send: (request) async {
          originalKey = request['attemptId'] as String;
          throw TimeoutException('Response lost after commit');
        },
      );
      await expectLater(first, throwsA(isA<TimeoutException>()));
      final preferences = await SharedPreferences.getInstance();
      // Simulate a new instance loading the persisted local state.
      SharedPreferences.setMockInitialValues({
        for (final key in preferences.getKeys()) key: preferences.get(key)!,
      });
      final result = await EventReservationAttempts().submit(
        uid: 'client',
        payload: basket(payment: method),
        send: (request) async {
          expect(request['attemptId'], originalKey);
          return 'first-reservation';
        },
      );
      expect(result, 'first-reservation');
    });
  }

  test(
      'different baskets get distinct keys; returning to an uncertain basket retains its key',
      () async {
    final keys = <String>[];
    Future<String> fail(Map<String, dynamic> request) async {
      keys.add(request['attemptId'] as String);
      throw TimeoutException('timeout');
    }

    for (final quantity in [1, 2, 1]) {
      await expectLater(
          EventReservationAttempts().submit(
            uid: 'client',
            payload: basket(quantity: quantity),
            send: fail,
          ),
          throwsA(isA<TimeoutException>()));
    }
    expect(keys[0], isNot(keys[1]));
    expect(keys[0], keys[2]);
  });

  test(
      'successful acknowledgement retires the key for a deliberate new booking',
      () async {
    final keys = <String>[];
    Future<String> send(Map<String, dynamic> request) async {
      keys.add(request['attemptId'] as String);
      return 'reservation-${keys.length}';
    }

    for (var i = 0; i < 2; i++) {
      await EventReservationAttempts()
          .submit(uid: 'client', payload: basket(), send: send);
    }
    expect(keys[0], isNot(keys[1]));
  });

  test(
      'insufficient balance preserves the attempt and releases the in-flight lock',
      () async {
    String? key;
    await expectLater(
        EventReservationAttempts().submit(
          uid: 'client',
          payload: basket(),
          send: (request) async {
            key = request['attemptId'] as String;
            throw StateError('SOLDE_INSUFFISANT:100:500');
          },
        ),
        throwsStateError);
    expect(
        await EventReservationAttempts().submit(
          uid: 'client',
          payload: basket(),
          send: (request) async {
            expect(request['attemptId'], key);
            return 'reservation';
          },
        ),
        'reservation');
  });

  test('attempts are isolated by authenticated user', () async {
    final keys = <String>[];
    for (final uid in ['client-a', 'client-b']) {
      await expectLater(
          EventReservationAttempts().submit(
            uid: uid,
            payload: basket(),
            send: (request) async {
              keys.add(request['attemptId'] as String);
              throw TimeoutException('timeout');
            },
          ),
          throwsA(isA<TimeoutException>()));
    }
    expect(keys[0], isNot(keys[1]));
  });
}
