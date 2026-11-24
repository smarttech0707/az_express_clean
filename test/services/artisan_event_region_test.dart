import 'dart:math';

import 'package:az_express/event/services/event_service.dart';
import 'package:az_express/services/artisan_account_service.dart';
import 'package:cloud_functions/cloud_functions.dart';
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:cloud_functions_platform_interface/src/pigeon/messages.pigeon.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.cloud_functions_platform_interface.CloudFunctionsHostApi.call',
    CloudFunctionsHostApi.pigeonChannelCodec,
  );
  final requests = <Map<String, Object?>>[];
  bool pinIsCurrent = true;
  bool fail = false;
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });
  setUp(() {
    requests.clear();
    pinIsCurrent = true;
    fail = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(channel, (message) async {
      final args = (message! as List).single as Map;
      requests.add(Map<String, Object?>.from(args));
      if (fail) return ['unavailable', 'Transport indisponible', null];
      return [
        {'success': true, 'pinSet': pinIsCurrent, 'reservationId': 'reservation'},
      ];
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(channel, null);
  });

  test('event default transport sends the callable to europe-west1', () async {
    final service = EventService();
    await service.functions.httpsCallable('createEventReservationCF').call({
      'attemptId': 'regional-test-attempt',
    });
    expect(requests.single['functionName'], 'createEventReservationCF');
    expect(requests.single['region'], 'europe-west1');
  });

  for (final approve in [false, true]) {
    test('artisan transport routes setPin with approve=$approve to europe-west1', () async {
      final current = await ArtisanAccountService().setPin(
        providerId: 'provider',
        pin: (100000 + Random.secure().nextInt(900000)).toString(),
        approve: approve,
      );
      expect(current, isTrue);
      expect(requests.single['functionName'], 'setArtisanPin');
      expect(requests.single['region'], 'europe-west1');
      expect((requests.single['parameters'] as Map)['approve'], approve);
    });
  }

  test('approval replay with a superseded PIN does not advertise it as current', () async {
    pinIsCurrent = false;
    expect(await ArtisanAccountService().setPin(
      providerId: 'provider', pin: 'test-only', approve: true,
    ), isFalse);
  });

  test('failed approval transport propagates the failure without a success result', () async {
    fail = true;
    await expectLater(ArtisanAccountService().setPin(
      providerId: 'provider', pin: 'test-only', approve: true,
    ), throwsA(isA<FirebaseFunctionsException>()));
  });
}
