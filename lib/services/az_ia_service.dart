import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AzIaChatResult {
  final String conversationId;
  final String reply;
  final AzIaStructuredResponse response;
  const AzIaChatResult({
    required this.conversationId,
    required this.reply,
    required this.response,
  });
}

/// Suggestion rapide déclarée par le serveur (Master Prompt 117, remplace
/// les puces devinées côté Flutter par mots-clés au Prompt 116) — un simple
/// texte pré-rempli envoyé via le même chemin que la saisie manuelle,
/// jamais une action qui mute quoi que ce soit directement.
class AzIaResponseAction {
  final String label;
  final String message;
  const AzIaResponseAction({required this.label, required this.message});

  factory AzIaResponseAction.fromJson(Map<String, dynamic> json) {
    return AzIaResponseAction(
      label: json['label'] as String? ?? '',
      message: json['message'] as String? ?? '',
    );
  }
}

/// Réponse structurée AZ IA (Master Prompt 117) — remplace les heuristiques
/// visuelles basées sur des mots-clés (Prompt 116) par une enveloppe
/// construite côté serveur à partir de DONNÉES RÉELLES (l'outil
/// effectivement exécuté et son résultat réel). Flutter ne devine plus
/// rien : il choisit le widget à afficher uniquement via [type], et lit
/// [icon]/[color] dans des tables de correspondance statiques (jamais du
/// texte re-parsé) — voir az_ia_response_widgets.dart.
class AzIaStructuredResponse {
  final String type;
  final String title;
  final String message;
  final String icon;
  final String color;
  final String priority;
  final List<AzIaResponseAction> actions;
  final Map<String, dynamic> payload;

  const AzIaStructuredResponse({
    required this.type,
    required this.title,
    required this.message,
    required this.icon,
    required this.color,
    required this.priority,
    required this.actions,
    required this.payload,
  });

  /// Compatibilité descendante (section "Compatibilité" du Prompt 117) —
  /// un ancien message texte sans enveloppe structurée (historique chargé
  /// avant ce déploiement, ou message d'erreur construit localement) reçoit
  /// systématiquement `type: 'generic'` plutôt que de faire planter l'écran.
  factory AzIaStructuredResponse.generic(String message) {
    return AzIaStructuredResponse(
      type: 'generic',
      title: 'AZ IA',
      message: message,
      icon: 'auto_awesome',
      color: '#6D4C41',
      priority: 'normal',
      actions: const [],
      payload: const {},
    );
  }

  factory AzIaStructuredResponse.fromJson(dynamic json, {required String fallbackMessage}) {
    if (json == null || json is! Map) {
      return AzIaStructuredResponse.generic(fallbackMessage);
    }
    final map = Map<String, dynamic>.from(json);
    final rawActions = map['actions'];
    final rawMessage = map['message'] as String?;
    return AzIaStructuredResponse(
      type: map['type'] as String? ?? 'generic',
      title: map['title'] as String? ?? 'AZ IA',
      // `??` seul ne suffit pas : un `message` présent mais vide (`''`) doit
      // aussi retomber sur `fallbackMessage`, pas juste un `message` absent.
      message: (rawMessage != null && rawMessage.trim().isNotEmpty)
          ? rawMessage
          : fallbackMessage,
      icon: map['icon'] as String? ?? 'auto_awesome',
      color: map['color'] as String? ?? '#6D4C41',
      priority: map['priority'] as String? ?? 'normal',
      actions: rawActions is List
          ? rawActions
              .whereType<Map>()
              .map((a) => AzIaResponseAction.fromJson(Map<String, dynamic>.from(a)))
              .toList()
          : const [],
      payload: map['payload'] is Map ? Map<String, dynamic>.from(map['payload'] as Map) : const {},
    );
  }

  /// Vrai si cette réponse a réellement quelque chose à montrer (texte ou
  /// données de payload) — utilisé côté rendu pour ne jamais construire une
  /// carte entièrement vide (cadre blanc décoré sans aucun contenu visible).
  /// Volontairement permissif sur le payload (toute valeur non vide compte,
  /// sans reproduire la logique d'affichage précise de chaque carte) : en
  /// cas de doute, on préfère garder une carte plutôt que d'en masquer une
  /// qui aurait eu du contenu.
  bool get hasVisibleContent {
    if (message.trim().isNotEmpty) return true;
    return payload.values.any((v) {
      if (v == null) return false;
      if (v is String) return v.trim().isNotEmpty;
      if (v is Iterable) return v.isNotEmpty;
      if (v is Map) return v.isNotEmpty;
      return true;
    });
  }

  /// Copie avec un `message` différent — utilisé uniquement pour l'effet
  /// machine-à-écrire (Master Prompt 116/117) : seul le texte affiché doit
  /// se révéler progressivement, jamais le type/icône/couleur/payload de
  /// l'enveloppe, qui restent fixes dès la réception de la réponse.
  AzIaStructuredResponse withMessage(String newMessage) {
    return AzIaStructuredResponse(
      type: type, title: title, message: newMessage, icon: icon,
      color: color, priority: priority, actions: actions, payload: payload,
    );
  }
}

/// Action AZ IA en attente de confirmation explicite (`ai_pending_actions`,
/// Master Prompt 115) — reflète tel quel le document Firestore déjà écrit
/// par `createPendingAction()` côté serveur (`functions/azia/pendingActions.js`).
/// Ne mute jamais rien elle-même : c'est un simple DTO de lecture.
class AzIaPendingAction {
  final String id;
  final String toolName;
  final String summaryFr;
  final num? amount;
  final Timestamp? createdAt;
  const AzIaPendingAction({
    required this.id,
    required this.toolName,
    required this.summaryFr,
    this.amount,
    this.createdAt,
  });

  factory AzIaPendingAction.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    return AzIaPendingAction(
      id: doc.id,
      toolName: data['toolName'] as String? ?? '',
      summaryFr: data['summaryFr'] as String? ?? 'Confirmer cette action ?',
      amount: data['amount'] as num?,
      createdAt: data['createdAt'] as Timestamp?,
    );
  }
}

/// Position GPS best-effort transmise à AZ IA (Master Prompt 113, section 3)
/// — jamais capturée en forçant une demande de permission depuis le chat,
/// seulement si déjà autorisée ailleurs dans l'app.
class AzIaLocation {
  final double latitude;
  final double longitude;
  final String? address;
  const AzIaLocation({required this.latitude, required this.longitude, this.address});
}

/// Client léger pour la Cloud Function `azIaChat`.
/// AZ IA ne touche jamais Firestore directement — tout passe par cet appel.
class AzIaService {
  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  Future<AzIaChatResult> sendMessage({
    required String message,
    String? conversationId,
    AzIaLocation? location,
    String? imageBase64,
    String? imageMediaType,
  }) async {
    final callable = _functions.httpsCallable(
      'azIaChat',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 90)),
    );

    final result = await callable.call(<String, dynamic>{
      'message': message,
      if (conversationId != null) 'conversationId': conversationId,
      if (location != null)
        'location': <String, dynamic>{
          'latitude': location.latitude,
          'longitude': location.longitude,
          if (location.address != null) 'address': location.address,
        },
      if (imageBase64 != null) 'imageBase64': imageBase64,
      if (imageMediaType != null) 'imageMediaType': imageMediaType,
    });

    final data = Map<String, dynamic>.from(result.data as Map);
    final reply = data['reply'] as String;
    return AzIaChatResult(
      conversationId: data['conversationId'] as String,
      reply: reply,
      // `response` peut être absent (ancienne version de la Cloud Function
      // pas encore redéployée, ou requête interceptée par un mock de test)
      // — repli automatique en type 'generic', jamais un plantage.
      response: AzIaStructuredResponse.fromJson(data['response'], fallbackMessage: reply),
    );
  }

  /// Efface tout l'historique de conversation de l'utilisateur courant
  /// (Prompt 33) — l'utilisateur reprend son contrôle sur la seule mémoire
  /// IA qui existe aujourd'hui (`ai_conversations`), jusqu'ici inaccessible
  /// depuis le client.
  Future<void> clearHistory() async {
    await _functions.httpsCallable('clearAiHistory').call();
  }

  /// Écoute la dernière action AZ IA en attente de confirmation
  /// (`ai_pending_actions`, `status == 'pending'`) pour l'utilisateur courant
  /// — lecture directe déjà autorisée par les règles Firestore
  /// (`resource.data.uid == uid()`), aucune Cloud Function nécessaire pour
  /// ça. `null` si aucune action en attente (cas normal, la grande majorité
  /// du temps) ou si l'utilisateur n'est pas connecté.
  ///
  /// Volontairement deux filtres d'égalité SANS `orderBy` (le tri du plus
  /// récent se fait côté client sur les au plus 5 documents retournés) —
  /// un `orderBy('createdAt')` combiné à ces deux filtres exigerait un
  /// nouvel index composite Firestore, hors du périmètre "aucune
  /// modification backend" de ce chantier (Master Prompt 115).
  Stream<AzIaPendingAction?> streamLatestPendingAction() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value(null);
    return FirebaseFirestore.instance
        .collection('ai_pending_actions')
        .where('uid', isEqualTo: uid)
        .where('status', isEqualTo: 'pending')
        .limit(5)
        .snapshots()
        .map((snap) {
      if (snap.docs.isEmpty) return null;
      final docs = [...snap.docs]..sort((a, b) {
        final ta = a.data()['createdAt'] as Timestamp?;
        final tb = b.data()['createdAt'] as Timestamp?;
        if (ta == null || tb == null) return 0;
        return tb.compareTo(ta);
      });
      return AzIaPendingAction.fromDoc(docs.first);
    });
  }

  /// Confirme ou annule une action en attente — seul point d'entrée réel
  /// (Master Prompt 115) : jusqu'ici rien dans l'app n'appelait jamais cette
  /// Cloud Function, malgré la règle non négociable exigeant une confirmation
  /// validée côté serveur pour toute action financière d'AZ IA.
  Future<Map<String, dynamic>> confirmAction({
    required String actionId,
    required bool confirm,
  }) async {
    final result = await _functions.httpsCallable(
      'aiConfirmAction',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    ).call(<String, dynamic>{
      'actionId': actionId,
      'decision': confirm ? 'confirm' : 'cancel',
    });
    return Map<String, dynamic>.from(result.data as Map);
  }
}
