import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';

class AdminSecurityDashboard extends StatefulWidget {
  const AdminSecurityDashboard({super.key});

  @override
  State<AdminSecurityDashboard> createState() => _AdminSecurityDashboardState();
}

class _AdminSecurityDashboardState extends State<AdminSecurityDashboard> {
  final _db = FirebaseFirestore.instance;

  // ── Période d'analyse : dernières 24h ─────────────────────────────────────
  late final Timestamp _since24h = Timestamp.fromDate(
    DateTime.now().subtract(const Duration(hours: 24)),
  );
  late final Timestamp _since1h = Timestamp.fromDate(
    DateTime.now().subtract(const Duration(hours: 1)),
  );
  late final Timestamp _since7d = Timestamp.fromDate(
    DateTime.now().subtract(const Duration(days: 7)),
  );
  late final Timestamp _since30d = Timestamp.fromDate(
    DateTime.now().subtract(const Duration(days: 30)),
  );

  Future<Map<String, int>> _loadAuditStats() async {
    final results = await Future.wait([
      _db.collection('audit_logs')
          .where('action', isEqualTo: 'payment_initiated')
          .where('createdAt', isGreaterThan: _since24h).count().get(),
      _db.collection('audit_logs')
          .where('action', isEqualTo: 'wallet_credited')
          .where('createdAt', isGreaterThan: _since24h).count().get(),
      _db.collection('audit_logs')
          .where('action', isEqualTo: 'withdrawal_initiated')
          .where('createdAt', isGreaterThan: _since24h).count().get(),
      _db.collection('security_events')
          .where('resolved', isEqualTo: false)
          .count().get(),
      _db.collection('security_events')
          .where('severity', isEqualTo: 'critical')
          .where('resolved', isEqualTo: false).count().get(),
      _db.collection('security_events')
          .where('eventType', isEqualTo: 'webhook_invalid_secret')
          .where('createdAt', isGreaterThan: _since24h).count().get(),
      _db.collection('security_events')
          .where('eventType', isEqualTo: 'webhook_replay_attempt')
          .where('createdAt', isGreaterThan: _since24h).count().get(),
      _db.collection('rate_limits')
          .where('updatedAt', isGreaterThan: _since1h).count().get(),
      // Dispatching — commandes annulées faute de livreur
      _db.collection('audit_logs')
          .where('action', isEqualTo: 'order_auto_cancelled_no_driver')
          .where('createdAt', isGreaterThan: _since24h).count().get(),
      _db.collection('audit_logs')
          .where('action', isEqualTo: 'order_auto_cancelled_no_driver')
          .where('createdAt', isGreaterThan: _since7d).count().get(),
      _db.collection('audit_logs')
          .where('action', isEqualTo: 'order_auto_cancelled_no_driver')
          .where('createdAt', isGreaterThan: _since30d).count().get(),
    ]);

    return {
      'payments_24h':        results[0].count ?? 0,
      'recharges_24h':       results[1].count ?? 0,
      'withdrawals_24h':     results[2].count ?? 0,
      'open_events':         results[3].count ?? 0,
      'critical_events':     results[4].count ?? 0,
      'webhook_invalid':     results[5].count ?? 0,
      'webhook_replay':      results[6].count ?? 0,
      'rate_limited_1h':     results[7].count ?? 0,
      'no_driver_24h':       results[8].count ?? 0,
      'no_driver_7d':        results[9].count ?? 0,
      'no_driver_30d':       results[10].count ?? 0,
    };
  }

  String _alertLevel(Map<String, int> s) {
    if ((s['critical_events'] ?? 0) > 0 || (s['webhook_invalid'] ?? 0) > 2) {
      return 'critical';
    }
    if ((s['open_events'] ?? 0) > 3 || (s['webhook_replay'] ?? 0) > 0) {
      return 'warning';
    }
    return 'normal';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Sécurité',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
        backgroundColor: const Color(0xFF1A1A2E),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => setState(() {}),
            tooltip: 'Actualiser',
          ),
        ],
      ),
      body: FutureBuilder<Map<String, int>>(
        future: _loadAuditStats(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: AppColors.primary));
          }
          if (snap.hasError) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 48),
                const SizedBox(height: 12),
                Text('Erreur : ${snap.error}',
                    style: const TextStyle(color: Colors.red)),
              ]),
            );
          }
          final s     = snap.data!;
          final level = _alertLevel(s);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _AlertBanner(level: level),
              const SizedBox(height: 16),
              const _SectionTitle('Activité financière — 24h'),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _StatCard(
                  icon: Icons.payment_rounded,
                  label: 'Paiements initiés',
                  value: '${s['payments_24h']}',
                  color: const Color(0xFF2196F3),
                )),
                const SizedBox(width: 10),
                Expanded(child: _StatCard(
                  icon: Icons.account_balance_wallet_rounded,
                  label: 'Wallets crédités',
                  value: '${s['recharges_24h']}',
                  color: const Color(0xFF4CAF50),
                )),
                const SizedBox(width: 10),
                Expanded(child: _StatCard(
                  icon: Icons.send_rounded,
                  label: 'Retraits',
                  value: '${s['withdrawals_24h']}',
                  color: AppColors.primary,
                )),
              ]),
              const SizedBox(height: 16),
              const _SectionTitle('Événements suspects'),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _StatCard(
                  icon: Icons.warning_rounded,
                  label: 'Alertes ouvertes',
                  value: '${s['open_events']}',
                  color: (s['open_events'] ?? 0) > 0 ? Colors.orange : const Color(0xFF4CAF50),
                  highlight: (s['open_events'] ?? 0) > 0,
                )),
                const SizedBox(width: 10),
                Expanded(child: _StatCard(
                  icon: Icons.dangerous_rounded,
                  label: 'Critiques',
                  value: '${s['critical_events']}',
                  color: (s['critical_events'] ?? 0) > 0 ? Colors.red : const Color(0xFF4CAF50),
                  highlight: (s['critical_events'] ?? 0) > 0,
                )),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _StatCard(
                  icon: Icons.webhook_rounded,
                  label: 'Webhooks invalides\n(24h)',
                  value: '${s['webhook_invalid']}',
                  color: (s['webhook_invalid'] ?? 0) > 0 ? Colors.red : const Color(0xFF4CAF50),
                  highlight: (s['webhook_invalid'] ?? 0) > 0,
                )),
                const SizedBox(width: 10),
                Expanded(child: _StatCard(
                  icon: Icons.replay_rounded,
                  label: 'Replays tentés\n(24h)',
                  value: '${s['webhook_replay']}',
                  color: (s['webhook_replay'] ?? 0) > 0 ? Colors.red : const Color(0xFF4CAF50),
                  highlight: (s['webhook_replay'] ?? 0) > 0,
                )),
                const SizedBox(width: 10),
                Expanded(child: _StatCard(
                  icon: Icons.block_rounded,
                  label: 'Rate limits\n(1h)',
                  value: '${s['rate_limited_1h']}',
                  color: (s['rate_limited_1h'] ?? 0) > 5 ? Colors.orange : const Color(0xFF607D8B),
                )),
              ]),
              const SizedBox(height: 20),
              const _SectionTitle('Dispatching — commandes sans livreur'),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _StatCard(
                  icon: Icons.person_off_rounded,
                  label: 'Aujourd\'hui',
                  value: '${s['no_driver_24h']}',
                  color: (s['no_driver_24h'] ?? 0) > 0
                      ? Colors.deepOrange : const Color(0xFF4CAF50),
                  highlight: (s['no_driver_24h'] ?? 0) > 0,
                )),
                const SizedBox(width: 10),
                Expanded(child: _StatCard(
                  icon: Icons.date_range_rounded,
                  label: '7 derniers jours',
                  value: '${s['no_driver_7d']}',
                  color: (s['no_driver_7d'] ?? 0) > 3
                      ? Colors.orange : const Color(0xFF607D8B),
                )),
                const SizedBox(width: 10),
                Expanded(child: _StatCard(
                  icon: Icons.calendar_month_rounded,
                  label: '30 derniers jours',
                  value: '${s['no_driver_30d']}',
                  color: const Color(0xFF607D8B),
                )),
              ]),
              const SizedBox(height: 10),
              _TopZonesSection(db: _db),
              const SizedBox(height: 20),
              const _SectionTitle('Événements récents'),
              const SizedBox(height: 10),
              _RecentSecurityEvents(db: _db),
              const SizedBox(height: 20),
              const _SectionTitle('Derniers audit logs'),
              const SizedBox(height: 10),
              _RecentAuditLogs(db: _db),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

// ── Alert Banner ─────────────────────────────────────────────────────────────
class _AlertBanner extends StatelessWidget {
  final String level;
  const _AlertBanner({required this.level});

  @override
  Widget build(BuildContext context) {
    final (icon, label, bg, fg) = switch (level) {
      'critical' => (Icons.emergency_rounded,  '🔴 CRITIQUE — Intervention requise immédiatement', const Color(0xFFFFEBEE), Colors.red.shade700),
      'warning'  => (Icons.warning_amber_rounded, '🟠 SURVEILLANCE — Activité suspecte détectée',   const Color(0xFFFFF3E0), Colors.orange.shade700),
      _          => (Icons.check_circle_rounded,   '🟢 NORMAL — Aucune alerte active',              const Color(0xFFE8F5E9), Colors.green.shade700),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color:        bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: fg.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        Icon(icon, color: fg, size: 24),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label,
            style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 14)),
        ),
      ]),
    );
  }
}

// ── Section Title ─────────────────────────────────────────────────────────────
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Text(text,
    style: const TextStyle(
      fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF424242)));
}

// ── Stat Card ─────────────────────────────────────────────────────────────────
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool highlight;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: highlight ? color.withValues(alpha: 0.08) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlight ? color.withValues(alpha: 0.4) : const Color(0xFFEEEEEE),
        ),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(height: 8),
          Text(value,
            style: TextStyle(
              fontSize: 22, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: 2),
          Text(label,
            style: const TextStyle(fontSize: 10, color: Color(0xFF757575)),
            maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

// ── Recent Security Events ────────────────────────────────────────────────────
class _RecentSecurityEvents extends StatelessWidget {
  final FirebaseFirestore db;
  const _RecentSecurityEvents({required this.db});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: db.collection('security_events')
          .orderBy('createdAt', descending: true)
          .limit(10)
          .snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return const _EmptyCard(
            icon: Icons.verified_user_rounded,
            message: 'Aucun événement suspect',
            color: Color(0xFF4CAF50),
          );
        }
        return Column(
          children: snap.data!.docs.map((doc) {
            final d        = doc.data() as Map<String, dynamic>;
            final severity = d['severity'] as String? ?? 'low';
            final resolved = d['resolved'] as bool? ?? false;
            final ts       = (d['createdAt'] as Timestamp?)?.toDate();
            final color    = switch (severity) {
              'critical' => Colors.red,
              'high'     => Colors.orange,
              'medium'   => Colors.amber,
              _          => Colors.grey,
            };
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: resolved ? Colors.white : color.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: resolved
                      ? const Color(0xFFEEEEEE)
                      : color.withValues(alpha: 0.3),
                ),
              ),
              child: Row(children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    color: resolved ? Colors.grey : color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d['eventType'] ?? '—',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: resolved ? Colors.grey : const Color(0xFF212121),
                          decoration: resolved ? TextDecoration.lineThrough : null,
                        )),
                      if (d['description'] != null)
                        Text(d['description'],
                          style: const TextStyle(fontSize: 11, color: Color(0xFF757575)),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  _SeverityChip(severity: severity, resolved: resolved),
                  if (ts != null) ...[
                    const SizedBox(height: 4),
                    Text(DateFormat('dd/MM HH:mm').format(ts),
                      style: const TextStyle(fontSize: 10, color: Color(0xFF9E9E9E))),
                  ],
                ]),
              ]),
            );
          }).toList(),
        );
      },
    );
  }
}

class _SeverityChip extends StatelessWidget {
  final String severity;
  final bool resolved;
  const _SeverityChip({required this.severity, required this.resolved});

  @override
  Widget build(BuildContext context) {
    if (resolved) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Text('Résolu', style: TextStyle(fontSize: 10, color: Colors.grey)),
      );
    }
    final (label, color) = switch (severity) {
      'critical' => ('CRITIQUE', Colors.red),
      'high'     => ('ÉLEVÉ',    Colors.orange),
      'medium'   => ('MOYEN',    Colors.amber),
      _          => ('BAS',      Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

// ── Recent Audit Logs ─────────────────────────────────────────────────────────
class _RecentAuditLogs extends StatelessWidget {
  final FirebaseFirestore db;
  const _RecentAuditLogs({required this.db});

  static const _actionIcons = {
    'payment_initiated':              (Icons.payment_rounded,                Color(0xFF2196F3)),
    'wallet_credited':                (Icons.account_balance_wallet_rounded, Color(0xFF4CAF50)),
    'withdrawal_initiated':           (Icons.send_rounded,                   Color(0xFFFF6B00)),
    'create_sub_admin':               (Icons.person_add_rounded,             Color(0xFF9C27B0)),
    'delete_sub_admin':               (Icons.person_remove_rounded,          Colors.red),
    'ekbine_confirm_order':           (Icons.check_circle_rounded,           Color(0xFF009688)),
    'order_auto_cancelled_no_driver': (Icons.person_off_rounded,             Colors.deepOrange),
  };

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: db.collection('audit_logs')
          .orderBy('createdAt', descending: true)
          .limit(15)
          .snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return const _EmptyCard(
            icon: Icons.history_rounded,
            message: 'Aucun audit log',
            color: Color(0xFF9E9E9E),
          );
        }
        return Column(
          children: snap.data!.docs.map((doc) {
            final d      = doc.data() as Map<String, dynamic>;
            final action = d['action'] as String? ?? '—';
            final ts     = (d['createdAt'] as Timestamp?)?.toDate();
            final amount = d['amount'] as int?;
            final (icon, color) = _actionIcons[action] ??
                (Icons.history_rounded, const Color(0xFF9E9E9E));

            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color:        Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFF0F0F0)),
              ),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: color, size: 16),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_labelFor(action),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      Text(d['userId'] != null
                          ? 'uid: ${(d['userId'] as String).substring(0, 8)}…'
                          : '—',
                        style: const TextStyle(fontSize: 10, color: Color(0xFF9E9E9E))),
                    ],
                  ),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (amount != null)
                    Text('${amount ~/ 1} FCFA',
                      style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700, color: color)),
                  if (ts != null)
                    Text(DateFormat('dd/MM HH:mm').format(ts),
                      style: const TextStyle(fontSize: 10, color: Color(0xFF9E9E9E))),
                ]),
              ]),
            );
          }).toList(),
        );
      },
    );
  }

  String _labelFor(String action) => switch (action) {
    'payment_initiated'              => 'Paiement initié',
    'wallet_credited'                => 'Wallet crédité',
    'withdrawal_initiated'           => 'Retrait initié',
    'create_sub_admin'               => 'Sous-admin créé',
    'delete_sub_admin'               => 'Sous-admin supprimé',
    'ekbine_confirm_order'           => 'E-Kbine confirmé',
    'order_auto_cancelled_no_driver' => 'Commande expirée — sans livreur',
    _                                => action,
  };
}

// ── Top Zones sans livreur ────────────────────────────────────────────────────
class _TopZonesSection extends StatelessWidget {
  final FirebaseFirestore db;
  const _TopZonesSection({required this.db});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: db.collection('dispatch_metrics')
          .orderBy('noDriverFoundCount', descending: true)
          .limit(5)
          .snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return const _EmptyCard(
            icon: Icons.location_on_rounded,
            message: 'Aucune zone concernée pour l\'instant',
            color: Color(0xFF4CAF50),
          );
        }
        return Column(
          children: snap.data!.docs.map((doc) {
            final d     = doc.data() as Map<String, dynamic>;
            final zone  = d['zone'] as String? ?? 'Inconnu';
            final count = d['noDriverFoundCount'] as int? ?? 0;
            final svc   = d['serviceType'] as String? ?? '';
            final date  = d['date'] as String? ?? '';
            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFF0F0F0)),
              ),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: Colors.deepOrange.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.location_on_rounded,
                      color: Colors.deepOrange, size: 16),
                ),
                const SizedBox(width: 10),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(zone,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    if (svc.isNotEmpty || date.isNotEmpty)
                      Text('$svc · $date',
                          style: const TextStyle(
                              fontSize: 10, color: Color(0xFF9E9E9E))),
                  ],
                )),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.deepOrange.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('$count annulation${count > 1 ? 's' : ''}',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.deepOrange)),
                ),
              ]),
            );
          }).toList(),
        );
      },
    );
  }
}

// ── Empty State Card ──────────────────────────────────────────────────────────
class _EmptyCard extends StatelessWidget {
  final IconData icon;
  final String message;
  final Color color;
  const _EmptyCard({required this.icon, required this.message, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEEEEEE)),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Text(message, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
