import 'dart:async';

import 'package:az_express/providers/az_ia_provider.dart';
import 'package:az_express/services/az_ia_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAzIaService extends AzIaService {
  final subscribedUids = <String>[];
  final streams = <String, StreamController<AzIaPendingAction?>>{};
  final conversations = <String, List<AzIaStoredMessage>>{};
  var clearHistoryCalls = 0;

  @override
  Stream<AzIaPendingAction?> streamLatestPendingAction(String uid) {
    subscribedUids.add(uid);
    return streams
        .putIfAbsent(
            uid, () => StreamController<AzIaPendingAction?>.broadcast())
        .stream;
  }

  @override
  Future<List<AzIaStoredMessage>> loadConversation(
      String uid, String conversationId) async {
    return conversations[conversationId] ?? const [];
  }

  @override
  Future<void> clearHistory() async {
    clearHistoryCalls++;
  }

  Future<void> close() async {
    await Future.wait(streams.values.map((controller) => controller.close()));
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('attend l’initialisation sécurisée avant de souscrire à Auth', () async {
    SharedPreferences.setMockInitialValues({});
    final ready = Completer<void>();
    final auth = StreamController<String?>.broadcast();
    final service = _FakeAzIaService();
    final provider = AzIaProvider(
      service: service,
      authUidChanges: auth.stream,
      initializationReady: ready.future,
    );

    auth.add('avant-app-check');
    await _settle();
    expect(service.subscribedUids, isEmpty);

    ready.complete();
    await _settle();
    auth.add('apres-app-check');
    await _settle();
    expect(service.subscribedUids, ['apres-app-check']);

    provider.dispose();
    await auth.close();
    await service.close();
  });

  test('expose une vue stable et non modifiable sans recopier l’historique',
      () async {
    final auth = StreamController<String?>.broadcast();
    final provider = AzIaProvider(
      service: _FakeAzIaService(),
      authUidChanges: auth.stream,
    );

    final firstView = provider.messages;
    expect(identical(firstView, provider.messages), isTrue);
    expect(
        () => firstView.add(AzIaMessage(
              sender: AzIaSender.user,
              text: 'interdit',
            )),
        throwsUnsupportedError);

    provider.dispose();
    await auth.close();
  });

  test('réabonne les actions en attente pour chaque UID et oublie l’ancien',
      () async {
    SharedPreferences.setMockInitialValues({});
    final auth = StreamController<String?>.broadcast();
    final service = _FakeAzIaService();
    final provider =
        AzIaProvider(service: service, authUidChanges: auth.stream);

    auth.add('user-a');
    await _settle();
    service.streams['user-a']!.add(const AzIaPendingAction(
      id: 'a1',
      toolName: 'wallet',
      summaryFr: 'Action A',
    ));
    await _settle();
    expect(provider.pendingAction?.id, 'a1');

    auth.add(null);
    await _settle();
    expect(provider.pendingAction, isNull);

    auth.add('user-b');
    await _settle();
    expect(service.subscribedUids, ['user-a', 'user-b']);
    service.streams['user-a']!.add(const AzIaPendingAction(
      id: 'stale',
      toolName: 'wallet',
      summaryFr: 'Ancienne action',
    ));
    await _settle();
    expect(provider.pendingAction, isNull);

    provider.dispose();
    await auth.close();
    await service.close();
  });

  test('nouvelle conversation vide et persiste un identifiant par UID',
      () async {
    SharedPreferences.setMockInitialValues({});
    final auth = StreamController<String?>.broadcast();
    final provider = AzIaProvider(
      service: _FakeAzIaService(),
      authUidChanges: auth.stream,
    );
    auth.add('user-a');
    await _settle();

    await provider.startNewConversation();
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('az_ia_current_conversation_user-a');
    expect(id, isNotNull);
    expect(id, isNotEmpty);
    expect(provider.messages, isEmpty);

    provider.dispose();
    await auth.close();
  });

  test('restaure uniquement la conversation persistée du bon UID', () async {
    SharedPreferences.setMockInitialValues({
      'az_ia_current_conversation_user-a': 'conversation-a',
      'az_ia_current_conversation_user-b': 'conversation-b',
    });
    final auth = StreamController<String?>.broadcast();
    final service = _FakeAzIaService()
      ..conversations['conversation-a'] = const [
        AzIaStoredMessage(role: 'assistant', content: 'Bonjour A'),
      ]
      ..conversations['conversation-b'] = const [
        AzIaStoredMessage(role: 'assistant', content: 'Bonjour B'),
      ];
    final provider =
        AzIaProvider(service: service, authUidChanges: auth.stream);

    auth.add('user-a');
    await _settle();
    await _settle();
    expect(provider.messages.single.text, 'Bonjour A');

    auth.add('user-b');
    await _settle();
    await _settle();
    expect(provider.messages.single.text, 'Bonjour B');

    provider.dispose();
    await auth.close();
    await service.close();
  });

  test('ouvre une conversation historique et la rend courante', () async {
    SharedPreferences.setMockInitialValues({});
    final auth = StreamController<String?>.broadcast();
    final service = _FakeAzIaService()
      ..conversations['old-conversation'] = const [
        AzIaStoredMessage(role: 'user', content: 'Ancienne demande'),
        AzIaStoredMessage(role: 'assistant', content: 'Ancienne réponse'),
      ];
    final provider =
        AzIaProvider(service: service, authUidChanges: auth.stream);
    auth.add('user-a');
    await _settle();

    await provider.openConversation('old-conversation');
    final prefs = await SharedPreferences.getInstance();
    expect(provider.messages, hasLength(2));
    expect(provider.messages.last.text, 'Ancienne réponse');
    expect(prefs.getString('az_ia_current_conversation_user-a'),
        'old-conversation');

    provider.dispose();
    await auth.close();
    await service.close();
  });

  test(
      'une nouvelle conversation obtient un identifiant différent de la précédente',
      () async {
    SharedPreferences.setMockInitialValues({});
    final auth = StreamController<String?>.broadcast();
    final provider = AzIaProvider(
      service: _FakeAzIaService(),
      authUidChanges: auth.stream,
    );
    auth.add('user-a');
    await _settle();

    await provider.startNewConversation();
    final prefs = await SharedPreferences.getInstance();
    final firstId = prefs.getString('az_ia_current_conversation_user-a');

    await provider.startNewConversation();
    final secondId = prefs.getString('az_ia_current_conversation_user-a');

    expect(firstId, isNotNull);
    expect(secondId, isNotNull);
    expect(secondId, isNot(equals(firstId)));
    expect(provider.messages, isEmpty);

    provider.dispose();
    await auth.close();
  });

  test('une image trop lourde est refusée avant encodage', () {
    expect(AzIaProvider.maxImageBytes, 4 * 1024 * 1024);
    expect(AzIaProvider.maxImageBytes, lessThan(6 * 1024 * 1024));
    expect(AzIaProvider.isImageTooLarge(AzIaProvider.maxImageBytes), isFalse);
    expect(
        AzIaProvider.isImageTooLarge(AzIaProvider.maxImageBytes + 1), isTrue);
  });

  test('un double appel à nouvelle conversation ne crée qu’un seul identifiant',
      () async {
    SharedPreferences.setMockInitialValues({});
    final auth = StreamController<String?>.broadcast();
    final provider = AzIaProvider(
      service: _FakeAzIaService(),
      authUidChanges: auth.stream,
    );
    auth.add('user-a');
    await _settle();

    await Future.wait([
      provider.startNewConversation(),
      provider.startNewConversation(),
    ]);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('az_ia_current_conversation_user-a'), isNotEmpty);

    provider.dispose();
    await auth.close();
  });

  test('supprime la référence locale après effacement de l’historique',
      () async {
    SharedPreferences.setMockInitialValues({});
    final auth = StreamController<String?>.broadcast();
    final service = _FakeAzIaService();
    final provider =
        AzIaProvider(service: service, authUidChanges: auth.stream);
    auth.add('user-a');
    await _settle();
    await provider.startNewConversation();

    await provider.clearHistory();

    final prefs = await SharedPreferences.getInstance();
    expect(service.clearHistoryCalls, 1);
    expect(prefs.getString('az_ia_current_conversation_user-a'), isNull);

    provider.dispose();
    await auth.close();
  });

  test('nettoie une référence persistée vers une conversation inexistante',
      () async {
    SharedPreferences.setMockInitialValues({
      'az_ia_current_conversation_user-a': 'missing-conversation',
    });
    final auth = StreamController<String?>.broadcast();
    final provider = AzIaProvider(
      service: _FakeAzIaService(),
      authUidChanges: auth.stream,
    );
    auth.add('user-a');
    await _settle();
    await _settle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('az_ia_current_conversation_user-a'), isNull);
    expect(provider.messages, isEmpty);

    provider.dispose();
    await auth.close();
  });

  test('n’émet plus de notification après dispose', () async {
    SharedPreferences.setMockInitialValues({});
    final auth = StreamController<String?>.broadcast();
    final service = _FakeAzIaService();
    final provider =
        AzIaProvider(service: service, authUidChanges: auth.stream);
    var notifications = 0;
    provider.addListener(() => notifications++);

    auth.add('user-a');
    await _settle();
    provider.dispose();
    final countAtDispose = notifications;
    service.streams['user-a']!.add(const AzIaPendingAction(
      id: 'late',
      toolName: 'wallet',
      summaryFr: 'Action tardive',
    ));
    await _settle();

    expect(notifications, countAtDispose);
    await auth.close();
    await service.close();
  });
}
