import 'package:flutter/foundation.dart';

import '../services/az_ia_service.dart';

enum AzIaSender { user, assistant }

class AzIaMessage {
  final AzIaSender sender;
  final String text;
  const AzIaMessage({required this.sender, required this.text});
}

/// État de la conversation avec AZ IA (M0 : texte seul, sans outils).
class AzIaProvider extends ChangeNotifier {
  final AzIaService _service = AzIaService();

  final List<AzIaMessage> _messages = [];
  String? _conversationId;
  bool _isSending = false;
  String? _error;

  List<AzIaMessage> get messages => List.unmodifiable(_messages);
  bool get isSending => _isSending;
  String? get error => _error;

  /// Retourne le texte de la réponse d'AZ IA (succès ou message d'erreur) —
  /// utilisé par l'écran pour, entre autres, le lire à voix haute (M7).
  Future<String?> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _isSending) return null;

    _messages.add(AzIaMessage(sender: AzIaSender.user, text: trimmed));
    _isSending = true;
    _error = null;
    notifyListeners();

    String? replyText;
    try {
      final result = await _service.sendMessage(
        message: trimmed,
        conversationId: _conversationId,
      );
      _conversationId = result.conversationId;
      replyText = result.reply;
      _messages.add(AzIaMessage(sender: AzIaSender.assistant, text: replyText));
    } catch (e) {
      _error = "AZ IA n'a pas pu répondre. Vérifiez votre connexion et réessayez.";
      replyText = _error;
      _messages.add(AzIaMessage(sender: AzIaSender.assistant, text: _error!));
    } finally {
      _isSending = false;
      notifyListeners();
    }
    return replyText;
  }

  /// Efface l'historique côté serveur (`ai_conversations`) et réinitialise
  /// l'état local — après appel, la conversation repart de zéro.
  Future<void> clearHistory() async {
    await _service.clearHistory();
    _messages.clear();
    _conversationId = null;
    _error = null;
    notifyListeners();
  }
}
