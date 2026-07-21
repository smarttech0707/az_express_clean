/// Interface commune à tout fournisseur de synthèse vocale AZ IA
/// (Master Prompt 119) — permet de changer de fournisseur (gratuit
/// `flutter_tts` aujourd'hui, voix IA payante demain) sans jamais modifier
/// [VoiceManager] ni l'écran de chat. Chaque implémentation reste
/// responsable de son propre moteur/API, [VoiceManager] reste responsable
/// du nettoyage de texte et de la personnalité vocale.
abstract class VoiceProvider {
  /// Nom lisible du fournisseur (pour diagnostic/tests, jamais affiché à
  /// l'utilisateur final).
  String get name;

  /// `true` si ce fournisseur peut réellement être utilisé maintenant (clé
  /// API présente, plateforme supportée, etc.) — un fournisseur non
  /// configuré ne doit jamais lever d'exception, seulement retourner `false`.
  bool get isAvailable;

  /// Prépare le fournisseur (sélection de voix, langue, tuning) — appelé une
  /// fois avant le premier [speak]. Ne doit jamais lancer d'exception non
  /// interceptée : un échec d'initialisation doit seulement laisser
  /// [isAvailable] à `false`.
  Future<void> initialize();

  /// Lit `text` à voix haute. `text` est déjà nettoyé/segmenté par
  /// [VoiceManager] — ce fournisseur n'a qu'à le prononcer.
  Future<void> speak(String text);

  /// Arrête immédiatement toute lecture en cours.
  Future<void> stop();

  /// Réglages de personnalité vocale (Master Prompt 119) — débit, hauteur,
  /// volume. Chaque fournisseur les interprète selon son propre SDK
  /// (`flutter_tts` utilise des échelles 0.0-1.0 sur Android, différentes
  /// sur iOS ; un futur fournisseur cloud utiliserait ses propres unités).
  Future<void> applyVoiceSettings({
    required double speechRate,
    required double pitch,
    required double volume,
  });
}
