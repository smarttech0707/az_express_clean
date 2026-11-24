import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/stream_error_state.dart';
import 'admin_disputes_page.dart';

/// Alertes de commandes bloquées (acceptées depuis longtemps ou récupérées sans livraison).
/// Lecture seule via `adminOrderDisputeCF` (action `listAlerts`) ; aucune annulation ni
/// remboursement automatique. Une commande récupérée mène au dossier de litige.
class AdminStuckAlertsPage extends StatefulWidget {
  const AdminStuckAlertsPage({super.key});
  @override
  State<AdminStuckAlertsPage> createState() => _AdminStuckAlertsPageState();
}

class _AdminStuckAlertsPageState extends State<AdminStuckAlertsPage> {
  late Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final res = await FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('adminOrderDisputeCF')
        .call<Map<Object?, Object?>>({'action': 'listAlerts'});
    return ((res.data['alerts'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  void _refresh() => setState(() => _future = _load());

  String _age(Object? ms) {
    final t = (ms as num?)?.toInt();
    if (t == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Commandes bloquées'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
              tooltip: 'Actualiser',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            final e = snap.error;
            return StreamErrorState(
              message: e is FirebaseFunctionsException
                  ? (e.message ?? 'Accès refusé')
                  : 'Impossible de charger les alertes.',
              onRetry: _refresh,
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final alerts = snap.data!;
          if (alerts.isEmpty) {
            return const Center(child: Text('Aucune alerte.'));
          }
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: alerts.length,
              itemBuilder: (context, i) {
                final a = alerts[i];
                final pickedUp = a['status'] == 'picked_up';
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: Icon(
                        pickedUp
                            ? Icons.inventory_2_rounded
                            : Icons.hourglass_bottom_rounded,
                        color: AppColors.primary),
                    title: Text('Commande ${a['orderId']}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                        '${pickedUp ? 'Récupérée' : 'Acceptée'} depuis ${a['minutes'] ?? '?'} min'
                        ' · alerte ${_age(a['alertedAtMs'])}'
                        '${a['driverId'] != null ? ' · livreur ${a['driverId']}' : ''}'),
                    trailing: pickedUp ? const Icon(Icons.chevron_right_rounded) : null,
                    onTap: pickedUp
                        ? () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => AdminDisputeDetailPage(
                                    orderId: a['orderId'] as String)))
                        : null,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
