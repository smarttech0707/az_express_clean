import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../delivery_proofs/delivery_proof_service.dart';
import '../../delivery_proofs/delivery_transfer_service.dart';
import '../../delivery_proofs/proof_scanner_page.dart';
import '../../theme/app_theme.dart';
import '../../widgets/stream_error_state.dart';

/// Remplacement d'un livreur en cours de course (après récupération du colis).
/// Trois rôles dans le même écran :
///  - demandes proposées au livreur (candidat) : accepter / refuser ;
///  - livreur remplaçant B (transfert accepté) : afficher son QR/PIN de remise ;
///  - livreur d'origine A : suivre la demande et scanner le code de B.
/// Aucune décision n'est prise ici : le serveur contrôle tout.
class DriverTransferPage extends StatefulWidget {
  final String driverId;
  const DriverTransferPage({super.key, required this.driverId});
  @override
  State<DriverTransferPage> createState() => _DriverTransferPageState();
}

class _DriverTransferPageState extends State<DriverTransferPage> {
  final _service = DeliveryTransferService();
  bool _busy = false; // anti double-tap
  DeliveryProof? _proof;

  Future<void> _run(Future<void> Function() action, {String? ok}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && ok != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanAndConfirm(String transferId, String orderId) async {
    final credential = await Navigator.push<ProofCredential>(
      context,
      MaterialPageRoute(
          builder: (_) => ProofScannerPage(orderId: orderId, type: 'handover')),
    );
    if (credential == null) return;
    await _run(() => _service.confirmHandover(transferId, credential),
        ok: 'Remise confirmée : la course est maintenant au nouveau livreur.');
  }

  Widget _card(List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: children),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final transfers =
        FirebaseFirestore.instance.collection('delivery_transfers');
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Remplacement de livreur'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _stream(
          transfers.where('fromDriverId', isEqualTo: widget.driverId),
          (docs) => docs
              .where((d) =>
                  ['requested', 'accepted'].contains(d['status']) &&
                  (d['expiresAtMs'] as num) > nowMs)
              .map(_asRequester)
              .toList(),
        ),
        _stream(
          transfers.where('toDriverId', isEqualTo: widget.driverId),
          (docs) => docs
              .where((d) =>
                  d['status'] == 'accepted' && (d['expiresAtMs'] as num) > nowMs)
              .map(_asReplacement)
              .toList(),
        ),
        _cashStream(),
        _stream(
          transfers.where('candidateIds', arrayContains: widget.driverId),
          (docs) => docs
              .where((d) =>
                  d['status'] == 'requested' &&
                  !((d['declinedBy'] as List?) ?? const [])
                      .contains(widget.driverId) &&
                  (d['expiresAtMs'] as num) > nowMs)
              .map(_asCandidate)
              .toList(),
        ),
      ]),
    );
  }

  // Filtrage côté client : array-contains + égalité demanderait un index composite.
  Widget _stream(Query<Map<String, dynamic>> query,
      List<Widget> Function(List<Map<String, dynamic>>) build) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return const StreamErrorState();
        if (!snap.hasData) return const SizedBox.shrink();
        final docs =
            snap.data!.docs.map((d) => {...d.data(), 'id': d.id}).toList();
        return Column(children: build(docs));
      },
    );
  }

  // Règlement cash : le livreur créancier confirme avoir reçu sa part en espèces.
  Widget _cashStream() {
    final q = FirebaseFirestore.instance
        .collection('transfer_settlements')
        .where('driverIds', arrayContains: widget.driverId);
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: q.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return const StreamErrorState();
        if (!snap.hasData) return const SizedBox.shrink();
        final cards = <Widget>[];
        for (final d in snap.data!.docs) {
          final s = d.data();
          if (s['status'] != 'cash_pending') continue;
          final cash = (s['cash'] as Map?) ?? const {};
          for (final x in (cash['toRegularize'] as List? ?? const [])) {
            if (x['to'] != widget.driverId) continue;
            final confirmed = (cash['confirmations'] as Map?)
                    ?.containsKey(widget.driverId) ==
                true;
            cards.add(_card([
              Text('Espèces à recevoir : ${x['amount']} FCFA',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('Le livreur ${x['from']} a encaissé la course. Confirmez ici '
                  'uniquement quand vous avez réellement reçu votre part.'),
              if (!confirmed)
                FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => _confirmCash(s['orderId'] as String),
                            ok: 'Réception confirmée.'),
                    child: const Text('Réception des espèces reçue'))
              else
                const Text('Réception confirmée, en attente de clôture.'),
            ]));
          }
        }
        return Column(children: cards);
      },
    );
  }

  Future<void> _confirmCash(String orderId) async {
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('settleTransferEarningsCF')
          .call<Map<String, dynamic>>(
              {'action': 'confirmCashReceipt', 'orderId': orderId});
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Confirmation impossible');
    }
  }

  Widget _asCandidate(Map<String, dynamic> t) => _card([
        const Text('Un livreur cherche un remplaçant',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('Motif : ${transferReasons[t['reason']] ?? 'Autre raison'}'),
        const Text(
            'Aucune commission supplémentaire. Le partage des gains est validé par l\'administration.'),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
              child: FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() => _service.accept(t['id'] as String),
                          ok: 'Demande acceptée : rejoignez le livreur.'),
                  child: const Text('Accepter'))),
          const SizedBox(width: 8),
          Expanded(
              child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() => _service.decline(t['id'] as String)),
                  child: const Text('Refuser'))),
        ]),
      ]);

  Widget _asReplacement(Map<String, dynamic> t) {
    final proof = _proof;
    return _card([
      const Text('Vous êtes le livreur remplaçant',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const Text(
          'Retrouvez le livreur et montrez-lui ce code pour recevoir le colis.'),
      const SizedBox(height: 8),
      if (proof == null || proof.expired)
        FilledButton.icon(
          icon: const Icon(Icons.qr_code_rounded),
          label: const Text('Afficher mon code de remise'),
          onPressed: _busy
              ? null
              : () => _run(() async {
                    final p = await _service.prepareHandover(
                        t['id'] as String, t['orderId'] as String);
                    if (mounted) setState(() => _proof = p);
                  }),
        )
      else
        Center(
          child: Column(children: [
            QrImageView(
                data: proof.qr, size: 220, backgroundColor: Colors.white),
            Text('PIN : ${proof.pin}', style: const TextStyle(fontSize: 26)),
            const Text(
                'Valable 15 minutes. À montrer uniquement lors de la remise.'),
          ]),
        ),
      TextButton(
          onPressed: _busy
              ? null
              : () => _run(() => _service.decline(t['id'] as String)),
          child: const Text('Je ne peux plus me rendre sur place')),
    ]);
  }

  Widget _asRequester(Map<String, dynamic> t) {
    final accepted = t['status'] == 'accepted';
    return _card([
      Text(accepted ? 'Un livreur a accepté' : 'En attente d\'un remplaçant',
          style: const TextStyle(fontWeight: FontWeight.bold)),
      const Text(
          'Vous restez responsable du colis jusqu\'à la remise confirmée.'),
      const SizedBox(height: 8),
      if (accepted)
        FilledButton.icon(
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: const Text('Scanner le code du remplaçant'),
          onPressed: _busy
              ? null
              : () => _scanAndConfirm(
                  t['id'] as String, t['orderId'] as String),
        ),
      TextButton(
          onPressed: _busy
              ? null
              : () => _run(() => _service.cancel(t['id'] as String),
                  ok: 'Transfert annulé.'),
          child: const Text('Annuler le transfert')),
    ]);
  }
}
