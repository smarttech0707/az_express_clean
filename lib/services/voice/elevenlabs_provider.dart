import 'voice_provider.dart';

/// Niveau 2 (Master Prompt 119) — architecture prête pour ElevenLabs
/// (voix IA ultra-naturelles), PAS encore activée : aucune clé ElevenLabs
/// n'existe dans ce projet, et une synthèse vocale payante doit être
/// appelée depuis une Cloud Function dédiée (jamais une clé API dans l'app
/// Flutter). Même contrat que [GoogleCloudTtsProvider] — voir ce fichier
/// pour le raisonnement complet, non répété ici.
class ElevenLabsProvider implements VoiceProvider {
  @override
  String get name => 'ElevenLabs (non configuré)';

  @override
  bool get isAvailable => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String text) async {
    throw UnimplementedError(
      'ElevenLabsProvider n\'est pas encore configuré — nécessite une Cloud '
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
