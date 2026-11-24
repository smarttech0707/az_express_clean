import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

class SubscriptionService {
  static final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  static String _requestId() {
    final random = Random.secure();
    final entropy = List<int>.generate(16, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${DateTime.now().microsecondsSinceEpoch}_$entropy';
  }

  static Future<Map<String, dynamic>> _call({
    required String action,
    required String collection,
    required String docId,
    bool? chargeWallet,
    String? requestId,
  }) async {
    final response = await _functions
        .httpsCallable('manageProfessionalSubscription')
        .call(<String, dynamic>{
      'action': action,
      'collection': collection,
      'docId': docId,
      if (chargeWallet != null) 'chargeWallet': chargeWallet,
      if (requestId != null) 'requestId': requestId,
    });
    return Map<String, dynamic>.from(response.data as Map);
  }

  static Future<void> activateEkbineTrial(String agentId) async {
    await _call(
      action: 'activateTrial',
      collection: 'ekbine_agents',
      docId: agentId,
      requestId: _requestId(),
    );
  }

  static Future<Map<String, dynamic>> checkAndRenew(
    String collection,
    String docId,
  ) =>
      _call(action: 'renew', collection: collection, docId: docId);

  static Future<void> adminActivateSubscription(
    String collection,
    String docId, {
    bool chargeWallet = false,
  }) async {
    await _call(
      action: 'activateStandard',
      collection: collection,
      docId: docId,
      chargeWallet: chargeWallet,
      requestId: _requestId(),
    );
  }

  static Future<void> adminActivateVip(
    String collection,
    String docId, {
    bool chargeWallet = false,
  }) async {
    await _call(
      action: 'activateVip',
      collection: collection,
      docId: docId,
      chargeWallet: chargeWallet,
      requestId: _requestId(),
    );
  }

  static Future<void> adminDeactivateVip(
    String collection,
    String docId,
  ) async {
    await _call(
      action: 'deactivateVip',
      collection: collection,
      docId: docId,
      requestId: _requestId(),
    );
  }

  static Future<void> adminSuspend(String collection, String docId) async {
    await _call(
      action: 'suspend',
      collection: collection,
      docId: docId,
      requestId: _requestId(),
    );
  }

  static String formatExpiry(dynamic timestamp) {
    if (timestamp == null) return 'Non défini';
    final dt = (timestamp as Timestamp).toDate();
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }
}
