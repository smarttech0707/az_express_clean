import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/stream_error_state.dart';

/// Examen administratif de la facturation Marketplace / Boutique (super-admin) :
///  - frais de livraison retenus après récupération du colis (décision à prendre) ;
///  - livraisons bloquées (acceptées/récupérées depuis longtemps) à clôturer ;
///  - commandes boutique payées dont la livraison est close, à rembourser.
/// Aucune écriture Firestore directe : tout passe par `adminBillingCF`, qui
/// contrôle les droits, journalise et empêche les doubles remboursements.
class AdminBillingReviewsPage extends StatefulWidget {
  const AdminBillingReviewsPage({super.key});
  @override
  State<AdminBillingReviewsPage> createState() =>
      _AdminBillingReviewsPageState();
}

class _AdminBillingReviewsPageState extends State<AdminBillingReviewsPage> {
  bool _busy = false; // anti double-tap
  static const _stuckAfter = Duration(hours: 2);

  Future<String?> _askJustification(String title) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          decoration: const InputDecoration(
              labelText: 'Justification obligatoire (10 car. min.)'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmer')),
        ],
      ),
    );
    final text = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true) return null;
    if (text.length < 10) {
      _snack('Justification trop courte.');
      return null;
    }
    return text;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _call(String title, Map<String, dynamic> data) async {
    if (_busy) return;
    final why = await _askJustification(title);
    if (why == null) return;
    setState(() => _busy = true);
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('adminBillingCF')
          .call<Map<String, dynamic>>({...data, 'justification': why});
      _snack('Décision enregistrée.');
    } on FirebaseFunctionsException catch (e) {
      _snack(e.message ?? 'Échec');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      );

  Widget _stream(Query<Map<String, dynamic>> query,
      List<Widget> Function(List<QueryDocumentSnapshot<Map<String, dynamic>>>) build,
      {required String empty}) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return const StreamErrorState();
        if (!snap.hasData) {
          return const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()));
        }
        final cards = build(snap.data!.docs);
        if (cards.isEmpty) {
          return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(empty, style: const TextStyle(color: Colors.grey)));
        }
        return Column(children: cards);
      },
    );
  }

  Widget _card(List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: children),
        ),
      );

  List<Widget> _holdCards(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    return docs.map((d) {
      final o = d.data();
      final hold = (o['deliveryFeeHold'] as Map?) ?? const {};
      return _card([
        Text('Commande ${d.id}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        Text('Frais retenus : ${hold['amount']} FCFA · annulée après '
            'récupération · livreur ${hold['driverId'] ?? '?'}'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final e in const {
            'refundClient': 'Rembourser le client (faute livreur/AZ)',
            'payDriver': 'Rémunérer le livreur',
            'retain': 'Conserver (AZ)',
          }.entries)
            OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _call(e.value, {
                          'action': 'resolveFeeHold',
                          'orderId': d.id,
                          'decision': e.key,
                        }),
                child: Text(e.value)),
        ]),
      ]);
    }).toList();
  }

  List<Widget> _stuckCards(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final limit = DateTime.now().subtract(_stuckAfter);
    final cards = <Widget>[];
    for (final d in docs) {
      final o = d.data();
      if (!['seller', 'boutique'].contains(o['sellerType'])) continue;
      final since = (o['acceptedAt'] as Timestamp?)?.toDate() ??
          (o['createdAt'] as Timestamp?)?.toDate();
      if (since == null || since.isAfter(limit)) continue;
      cards.add(_card([
        Text('${o['description'] ?? 'Commande'} · ${d.id}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        Text('Statut ${o['status']} depuis ${since.toLocal()} · '
            '${o['paymentMethod']} · total ${o['totalAmount'] ?? o['budget']} FCFA'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _call('Clôturer selon la règle commerciale',
                      {'action': 'closeStuckDelivery', 'orderId': d.id}),
              child: const Text('Clôturer (règle standard)')),
          OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _call('Clôturer — faute livreur/AZ (frais remboursés)', {
                        'action': 'closeStuckDelivery',
                        'orderId': d.id,
                        'refundFee': true,
                      }),
              child: const Text('Clôturer — faute (rembourser les frais)')),
        ]),
      ]));
    }
    return cards;
  }

  /// Anciennes commandes (créées par une ancienne application, sans montants
  /// explicites) en attente d'un livreur : elles ne peuvent plus être acceptées
  /// sans commission injustifiée, l'administration les clôture et rembourse.
  List<Widget> _legacyCards(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final cards = <Widget>[];
    for (final d in docs) {
      final o = d.data();
      if (!['seller', 'boutique'].contains(o['sellerType'])) continue;
      if (o['amountsVersion'] == 1) continue;
      cards.add(_card([
        Text('${o['description'] ?? 'Commande'} · ${d.id}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        Text('Ancienne commande en attente de livreur (statut ${o['status']}) · '
            '${o['paymentMethod']} · ${o['budget']} FCFA'),
        const SizedBox(height: 8),
        OutlinedButton(
            onPressed: _busy
                ? null
                : () => _call('Clôturer la commande historique et rembourser',
                    {'action': 'closeStuckDelivery', 'orderId': d.id}),
            child: const Text('Clôturer et rembourser')),
      ]));
    }
    return cards;
  }

  List<Widget> _boutiqueCards(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final now = DateTime.now();
    final cards = <Widget>[];
    for (final d in docs) {
      final o = d.data();
      if (o['paymentMethod'] != 'wallet') continue;
      final deadline = (o['deliveryDeadline'] as Timestamp?)?.toDate();
      if (deadline == null || deadline.isAfter(now)) continue;
      cards.add(_card([
        Text('${o['productName'] ?? 'Boutique'} · ${d.id}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        Text('Payée, non livrée dans les 48 h · '
            '${o['totalAmount'] ?? o['totalPrice']} FCFA'),
        const SizedBox(height: 8),
        OutlinedButton(
            onPressed: _busy
                ? null
                : () => _call('Rembourser la commande boutique',
                    {'action': 'refundBoutiqueOrder', 'orderId': d.id}),
            child: const Text('Rembourser (livraison clôturée requise)')),
      ]));
    }
    return cards;
  }

  @override
  Widget build(BuildContext context) {
    final fs = FirebaseFirestore.instance;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Facturation Marketplace / Boutique'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _section('Frais de livraison retenus'),
        _stream(
          fs
              .collection('orders')
              .where('deliveryFeeHold.status', isEqualTo: 'pending_admin_review')
              .limit(100),
          _holdCards,
          empty: 'Aucun frais en attente de décision.',
        ),
        _section('Livraisons bloquées (> 2 h)'),
        _stream(
          fs
              .collection('orders')
              .where('status', whereIn: ['accepted', 'picked_up']).limit(200),
          _stuckCards,
          empty: 'Aucune livraison Marketplace/Boutique bloquée.',
        ),
        _section('Anciennes commandes à résoudre'),
        _stream(
          fs
              .collection('orders')
              .where('status', whereIn: ['pending', 'broadcast', 'assigned']).limit(200),
          _legacyCards,
          empty: 'Aucune ancienne commande en attente.',
        ),
        _section('Commissions à vérifier (ancienne acceptation)'),
        _stream(
          fs
              .collection('orders')
              .where('legacyBillingReview.status', isEqualTo: 'pending_admin_review')
              .limit(100),
          (docs) => docs
              .map((d) => _card([
                    Text('Commande ${d.id}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const Text('Livrée avec une commission non tracée : à '
                        'vérifier manuellement (aucun remboursement automatique).'),
                  ]))
              .toList(),
          empty: 'Aucune commission à vérifier.',
        ),
        _section('Boutique payée non livrée (48 h)'),
        _stream(
          fs
              .collection('boutique_orders')
              .where('status', isEqualTo: 'paid')
              .limit(100),
          _boutiqueCards,
          empty: 'Aucune commande boutique à rembourser.',
        ),
      ]),
    );
  }
}
