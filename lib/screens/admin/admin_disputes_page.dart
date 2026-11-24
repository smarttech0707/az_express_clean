import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../theme/app_theme.dart';
import '../../widgets/stream_error_state.dart';

/// Litiges après récupération du colis (livraisons ordinaires).
///
/// Aucune écriture Firestore : tout passe par `adminOrderDisputeCF` (lecture, résolution,
/// remboursements) et `adminConfirmDeliveryCF` (confirmation administrative de livraison).
/// Les montants affichés sont calculés par le serveur ; l'écran n'en saisit jamais.
/// Remboursements et confirmation : super-administrateur seul (le serveur refuse les autres).
/// Spécification : docs/ORDER_DISPUTES_SPEC.md.
final _functions = FirebaseFunctions.instanceFor(region: 'europe-west1');

Future<Map<String, dynamic>> _callDispute(Map<String, dynamic> data) async {
  final res = await _functions
      .httpsCallable('adminOrderDisputeCF')
      .call<Map<Object?, Object?>>(data);
  return Map<String, dynamic>.from(res.data);
}

String _fcfa(Object? v) => '${(v as num?)?.toInt() ?? 0} FCFA';

class AdminDisputesPage extends StatefulWidget {
  const AdminDisputesPage({super.key});
  @override
  State<AdminDisputesPage> createState() => _AdminDisputesPageState();
}

class _AdminDisputesPageState extends State<AdminDisputesPage> {
  late Future<List<List<Map<String, dynamic>>>> _future = _load();

  Future<List<List<Map<String, dynamic>>>> _load() async {
    final results = await Future.wait([
      _callDispute({'action': 'listDisputes'}),
      _callDispute({'action': 'listReconciliation'}),
    ]);
    List<Map<String, dynamic>> rows(Map<String, dynamic> r, String key) =>
        ((r[key] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    return [rows(results[0], 'disputes'), rows(results[1], 'flags')];
  }

  void _refresh() => setState(() => _future = _load());

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Litiges de livraison'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
              tooltip: 'Actualiser',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: FutureBuilder<List<List<Map<String, dynamic>>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            final e = snap.error;
            return StreamErrorState(
              message: e is FirebaseFunctionsException
                  ? (e.message ?? 'Accès refusé')
                  : 'Impossible de charger les litiges.',
              onRetry: _refresh,
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final disputes = snap.data![0];
          final flags = snap.data![1];
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _section('Demandes d\'annulation après récupération'),
                if (disputes.isEmpty)
                  const Text('Aucun litige en attente.',
                      style: TextStyle(color: Colors.grey)),
                for (final d in disputes)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      title: Text('Commande ${d['orderId']}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('Payé ${_fcfa(d['paid'])} · '
                          '${d['paymentMethod'] ?? '?'} · ${d['type'] ?? ''}'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => AdminDisputeDetailPage(
                                    orderId: d['orderId'] as String)));
                        if (mounted) _refresh();
                      },
                    ),
                  ),
                _section('Rapprochements comptables à traiter'),
                if (flags.isEmpty)
                  const Text('Aucun signalement ouvert.',
                      style: TextStyle(color: Colors.grey)),
                for (final f in flags)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      leading: const Icon(Icons.balance_rounded),
                      title: Text('Commande ${f['orderId']}'),
                      subtitle: Text(f['type'] == 'driver_advance_unreimbursed'
                          ? 'AVANCE DU LIVREUR ${f['driverId'] ?? '?'} À RÉGLER : '
                              '${f['amount'] ?? '?'} FCFA avancés pour des achats, '
                              'client remboursé. Aucune compensation automatique.'
                          : f['type'] == 'commission_untraced'
                              ? 'Commission jamais prouvée pour le livreur '
                                  '${f['driverId'] ?? '?'} : rien n\'a été rendu. '
                                  'Vérifier le prélèvement avant tout crédit.'
                              : 'Vendeur ${f['sellerId'] ?? '?'} '
                                  '(${f['sellerType'] ?? '?'}) — vérifier s\'il a déjà '
                                  'été payé. Aucun débit automatique.'),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Dossier d'un litige : faits financiers, options chiffrées par le serveur, décisions.
class AdminDisputeDetailPage extends StatefulWidget {
  final String orderId;
  const AdminDisputeDetailPage({super.key, required this.orderId});
  @override
  State<AdminDisputeDetailPage> createState() => _AdminDisputeDetailPageState();
}

class _AdminDisputeDetailPageState extends State<AdminDisputeDetailPage> {
  static const _shoppingLabels = {
    'not_purchased': 'Rien n\'a été acheté',
    'purchased_returned': 'Acheté, produits retournés',
    'purchased_delivered': 'Acheté, produits remis au client',
    'purchased_unreturned': 'Acheté, produits non remis ni retournés',
  };
  static const _evidenceLabels = {
    'client_confirmed': 'Le client confirme avoir reçu',
    'driver_proof': 'Preuve fournie par le livreur',
    'phone_verified': 'Vérifié par appel téléphonique',
    'other_justified': 'Autre (à détailler)',
  };
  static const _options = {
    'refundShopping': 'A · Rembourser le budget d\'achat',
    'refundFee': 'B · Rembourser les frais de livraison',
    'refundHalfFee': 'C · Rembourser 50 % des frais',
    'exceptionalCancel': 'D · Remboursement total (annulation)',
  };

  late Future<Map<String, dynamic>> _future = _load();
  bool _busy = false; // anti double-tap
  // Un requestId par décision, conservé tant qu'elle n'a pas abouti : un nouvel essai après
  // une coupure réseau rejoue la MÊME opération (idempotente) au lieu d'en créer une autre.
  final Map<String, String> _requestIds = {};

  Future<Map<String, dynamic>> _load() async {
    final r = await _callDispute({'action': 'get', 'orderId': widget.orderId});
    return Map<String, dynamic>.from(r['dispute'] as Map);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _requestId(String key) => _requestIds.putIfAbsent(key, () => const Uuid().v4());

  /// Fenêtre de décision : justification, situation du budget d'achat, preuve.
  Future<Map<String, dynamic>?> _ask({
    required String title,
    required String summary,
    bool askShopping = false,
    bool spentToggleFor = false,
    bool askEvidence = false,
    bool advanceToggleFor = false,
  }) async {
    final ctrl = TextEditingController();
    String? shopping;
    String? evidence;
    bool justifiedSpent = false;
    bool driverAdvanced = false;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final spent = shopping == 'purchased_delivered' ||
            shopping == 'purchased_unreturned';
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(summary),
                const SizedBox(height: 12),
                if (askShopping)
                  DropdownButtonFormField<String>(
                    initialValue: shopping,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Situation du budget d\'achat'),
                    items: [
                      for (final e in _shoppingLabels.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setLocal(() => shopping = v),
                  ),
                if (askShopping && spent && spentToggleFor)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                        'Budget déjà dépensé : rembourser quand même (décision justifiée)'),
                    value: justifiedSpent,
                    onChanged: (v) => setLocal(() => justifiedSpent = v),
                  ),
                if (askShopping && spent && advanceToggleFor)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                        'Le livreur a avancé ses propres fonds pour les achats (remboursé sur le budget d\'achat)'),
                    value: driverAdvanced,
                    onChanged: (v) => setLocal(() => driverAdvanced = v),
                  ),
                if (askEvidence)
                  DropdownButtonFormField<String>(
                    initialValue: evidence,
                    isExpanded: true,
                    decoration:
                        const InputDecoration(labelText: 'Preuve de livraison'),
                    items: [
                      for (final e in _evidenceLabels.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setLocal(() => evidence = v),
                  ),
                TextField(
                  controller: ctrl,
                  maxLines: 3,
                  decoration: InputDecoration(
                      labelText: justifiedSpent
                          ? 'Justification détaillée (30 car. min.)'
                          : 'Justification obligatoire (10 car. min.)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Annuler')),
            FilledButton(
              onPressed: () {
                final text = ctrl.text.trim();
                if (text.length < (justifiedSpent ? 30 : 10)) {
                  _snack('Justification trop courte.');
                  return;
                }
                if (askShopping && shopping == null) {
                  _snack('Indiquez la situation du budget d\'achat.');
                  return;
                }
                if (askEvidence && evidence == null) {
                  _snack('Indiquez la preuve de livraison.');
                  return;
                }
                Navigator.pop(ctx, {
                  'justification': text,
                  if (shopping != null) 'shoppingContext': shopping,
                  if (justifiedSpent) 'justifiedSpentRefund': true,
                  if (driverAdvanced) 'advancedBy': 'driver_own_funds',
                  if (evidence != null) 'evidence': evidence,
                });
              },
              child: const Text('Confirmer'),
            ),
          ],
        );
      }),
    );
    ctrl.dispose();
    return result;
  }

  Future<void> _run(String key, Future<void> Function() call) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await call();
      _requestIds.remove(key);
      _snack('Décision enregistrée.');
      if (mounted) setState(() => _future = _load());
    } on FirebaseFunctionsException catch (e) {
      _snack(e.message ?? 'Échec');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decide(String decision, Map<String, dynamic> d) async {
    final needsShopping = (d['checks'] as Map)['needsShoppingContext'] == true;
    final isRefund = decision != 'resolve';
    final opt = (d['options'] as Map?)?[decision] as Map?;
    final summary = decision == 'resolve'
        ? 'La demande est classée. La commande reste en cours : aucun mouvement d\'argent.'
        : 'Budget d\'achat non dépensé : client remboursé de ${_fcfa(opt?['clientRefund'])}'
            '${decision == 'exceptionalCancel' ? ', commission rendue au livreur, commande annulée' : ', rémunération du livreur ${_fcfa(opt?['driverPay'])}, commission AZ conservée, commande close'}.'
            '${(opt?['ifSpent'] is Map) ? ' Budget dépensé et avancé par le livreur : client ${_fcfa((opt!['ifSpent'] as Map)['clientRefund'])}, remboursement des achats au livreur ${_fcfa((opt['ifSpent'] as Map)['driverReimbursement'])}, rémunération ${_fcfa((opt['ifSpent'] as Map)['driverPay'])}.' : ''}'
            ' Le budget d\'achat n\'est jamais une rémunération. Décision définitive.';
    final form = await _ask(
      title: isRefund ? _options[decision]! : 'Résoudre sans clôturer',
      summary: summary,
      askShopping: isRefund && needsShopping,
      spentToggleFor: decision == 'refundShopping' || decision == 'exceptionalCancel',
      advanceToggleFor: true,
    );
    if (form == null) return;
    await _run(decision, () async {
      await _callDispute({
        'action': 'decide',
        'orderId': widget.orderId,
        'decision': decision,
        'requestId': _requestId(decision),
        ...form,
      });
    });
  }

  Future<void> _confirmDelivery(Map<String, dynamic> d) async {
    final form = await _ask(
      title: 'Confirmer la livraison',
      summary: 'À utiliser uniquement si la livraison a réellement eu lieu. '
          'La commande passe à « livrée » et le livreur est payé selon les règles '
          'normales (une seule fois, sans nouvelle commission).',
      askEvidence: true,
    );
    if (form == null) return;
    await _run('confirmDelivery', () async {
      await _functions.httpsCallable('adminConfirmDeliveryCF').call({
        'orderId': widget.orderId,
        'requestId': _requestId('confirmDelivery'),
        ...form,
      });
    });
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 150, child: Text(k, style: const TextStyle(color: Colors.grey))),
          Expanded(child: Text(v)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text('Litige ${widget.orderId}'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            final e = snap.error;
            return StreamErrorState(
              message: e is FirebaseFunctionsException
                  ? (e.message ?? 'Accès refusé')
                  : 'Impossible de charger le dossier.',
              onRetry: () => setState(() => _future = _load()),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data!;
          final amounts = Map<String, dynamic>.from(d['amounts'] as Map);
          final checks = Map<String, dynamic>.from(d['checks'] as Map);
          final options = Map<String, dynamic>.from(d['options'] as Map);
          final open = d['status'] == 'picked_up';
          final admin = d['handledByAdminBilling'] == true;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _kv('Statut', '${d['status']}'),
                  _kv('Client', '${(d['client'] as Map)['name'] ?? (d['client'] as Map)['id']}'),
                  _kv('Livreur', '${(d['driver'] as Map)['name'] ?? (d['driver'] as Map)['id']}'),
                  _kv('Paiement', '${amounts['paymentMethod']}'),
                  _kv('Réellement payé', _fcfa(amounts['paidFromWallet'])),
                  _kv('Frais / achat', '${_fcfa(amounts['budget'])} / ${_fcfa(amounts['shoppingBudget'])}'),
                  _kv('Commission AZ', '${amounts['commissionStatus'] ?? 'aucune'} ${amounts['commissionAmount'] ?? ''}'),
                  _kv('Livreur déjà payé', checks['driverAlreadyPaid'] == true ? 'OUI' : 'non'),
                  _kv('Vendeur', checks['hasSeller'] == true ? 'oui (rapprochement)' : 'aucun'),
                ]),
              ),
            ),
            if (admin)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Commande Marketplace/Boutique : utiliser « Facturation Marketplace ».',
                    style: TextStyle(color: Colors.orange)),
              ),
            if (!open && !admin)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Cette commande n\'est plus récupérée : aucune décision possible.'),
              ),
            if (open && !admin) ...[
              const Padding(
                padding: EdgeInsets.only(top: 16, bottom: 8),
                child: Text('Décisions',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _decide('resolve', d),
                icon: const Icon(Icons.check_circle_outline_rounded),
                label: const Text('Résoudre sans clôturer (aucun argent)'),
              ),
              for (final e in _options.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton(
                    onPressed: _busy || (options[e.key] as Map)['available'] != true
                        ? null
                        : () => _decide(e.key, d),
                    child: Text(
                      (options[e.key] as Map)['available'] == true
                          ? '${e.value} — client ${_fcfa((options[e.key] as Map)['clientRefund'])}'
                          : '${e.value} — indisponible',
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _confirmDelivery(d),
                  icon: const Icon(Icons.local_shipping_rounded),
                  label: const Text('Confirmer la livraison (clôture réelle)'),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                    'Remboursements et confirmation : super-administrateur uniquement. '
                    'Montants calculés par le serveur.',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ),
            ],
          ]);
        },
      ),
    );
  }
}
