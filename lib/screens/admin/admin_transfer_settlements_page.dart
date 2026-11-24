import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/stream_error_state.dart';

/// Règlement des gains des courses transférées entre livreurs (super-admin).
/// Les montants affichés sont ceux calculés par le serveur ; toute validation
/// passe par `settleTransferEarningsCF` (aucune écriture Firestore directe).
class AdminTransferSettlementsPage extends StatefulWidget {
  const AdminTransferSettlementsPage({super.key});
  @override
  State<AdminTransferSettlementsPage> createState() =>
      _AdminTransferSettlementsPageState();
}

class _AdminTransferSettlementsPageState
    extends State<AdminTransferSettlementsPage> {
  bool _busy = false; // anti double-tap

  static const _reasonLabels = <String, String>{
    'commission_untraced': 'Commission non tracée',
    'commission_exceeds_price': 'Commission supérieure au prix',
    'driver_chain_incomplete': 'Livreurs incomplets',
    'driver_appears_twice': 'Livreur en double',
    'commission_payer_not_in_chain': 'Payeur de commission étranger à la course',
    'pickup_coordinates_missing': 'Point de retrait manquant',
    'destination_coordinates_missing': 'Destination manquante',
    'handover_proof_missing': 'Preuve de remise absente',
    'delivery_proof_missing': 'Preuve de livraison absente',
    'zero_useful_distance': 'Distance utile nulle pour un livreur',
  };

  String _reason(String r) => r.startsWith('handover_gps_untrusted')
      ? 'GPS de remise non fiable (${r.split(':').last})'
      : (_reasonLabels[r] ?? r);

  Future<void> _call(Map<String, dynamic> data, String okMessage) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('settleTransferEarningsCF')
          .call<Map<String, dynamic>>(data);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(okMessage)));
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message ?? 'Échec')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _correct(Map<String, dynamic> s) async {
    final ids = List<String>.from(s['driverIds'] as List);
    final proposed = (s['proposal']?['credits'] as Map?) ?? const {};
    final controllers = {
      for (final id in ids)
        id: TextEditingController(text: '${proposed[id] ?? 0}')
    };
    final why = TextEditingController();
    final total = (s['totalPaid'] as num).toInt();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Répartition corrigée (total $total FCFA)'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final id in ids)
              TextField(
                controller: controllers[id],
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'Livreur $id (FCFA)'),
              ),
            TextField(
              controller: why,
              maxLines: 2,
              decoration: const InputDecoration(
                  labelText: 'Justification obligatoire (10 car. min.)'),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Valider')),
        ],
      ),
    );
    final credits = {
      for (final e in controllers.entries)
        e.key: int.tryParse(e.value.text.trim()) ?? -1
    };
    final justification = why.text.trim();
    for (final c in controllers.values) {
      c.dispose();
    }
    why.dispose();
    if (ok != true) return;
    await _call({
      'action': 'approve',
      'orderId': s['orderId'],
      'credits': credits,
      'justification': justification,
    }, 'Répartition corrigée enregistrée.');
  }

  Future<void> _closeCash(Map<String, dynamic> s) async {
    final why = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clôturer le règlement cash'),
        content: TextField(
          controller: why,
          maxLines: 2,
          decoration: const InputDecoration(
              labelText: 'Justification (obligatoire si une réception n\'est pas confirmée)'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clôturer')),
        ],
      ),
    );
    final justification = why.text.trim();
    why.dispose();
    if (ok != true) return;
    await _call({
      'action': 'closeCash',
      'orderId': s['orderId'],
      if (justification.isNotEmpty) 'justification': justification,
    }, 'Règlement cash clôturé.');
  }

  Widget _card(Map<String, dynamic> s) {
    final status = s['status'] as String;
    final due = (s['dueAtMs'] as num).toInt();
    final open = status == 'pending_review' || status == 'cash_pending';
    final overdue = open && DateTime.now().millisecondsSinceEpoch > due;
    final proposal = (s['proposal'] as Map?) ?? const {};
    final reasons = List<String>.from((proposal['reasons'] as List?) ?? const []);
    final legs = (proposal['legs'] as List?) ?? const [];
    final shares = (proposal['shares'] as List?) ?? const [];
    final commission = (proposal['commission'] as Map?) ?? const {};
    final decisions = (s['decisions'] as List?) ?? const [];
    final cash = (s['cash'] as Map?) ?? const {};
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('Commande ${s['orderId']}',
                    style: const TextStyle(fontWeight: FontWeight.bold))),
            if (overdue)
              const Chip(
                  label: Text('EN RETARD (>24 h)'),
                  backgroundColor: Color(0xFFFFCDD2)),
          ]),
          Text('${s['method'] == 'cash' ? 'Cash' : 'Wallet'} · $status · '
              '${s['totalPaid']} FCFA · commission AZ ${commission['amount'] ?? 0} FCFA '
              '(payée par ${commission['payerId'] ?? '?'})'),
          const SizedBox(height: 6),
          Text('Livreurs : ${(s['driverIds'] as List).join(' → ')}'),
          for (final l in legs)
            Text('  • ${l['driverId']} : ${l['usefulM']} m utiles'),
          if (shares.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Text('Parts proposées :',
                style: TextStyle(fontWeight: FontWeight.w600)),
            for (final sh in shares)
              Text('  • ${sh['driverId']} : ${sh['share']} FCFA'),
          ],
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Text('Validation administrative requise :',
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: Color(0xFFB71C1C))),
            for (final r in reasons) Text('  • ${_reason(r)}'),
          ],
          if (status == 'cash_pending')
            for (final x in (cash['toRegularize'] as List? ?? const []))
              Text(
                  '  • ${x['from']} doit ${x['amount']} FCFA à ${x['to']} — '
                  '${(cash['confirmations'] as Map?)?.containsKey(x['to']) == true ? 'reçu confirmé' : 'en attente de confirmation'}'),
          if (decisions.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Text('Historique :',
                style: TextStyle(fontWeight: FontWeight.w600)),
            for (final d in decisions)
              Text('  • ${d['action']} par ${d['byUid']}'
                  '${d['justification'] != null ? ' — ${d['justification']}' : ''}'),
          ],
          const SizedBox(height: 8),
          if (status == 'pending_review')
            Wrap(spacing: 8, children: [
              if (proposal['credits'] != null && reasons.isEmpty)
                FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _call({'action': 'approve', 'orderId': s['orderId']},
                            s['method'] == 'cash'
                                ? 'Règlement cash ouvert.'
                                : 'Gains crédités.'),
                    child: const Text('Valider la répartition')),
              OutlinedButton(
                  onPressed: _busy ? null : () => _correct(s),
                  child: const Text('Corriger avec justification')),
            ]),
          if (status == 'cash_pending')
            FilledButton(
                onPressed: _busy ? null : () => _closeCash(s),
                child: const Text('Clôturer le règlement cash')),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Gains des courses transférées'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('transfer_settlements')
            .orderBy('createdAtMs', descending: true)
            .limit(100)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return const StreamErrorState();
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs.map((d) => d.data()).toList();
          final pending = docs
              .where((s) =>
                  s['status'] == 'pending_review' || s['status'] == 'cash_pending')
              .length;
          final now = DateTime.now().millisecondsSinceEpoch;
          final late = docs
              .where((s) =>
                  (s['status'] == 'pending_review' || s['status'] == 'cash_pending') &&
                  now > (s['dueAtMs'] as num))
              .length;
          if (docs.isEmpty) {
            return const Center(child: Text('Aucun règlement en attente.'));
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text('$pending dossier(s) ouvert(s) · $late en retard (objectif 24 h)',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: late > 0 ? const Color(0xFFB71C1C) : null)),
            const SizedBox(height: 8),
            for (final s in docs) _card(s),
          ]);
        },
      ),
    );
  }
}
