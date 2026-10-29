import 'dart:async';
import 'package:flutter/material.dart';
import 'delivery_proof_service.dart';

const deliverySmsUiEnabled = bool.fromEnvironment('DELIVERY_SMS_UI');

String smsStatusLabel(String? status) => switch (status) {
      'not_configured' => 'Pour un proche sans Internet ni WhatsApp',
      'waiting_arrival' => 'SMS en attente de l’arrivée du livreur',
      'queued' || 'sending' => 'Envoi SMS en attente',
      'accepted' => 'SMS accepté par le fournisseur. Réception non confirmée.',
      'simulated' => 'Simulation : aucun SMS réel envoyé.',
      'failed' => 'Échec de l’envoi SMS',
      'unknown' => 'Résultat inconnu. Ne supposez pas que le SMS a été reçu.',
      'unavailable' => 'Fournisseur SMS indisponible',
      'limited' => 'Limite d’envoi atteinte',
      'superseded' => 'Un nouveau QR/PIN a remplacé le code SMS.',
      'expired' => 'Le code SMS a expiré.',
      'completed' => 'Livraison confirmée',
      'blocked' => 'Envoi bloqué : contactez l’assistance.',
      _ => 'Vérification de l’envoi SMS',
    };

class DeliverySmsPanel extends StatefulWidget {
  final String orderId;
  final bool driver;
  final DeliveryProofService? service;
  const DeliverySmsPanel(
      {super.key, required this.orderId, this.driver = false, this.service});
  @override
  State<DeliverySmsPanel> createState() => _DeliverySmsPanelState();
}

class _DeliverySmsPanelState extends State<DeliverySmsPanel> {
  Map<String, dynamic>? state;
  bool busy = false;
  String? error, notice;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    if (deliveryProofUiEnabled && deliverySmsUiEnabled && !widget.driver) {
      unawaited(invoke('getDeliverySmsStatus'));
      timer = Timer.periodic(const Duration(seconds: 45), (_) {
        unawaited(invoke('getDeliverySmsStatus'));
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> invoke(String name) async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      final result = await (widget.service ?? DeliveryProofService())
          .call(name, {'orderId': widget.orderId});
      if (!mounted) return;
      setState(() {
        if (widget.driver) {
          notice = 'Arrivée signalée. Demandez le PIN au destinataire après la remise.';
        } else {
          state = result;
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = proofError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!deliveryProofUiEnabled || !deliverySmsUiEnabled) {
      return const SizedBox.shrink();
    }
    if (widget.driver) {
      return Column(children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.near_me),
          onPressed: busy || notice != null ? null : () async {
            final confirmed = await showDialog<bool>(context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Vous êtes arrivé ?'),
                  content: const Text('Signalez votre arrivée seulement à proximité du destinataire. Le code expire après 15 minutes.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirmer')),
                  ],
                ));
            if (confirmed == true && mounted) await invoke('markDeliverySmsArrival');
          },
          label: const Text('Signaler mon arrivée pour le SMS'),
        ),
        if (notice != null) Text(notice!),
        if (error != null) Text(error!),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Divider(),
      const Text('Code de réception par SMS'),
      Text(smsStatusLabel(state?['status'] as String?)),
      if (error != null) Text(error!),
      if (state?['status'] == 'not_configured') ...[
        const Text('Le SMS sera envoyé au numéro destinataire enregistré dans la commande, lorsque le livreur signalera son arrivée. Vérifiez ce numéro avant de choisir cette option.'),
        OutlinedButton(onPressed: busy ? null : () => invoke('configureDeliverySms'),
            child: const Text('Choisir le SMS pour mon proche')),
      ],
      if (state?['canRetry'] == true)
        OutlinedButton(onPressed: busy ? null : () => invoke('retryDeliverySms'),
            child: const Text('Demander un nouveau SMS')),
      TextButton(onPressed: busy ? null : () => invoke('getDeliverySmsStatus'),
          child: const Text('Actualiser l’état SMS')),
      const Text('Le PIN expire après 15 minutes. Un renvoi autorisé crée un nouveau code et invalide l’ancien. Sans SMS, le client peut générer un nouveau code et le transmettre au destinataire par appel, jamais au livreur. L’accès WhatsApp sécurisé reste facultatif. Ne confirmez pas sans preuve ; contactez l’assistance si nécessaire.'),
    ]);
  }
}
