import 'voice_provider.dart';

/// Niveau 2 (Master Prompt 119) — architecture prête pour Google Cloud
/// Text-to-Speech (voix neuronales), PAS encore activée : aucune clé API
/// Google Cloud n'existe dans ce projet (`functions/.env` n'a que
/// FEEXPAY_TOKEN/FEEXPAY_WEBHOOK_SECRET/ANTHROPIC_API_KEY), et une synthèse
/// vocale cloud doit être appelée depuis une Cloud Function (jamais une clé
/// API directement dans l'app Flutter — même règle que tout le reste du
/// projet). Cette classe documente le contrat exact à respecter le jour où
/// ce fournisseur sera réellement branché, sans jamais prétendre
/// fonctionner en attendant : [isAvailable] reste `false`, [speak] ne fait
/// jamais un appel réseau fantôme.
class GoogleCloudTtsProvider implements VoiceProvider {
  @override
  String get name => 'Google Cloud TTS (non configuré)';

  @override
  bool get isAvailable => false;

  @override
  Future<void> initialize() async {
    // Rien à initialiser : ce fournisseur reste inactif tant qu'aucune
    // Cloud Function de synthèse vocale n'existe côté serveur.
  }

  @override
  Future<void> speak(String text) async {
    throw UnimplementedError(
      'GoogleCloudTtsProvider n\'est pas encore configuré — nécessite une '
      'Cloud Function dédiée (clé API côté functions/.env, jamais côté '
      'client) avant de pouvoir synthétiser de la voix.',
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
