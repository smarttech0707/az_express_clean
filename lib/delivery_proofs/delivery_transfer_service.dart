import 'package:cloud_functions/cloud_functions.dart';
import 'delivery_proof_service.dart';

/// Motifs acceptés par le serveur (`functions/driverTransfer.js`).
const transferReasons = <String, String>{
  'vehicle_problem': 'Problème de véhicule',
  'emergency': 'Urgence personnelle',
  'fatigue': 'Fatigue',
  'customer_unreachable': 'Client injoignable',
  'other': 'Autre raison',
};

/// Appels du transfert de livraison entre livreurs. Toute la logique et les
/// vérifications sont côté serveur (`deliveryTransferCF`) : ce service ne fait
/// que transporter la demande et traduire l'erreur en message lisible.
class DeliveryTransferService {
  Future<Map<String, dynamic>> _call(Map<String, dynamic> data) async {
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('deliveryTransferCF')
          .call<Map<String, dynamic>>(data);
      return result.data;
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Transfert impossible');
    }
  }

  /// Demande un remplaçant après récupération du colis. Retourne le transferId.
  Future<String> request(String orderId, String reason) async {
    final r = await _call(
        {'action': 'request', 'orderId': orderId, 'reason': reason});
    return r['transferId'] as String;
  }

  Future<void> accept(String transferId) =>
      _call({'action': 'accept', 'transferId': transferId});
  Future<void> decline(String transferId) =>
      _call({'action': 'decline', 'transferId': transferId});
  Future<void> cancel(String transferId) =>
      _call({'action': 'cancel', 'transferId': transferId});

  /// B : émet le QR/PIN de remise (les secrets restent en mémoire de l'écran).
  Future<DeliveryProof> prepareHandover(
      String transferId, String orderId) async {
    final r =
        await _call({'action': 'prepareHandover', 'transferId': transferId});
    return DeliveryProof({...r, 'orderId': orderId, 'type': 'handover'});
  }

  /// A : confirme la remise avec le QR scanné ou le PIN saisi.
  Future<void> confirmHandover(
          String transferId, ProofCredential credential) =>
      _call({
        'action': 'confirmHandover',
        'transferId': transferId,
        if (credential.token != null) 'token': credential.token,
        if (credential.pin != null) 'pin': credential.pin,
      });
}
