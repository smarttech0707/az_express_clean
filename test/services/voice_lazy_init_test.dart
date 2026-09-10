import 'package:az_express/services/voice/voice_manager.dart';
import 'package:az_express/services/voice/voice_provider.dart';
import 'package:flutter_test/flutter_test.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Prouve que `VoiceManager` n'initialise le moteur TTS (`AndroidTtsProvider` /
// `FlutterTts`) QU'À la première utilisation vocale réelle — jamais à la
// construction. Avant ce correctif, `az_ia_chat_screen.dart` construisait
// `VoiceManager()` (→ `FlutterTts()`) en champ et appelait `_voice.initialize()`
// dans `initState`, donc dès l'ouverture du chat, même sans usage vocal.
//
// Aucun moteur Android réel n'est touché : le fournisseur est injecté via une
// fabrique (`providerFactory`) qui compte ses appels.
// ─────────────────────────────────────────────────────────────────────────────

/// Fournisseur espion — compte création/initialize/speak/stop, sans dépendre
/// de `flutter_tts` ni d'un appareil.
class _SpyProvider implements VoiceProvider {
  int initializeCount = 0;
  int stopCount = 0;
  final List<String> spoken = [];

  @override
  String get name => 'SpyProvider';
  @override
  bool get isAvailable => true;
  @override
  Future<void> initialize() async => initializeCount++;
  @override
  Future<void> speak(String text) async => spoken.add(text);
  @override
  Future<void> stop() async => stopCount++;
  @override
  Future<void> applyVoiceSettings({
    required double speechRate,
    required double pitch,
    required double volume,
  }) async {}
}

void main() {
  test('1. construire VoiceManager ne crée AUCUN fournisseur / moteur TTS', () {
    var factoryCalls = 0;
    final manager = VoiceManager(providerFactory: () {
      factoryCalls++;
      return _SpyProvider();
    });

    expect(factoryCalls, 0, reason: 'la fabrique ne doit pas être appelée');
    expect(manager.activeProvider, isNull);
    expect(manager.isInitialized, isFalse);
  });

  test('2. première action vocale (speak) initialise exactement une fois',
      () async {
    var factoryCalls = 0;
    late _SpyProvider spy;
    final manager = VoiceManager(
      providerFactory: () {
        factoryCalls++;
        return spy = _SpyProvider();
      },
      sentencePause: const Duration(milliseconds: 1),
    );

    await manager.speak('Bonjour.');

    expect(factoryCalls, 1);
    expect(spy.initializeCount, 1);
    expect(manager.isInitialized, isTrue);
    expect(manager.activeProvider, same(spy));
    expect(spy.spoken, ['Bonjour.']);
  });

  test('3. deuxième action vocale réutilise la même instance (0 re-init)',
      () async {
    var factoryCalls = 0;
    late _SpyProvider spy;
    final manager = VoiceManager(
      providerFactory: () {
        factoryCalls++;
        return spy = _SpyProvider();
      },
      sentencePause: const Duration(milliseconds: 1),
    );

    await manager.speak('Un.');
    final providerAfterFirst = manager.activeProvider;
    await manager.speak('Deux.');

    expect(factoryCalls, 1, reason: 'aucune nouvelle instance');
    expect(spy.initializeCount, 1, reason: 'aucun re-initialize');
    expect(manager.activeProvider, same(providerAfterFirst));
    expect(spy.spoken, ['Un.', 'Deux.']);
  });

  test('4. stop() fonctionne après initialisation', () async {
    late _SpyProvider spy;
    final manager = VoiceManager(providerFactory: () => spy = _SpyProvider());

    await manager.speak('Test.');
    await manager.stop();

    expect(spy.stopCount, 1);
  });

  test(
      '4bis / 5. stop() AVANT toute utilisation vocale est un no-op '
      '(ne crée pas de moteur TTS)', () async {
    var factoryCalls = 0;
    final manager =
        VoiceManager(providerFactory: () {
      factoryCalls++;
      return _SpyProvider();
    });

    await manager.stop(); // ex. dispose de l'écran, ou barge-in micro

    expect(factoryCalls, 0);
    expect(manager.activeProvider, isNull);
    expect(manager.isInitialized, isFalse);
  });

  test(
      '6. après stop() de nettoyage, plus aucun speak n\'est délégué au '
      'fournisseur si l\'appelant cesse de l\'utiliser', () async {
    late _SpyProvider spy;
    final manager = VoiceManager(
      providerFactory: () => spy = _SpyProvider(),
      sentencePause: const Duration(milliseconds: 1),
    );

    await manager.speak('Avant.');
    await manager.stop();
    // L'appelant (écran) est "disposé" : il ne rappelle plus speak().

    expect(spy.spoken, ['Avant.']);
    expect(spy.stopCount, 1);
  });

  test('7. interactions existantes : segmentation + nettoyage inchangés',
      () async {
    late _SpyProvider spy;
    final manager = VoiceManager(
      providerFactory: () => spy = _SpyProvider(),
      sentencePause: const Duration(milliseconds: 1),
    );

    await manager.speak(
        '**Commande confirmée** 👍. Merci de votre `confiance` !');

    // 2 phrases (« Commande confirmée 👍. » / « Merci … confiance ! »),
    // markdown + emoji retirés.
    expect(spy.spoken.length, 2);
    final joined = spy.spoken.join(' ');
    expect(joined, isNot(contains('**')));
    expect(joined, isNot(contains('`')));
    expect(joined, isNot(contains('👍')));
    expect(joined, contains('Commande confirmée'));
    expect(joined, contains('confiance'));
  });

  test('setProvider reste opérationnel (voix IA payante future)', () async {
    final first = _SpyProvider();
    final manager = VoiceManager(provider: first);
    await manager.speak('X.');

    final second = _SpyProvider();
    await manager.setProvider(second);
    await manager.speak('Y.');

    expect(first.stopCount, greaterThanOrEqualTo(1));
    expect(second.initializeCount, 1);
    expect(second.spoken, ['Y.']);
    expect(manager.activeProvider, same(second));
  });
}
