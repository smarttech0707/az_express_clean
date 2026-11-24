import 'dart:async';

import 'package:az_express/providers/az_ia_provider.dart';
import 'package:az_express/services/az_ia_consent.dart';
import 'package:az_express/services/az_ia_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeService extends AzIaService {
  final consentCalls = <bool>[];
  bool serverAccepts = true;
  bool serverReachable = true;

  @override
  Stream<AzIaPendingAction?> streamLatestPendingAction(String uid) =>
      const Stream.empty();

  @override
  Future<List<AzIaStoredMessage>> loadConversation(
          String uid, String conversationId) async =>
      const [];

  @override
  Future<bool> setAiConsent(
      {required bool granted, required int version}) async {
    consentCalls.add(granted);
    if (!serverReachable) throw Exception('offline');
    return granted ? serverAccepts : false;
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

Future<(AzIaProvider, _FakeService, StreamController<String?>)> _signedIn(
    [Map<String, Object> prefs = const {}]) async {
  SharedPreferences.setMockInitialValues(prefs);
  final auth = StreamController<String?>.broadcast();
  final service = _FakeService();
  final provider = AzIaProvider(service: service, authUidChanges: auth.stream);
  auth.add('u1');
  await _settle();
  return (provider, service, auth);
}

void main() {
  test('sans consentement : rien n’est envoyé et aucun message n’est ajouté',
      () async {
    final (provider, _, auth) = await _signedIn();
    expect(await provider.hasConsent(), isFalse);
    expect(await provider.sendMessage('Bonjour'), isNull);
    expect(provider.messages, isEmpty);
    provider.dispose();
    await auth.close();
  });

  test('consentement accepté : enregistré côté serveur puis sur l’appareil',
      () async {
    final (provider, service, auth) = await _signedIn();
    expect(await provider.grantConsent(), isTrue);
    expect(service.consentCalls, [true]);
    expect(await provider.hasConsent(), isTrue);
    expect(await AzIaConsent.isGranted('u1'), isTrue);
    provider.dispose();
    await auth.close();
  });

  test('consentement refusé par le serveur ou injoignable : rien n’est activé',
      () async {
    final (provider, service, auth) = await _signedIn();
    service.serverAccepts = false;
    expect(await provider.grantConsent(), isFalse);
    service.serverReachable = false;
    expect(await provider.grantConsent(), isFalse);
    expect(await provider.hasConsent(), isFalse);
    expect(await provider.sendMessage('Bonjour'), isNull);
    provider.dispose();
    await auth.close();
  });

  test('consentement retiré : envoi bloqué immédiatement, même hors ligne',
      () async {
    final (provider, service, auth) = await _signedIn();
    await provider.grantConsent();
    service.serverReachable = false;
    expect(await provider.revokeConsent(), isFalse); // serveur injoignable
    expect(await provider.hasConsent(), isFalse); // mais bloqué sur l’appareil
    expect(await provider.sendMessage('Bonjour'), isNull);
    expect(provider.messages, isEmpty);
    provider.dispose();
    await auth.close();
  });

  test('le consentement est propre à chaque compte', () async {
    final (provider, _, auth) = await _signedIn();
    await provider.grantConsent();
    auth.add('u2');
    await _settle();
    expect(await provider.hasConsent(), isFalse);
    expect(await AzIaConsent.isGranted('u1'), isTrue);
    provider.dispose();
    await auth.close();
  });

  test('ancien consentement local d’une autre version : ignoré', () async {
    final (provider, _, auth) =
        await _signedIn({'az_ia_consent_v0_u1': true});
    expect(await provider.hasConsent(), isFalse);
    provider.dispose();
    await auth.close();
  });
}
