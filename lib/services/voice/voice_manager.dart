import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../screens/ai/az_ia_message_parser.dart';
import 'android_tts_provider.dart';
import 'voice_provider.dart';

/// Orchestrateur unique de la voix AZ IA (Master Prompt 119) — le seul point
/// que `az_ia_chat_screen.dart` doit connaître. Responsabilités :
/// - choisir/activer un [VoiceProvider] (niveau 1 gratuit par défaut,
///   niveau 2 IA plus tard sans changer l'appelant) ;
/// - nettoyer le texte avant lecture (markdown, emoji) ;
/// - découper le texte en phrases avec de courtes pauses entre elles, pour
///   sonner comme une vraie conversation plutôt qu'un bloc monocorde ;
/// - appliquer une personnalité vocale cohérente (débit/hauteur/volume).
///
/// Ne remplace PAS la reconnaissance vocale (speech_to_text, gérée
/// directement par az_ia_chat_screen.dart, inchangée) — uniquement la
/// synthèse (sortie), en remplacement du `FlutterTts` utilisé jusqu'ici
/// sans configuration (Prompt 116/M7).
class VoiceManager {
  /// Fabrique du fournisseur niveau 1 — n'est appelée qu'à la première
  /// utilisation vocale réelle (voir [_ensureProvider]). Construire un
  /// [AndroidTtsProvider] instancie un `FlutterTts`, ce qui ne doit PAS
  /// arriver tant que l'utilisateur n'a rien demandé de vocal.
  final VoiceProvider Function() _providerFactory;

  /// `null` tant qu'aucune fonctionnalité vocale n'a été utilisée — aucun
  /// moteur TTS n'est alors créé/connecté.
  VoiceProvider? _provider;
  bool _initialized = false;

  /// Pause entre deux phrases (Master Prompt 119, "pauses naturelles") —
  /// `flutter_tts` n'a pas de contrôle SSML fiable multi-plateforme ; une
  /// courte pause réelle entre chaque `speak()` séquentiel reste le moyen
  /// le plus honnête d'obtenir un débit conversationnel plutôt qu'un bloc
  /// de texte lu d'une traite.
  final Duration sentencePause;

  VoiceManager(
      {VoiceProvider? provider,
      VoiceProvider Function()? providerFactory,
      this.sentencePause = const Duration(milliseconds: 180)})
      : _provider = provider,
        _providerFactory = providerFactory ?? (() => AndroidTtsProvider());

  /// `null` tant qu'aucune synthèse vocale n'a été demandée.
  VoiceProvider? get activeProvider => _provider;

  /// `true` une fois le fournisseur réellement initialisé (première
  /// utilisation vocale). Exposé pour les tests.
  @visibleForTesting
  bool get isInitialized => _initialized;

  VoiceProvider _ensureProvider() => _provider ??= _providerFactory();

  Future<void> initialize() async {
    final provider = _ensureProvider();
    await provider.initialize();
    if (!provider.isAvailable && provider is! AndroidTtsProvider) {
      // Tout fournisseur de niveau 2 non configuré retombe sur le niveau 1
      // gratuit — jamais un AZ IA muet parce qu'un fournisseur payant
      // n'est pas encore activé.
      debugPrint(
          '[VoiceManager] "${provider.name}" indisponible — repli sur AndroidTtsProvider.');
      _provider = AndroidTtsProvider();
      await _provider!.initialize();
    }
    _initialized = true;
    debugPrint(
        '[VoiceManager] Fournisseur actif : ${_provider!.name} (disponible: ${_provider!.isAvailable})');
  }

  /// Change de fournisseur à chaud (ex. activer une voix IA payante plus
  /// tard) — le reste de l'application n'a jamais besoin de le savoir.
  Future<void> setProvider(VoiceProvider provider) async {
    await _provider?.stop();
    _provider = provider;
    await provider.initialize();
    _initialized = true;
  }

  /// N'initialise jamais le moteur TTS : s'il n'a jamais été créé, il n'y a
  /// rien à arrêter (utilisé aussi en anti-collision micro/haut-parleur).
  Future<void> stop() async {
    final provider = _provider;
    if (provider == null) return;
    await provider.stop();
  }

  /// Lit `rawText` (la réponse brute d'AZ IA, potentiellement pleine de
  /// markdown/emoji) à voix haute, nettoyée et segmentée pour un débit
  /// naturel. Ne fait jamais planter l'appelant : toute erreur est avalée
  /// et journalisée (la voix est un agrément, jamais un chemin critique).
  Future<void> speak(String rawText) async {
    // Première utilisation vocale réelle → c'est ICI (et pas avant) que le
    // moteur TTS est créé et connecté.
    if (!_initialized) await initialize();
    final provider = _provider!;
    if (!provider.isAvailable) {
      debugPrint(
          '[VoiceManager] Aucun fournisseur vocal disponible — lecture ignorée.');
      return;
    }

    final cleaned = _prepareForSpeech(rawText);
    if (cleaned.isEmpty) return;

    try {
      final sentences = _splitIntoSentences(cleaned);
      for (var i = 0; i < sentences.length; i++) {
        await provider.speak(sentences[i]);
        if (i < sentences.length - 1) {
          await Future.delayed(sentencePause);
        }
      }
    } catch (e) {
      debugPrint('[VoiceManager] Erreur de lecture vocale : $e');
    }
  }

  /// Nettoyage (Master Prompt 119, section "Nettoyage du texte") — réutilise
  /// `AzIaMessageParser.cleanForSpeech` (markdown déjà couvert : **, ***,
  /// #/##/###, backticks, puces) et complète avec ce qui manquait :
  /// underscores d'emphase (_texte_) et emoji.
  String _prepareForSpeech(String text) {
    var t = AzIaMessageParser.cleanForSpeech(text);
    // Underscores d'emphase markdown (_mot_) — jamais utiles à l'oral.
    t = t.replaceAll('_', ' ');
    // Emoji — un moteur TTS les ignore silencieusement la plupart du temps,
    // mais certains (dont Samsung TTS) tentent de les décrire à voix haute
    // ("émoji pouce levé"), ce qui casse immédiatement le naturel recherché.
    t = t.replaceAll(_emojiPattern, '');
    t = t.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
    return t;
  }

  static final RegExp _emojiPattern = RegExp(
    r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2190}-\u{21FF}\u{2B00}-\u{2BFF}]',
    unicode: true,
  );

  /// Découpe en phrases sur la ponctuation forte (. ! ? :), en conservant
  /// le signe de ponctuation — chaque phrase est ensuite lue séparément
  /// avec une courte pause, pour un débit conversationnel plutôt qu'un bloc.
  List<String> _splitIntoSentences(String text) {
    final parts = text.split(RegExp(r'(?<=[.!?:])\s+'));
    return parts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  }
}
