import 'voice_provider.dart';

/// Niveau 2 (Master Prompt 119) — architecture prête pour OpenAI
/// Text-to-Speech, PAS encore activée : aucune clé OpenAI TTS n'existe dans
/// ce projet, et une synthèse vocale payante doit être appelée depuis une
/// Cloud Function dédiée (jamais une clé API dans l'app Flutter). Même
/// contrat que [GoogleCloudTtsProvider] — voir ce fichier pour le
/// raisonnement complet, non répété ici.
class OpenAiTtsProvider implements VoiceProvider {
  @override
  String get name => 'OpenAI TTS (non configuré)';

  @override
  bool get isAvailable => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String text) async {
    throw UnimplementedError(
      'OpenAiTtsProvider n\'est pas encore configuré — nécessite une Cloud '
      'Function dédiée avant de pouvoir synthétiser de la voix.',
    );
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> applyVoiceSettings({
    required double speechRate,
    required double pitch,
    required double volume,
  }) async {}
}
