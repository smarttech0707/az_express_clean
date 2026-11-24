import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'delivery_proof_service.dart';
import 'delivery_sms_panel.dart';

class ProofDisplay extends StatelessWidget {
  final DeliveryProof proof;
  const ProofDisplay({super.key, required this.proof});
  @override
  Widget build(BuildContext context) => proof.expired
      ? const Text('Code expiré. Demandez un renouvellement.')
      : Column(mainAxisSize: MainAxisSize.min, children: [
          Text(proof.type == 'pickup'
              ? 'QR de récupération'
              : 'Code de réception'),
          const Text('Présentez ce code uniquement lors de la remise.'),
          QrImageView(data: proof.qr, size: 220, backgroundColor: Colors.white),
          Text('PIN : ${proof.pin}', style: const TextStyle(fontSize: 26)),
          Text(
              'Expire à ${TimeOfDay.fromDateTime(proof.expiresAt).format(context)}'),
        ]);
}

/// Public order status only; proof secrets exist solely in the page's memory.
class ProofActions extends StatelessWidget {
  final String orderId;
  final bool partner;
  const ProofActions({super.key, required this.orderId, this.partner = false});
  @override
  Widget build(BuildContext context) {
    if (!deliveryProofUiEnabled) return const SizedBox.shrink();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('orders')
          .doc(orderId)
          .snapshots(),
      builder: (context, snap) {
        final order = snap.data?.data();
        if (order == null) return const SizedBox.shrink();
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid == null || order['driverId'] == uid) {
          return const SizedBox.shrink();
        }
        if (!partner && order['clientId'] != uid) {
          return const SizedBox.shrink();
        }
        final pickup = order['status'] == 'accepted' &&
            (partner
                ? (order['sellerStatus'] == null ||
                    order['sellerStatus'] == 'ready')
                : order['sellerId'] == null);
        final delivery = !partner &&
            order['status'] == 'picked_up' &&
            order['deliveryProofMode'] == 'qr_v1';
        if (!pickup && !delivery) {
          return order['deliveryProofMode'] == 'qr_v1'
              ? Text(order['status'] == 'delivered'
                  ? 'Livraison confirmée'
                  : 'Récupération confirmée ou en attente')
              : const SizedBox.shrink();
        }
        final type = pickup ? 'pickup' : 'delivery';
        return OutlinedButton.icon(
          icon: const Icon(Icons.qr_code),
          label: Text(pickup ? 'QR de récupération' : 'Code de réception'),
          onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                  builder: (_) =>
                      ProofPresentationPage(orderId: orderId, type: type))),
        );
      },
    );
  }
}

class ProofPresentationPage extends StatefulWidget {
  final String orderId, type;
  const ProofPresentationPage(
      {super.key, required this.orderId, required this.type});
  @override
  State<ProofPresentationPage> createState() => _ProofPresentationPageState();
}

class _ProofPresentationPageState extends State<ProofPresentationPage> {
  final service = DeliveryProofService();
  DeliveryProof? proof;
  Map<String, dynamic>? access;
  bool busy = false, pickupReady = false;
  String? error;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    proof = null;
    access = null;
    super.dispose();
  }

  Future<void> generate({bool guest = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (guest) {
        final result = await service
            .call('createRecipientProofAccess', {'orderId': widget.orderId});
        if (mounted) {
          setState(() {
            access = result;
            proof = null;
          });
        }
      } else {
        final result = await service.prepare(widget.orderId, widget.type);
        if (mounted) {
          setState(() {
            proof = result;
            access = null;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = proofError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!deliveryProofUiEnabled) {
      return const Scaffold(
          body: Center(child: Text('Fonctionnalité non activée')));
    }
    return Scaffold(
        appBar: AppBar(
            title: Text(widget.type == 'pickup'
                ? 'QR de récupération'
                : 'Code de réception')),
        body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('orders')
              .doc(widget.orderId)
              .snapshots(),
          builder: (context, snap) {
            final order = snap.data?.data();
            if (order == null) {
              return const Center(child: Text('Vérification du statut…'));
            }
            if (order['driverId'] == FirebaseAuth.instance.currentUser?.uid) {
              return const Center(child: Text('Accès refusé'));
            }
            if (order['status'] !=
                (widget.type == 'pickup' ? 'accepted' : 'picked_up')) {
              return const Center(
                  child: Text('Étape terminée ou indisponible.'));
            }
            return ListView(padding: const EdgeInsets.all(20), children: [
              if (proof != null) ProofDisplay(proof: proof!),
              if (error != null) Text(error!),
              if (widget.type == 'pickup')
                CheckboxListTile(
                    value: pickupReady,
                    onChanged: busy
                        ? null
                        : (value) =>
                            setState(() => pickupReady = value ?? false),
                    title: const Text(
                        'La commande est prête à être remise au livreur')),
              FilledButton(
                  onPressed: busy ||
                          (widget.type == 'pickup' && !pickupReady) ||
                          (proof != null && !proof!.expired)
                      ? null
                      : () => generate(),
                  child: Text(proof == null
                      ? 'Afficher mon code'
                      : 'Régénérer le code expiré')),
              const Text(
                  'Maximum 3 émissions par étape. Un nouveau code invalide le précédent. Les codes ne sont pas conservés après fermeture.'),
              if (widget.type == 'delivery') ...[
                DeliverySmsPanel(orderId: widget.orderId),
                const Divider(),
                const Text('Pour un proche sans compte AZ Express'),
                OutlinedButton(
                    onPressed: busy ? null : () => generate(guest: true),
                    child: const Text('Créer un accès destinataire')),
                if (access != null &&
                    DateTime.now().millisecondsSinceEpoch <
                        (access!['expiresAt'] as num)) ...[
                  Text('Code de récupération : ${access!['recovery']}'),
                  const Text(
                      'Communiquez ce code séparément, en personne ou par appel au destinataire. Ne le donnez jamais au livreur. Le lien seul ne permet pas de voir le QR/PIN.'),
                  OutlinedButton(
                      onPressed: () async {
                        try {
                          final link = recipientLink(
                              access!['grantId'] as String,
                              deliveryProofRecipientOrigin);
                          final ok = await launchUrl(
                              Uri.https('wa.me', '/', {
                                'text': 'Votre réception AZ Express : $link'
                              }),
                              mode: LaunchMode.externalApplication);
                          if (!ok && mounted) {
                            setState(() => error = 'WhatsApp indisponible.');
                          }
                        } catch (_) {
                          if (mounted) {
                            setState(() => error =
                                'Partage indisponible. Vérifiez la configuration du lien destinataire.');
                          }
                        }
                      },
                      child: const Text('Partager le lien par WhatsApp')),
                ],
                const Text(
                    'Partage WhatsApp manuel. En cas de perte, le client crée un nouvel accès : l’ancien lien est invalidé. Un nouveau QR/PIN remplace aussi tout code SMS précédent.'),
              ],
            ]);
          },
        ));
  }
}

class RecipientProofPage extends StatefulWidget {
  final String grantId;
  const RecipientProofPage({super.key, required this.grantId});
  @override
  State<RecipientProofPage> createState() => _RecipientProofPageState();
}

class _RecipientProofPageState extends State<RecipientProofPage> {
  final code = TextEditingController();
  DeliveryProof? proof;
  String? error;
  bool busy = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    code.dispose();
    proof = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Réception AZ Express')),
      body: !deliveryProofUiEnabled
          ? const Center(child: Text('Fonctionnalité non activée'))
          : ListView(padding: const EdgeInsets.all(24), children: [
              if (proof != null)
                ProofDisplay(proof: proof!)
              else ...[
                const Text(
                    'Demandez au client le code de récupération, transmis séparément du lien. Aucun compte AZ Express à créer.'),
                TextField(
                    controller: code,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                        labelText: 'Code de récupération')),
                FilledButton(
                    onPressed: busy
                        ? null
                        : () async {
                            setState(() {
                              busy = true;
                              error = null;
                            });
                            try {
                              if (FirebaseAuth.instance.currentUser == null) {
                                await FirebaseAuth.instance.signInAnonymously();
                              }
                              final result = await DeliveryProofService().call(
                                  'redeemRecipientProofAccess', {
                                'grantId': widget.grantId,
                                'recovery': code.text.trim()
                              });
                              code.clear();
                              if (mounted) {
                                setState(() => proof = DeliveryProof(result));
                              }
                            } catch (e) {
                              if (mounted) {
                                setState(() => error = proofError(e));
                              }
                            } finally {
                              if (mounted) setState(() => busy = false);
                            }
                          },
                    child: const Text('Afficher mon code de réception')),
              ],
              if (error != null) Text(error!),
              const Text(
                  'Accès à usage unique. En cas de fermeture, expiration ou perte, demandez au client un nouvel accès. Présentez le code uniquement lors de la remise.'),
            ]));
}
