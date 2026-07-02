import 'package:cloud_functions/cloud_functions.dart';

class AzIaChatResult {
  final String conversationId;
  final String reply;
  const AzIaChatResult({required this.conversationId, required this.reply});
}

/// Client léger pour la Cloud Function `azIaChat`.
/// AZ IA ne touche jamais Firestore directement — tout passe par cet appel.
class AzIaService {
  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  Future<AzIaChatResult> sendMessage({
    required String message,
    String? conversationId,
  }) async {
    final callable = _functions.httpsCallable(
      'azIaChat',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 90)),
    );

    final result = await callable.call(<String, dynamic>{
      'message': message,
      if (conversationId != null) 'conversationId': conversationId,
    });

    final data = Map<String, dynamic>.from(result.data as Map);
    return AzIaChatResult(
      conversationId: data['conversationId'] as String,
      reply: data['reply'] as String,
    );
  }

  /// Efface tout l'historique de conversation de l'utilisateur courant
  /// (Prompt 33) — l'utilisateur reprend son contrôle sur la seule mémoire
  /// IA qui existe aujourd'hui (`ai_conversations`), jusqu'ici inaccessible
  /// depuis le client.
  Future<void> clearHistory() async {
    await _functions.httpsCallable('clearAiHistory').call();
  }
}
