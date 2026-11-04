import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Actions de préparation exposées par partnerOrderActionCF (noms exacts du contrat serveur).
enum PartnerAction {
  /// « Accepter et préparer » : le serveur pose partnerAcceptedAtMs ET sellerStatus 'preparing', puis propose la commande aux
  /// livreurs. Le dispatch n'est JAMAIS déclenché depuis Flutter.
  startPreparation('startPreparation'),
  markReady('markReady'),
  refuse('refusePartnerOrder');

  final String wireName;
  const PartnerAction(this.wireName);
}

class PartnerActionResult {
  final PartnerAction action;
  final String message;
  final String? sellerStatus;

  /// Rejeu d'une action déjà appliquée (double appui, réponse perdue) : aucun effet supplémentaire.
  final bool replay;
  const PartnerActionResult(
      {required this.action,
      required this.message,
      required this.sellerStatus,
      required this.replay});
}

/// Refus serveur ou panne réseau. [retryable] : l'issue est inconnue ; renvoyer la même action est sûr (rejeu idempotent).
class PartnerActionException implements Exception {
  final String code;
  final String message;
  final bool retryable;
  const PartnerActionException(this.code, this.message,
      {this.retryable = false});

  String get userMessage {
    switch (code) {
      case 'NETWORK':
        return 'Connexion instable : l\'action n\'est pas confirmée. Vérifiez l\'état de la commande puis réessayez.';
      case 'MANAGEMENT_FROZEN':
        return 'La gestion des commandes est temporairement suspendue par l\'administration.';
      case 'FEATURE_DISABLED':
        return 'La gestion de ces commandes n\'est pas activée.';
      case 'ORDER_NOT_FOUND':
      case 'ORDER_NOT_PARTNER_V2':
        return 'Commande introuvable ou non gérable depuis cet écran.';
      case 'PARTNER_UNAVAILABLE':
        return 'Votre compte restaurant est indisponible. Contactez le support AZ Express.';
      case 'ORDER_CLOSED':
        return 'Cette commande est déjà terminée ou annulée.';
      case 'ORDER_PICKED_UP':
        return 'Le livreur a déjà récupéré cette commande.';
      case 'PREPARATION_STARTED':
        return 'La préparation est commencée : contactez le support AZ Express pour annuler.';
      case 'INVALID_TRANSITION':
        return 'Cette action n\'est plus possible dans l\'état actuel de la commande.';
      case 'unauthenticated':
      case 'permission-denied':
        return 'Vous n\'êtes pas autorisé à gérer cette commande. Reconnectez-vous.';
      case 'resource-exhausted':
        return 'Trop de tentatives. Patientez un instant puis réessayez.';
      default:
        return message.isNotEmpty ? message : 'Action impossible, réessayez.';
    }
  }

  @override
  String toString() => 'PartnerActionException($code)';
}

/// Seul point d'écriture du restaurateur sur une commande v2 : partnerOrderActionCF. Aucune écriture Firestore directe.
class PartnerOrderActionService {
  static final _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  /// Appel d'une Cloud Function renvoyant l'enveloppe {success, error, message, data, code}. Remplaçable dans les tests.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(
          String name, Map<String, dynamic> data) callFunction =
      (name, data) async {
    final res = await _functions.httpsCallable(name).call(data);
    return Map<String, dynamic>.from(res.data as Map);
  };

  /// [reason] : motif facultatif (le serveur le tronque à 200 caractères et ne l'exige pas), utile au refus.
  static Future<PartnerActionResult> run({
    required String orderId,
    required PartnerAction action,
    String? reason,
  }) async {
    final Map<String, dynamic> map;
    try {
      map = await callFunction('partnerOrderActionCF', {
        'orderId': orderId,
        'action': action.wireName,
        if (action == PartnerAction.refuse &&
            reason != null &&
            reason.trim().isNotEmpty)
          'reason': reason.trim(),
      });
    } on FirebaseFunctionsException catch (e) {
      const network = {
        'unavailable',
        'deadline-exceeded',
        'internal',
        'unknown',
        'cancelled',
        'aborted'
      };
      if (network.contains(e.code)) {
        throw const PartnerActionException('NETWORK', '', retryable: true);
      }
      throw PartnerActionException(e.code, e.message ?? '');
    } catch (_) {
      // Coupure avant la réponse : on ignore si le serveur a traité l'appel.
      throw const PartnerActionException('NETWORK', '', retryable: true);
    }
    if (map['success'] != true) {
      final code = map['code'] ?? map['error'];
      throw PartnerActionException(
          code is String ? code : 'ERREUR', (map['message'] as String?) ?? '');
    }
    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : <String, dynamic>{};
    return PartnerActionResult(
      action: action,
      message: (map['message'] as String?) ?? '',
      sellerStatus: data['sellerStatus'] as String?,
      replay: data['replay'] == true,
    );
  }
}
