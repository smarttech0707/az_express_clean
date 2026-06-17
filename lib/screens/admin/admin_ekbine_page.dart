import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/subscription_service.dart';

class AdminEkbinePage extends StatefulWidget {
  const AdminEkbinePage({super.key});
  @override
  State<AdminEkbinePage> createState() => _AdminEkbinePageState();
}

class _AdminEkbinePageState extends State<AdminEkbinePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  static const _green = Color(0xFF00695C);
  static const _teal  = Color(0xFF00BFA5);

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: _green,
        foregroundColor: Colors.white,
        title: const Text('E-Kbine Admin',
            style: TextStyle(fontWeight: FontWeight.bold)),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          tabs: const [
            Tab(text: 'En attente'),
            Tab(text: 'Approuvés'),
            Tab(text: 'Rejetés'),
            Tab(text: 'Commandes'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _AgentList(status: 'pending',  color: _green, teal: _teal),
          _AgentList(status: 'approved', color: _green, teal: _teal),
          _AgentList(status: 'rejected', color: _green, teal: _teal),
          _OrdersTab(color: _green),
        ],
      ),
    );
  }
}

// ── LISTE DES COMMANDES ─────────────────────────────────────────────────────────

class _OrdersTab extends StatelessWidget {
  final Color color;
  const _OrdersTab({required this.color});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('ekbine_orders')
          .orderBy('createdAt', descending: true)
          .limit(50)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.receipt_long_rounded, size: 64, color: Colors.grey.shade300),
              const SizedBox(height: 12),
              Text('Aucune commande', style: TextStyle(color: Colors.grey.shade500)),
            ]),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final d = docs[i].data() as Map<String, dynamic>;
            return _OrderCard(docId: docs[i].id, data: d, color: color);
          },
        );
      },
    );
  }
}

class _OrderCard extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> data;
  final Color color;

  const _OrderCard({
    required this.docId,
    required this.data,
    required this.color,
  });

  Color _statusColor(String s) {
    switch (s) {
      case 'completed':        return const Color(0xFF00C853);
      case 'cancelled':        return Colors.red;
      case 'disputed':         return Colors.deepOrange;
      case 'pending':          return Colors.orange;
      case 'in_progress':      return const Color(0xFF1565C0);
      case 'proof_sent':       return const Color(0xFF00BCD4);
      case 'awaiting_deposit': return const Color(0xFFE65100);
      default:                 return Colors.grey;
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'pending':          return 'En attente';
      case 'assigned':         return 'Agent trouvé';
      case 'awaiting_deposit': return 'Attente dépôt';
      case 'in_progress':      return 'En cours';
      case 'proof_sent':       return 'Preuve envoyée';
      case 'completed':        return 'Terminée';
      case 'cancelled':        return 'Annulée';
      case 'disputed':         return 'Litige';
      default:                 return s;
    }
  }

  int _fmt(dynamic v) => (v as num? ?? 0).toInt();

  @override
  Widget build(BuildContext context) {
    final status     = data['status'] as String? ?? 'pending';
    final statusCol  = _statusColor(status);
    final amount     = _fmt(data['amount']);
    final fee        = _fmt(data['fee']);
    final commAZ     = _fmt(data['commissionAZ']);
    final agentEarn  = _fmt(data['agentEarning']);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8, offset: const Offset(0, 3)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(data['serviceLabel'] ?? '-',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14)),
                Text('${data['operator']?.toString().toUpperCase() ?? ''} · '
                    '${data['beneficiaryNumber'] ?? ''}',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  color: statusCol.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20)),
              child: Text(_statusLabel(status),
                  style: TextStyle(
                      color: statusCol, fontSize: 11,
                      fontWeight: FontWeight.bold)),
            ),
          ]),
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(children: [
            _InfoChip('Montant', '$amount F', Colors.grey.shade700),
            const SizedBox(width: 8),
            _InfoChip('Frais', '$fee F', color),
            const SizedBox(width: 8),
            _InfoChip('AZ 25%', '$commAZ F', Colors.purple.shade700),
            const SizedBox(width: 8),
            _InfoChip('Agent 75%', '$agentEarn F', const Color(0xFF00C853)),
          ]),
          if (data['clientName'] != null || data['agentName'] != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              const Icon(Icons.person_outline, size: 14, color: Colors.grey),
              const SizedBox(width: 4),
              Text('Client: ${data['clientName'] ?? '-'}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              if (data['agentName'] != null) ...[
                const SizedBox(width: 12),
                const Icon(Icons.support_agent, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Expanded(
                  child: Text('Agent: ${data['agentName']}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ]),
          ],
          if (status == 'disputed') ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.deepOrange.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.deepOrange.withValues(alpha: 0.4)),
              ),
              child: Row(children: [
                const Icon(Icons.warning_rounded, color: Colors.deepOrange, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Litige ouvert — intervention admin requise',
                      style: TextStyle(fontSize: 12, color: Colors.deepOrange.shade700)),
                ),
              ]),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _resolveDispute(context, 'completed'),
                  icon: const Icon(Icons.check_circle_rounded, size: 16),
                  label: const Text('Résoudre → Terminé'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00C853),
                    side: const BorderSide(color: Color(0xFF00C853)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _resolveDispute(context, 'cancelled'),
                  icon: const Icon(Icons.cancel_rounded, size: 16),
                  label: const Text('Résoudre → Annulé'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  Future<void> _resolveDispute(BuildContext context, String resolution) async {
    await FirebaseFirestore.instance
        .collection('ekbine_orders')
        .doc(docId)
        .update({
      'status': resolution,
      if (resolution == 'cancelled')
        'cancellationReason': 'Résolu par l\'administrateur',
    });
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Litige résolu : $resolution'),
        backgroundColor: resolution == 'completed' ? const Color(0xFF00C853) : Colors.red,
      ));
    }
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _InfoChip(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text(value,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.bold, color: color)),
      Text(label,
          style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
    ]);
  }
}

// ── LISTE AGENTS PAR STATUT ─────────────────────────────────────────────────────

class _AgentList extends StatelessWidget {
  final String status;
  final Color color;
  final Color teal;
  const _AgentList({required this.status, required this.color, required this.teal});

  @override
  Widget build(BuildContext context) {
    Query query = FirebaseFirestore.instance
        .collection('ekbine_agents')
        .orderBy('createdAt', descending: true);

    if (status == 'pending') {
      query = query.where('status', isEqualTo: 'pending');
    } else if (status == 'approved') {
      query = query.where('isVerified', isEqualTo: true);
    } else {
      query = query.where('status', isEqualTo: 'rejected');
    }

    return StreamBuilder<QuerySnapshot>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.inbox_rounded, size: 64, color: Colors.grey.shade300),
              const SizedBox(height: 12),
              Text('Aucun agent',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 15)),
            ]),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final doc = docs[i];
            final d   = doc.data() as Map<String, dynamic>;
            return _AgentCard(
              docId:  doc.id,
              data:   d,
              status: status,
              color:  color,
            );
          },
        );
      },
    );
  }
}

// ── CARTE AGENT ─────────────────────────────────────────────────────────────────

class _AgentCard extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> data;
  final String status;
  final Color color;
  const _AgentCard({
    required this.docId,
    required this.data,
    required this.status,
    required this.color,
  });

  Future<void> _approve(BuildContext context) async {
    final ref = FirebaseFirestore.instance
        .collection('ekbine_agents').doc(docId);
    final trialEnd = Timestamp.fromDate(
        DateTime.now().add(const Duration(days: SubscriptionService.freeTrialDays)));
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        tx.update(ref, {
          'status':                'approved',
          'isVerified':            true,
          'isSuspended':           false,
          'subscriptionStatus':    'trial',
          'subscriptionExpiresAt': trialEnd,
        });
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Agent approuvé — 2 mois gratuits activés'),
              backgroundColor: Color(0xFF00695C)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Erreur lors de l\'approbation : $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _reject(BuildContext context) async {
    await FirebaseFirestore.instance
        .collection('ekbine_agents')
        .doc(docId)
        .update({'status': 'rejected', 'isVerified': false});
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agent rejeté'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _revoke(BuildContext context) async {
    await FirebaseFirestore.instance
        .collection('ekbine_agents')
        .doc(docId)
        .update({'status': 'pending', 'isVerified': false, 'isOnline': false});
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Approbation révoquée')));
    }
  }

  Future<void> _suspend(BuildContext context) async {
    await FirebaseFirestore.instance
        .collection('ekbine_agents')
        .doc(docId)
        .update({'isSuspended': true, 'isOnline': false});
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agent suspendu'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _unsuspend(BuildContext context) async {
    await FirebaseFirestore.instance
        .collection('ekbine_agents')
        .doc(docId)
        .update({'isSuspended': false});
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Suspension levée'),
            backgroundColor: Color(0xFF00695C)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ops        = (data['operators'] as List<dynamic>?)?.cast<String>() ?? [];
    final opNums     = Map<String, String>.from(data['operatorNumbers'] as Map? ?? {});
    final isSuspended = data['isSuspended'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              backgroundColor: isSuspended
                  ? Colors.red.withValues(alpha: 0.12)
                  : color.withValues(alpha: 0.12),
              radius: 24,
              child: Text(
                (data['name'] as String? ?? '?')[0].toUpperCase(),
                style: TextStyle(
                    color: isSuspended ? Colors.red : color,
                    fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(data['name'] ?? 'Inconnu',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                  if (isSuspended)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10)),
                      child: const Text('SUSPENDU',
                          style: TextStyle(color: Colors.red,
                              fontSize: 9, fontWeight: FontWeight.bold)),
                    ),
                ]),
                Text(data['phone'] ?? '',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
              ]),
            ),
            _StatusBadge(status: data['status'] ?? 'pending'),
          ]),

          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),

          Row(children: [
            Icon(Icons.location_on_rounded, size: 16, color: Colors.grey.shade500),
            const SizedBox(width: 4),
            Text(data['city'] ?? '-',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
            const SizedBox(width: 20),
            const Icon(Icons.star_rounded, size: 16, color: Colors.amber),
            const SizedBox(width: 4),
            Text('${data['totalCompleted'] ?? 0} commandes',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
          ]),

          if (ops.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              children: ops.map((op) {
                final num = opNums[op];
                return Chip(
                  label: Text(
                    num != null ? '$op · $num' : op,
                    style: const TextStyle(fontSize: 10),
                  ),
                  backgroundColor: color.withValues(alpha: 0.08),
                  side: BorderSide(color: color.withValues(alpha: 0.3)),
                  padding: EdgeInsets.zero,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                );
              }).toList(),
            ),
          ],

          const SizedBox(height: 14),

          if (status == 'pending')
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _reject(context),
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Rejeter'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _approve(context),
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: const Text('Approuver'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: color,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ]),

          if (status == 'approved')
            Column(children: [
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _revoke(context),
                    icon: const Icon(Icons.block_rounded, size: 16),
                    label: const Text('Révoquer'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange,
                      side: const BorderSide(color: Colors.orange),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: isSuspended
                      ? ElevatedButton.icon(
                          onPressed: () => _unsuspend(context),
                          icon: const Icon(Icons.lock_open_rounded, size: 16),
                          label: const Text('Lever susp.'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00695C),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        )
                      : OutlinedButton.icon(
                          onPressed: () => _suspend(context),
                          icon: const Icon(Icons.do_not_disturb_rounded, size: 16),
                          label: const Text('Suspendre'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                ),
              ]),
            ]),

          if (status == 'rejected')
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _approve(context),
                icon: const Icon(Icons.check_rounded, size: 16),
                label: const Text('Approuver quand même'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: color,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

// ── BADGE STATUT ────────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    String label;
    switch (status) {
      case 'approved':
        bg = const Color(0xFFE8F5E9);
        fg = const Color(0xFF2E7D32);
        label = 'Approuvé';
        break;
      case 'rejected':
        bg = const Color(0xFFFFEBEE);
        fg = Colors.red.shade700;
        label = 'Rejeté';
        break;
      default:
        bg = const Color(0xFFFFF8E1);
        fg = const Color(0xFFF57F17);
        label = 'En attente';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label,
          style: TextStyle(
              color: fg, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }
}
