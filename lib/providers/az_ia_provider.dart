import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../screens/ai/az_ia_offline_engine.dart';
import '../services/az_ia_service.dart';

enum AzIaSender { user, assistant }

int _nextMessageId = 0;

class AzIaMessage {
  final int id;
  final AzIaSender sender;
  final String text;
  final bool hasImage;

  /// Marqué `true` une fois que l'effet machine-à-écrire (Master Prompt 116)
  /// a fini de se dérouler pour ce message — évite de le réanimer si le
  /// widget est reconstruit (scroll, retour sur l'écran, etc.). Mutable
  /// volontairement : c'est un flag de présentation, pas une donnée métier.
  bool animated;

  /// Enveloppe structurée (Master Prompt 117) — `null` uniquement pour les
  /// messages utilisateur (jamais affichés en carte) ; toujours non-null
  /// pour un message assistant, avec repli automatique en `type: 'generic'`
  /// si le serveur n'a pas encore été redéployé avec cette fonctionnalité.
  final AzIaStructuredResponse? response;

  AzIaMessage({
    required this.sender,
    required this.text,
    this.hasImage = false,
    this.animated = false,
    this.response,
  }) : id = _nextMessageId++;
}

/// État de la conversation avec AZ IA (M0 : texte seul, sans outils).
class AzIaProvider extends ChangeNotifier {
  static const maxImageBytes = 4 * 1024 * 1024;

  static bool isImageTooLarge(int byteLength) => byteLength > maxImageBytes;
  final AzIaService _service;
  final Stream<String?> _authUidChanges;

  final List<AzIaMessage> _messages = [];
  String? _conversationId;
  bool _isSending = false;
  String? _error;

  // ── Confirmation d'action financière (Master Prompt 115) — jusqu'ici,
  // rien n'écoutait jamais `ai_pending_actions` côté client, donc aucune
  // action confirmation-gated (recharge wallet, E-Kbine, etc.) ne pouvait
  // jamais réellement s'exécuter : AZ IA décrivait la nécessité d'une
  // confirmation "via l'interface" sans qu'aucune interface n'existe.
  StreamSubscription<AzIaPendingAction?>? _pendingActionSub;
  StreamSubscription<String?>? _authSub;
  AzIaPendingAction? _pendingAction;
  bool _confirming = false;
  String? _activeUid;

  AzIaPendingAction? get pendingAction => _pendingAction;
  bool get confirming => _confirming;

  AzIaProvider({AzIaService? service, Stream<String?>? authUidChanges})
      : _service = service ?? AzIaService(),
        _authUidChanges = authUidChanges ??
            FirebaseAuth.instance.authStateChanges().map((user) => user?.uid) {
    _authSub = _authUidChanges.listen(_onAuthChanged);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _pendingActionSub?.cancel();
    super.dispose();
  }

  List<AzIaMessage> get messages => List.unmodifiable(_messages);
  bool get isSending => _isSending;
  String? get error => _error;

  String _conversationKey(String uid) => 'az_ia_current_conversation_$uid';

  Future<void> _onAuthChanged(String? uid) async {
    if (uid == _activeUid) return;
    debugPrint('[AZ_IA_AUTH_UID] ancien=$_activeUid nouveau=$uid');
    _activeUid = uid;
    debugPrint(
        '[AZ_IA_PENDING_CANCEL] annulation de l\'abonnement pending pour uid=$_activeUid');
    await _pendingActionSub?.cancel();
    // Deux événements Auth peuvent se succéder pendant l'annulation
    // asynchrone. Seul le dernier UID recrée un abonnement.
    if (_activeUid != uid) return;
    _pendingActionSub = null;
    _pendingAction = null;
    _messages.clear();
    _conversationId = null;
    _error = null;
    _confirming = false;
    notifyListeners();
    if (uid == null) return;

    debugPrint(
        '[AZ_IA_PENDING_SUBSCRIBE] nouvel abonnement ai_pending_actions pour uid=$uid');
    _pendingActionSub =
        _service.streamLatestPendingAction(uid).listen((action) {
      if (_activeUid != uid) return;
      _pendingAction = action;
      notifyListeners();
    }, onError: (Object e, StackTrace st) {
      debugPrint('[AZ_IA_ERROR] flux ai_pending_actions uid=$uid : $e');
      debugPrintStack(stackTrace: st);
    });
    await _restoreConversation(uid);
  }

  Future<void> _restoreConversation(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final conversationId = prefs.getString(_conversationKey(uid));
    if (_activeUid != uid || conversationId == null || conversationId.isEmpty) {
      return;
    }
    await openConversation(conversationId);
  }

  Future<void> _persistConversation(String uid, String conversationId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_conversationKey(uid), conversationId);
  }

  Future<void> startNewConversation() async {
    final uid = _activeUid;
    if (uid == null) return;
    final id = const Uuid().v4();
    debugPrint(
        '[AZ_IA_NEW_CONVERSATION] uid=$uid ancienConversationId=$_conversationId nouveauConversationId=$id');
    _conversationId = id;
    _messages.clear();
    _error = null;
    await _persistConversation(uid, id);
    if (_activeUid == uid) notifyListeners();
  }

  Future<void> openConversation(String conversationId) async {
    final uid = _activeUid;
    if (uid == null || conversationId.isEmpty) return;
    final stored = await _service.loadConversation(uid, conversationId);
    if (_activeUid != uid) return;
    _conversationId = conversationId;
    _messages
      ..clear()
      ..addAll(stored.map((message) => AzIaMessage(
            sender:
                message.role == 'user' ? AzIaSender.user : AzIaSender.assistant,
            text: message.content,
            animated: true,
            response: message.role == 'user'
                ? null
                : AzIaStructuredResponse.generic(message.content),
          )));
    await _persistConversation(uid, conversationId);
    if (_activeUid == uid) notifyListeners();
  }

  Future<List<AzIaConversationSummary>> loadConversationSummaries() async {
    final uid = _activeUid;
    if (uid == null) return const [];
    final summaries = await _service.loadConversationSummaries(uid);
    return _activeUid == uid ? summaries : const [];
  }

  /// Position GPS best-effort (Master Prompt 113, section 3) — ne déclenche
  /// JAMAIS de demande de permission depuis ce provider : lit uniquement une
  /// position déjà connue (`getLastKnownPosition`, pas de nouveau relevé GPS)
  /// si l'app a déjà l'autorisation ailleurs. Absence totale = simplement
  /// ignorée, AZ IA redemandera l'adresse dans la conversation.
  Future<AzIaLocation?> _tryGetLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        return null;
      }
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) return null;
      return AzIaLocation(latitude: last.latitude, longitude: last.longitude);
    } catch (_) {
      return null;
    }
  }

  String? _guessMediaType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'image/jpeg';
  }

  /// Retourne le texte de la réponse d'AZ IA (succès ou message d'erreur) —
  /// utilisé par l'écran pour, entre autres, le lire à voix haute (M7).
  /// [image] est optionnelle (Master Prompt 113, section 13) : ordonnance,
  /// colis, produit... analysés directement par Claude dans le même appel.
  Future<String?> sendMessage(String text, {XFile? image}) async {
    final trimmed = text.trim();
    if ((trimmed.isEmpty && image == null) || _isSending) return null;
    // Un message purement image doit quand même porter un texte non vide
    // côté serveur (azIaChat exige `message`) — légende neutre par défaut.
    final effectiveText =
        trimmed.isEmpty ? 'Voici une image, peux-tu l\'analyser ?' : trimmed;
    // Phase 12 (nettoyage) — jamais le contenu réel du message (peut contenir
    // adresse, numéro, demande financière...), seulement sa longueur.
    debugPrint(
        '[AZ_IA_SEND_MESSAGE] uid=$_activeUid conversationId=$_conversationId image=${image != null} longueurTexte=${effectiveText.length}');

    _messages.add(AzIaMessage(
        sender: AzIaSender.user,
        text: effectiveText,
        hasImage: image != null,
        animated: true));
    _isSending = true;
    _error = null;
    notifyListeners();

    String? replyText;
    try {
      // Mode hors ligne (Master Prompt 118) — évite un appel réseau voué à
      // l'échec (et son délai d'attente) quand la connectivité est
      // clairement absente ; répond localement à quelques questions
      // simples plutôt que de laisser l'utilisateur face à une erreur sèche.
      final connectivity = await Connectivity().checkConnectivity();
      final isOffline = connectivity.every((r) => r == ConnectivityResult.none);

      if (isOffline) {
        final offlineAnswer = AzIaOfflineEngine.tryAnswer(effectiveText) ??
            "Je suis hors ligne pour le moment — vérifie ta connexion internet. "
                "En attendant, je peux répondre à quelques questions simples "
                "(horaires, wallet, suivi de commande, contact).";
        replyText = offlineAnswer;
        _messages.add(AzIaMessage(
          sender: AzIaSender.assistant,
          text: offlineAnswer,
          response: AzIaStructuredResponse.generic(offlineAnswer),
        ));
      } else {
        String? imageBase64;
        String? imageMediaType;
        if (image != null) {
          final length = await File(image.path).length();
          if (isImageTooLarge(length)) {
            _error = 'L’image dépasse 4 Mo. Choisissez une image plus légère.';
            _messages.add(AzIaMessage(
              sender: AzIaSender.assistant,
              text: _error!,
              response: AzIaStructuredResponse.generic(_error!),
            ));
            return _error;
          }
          final bytes = await File(image.path).readAsBytes();
          imageBase64 = base64Encode(bytes);
          imageMediaType = _guessMediaType(image.path);
        }
        final location = await _tryGetLocation();

        final result = await _service.sendMessage(
          message: effectiveText,
          conversationId: _conversationId,
          location: location,
          imageBase64: imageBase64,
          imageMediaType: imageMediaType,
        );
        _conversationId = result.conversationId;
        replyText = result.reply;
        _messages.add(AzIaMessage(
            sender: AzIaSender.assistant,
            text: replyText,
            response: result.response));
      }
    } catch (e, st) {
      // Master Prompt 121 — le message générique masquait des cas
      // distincts (délai dépassé, IA temporairement indisponible, réseau) ;
      // le détail technique brut reste en log, jamais affiché à l'utilisateur.
      debugPrint(
          '[AZ_IA_ERROR] sendMessage uid=$_activeUid conversationId=$_conversationId exception=$e');
      debugPrintStack(stackTrace: st);
      if (e is TimeoutException) {
        _error =
            "AZ IA met plus de temps que prévu à répondre. Réessayez dans un instant.";
      } else if (e is FirebaseFunctionsException &&
          (e.code == 'deadline-exceeded' || e.code == 'unavailable')) {
        _error =
            "AZ IA est momentanément indisponible. Réessayez dans un instant.";
      } else if (e is FirebaseFunctionsException &&
          e.code == 'resource-exhausted') {
        _error =
            "Trop de messages envoyés d'un coup — patientez quelques secondes puis réessayez.";
      } else {
        _error =
            "AZ IA n'a pas pu répondre. Vérifiez votre connexion et réessayez.";
      }
      replyText = _error;
      _messages.add(AzIaMessage(
        sender: AzIaSender.assistant,
        text: _error!,
        response: AzIaStructuredResponse.generic(_error!),
      ));
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

  /// Confirme ou annule l'action AZ IA actuellement en attente
  /// (`_pendingAction`) — seul chemin réel vers `aiConfirmAction`
  /// (Master Prompt 115). Le résultat est ajouté au fil de conversation
  /// comme un message assistant, pour rester visible dans l'historique
  /// exactement comme une réponse normale d'AZ IA.
  Future<void> _resolvePendingAction(bool confirm) async {
    final action = _pendingAction;
    if (action == null || _confirming) return;
    debugPrint(
        '[AZ_IA_CONFIRM_ACTION] uid=$_activeUid actionId=${action.id} outil=${action.toolName} confirm=$confirm');
    _confirming = true;
    notifyListeners();

    try {
      final result =
          await _service.confirmAction(actionId: action.id, confirm: confirm);
      final message = result['message'] as String? ??
          result['error'] as String? ??
          (confirm ? 'Action confirmée ✅' : 'Action annulée.');
      // `response` n'existe que côté confirmation réussie (decision:'confirm')
      // — une annulation (decision:'cancel') reste un simple message texte,
      // pas une carte structurée, cohérent avec l'absence de payload à afficher.
      final response = result['response'] != null
          ? AzIaStructuredResponse.fromJson(result['response'],
              fallbackMessage: message)
          : AzIaStructuredResponse.generic(message);
      _messages.add(AzIaMessage(
          sender: AzIaSender.assistant, text: message, response: response));
    } catch (e, st) {
      debugPrint(
          '[AZ_IA_ERROR] confirmAction uid=$_activeUid actionId=${action.id} confirm=$confirm exception=$e');
      debugPrintStack(stackTrace: st);
      final errorText = confirm
          ? "La confirmation a échoué. Réessayez dans un instant."
          : "L'annulation a échoué. Réessayez dans un instant.";
      _messages.add(AzIaMessage(
        sender: AzIaSender.assistant,
        text: errorText,
        response: AzIaStructuredResponse.generic(errorText),
      ));
    } finally {
      // La bascule de statut Firestore (pending -> completed/cancelled) fait
      // déjà disparaître _pendingAction via le stream — ce reset local évite
      // juste un court affichage résiduel de la carte le temps que le
      // stream se mette à jour.
      _pendingAction = null;
      _confirming = false;
      notifyListeners();
    }
  }

  Future<void> confirmPendingAction() => _resolvePendingAction(true);
  Future<void> cancelPendingAction() => _resolvePendingAction(false);
}
