import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Configuration du pilote Restaurant/Boulangerie v2 (`config/partnerOrdersV2`), en LECTURE SEULE côté Flutter.
/// Valeurs par défaut identiques au serveur : tout est fermé (aucun pilote, création fermée, pas de gel).
@immutable
class PartnerOrdersConfig {
  final List<String> pilotPartnerIds;

  /// Autorisation de créer de nouvelles commandes v2 (false/absent = fermé).
  final bool creationOpen;

  /// Gel exceptionnel de la gestion des commandes v2 existantes.
  final bool managementFrozen;

  /// Contrôle de concurrence : à renvoyer tel quel (`expectedVersion`) à la prochaine modification.
  final int version;
  final String? lastReason;
  final int? updatedAtMs;

  const PartnerOrdersConfig({
    required this.pilotPartnerIds,
    required this.creationOpen,
    required this.managementFrozen,
    required this.version,
    this.lastReason,
    this.updatedAtMs,
  });

  /// Document absent : configuration fermée, version 0.
  static const closed = PartnerOrdersConfig(
      pilotPartnerIds: [],
      creationOpen: false,
      managementFrozen: false,
      version: 0);

  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// Même lecture prudente que le serveur (`parsePilotConfig`) : seul un booléen `true` ouvre ou gèle.
  static PartnerOrdersConfig fromDoc(Map<String, dynamic>? d) {
    if (d == null) return closed;
    final ids = d['pilotPartnerIds'];
    final version = d['version'];
    final last = d['lastChange'];
    final updated = d['updatedAtMs'];
    return PartnerOrdersConfig(
      pilotPartnerIds: [
        if (ids is List)
          for (final id in ids)
            if (id is String && _id.hasMatch(id)) id,
      ]..sort(),
      creationOpen: d['creationOpen'] == true,
      managementFrozen: d['managementFrozen'] == true,
      version: version is int && version >= 0 ? version : 0,
      lastReason: last is Map && last['reason'] is String
          ? last['reason'] as String
          : null,
      updatedAtMs: updated is int ? updated : null,
    );
  }

  static bool validPartnerId(String id) => _id.hasMatch(id);

  /// Plafond serveur de partenaires pilotes.
  static const maxPilots = 50;
}

class PartnerOrdersConfigException implements Exception {
  final String code;
  final String message;
  final bool retryable;
  const PartnerOrdersConfigException(this.code, this.message,
      {this.retryable = false});

  String get userMessage {
    switch (code) {
      case 'CONFIG_CONFLICT':
        return 'La configuration a changé entre-temps. L’écran affiche la version à jour : vérifiez-la puis recommencez.';
      case 'INVALID_CONFIG':
        return message.isNotEmpty ? message : 'Modification invalide.';
      case 'NETWORK':
        return 'Connexion instable : la modification n’est pas confirmée. Vérifiez l’état affiché avant de réessayer.';
      case 'permission-denied':
        return 'Réservé à l’administrateur principal.';
      case 'unauthenticated':
        return 'Session expirée : reconnectez-vous.';
      case 'resource-exhausted':
        return 'Trop de tentatives. Patientez un instant puis réessayez.';
      default:
        return message.isNotEmpty ? message : 'Modification impossible, réessayez.';
    }
  }

  @override
  String toString() => 'PartnerOrdersConfigException($code)';
}

/// Seul point de modification du pilote : l’action `setPartnerOrdersConfig` de `partnerOrderActionCF` (super-administrateur
/// vérifié par le serveur, version contrôlée, journal d’audit). Aucune écriture Firestore directe.
class PartnerOrdersConfigService {
  static final _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  @visibleForTesting
  static Future<Map<String, dynamic>> Function(
          String name, Map<String, dynamic> data) callFunction =
      (name, data) async {
    final res = await _functions.httpsCallable(name).call(data);
    return Map<String, dynamic>.from(res.data as Map);
  };

  /// [patch] : une ou plusieurs clés parmi `pilotPartnerIds` (liste COMPLÈTE), `creationOpen`, `managementFrozen`.
  /// [expectedVersion] : version lue à l’écran ; une version périmée est refusée (`CONFIG_CONFLICT`).
  /// [reason] : 10 à 300 caractères.
  static Future<PartnerOrdersConfig> update({
    required int expectedVersion,
    required Map<String, dynamic> patch,
    required String reason,
  }) async {
    final Map<String, dynamic> map;
    try {
      map = await callFunction('partnerOrderActionCF', {
        'action': 'setPartnerOrdersConfig',
        'patch': patch,
        'expectedVersion': expectedVersion,
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
        throw const PartnerOrdersConfigException('NETWORK', '',
            retryable: true);
      }
      throw PartnerOrdersConfigException(e.code, e.message ?? '');
    } catch (_) {
      // Coupure avant la réponse : on ignore si le serveur a appliqué la modification.
      throw const PartnerOrdersConfigException('NETWORK', '', retryable: true);
    }
    if (map['success'] != true) {
      final code = map['code'] ?? map['error'];
      throw PartnerOrdersConfigException(
          code is String ? code : 'ERREUR', (map['message'] as String?) ?? '');
    }
    final data = map['data'];
    final config = data is Map ? data['config'] : null;
    return PartnerOrdersConfig.fromDoc(
        config is Map ? Map<String, dynamic>.from(config) : null);
  }
}
