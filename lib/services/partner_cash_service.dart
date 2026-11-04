import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Actions de reversement cash de partnerOrderActionCF (noms exacts du contrat serveur).
enum CashAction {
  /// Livreur final : total CUMULÉ remis au partenaire. Une déclaration n'est jamais une confirmation.
  declare('declareCashHandover'),

  /// Partenaire : total CUMULÉ réellement reçu. Seule la confirmation du dû complet règle la commande.
  confirm('confirmCashRemittance'),

  /// Partenaire ou livreur final : désaccord, motif de 10 à 300 caractères.
  dispute('disputeCashRemittance'),

  /// Super-administrateur uniquement : décision finale (requestId idempotent, justification de 10 à 500 caractères).
  resolve('resolveCashRemittance');

  final String wireName;
  const CashAction(this.wireName);
}

class CashActionResult {
  final CashAction action;
  final String message;
  final bool replay;
  const CashActionResult(
      {required this.action, required this.message, required this.replay});
}

/// Refus serveur ou panne réseau. [retryable] : l'issue est inconnue ; renvoyer la MÊME action avec les mêmes paramètres est
/// sûr (rejeu idempotent côté serveur).
class CashActionException implements Exception {
  final String code;
  final String message;
  final bool retryable;
  const CashActionException(this.code, this.message, {this.retryable = false});

  String get userMessage {
    switch (code) {
      case 'NETWORK':
        return 'Connexion instable : l\'action n\'est pas confirmée. Vérifiez l\'état du reversement puis réessayez.';
      case 'CASH_ALREADY_FINAL':
        return 'Ce reversement est déjà clos.';
      case 'CASH_DISPUTED':
        return 'Ce reversement est contesté : la décision de l\'administration est attendue.';
      case 'INVALID_AMOUNT':
        return 'Montant invalide pour l\'état actuel du reversement (il doit dépasser le montant déjà confirmé).';
      case 'AMOUNT_EXCEEDS_DUE':
        return 'Le montant dépasse la somme due au restaurant.';
      case 'REASON_REQUIRED':
        return 'Motif requis (10 à 300 caractères).';
      case 'JUSTIFICATION_REQUIRED':
        return 'Justification requise (10 à 500 caractères).';
      case 'REQUEST_ID_REQUIRED':
        return 'Identifiant de décision manquant, réessayez.';
      case 'CASH_ORDER_NOT_DELIVERED':
        return 'La commande n\'est pas encore livrée.';
      case 'CASH_ORDER_NOT_CASH':
        return 'Cette commande n\'a pas été payée en espèces.';
      case 'CASH_REMITTANCE_INVALID':
      case 'ORDER_AMOUNTS_INCONSISTENT':
        return 'Suivi du reversement incohérent : contactez le support AZ Express.';
      case 'ORDER_NOT_FOUND':
      case 'ORDER_NOT_PARTNER_V2':
        return 'Commande introuvable ou non gérable ici.';
      case 'ACTOR_UNAVAILABLE':
        return 'Votre compte est indisponible. Contactez le support AZ Express.';
      case 'MANAGEMENT_FROZEN':
        return 'La gestion est temporairement suspendue par l\'administration.';
      case 'FEATURE_DISABLED':
        return 'Cette fonction n\'est pas activée.';
      case 'permission-denied':
      case 'unauthenticated':
        return 'Action réservée : vous n\'avez pas l\'autorisation requise.';
      case 'resource-exhausted':
        return 'Trop de tentatives. Patientez un instant puis réessayez.';
      default:
        return message.isNotEmpty ? message : 'Action impossible, réessayez.';
    }
  }

  @override
  String toString() => 'CashActionException($code)';
}

/// Seul point d'écriture des reversements cash : partnerOrderActionCF. Aucune écriture Firestore directe, aucun wallet.
class PartnerCashService {
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

  /// Paramètres selon l'action (contrat serveur) :
  ///  - declare / confirm : [amount] entier > 0, cumulé, ≤ dû ;
  ///  - dispute : [reason] ;
  ///  - resolve : [requestId] (16-128 car., réutilisé à l'identique pour tout rejeu), [finalAmount] entier ≥ 0 ≤ dû, [justification].
  static Future<CashActionResult> run({
    required String orderId,
    required CashAction action,
    int? amount,
    String? reason,
    String? requestId,
    int? finalAmount,
    String? justification,
  }) async {
    final Map<String, dynamic> map;
    try {
      map = await callFunction('partnerOrderActionCF', {
        'orderId': orderId,
        'action': action.wireName,
        if (action == CashAction.declare || action == CashAction.confirm)
          'amount': amount,
        if (action == CashAction.dispute) 'reason': reason?.trim() ?? '',
        if (action == CashAction.resolve) ...{
          'requestId': requestId,
          'finalAmount': finalAmount,
          'justification': justification?.trim() ?? '',
        },
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
        throw const CashActionException('NETWORK', '', retryable: true);
      }
      throw CashActionException(e.code, e.message ?? '');
    } catch (_) {
      // Coupure avant la réponse : on ignore si le serveur a traité l'appel.
      throw const CashActionException('NETWORK', '', retryable: true);
    }
    if (map['success'] != true) {
      final code = map['code'] ?? map['error'];
      throw CashActionException(
          code is String ? code : 'ERREUR', (map['message'] as String?) ?? '');
    }
    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : <String, dynamic>{};
    return CashActionResult(
        action: action,
        message: (map['message'] as String?) ?? '',
        replay: data['replay'] == true);
  }
}
