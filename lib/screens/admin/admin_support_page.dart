import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../widgets/empty_state.dart';
import '../../constants/support_categories.dart';

/// Support client + signalements — première visibilité admin sur
/// `support_tickets`/`marketplace_reports`, jusqu'ici lus par aucun écran
/// admin (gap documenté depuis le Prompt 13, confirmé de nouveau aux
/// Prompts 72/74/76). Deux onglets, chacun réutilisant des mécanismes déjà
/// existants côté règles Firestore : `support_tickets` autorisait déjà
/// l'admin en écriture libre (statut + messages), `marketplace_reports`
/// aussi (Master Prompt 78, 2026-07-09).
class AdminSupportPage extends StatefulWidget {
  const AdminSupportPage({super.key});

  @override
  State<AdminSupportPage> createState() => _AdminSupportPageState();
}

class _AdminSupportPageState extends State<AdminSupportPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Support & Signalements'),
        backgroundColor: const Color(0xFF00695C),
        foregroundColor: Colors.white,
        centerTitle: true,
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(text: 'Tickets support'),
            Tab(text: 'Signalements produits'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: const [_TicketsTab(), _ReportsTab()],
      ),
    );
  }
}

// ── Onglet 1 : support_tickets ──────────────────────────────────────────────

class _TicketsTab extends StatelessWidget {
  const _TicketsTab();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('support_tickets')
          .orderBy('createdAt', descending: true)
          .limit(100)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return const Center(
              child: Text('Impossible de charger les tickets.'));
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const EmptyState(
            icon: Icons.support_agent_rounded,
            title: 'Aucun ticket',
            description:
                'Les demandes de support des clients apparaîtront ici.',
          );
        }
        // Ouverts/en cours d'abord, fermés/résolus en bas — tri client-side,
        // volume attendu faible en pilote (pas de nouvel index nécessaire).
        final sorted = [...docs]..sort((a, b) {
            const order = {
              'open': 0,
              'in_progress': 1,
              'resolved': 2,
              'closed': 3
            };
            final sa = order[(a.data() as Map)['status']] ?? 0;
            final sb = order[(b.data() as Map)['status']] ?? 0;
            return sa.compareTo(sb);
          });
        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(16),
          itemCount: sorted.length,
          itemBuilder: (context, i) => _TicketAdminCard(doc: sorted[i]),
        );
      },
    );
  }
}

class _TicketAdminCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _TicketAdminCard({required this.doc});

  static const _statusLabels = {
    'open': 'Ouvert',
    'in_progress': 'En cours',
    'resolved': 'Résolu',
    'closed': 'Fermé',
  };
  static const _statusColors = {
    'open': Colors.orange,
    'in_progress': Colors.blue,
    'resolved': Colors.green,
    'closed': Colors.grey,
  };

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final status = data['status'] as String? ?? 'open';
    final color = _statusColors[status] ?? Colors.grey;
    final category = data['category'] as String? ?? '';
    final isApplicationFeedback =
        category == SupportCategories.applicationFeedback;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 6),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(data['subject'] as String? ?? 'Sans sujet',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8)),
              child: Text(_statusLabels[status] ?? status,
                  style: TextStyle(
                      color: color, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ]),
          const SizedBox(height: 4),
          AdminTicketCategoryBadge(
              category: category, isApplicationFeedback: isApplicationFeedback),
          const SizedBox(height: 6),
          Text(data['message'] as String? ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          _AdminTicketDetailScreen(ticketId: doc.id))),
              child: const Text('Ouvrir'),
            ),
          ),
        ],
      ),
    );
  }
}

class AdminTicketCategoryBadge extends StatelessWidget {
  const AdminTicketCategoryBadge({
    super.key,
    required this.category,
    this.isApplicationFeedback = false,
  });

  final String category;
  final bool isApplicationFeedback;

  @override
  Widget build(BuildContext context) => Container(
        key: isApplicationFeedback
            ? const Key('admin-application-feedback-category')
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isApplicationFeedback
              ? Colors.deepPurple.withValues(alpha: 0.12)
              : Colors.grey.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          category,
          style: TextStyle(
            color: isApplicationFeedback
                ? Colors.deepPurple
                : Colors.grey.shade600,
            fontSize: 12,
            fontWeight:
                isApplicationFeedback ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      );
}

class _AdminTicketDetailScreen extends StatefulWidget {
  final String ticketId;
  const _AdminTicketDetailScreen({required this.ticketId});

  @override
  State<_AdminTicketDetailScreen> createState() =>
      _AdminTicketDetailScreenState();
}

class _AdminTicketDetailScreenState extends State<_AdminTicketDetailScreen> {
  final _replyCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _replyCtrl.dispose();
    super.dispose();
  }

  DocumentReference get _ref => FirebaseFirestore.instance
      .collection('support_tickets')
      .doc(widget.ticketId);

  Future<void> _sendReply() async {
    final text = _replyCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      final snap = await _ref.get();
      final messages = List<Map<String, dynamic>>.from(
          (snap.data() as Map?)?['messages'] as List? ?? []);
      messages.add({
        'sender': 'admin',
        'text': text,
        'timestamp': DateTime.now().toIso8601String(),
      });
      await _ref.update({
        'messages': messages,
        if (((snap.data() as Map?)?['status']) == 'open')
          'status': 'in_progress',
      });
      if (!mounted) return;
      setState(() {
        _replyCtrl.clear();
        _sending = false;
      });
    } catch (_) {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _setStatus(String status) => _ref.update({'status': status});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Ticket'),
        backgroundColor: const Color(0xFF00695C),
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            onSelected: _setStatus,
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'in_progress', child: Text('Marquer en cours')),
              PopupMenuItem(value: 'resolved', child: Text('Marquer résolu')),
              PopupMenuItem(value: 'closed', child: Text('Fermer le ticket')),
            ],
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _ref.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(
                child: Text('Impossible de charger le ticket.'));
          }
          if (!snap.hasData || !snap.data!.exists) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data!.data() as Map<String, dynamic>;
          final messages = List<Map<String, dynamic>>.from(
              (data['messages'] as List?) ?? []);
          final screenshotUrl = data['screenshotUrl'] as String?;
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(data['subject'] as String? ?? '',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    Text('Client : ${data['userId'] ?? '—'}',
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 11)),
                    if (screenshotUrl != null) ...[
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: CachedNetworkImage(
                          imageUrl: screenshotUrl,
                          height: 160,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => const SizedBox(
                            height: 160,
                            child: Center(child: CircularProgressIndicator()),
                          ),
                          errorWidget: (_, __, ___) => const SizedBox(
                            height: 160,
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    ...messages.map((m) {
                      final isAdmin = m['sender'] == 'admin';
                      return Align(
                        alignment: isAdmin
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          constraints: const BoxConstraints(maxWidth: 280),
                          decoration: BoxDecoration(
                            color: isAdmin
                                ? const Color(0xFF00695C).withValues(alpha: 0.1)
                                : Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(isAdmin ? 'Vous (support)' : 'Client',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: isAdmin
                                          ? const Color(0xFF00695C)
                                          : Colors.grey.shade600)),
                              const SizedBox(height: 4),
                              Text(m['text'] as String? ?? ''),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              if (data['status'] != 'closed')
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _replyCtrl,
                            decoration: const InputDecoration(
                              hintText: 'Répondre au client…',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: _sending ? null : _sendReply,
                          icon: _sending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send_rounded,
                                  color: Color(0xFF00695C)),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ── Onglet 2 : marketplace_reports (signalements produits) ─────────────────

class _ReportsTab extends StatelessWidget {
  const _ReportsTab();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      // limit() par prudence (Master Prompt 79, 2026-07-09) — même
      // raisonnement que admin_cash_settlement_page.dart.
      stream: FirebaseFirestore.instance
          .collection('marketplace_reports')
          .where('status', isEqualTo: 'pending')
          .limit(100)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return const Center(
              child: Text('Impossible de charger les signalements.'));
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const EmptyState(
            icon: Icons.flag_outlined,
            title: 'Aucun signalement en attente',
            description:
                'Les produits signalés par les utilisateurs apparaîtront ici.',
          );
        }
        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final doc = docs[i];
            final data = doc.data() as Map<String, dynamic>;
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.red.shade100),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Produit : ${data['productId'] ?? '—'}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text('Raison : ${data['reason'] ?? '—'}',
                      style:
                          TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () =>
                            doc.reference.update({'status': 'dismissed'}),
                        child: const Text('Ignorer'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red)),
                        onPressed: () =>
                            doc.reference.update({'status': 'reviewed'}),
                        child: const Text('Traité'),
                      ),
                    ),
                  ]),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
