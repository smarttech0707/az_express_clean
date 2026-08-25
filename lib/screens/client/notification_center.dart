import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../services/notification_service.dart';
import '../../theme/app_theme.dart';

/// Centre de notifications premium — historique complet des push reçus.
class NotificationCenterScreen extends StatelessWidget {
  const NotificationCenterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text('Non connecté')));
    }
    return _NotificationCenterContent(uid: uid);
  }
}

class _NotificationCenterContent extends StatelessWidget {
  final String uid;
  const _NotificationCenterContent({required this.uid});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F8),
      appBar: _buildAppBar(context),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: NotificationService.streamNotifications(uid),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            );
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) return _buildEmpty();
          // Marquer comme lus en arrière-plan
          WidgetsBinding.instance.addPostFrameCallback((_) {
            NotificationService.markAllRead(uid);
          });
          return _buildList(context, docs);
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(64),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFFF8C42), AppColors.primary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
                color: Color(0x29FF6B00), blurRadius: 12, offset: Offset(0, 4)),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Notifications',
                  style: GoogleFonts.urbanist(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => NotificationService.markAllRead(uid),
                icon: const Icon(Icons.done_all_rounded,
                    color: Colors.white70, size: 18),
                label: Text(
                  'Tout lire',
                  style: GoogleFonts.urbanist(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context,
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    // Regrouper par date
    final Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>
        groups = {};
    for (final doc in docs) {
      final key = _dateKey(doc.data()['createdAt']);
      groups.putIfAbsent(key, () => []).add(doc);
    }

    final sections = groups.entries.toList();
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      itemCount: sections.length,
      itemBuilder: (context, i) {
        final section = sections[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(label: section.key),
            ...section.value.map((doc) => _NotifCard(
                  uid: uid,
                  doc: doc,
                )),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  String _dateKey(dynamic createdAt) {
    if (createdAt is! Timestamp) return 'Récent';
    final d = createdAt.toDate();
    final now = DateTime.now();
    final diff = now.difference(d).inDays;
    if (diff == 0) return 'Aujourd\'hui';
    if (diff == 1) return 'Hier';
    if (diff < 7) return DateFormat('EEEE', 'fr').format(d).capitalize();
    return DateFormat('d MMMM', 'fr').format(d);
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.08),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.notifications_none_rounded,
            size: 46,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Aucune notification',
          style: GoogleFonts.urbanist(
              fontSize: 17, fontWeight: FontWeight.w600, color: Colors.black87),
        ),
        const SizedBox(height: 6),
        Text(
          'Vos mises à jour de commandes\napparaîtront ici.',
          textAlign: TextAlign.center,
          style:
              GoogleFonts.urbanist(fontSize: 13.5, color: AppColors.textMuted),
        ),
      ]),
    );
  }
}

// ── Section header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        label,
        style: GoogleFonts.urbanist(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppColors.textMuted,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

// ── Carte notification ────────────────────────────────────────────────────────

class _NotifCard extends StatelessWidget {
  final String uid;
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;

  const _NotifCard({required this.uid, required this.doc});

  @override
  Widget build(BuildContext context) {
    final data = doc.data();
    final isRead = data['isRead'] as bool? ?? true;
    final type = data['type'] as String? ?? '';
    final title = data['title'] as String? ?? '';
    final body = data['body'] as String? ?? '';
    final ts = data['createdAt'];
    final timeStr = ts is Timestamp ? _timeAgo(ts.toDate()) : '';

    return Dismissible(
      key: Key(doc.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Icon(Icons.delete_rounded, color: Colors.white, size: 24),
      ),
      onDismissed: (_) => NotificationService.deleteNotification(uid, doc.id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isRead
                ? Colors.transparent
                : AppColors.primary.withValues(alpha: 0.25),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isRead ? 0.04 : 0.08),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () {
              final orderId = data['orderId'] as String?;
              final status = data['status'] as String?;
              NotificationService.triggerTap(type, orderId, status);
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Icône colorée
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _colorFor(type).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(_iconFor(type), color: _colorFor(type), size: 22),
                ),
                const SizedBox(width: 12),
                // Contenu
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(
                            title,
                            style: GoogleFonts.urbanist(
                              fontWeight:
                                  isRead ? FontWeight.w500 : FontWeight.w700,
                              fontSize: 13.5,
                              color: Colors.black87,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Point non-lu
                        if (!isRead) ...[
                          const SizedBox(width: 6),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 3),
                      Text(
                        body,
                        style: GoogleFonts.urbanist(
                          fontSize: 12.5,
                          color: AppColors.textMuted,
                          height: 1.35,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        timeStr,
                        style: GoogleFonts.urbanist(
                          fontSize: 11,
                          color: AppColors.textMuted.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'À l\'instant';
    if (diff.inMinutes < 60) return 'Il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'Il y a ${diff.inHours} h';
    return DateFormat('d MMM HH:mm', 'fr').format(dt);
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'order_confirmed':
        return Icons.check_circle_rounded;
      case 'driver_found':
        return Icons.two_wheeler_rounded;
      case 'order_update':
        return Icons.local_shipping_rounded;
      case 'mission_end':
        return Icons.task_alt_rounded;
      case 'order_cancelled':
        return Icons.cancel_rounded;
      case 'new_order':
        return Icons.delivery_dining_rounded;
      case 'low_balance':
        return Icons.account_balance_wallet_rounded;
      case 'recharge':
        return Icons.account_balance_wallet_rounded;
      case 'ek_new_order':
        return Icons.account_balance_rounded;
      case 'ek_update':
        return Icons.update_rounded;
      case 'admin_new_driver':
        return Icons.person_add_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  Color _colorFor(String type) {
    switch (type) {
      case 'order_confirmed':
      case 'driver_found':
        return const Color(0xFF2E7D32);
      case 'order_update':
        return const Color(0xFF1565C0);
      case 'mission_end':
        return const Color(0xFF00695C);
      case 'order_cancelled':
        return Colors.red;
      case 'low_balance':
        return Colors.red;
      case 'recharge':
        return const Color(0xFF00695C);
      case 'ek_new_order':
      case 'ek_update':
        return const Color(0xFF4A148C);
      default:
        return AppColors.primary;
    }
  }
}

// ── Extension String capitalize ──────────────────────────────────────────────
extension _StringCapitalize on String {
  String capitalize() =>
      isEmpty ? this : '${this[0].toUpperCase()}${substring(1)}';
}
