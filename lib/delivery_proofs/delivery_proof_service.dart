import 'dart:convert';
import 'package:cloud_functions/cloud_functions.dart';

const deliveryProofUiEnabled = bool.fromEnvironment('DELIVERY_PROOFS_UI');
const deliveryProofRecipientOrigin =
    String.fromEnvironment('DELIVERY_PROOF_RECIPIENT_ORIGIN');

String recipientLink(String grantId, String origin) {
  final base = Uri.tryParse(origin);
  if (base == null ||
      base.scheme != 'https' ||
      base.host.isEmpty ||
      base.userInfo.isNotEmpty ||
      base.hasQuery ||
      base.hasFragment ||
      (base.path.isNotEmpty && base.path != '/') ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(grantId)) {
    throw const FormatException('Origine destinataire non configurée');
  }
  return base.replace(path: '/', fragment: '/reception/$grantId').toString();
}

class DeliveryProof {
  final String orderId, type, token, pin;
  final DateTime expiresAt;
  DeliveryProof(Map<String, dynamic> data)
      : orderId = data['orderId'] as String,
        type = data['type'] as String,
        token = data['token'] as String,
        pin = data['pin'] as String,
        expiresAt = DateTime.fromMillisecondsSinceEpoch(
            (data['expiresAt'] as num).toInt());
  bool get expired => !DateTime.now().isBefore(expiresAt);
  String get qr => jsonEncode(
      {'v': 'qr_v1', 'orderId': orderId, 'type': type, 'token': token});
}

class ProofCredential {
  final String? token, pin;
  const ProofCredential({this.token, this.pin});
  static ProofCredential parse(String raw, String orderId, String type) {
    if (raw.length > 1024) throw const FormatException('QR invalide');
    final data = jsonDecode(raw);
    if (data is! Map ||
        data['v'] != 'qr_v1' ||
        data['orderId'] != orderId ||
        data['type'] != type ||
        data['token'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(data['token'] as String)) {
      throw const FormatException(
          'QR invalide pour cette commande ou cette étape');
    }
    return ProofCredential(token: data['token'] as String);
  }
}

class DeliveryProofService {
  Future<Map<String, dynamic>> call(
      String name, Map<String, dynamic> data) async {
    final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable(name)
        .call<Map<String, dynamic>>(data);
    return result.data;
  }

  Future<DeliveryProof> prepare(String id, String type) async => DeliveryProof(
      await call('prepareOrderProof', {'orderId': id, 'type': type}));
  Future<void> confirm(String id, String type, ProofCredential credential,
      {Map<String, dynamic> delivery = const {}}) async {
    await call(
        type == 'pickup'
            ? 'confirmOrderPickupWithProof'
            : 'confirmOrderDeliveryWithProof',
        {
          ...delivery,
          'orderId': id,
          if (credential.token != null)
            (type == 'pickup' ? 'token' : 'proofToken'): credential.token,
          if (credential.pin != null)
            (type == 'pickup' ? 'pin' : 'proofPin'): credential.pin,
        });
  }
}

String proofError(Object error) {
  if (error is FormatException) {
    return 'QR invalide pour cette commande ou cette étape.';
  }
  if (error is FirebaseFunctionsException) {
    switch (error.code) {
      case 'unauthenticated':
        return 'Connectez-vous pour continuer.';
      case 'permission-denied':
        return 'Accès refusé ou accès destinataire expiré.';
      case 'resource-exhausted':
        return 'Limite de tentatives ou de renouvellements atteinte.';
      case 'failed-precondition':
        if (error.message == 'Code expiré') {
          return 'Code expiré. Demandez un nouveau code.';
        }
        if (error.message == 'Code déjà utilisé') {
          return 'Code déjà utilisé. Actualisez la commande.';
        }
        return 'Code invalide, expiré ou déjà utilisé, ou étape indisponible. Actualisez la commande.';
      case 'unavailable':
      case 'deadline-exceeded':
        return 'Connexion interrompue. Vérifiez le statut avant de réessayer.';
    }
  }
  return 'Impossible de vérifier la preuve. Réessayez après vérification de la connexion.';
}
