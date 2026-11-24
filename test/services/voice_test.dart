import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'package:az_express/services/voice/android_tts_provider.dart';
import 'package:az_express/services/voice/voice_manager.dart';
import 'package:az_express/services/voice/voice_provider.dart';

/// Faux moteur `flutter_tts` — n'invoque jamais le canal de méthode natif
/// (aucun des appels ci-dessous ne fait `super.xxx()`), donc utilisable dans
/// un test unitaire pur, sans appareil ni émulateur. Enregistre chaque appel
/// pour permettre des assertions précises (Master Prompt 119, section Tests).
class _FakeFlutterTts implements FlutterTts {
  List<String> engines = [];
  List<Map<String, String>> voices = [];

  String? setEngineCalledWith;
  Map<String, String>? setVoiceCalledWith;
  String? setLanguageCalledWith;
  double? speechRate;
  double? pitch;
  double? volume;
  final List<String> spoken = [];
  bool stopped = false;

  @override
  Future<dynamic> get getEngines async => engines;

  @override
  Future<dynamic> get getVoices async => voices;

  @override
  Future<dynamic> setEngine(String engine) async {
    setEngineCalledWith = engine;
  }

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    setVoiceCalledWith = voice;
  }

  @override
  Future<dynamic> setLanguage(String language) async {
    setLanguageCalledWith = language;
  }

  @override
  Future<dynamic> setSpeechRate(double rate) async {
    speechRate = rate;
  }

  @override
  Future<dynamic> setPitch(double p) async {
    pitch = p;
  }

  @override
  Future<dynamic> setVolume(double v) async {
    volume = v;
  }

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    spoken.add(text);
  }

  @override
  Future<dynamic> stop() async {
    stopped = true;
  }

  // Le reste de l'API FlutterTts n'est jamais utilisé par AndroidTtsProvider
  // — noSuchMethod évite d'avoir à stubber ~30 méthodes non pertinentes ici.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Fournisseur de test générique — enregistre chaque texte reçu par
/// `speak()`, sans dépendre de flutter_tts, pour vérifier le comportement de
/// VoiceManager (nettoyage + segmentation) indépendamment du niveau 1.
class _RecordingVoiceProvider implements VoiceProvider {
  final List<String> spoken = [];
  bool stopCalled = false;
  bool initializeCalled = false;
  double? lastSpeechRate;

  @override
  String get name => 'RecordingVoiceProvider';

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {
    initializeCalled = true;
  }

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {
    stopCalled = true;
  }

  @override
  Future<void> applyVoiceSettings({
    required double speechRate,
    required double pitch,
    required double volume,
  }) async {
    lastSpeechRate = speechRate;
  }
}

void main() {
  // Requis car le repli "fournisseur niveau 2 indisponible" (ci-dessous)
  // construit un vrai AndroidTtsProvider()/FlutterTts() par défaut, dont le
  // constructeur enregistre un handler de MethodChannel — nécessite un
  // binding Flutter initialisé même dans un test purement unitaire.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidTtsProvider — sélection de moteur (compatibilité Samsung)', () {
    test(
        'préfère "Speech Services by Google" quand Samsung TTS est aussi présent',
        () async {
      final fake = _FakeFlutterTts()
        ..engines = ['com.samsung.SMT', 'com.google.android.tts'];
      final provider = AndroidTtsProvider(tts: fake);

      await provider.debugSelectBestEngine();

      expect(fake.setEngineCalledWith, 'com.google.android.tts');
      expect(provider.debugSelectedEngine, 'com.google.android.tts');
    });

    test(
        'ne force aucun moteur si "Speech Services by Google" est absent (repli moteur système)',
        () async {
      final fake = _FakeFlutterTts()..engines = ['com.samsung.SMT'];
      final provider = AndroidTtsProvider(tts: fake);

      await provider.debugSelectBestEngine();

      expect(fake.setEngineCalledWith, isNull);
      expect(provider.debugSelectedEngine, isNull);
    });

    test('ne plante jamais si getEngines() échoue', () async {
      final provider = AndroidTtsProvider(tts: _ThrowingFlutterTts());
      await expectLater(provider.debugSelectBestEngine(), completes);
      expect(provider.debugSelectedEngine, isNull);
    });
  });

  group('AndroidTtsProvider — sélection de la meilleure voix française', () {
    test('préfère une voix fr-FR exacte à une variante régionale', () async {
      final fake = _FakeFlutterTts()
        ..voices = [
          {'name': 'voice-ca', 'locale': 'fr-CA'},
          {'name': 'voice-fr', 'locale': 'fr-FR'},
        ];
      final provider = AndroidTtsProvider(tts: fake);

      await provider.debugSelectBestFrenchVoice();

      expect(fake.setVoiceCalledWith?['name'], 'voice-fr');
      expect(provider.debugSelectedVoiceName, 'voice-fr');
    });

    test('accepte une variante française si aucun fr-FR exact n\'existe',
        () async {
      final fake = _FakeFlutterTts()
        ..voices = [
          {'name': 'voice-ca', 'locale': 'fr-CA'},
        ];
      final provider = AndroidTtsProvider(tts: fake);

      await provider.debugSelectBestFrenchVoice();

      expect(fake.setVoiceCalledWith?['name'], 'voice-ca');
    });

    test(
        'retombe sur setLanguage(fr-FR) si aucune voix française n\'est listée',
        () async {
      final fake = _FakeFlutterTts()..voices = [];
      final provider = AndroidTtsProvider(tts: fake);

      await provider.debugSelectBestFrenchVoice();

      expect(fake.setLanguageCalledWith, 'fr-FR');
      expect(provider.debugSelectedVoiceName, isNull);
    });
  });

  group(
      'AndroidTtsProvider — réglages de débit/hauteur/volume (voix naturelle)',
      () {
    test('applyVoiceSettings transmet exactement les valeurs demandées',
        () async {
      final fake = _FakeFlutterTts();
      final provider = AndroidTtsProvider(tts: fake);

      await provider.applyVoiceSettings(
          speechRate: 0.48, pitch: 1.0, volume: 1.0);

      expect(fake.speechRate, 0.48);
      expect(fake.pitch, 1.0);
      expect(fake.volume, 1.0);
    });

    test(
        'initialize() choisit un débit inférieur à 1.0 (moins robotique que le débit par défaut)',
        () async {
      final fake = _FakeFlutterTts();
      final provider = AndroidTtsProvider(tts: fake);

      await provider.initialize();

      expect(fake.speechRate, lessThan(1.0));
      expect(provider.isAvailable, isTrue);
    });
  });

  group('VoiceManager — nettoyage du texte avant lecture', () {
    test('supprime markdown (**/***/#/```) et underscores avant de parler',
        () async {
      final recorder = _RecordingVoiceProvider();
      final manager = VoiceManager(provider: recorder);

      await manager
          .speak('**Titre important** : voici `du code` et _emphase_.');

      final spokenText = recorder.spoken.join(' ');
      expect(spokenText, isNot(contains('**')));
      expect(spokenText, isNot(contains('`')));
      expect(spokenText, isNot(contains('_')));
    });

    test(
        'supprime les emoji avant de parler (évite "émoji pouce levé" façon Samsung TTS)',
        () async {
      final recorder = _RecordingVoiceProvider();
      final manager = VoiceManager(provider: recorder);

      await manager.speak('Commande confirmée 👍 merci 😊 !');

      final spokenText = recorder.spoken.join(' ');
      expect(spokenText, isNot(contains('👍')));
      expect(spokenText, isNot(contains('😊')));
      expect(spokenText, contains('Commande confirmée'));
    });

    test('ignore silencieusement un texte vide après nettoyage', () async {
      final recorder = _RecordingVoiceProvider();
      final manager = VoiceManager(provider: recorder);

      await manager.speak('**  **');

      expect(recorder.spoken, isEmpty);
    });
  });

  group('VoiceManager — naturalité du débit (segmentation en phrases)', () {
    test(
        'découpe un texte multi-phrases en plusieurs appels speak() séquentiels',
        () async {
      final recorder = _RecordingVoiceProvider();
      final manager = VoiceManager(
        provider: recorder,
        sentencePause: const Duration(milliseconds: 1),
      );

      await manager.speak(
          'Votre commande est confirmée. Le livreur arrive dans 10 minutes ! Merci de votre confiance.');

      expect(recorder.spoken.length, 3);
      expect(recorder.spoken[0], contains('confirmée'));
      expect(recorder.spoken[1], contains('10 minutes'));
      expect(recorder.spoken[2], contains('confiance'));
    });

    test('une phrase unique ne produit qu\'un seul appel speak()', () async {
      final recorder = _RecordingVoiceProvider();
      final manager = VoiceManager(provider: recorder);

      await manager.speak('Bonjour.');

      expect(recorder.spoken.length, 1);
    });
  });

  group('VoiceManager — changement de fournisseur sans impacter l\'appelant',
      () {
    test('setProvider() arrête l\'ancien fournisseur et initialise le nouveau',
        () async {
      final first = _RecordingVoiceProvider();
      final manager = VoiceManager(provider: first);
      await manager.initialize();

      final second = _RecordingVoiceProvider();
      await manager.setProvider(second);

      expect(first.stopCalled, isTrue);
      expect(second.initializeCalled, isTrue);
      expect(manager.activeProvider, second);
    });

    test(
        'un fournisseur de niveau 2 indisponible retombe automatiquement sur AndroidTtsProvider',
        () async {
      final unavailable = _UnavailableVoiceProvider();
      final manager = VoiceManager(provider: unavailable);

      await manager.initialize();

      expect(manager.activeProvider, isA<AndroidTtsProvider>());
    });
  });
}

class _ThrowingFlutterTts implements FlutterTts {
  @override
  Future<dynamic> get getEngines async => throw Exception('canal indisponible');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _UnavailableVoiceProvider implements VoiceProvider {
  @override
  String get name => 'Indisponible (test)';

  @override
  bool get isAvailable => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> applyVoiceSettings({
    required double speechRate,
    required double pitch,
    required double volume,
  }) async {}
}
