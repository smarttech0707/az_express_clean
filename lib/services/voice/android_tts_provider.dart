import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'voice_provider.dart';

/// Niveau 1 (Master Prompt 119) — voix gratuite via `flutter_tts`, déjà
/// utilisée depuis le jalon M7 mais jusqu'ici configurée au strict minimum
/// (`setLanguage('fr-FR')` seul, aucun réglage de débit/hauteur/volume,
/// aucune sélection de moteur/voix). Cette implémentation :
/// - préfère le moteur "Speech Services by Google"
///   (`com.google.android.tts`) à un moteur constructeur (ex. Samsung TTS)
///   quand les deux sont installés ;
/// - choisit automatiquement la meilleure voix française disponible ;
/// - règle un débit/hauteur/volume pensés pour sonner naturel plutôt que
///   robotique.
class AndroidTtsProvider implements VoiceProvider {
  final FlutterTts _tts;
  bool _available = false;
  String? _selectedVoiceName;
  String? _selectedEngine;

  AndroidTtsProvider({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  @override
  String get name => 'flutter_tts (${_selectedEngine ?? 'moteur système'})';

  @override
  bool get isAvailable => _available;

  // Moteur Google déjà connu sur la quasi-totalité des appareils Android
  // avec les services Google — le préférer à un moteur constructeur (ex.
  // com.samsung.SMT) quand les deux sont présents.
  static const _preferredEngines = ['com.google.android.tts'];

  @override
  Future<void> initialize() async {
    try {
      if (Platform.isAndroid) {
        await _selectBestEngine();
      }
      await _selectBestFrenchVoice();
      await applyVoiceSettings(speechRate: 0.48, pitch: 1.0, volume: 1.0);
      _available = true;
    } catch (e) {
      // Un échec d'initialisation (plateforme non supportée, TTS absent...)
      // ne doit jamais faire planter AZ IA — juste indiquer que ce
      // fournisseur n'est pas utilisable, VoiceManager gère le repli.
      debugPrint(
          '[VoiceManager] AndroidTtsProvider.initialize() a échoué : $e');
      _available = false;
    }
  }

  /// Sélectionne "Speech Services by Google" si installé plutôt que le
  /// moteur du fabricant (ex. Samsung TTS, souvent plus robotique en
  /// français). `getEngines`/`setEngine` sont Android-only dans flutter_tts
  /// — jamais appelés ailleurs (protégé par `Platform.isAndroid` ci-dessus).
  Future<void> _selectBestEngine() async {
    try {
      final dynamic raw = await _tts.getEngines;
      final engines =
          (raw is List) ? raw.map((e) => e.toString()).toList() : <String>[];
      debugPrint('[VoiceManager] Moteurs TTS disponibles : $engines');
      for (final preferred in _preferredEngines) {
        if (engines.contains(preferred)) {
          await _tts.setEngine(preferred);
          _selectedEngine = preferred;
          debugPrint('[VoiceManager] Moteur sélectionné : $preferred');
          return;
        }
      }
      debugPrint(
          '[VoiceManager] Aucun moteur préféré trouvé — conserve le moteur système par défaut.');
    } catch (e) {
      debugPrint('[VoiceManager] getEngines()/setEngine() indisponible : $e');
    }
  }

  /// Parcourt les voix disponibles et choisit la meilleure voix française :
  /// priorité à `fr-FR` exact, puis toute variante `fr-*`, sinon repli sur
  /// `setLanguage('fr-FR')` (comportement déjà existant, inchangé si aucune
  /// voix nommée n'est trouvée).
  Future<void> _selectBestFrenchVoice() async {
    try {
      final dynamic raw = await _tts.getVoices;
      final voices = (raw is List) ? raw.cast<dynamic>() : <dynamic>[];
      final frVoices = voices.where((v) {
        final locale =
            (v is Map ? v['locale'] : null)?.toString().toLowerCase() ?? '';
        return locale.startsWith('fr');
      }).toList();

      debugPrint(
          '[VoiceManager] ${frVoices.length} voix françaises disponibles.');

      Map<dynamic, dynamic>? best;
      for (final v in frVoices) {
        final locale = (v['locale'] ?? '').toString().toLowerCase();
        if (locale == 'fr-fr') {
          best = v;
          break;
        }
        best ??= v;
      }

      if (best != null) {
        final voiceMap = {
          'name': best['name'].toString(),
          'locale': best['locale'].toString(),
        };
        await _tts.setVoice(voiceMap);
        _selectedVoiceName = voiceMap['name'];
        debugPrint(
            '[VoiceManager] Voix sélectionnée : $_selectedVoiceName (${voiceMap['locale']})');
      } else {
        debugPrint(
            '[VoiceManager] Aucune voix française nommée trouvée — repli sur setLanguage(fr-FR).');
        await _tts.setLanguage('fr-FR');
      }
    } catch (e) {
      debugPrint(
          '[VoiceManager] getVoices()/setVoice() indisponible, repli sur setLanguage : $e');
      await _tts.setLanguage('fr-FR');
    }
  }

  @override
  Future<void> applyVoiceSettings({
    required double speechRate,
    required double pitch,
    required double volume,
  }) async {
    await _tts.setSpeechRate(speechRate);
    await _tts.setPitch(pitch);
    await _tts.setVolume(volume);
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await _tts.speak(text);
  }

  @override
  Future<void> stop() => _tts.stop();

  /// Exposé pour les tests/diagnostics (Master Prompt 119, section Tests) —
  /// jamais utilisé par la logique métier elle-même.
  @visibleForTesting
  String? get debugSelectedVoiceName => _selectedVoiceName;
  @visibleForTesting
  String? get debugSelectedEngine => _selectedEngine;

  /// Permet aux tests d'exercer la sélection de moteur/voix indépendamment
  /// du garde `Platform.isAndroid` d'`initialize()` (les tests unitaires
  /// tournent sur l'hôte de build, pas sur un appareil Android réel).
  @visibleForTesting
  Future<void> debugSelectBestEngine() => _selectBestEngine();
  @visibleForTesting
  Future<void> debugSelectBestFrenchVoice() => _selectBestFrenchVoice();
}
