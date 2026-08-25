import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../web_theme.dart';
import '../../admin_auth_service.dart';
import '../../widgets/az_logo.dart';
import '../../../event/screens/admin_event_screen.dart';

class WebAdminDashboard extends StatefulWidget {
  const WebAdminDashboard({super.key});

  @override
  State<WebAdminDashboard> createState() => _WebAdminDashboardState();
}

class _WebAdminDashboardState extends State<WebAdminDashboard>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 6, vsync: this);
    // Vérifier auth au démarrage
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!AdminAuthService.instance.isAdmin) {
        context.go('/admin/login');
      }
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _logout() async {
    await AdminAuthService.instance.signOut();
    if (mounted) context.go('/admin/login');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kOrange,
        elevation: 0,
        leading: const Padding(
          padding: EdgeInsets.all(10),
          child: AzLogo(size: 32),
        ),
        title: Text('Administration AZ Express',
            style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
        actions: [
          TextButton.icon(
            onPressed: _logout,
            icon:
                const Icon(Icons.logout_rounded, color: Colors.white, size: 18),
            label: Text('Déconnexion',
                style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          labelStyle:
              GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700),
          unselectedLabelStyle:
              GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w400),
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white.withValues(alpha: 0.7),
          tabs: const [
            Tab(
                icon: Icon(Icons.delivery_dining_rounded, size: 18),
                text: 'Livreurs'),
            Tab(
                icon: Icon(Icons.storefront_rounded, size: 18),
                text: 'Commerçants'),
            Tab(icon: Icon(Icons.mail_rounded, size: 18), text: 'Messages'),
            Tab(icon: Icon(Icons.sos_rounded, size: 18), text: 'SOS'),
            Tab(
                icon: Icon(Icons.celebration_rounded, size: 18),
                text: 'Événementiel'),
            Tab(
                icon: Icon(Icons.lock_reset_rounded, size: 18),
                text: 'Réinitialisation'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Stats bar
          _StatsBar(),
          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [
                _ApplicationsList(
                    collection: 'driver_applications', type: 'driver'),
                _ApplicationsList(
                    collection: 'partner_applications', type: 'partner'),
                _ApplicationsList(
                    collection: 'contact_messages', type: 'message'),
                _SosList(),
                AdminEventScreen(),
                _PasswordResetList(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Stats bar ─────────────────────────────────────────────────────────────────
class _StatsBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: kCard,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: const Row(
        children: [
          _StatChip('driver_applications', 'Livreurs', kOrange),
          SizedBox(width: 12),
          _StatChip('partner_applications', 'Commerçants', kBlue),
          SizedBox(width: 12),
          _StatChip('contact_messages', 'Messages', kSuccess),
          SizedBox(width: 12),
          _StatChip('sos_alerts', 'SOS actifs', Colors.red, filter: 'active'),
          SizedBox(width: 12),
          _StatChip(
              'event_providers', 'Événementiel', Color(0xFF8E24AA),
              filter: 'pending'),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String collection;
  final String label;
  final Color color;
  final String filter;
  const _StatChip(this.collection, this.label, this.color,
      {this.filter = 'unread'});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(collection)
          .where('status', isEqualTo: filter)
          .snapshots(),
      builder: (_, snap) {
        final count = snap.data?.docs.length ?? 0;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: count > 0 ? color.withValues(alpha: 0.1) : kBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: count > 0 ? color.withValues(alpha: 0.3) : kDivider),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: count > 0 ? color : kTextMuted.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              child: Center(
                  child: Text('$count',
                      style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Colors.white))),
            ),
            const SizedBox(width: 8),
            Text(label,
                style: GoogleFonts.inter(
                    fontSize: 13,
                    color: count > 0 ? color : kTextMuted,
                    fontWeight: FontWeight.w600)),
          ]),
        );
      },
    );
  }
}

// ── Applications list ─────────────────────────────────────────────────────────
class _ApplicationsList extends StatelessWidget {
  final String collection;
  final String type;
  const _ApplicationsList({required this.collection, required this.type});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(collection)
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (_, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: kOrange));
        }
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return Center(
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.inbox_rounded,
                  size: 56, color: kTextMuted.withValues(alpha: 0.4)),
              const SizedBox(height: 12),
              Text('Aucune entrée pour le moment.',
                  style: GoogleFonts.inter(fontSize: 15, color: kTextMuted)),
            ]),
          );
        }
        final docs = snap.data!.docs;
        return ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: docs.length,
          itemBuilder: (_, i) => _EntryCard(
            doc: docs[i],
            collection: collection,
            type: type,
          ),
        );
      },
    );
  }
}

// ── Entry card ────────────────────────────────────────────────────────────────
class _EntryCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  final String collection;
  final String type;
  const _EntryCard(
      {required this.doc, required this.collection, required this.type});

  Future<void> _markAs(String status) async {
    await FirebaseFirestore.instance
        .collection(collection)
        .doc(doc.id)
        .update({'status': status});
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Confirmer',
            style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        content: Text('Supprimer définitivement cette entrée ?',
            style: GoogleFonts.inter()),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child:
                  const Text('Supprimer', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) {
      await FirebaseFirestore.instance
          .collection(collection)
          .doc(doc.id)
          .delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final status = data['status'] as String? ?? 'unread';
    final ts = data['createdAt'] as Timestamp?;
    final date = ts != null
        ? '${ts.toDate().day.toString().padLeft(2, '0')}/${ts.toDate().month.toString().padLeft(2, '0')}/${ts.toDate().year}  ${ts.toDate().hour.toString().padLeft(2, '0')}h${ts.toDate().minute.toString().padLeft(2, '0')}'
        : '—';

    Color statusColor;
    String statusLabel;
    switch (status) {
      case 'treated':
        statusColor = kSuccess;
        statusLabel = 'Traité';
        break;
      case 'in_progress':
        statusColor = kBlue;
        statusLabel = 'En cours';
        break;
      default:
        statusColor = kOrange;
        statusLabel = 'Nouveau';
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color:
                status == 'unread' ? kOrange.withValues(alpha: 0.3) : kDivider),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2))
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_typeIcon(), color: statusColor, size: 20),
          ),
          title: Text(
            data['name'] ?? data['fullName'] ?? 'Sans nom',
            style: GoogleFonts.inter(
                fontSize: 15, fontWeight: FontWeight.w600, color: kText),
          ),
          subtitle: Text(date,
              style: GoogleFonts.inter(fontSize: 12, color: kTextMuted)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(statusLabel,
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      color: statusColor,
                      fontWeight: FontWeight.w700)),
            ),
            const Icon(Icons.expand_more_rounded, color: kTextMuted),
          ]),
          children: [
            // Détails
            _detailRows(data),
            const SizedBox(height: 12),
            // Actions
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (status != 'treated')
                  _ActionBtn(
                    icon: Icons.check_circle_rounded,
                    label: 'Marquer traité',
                    color: kSuccess,
                    onTap: () => _markAs('treated'),
                  ),
                if (status == 'unread')
                  _ActionBtn(
                    icon: Icons.timelapse_rounded,
                    label: 'En cours',
                    color: kBlue,
                    onTap: () => _markAs('in_progress'),
                  ),
                if (_phone(data) != null)
                  _ActionBtn(
                    icon: Icons.chat_bubble_rounded,
                    label: 'WhatsApp',
                    color: const Color(0xFF25D366),
                    onTap: () => launchUrl(Uri.parse(
                        'https://wa.me/${_phone(data)!.replaceAll(RegExp(r'[^0-9]'), '')}')),
                  ),
                if (_email(data) != null)
                  _ActionBtn(
                    icon: Icons.email_rounded,
                    label: 'Email',
                    color: kOrange,
                    onTap: () => launchUrl(Uri.parse('mailto:${_email(data)}')),
                  ),
                _ActionBtn(
                  icon: Icons.delete_outline_rounded,
                  label: 'Supprimer',
                  color: Colors.red,
                  onTap: () => _delete(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _typeIcon() {
    switch (type) {
      case 'driver':
        return Icons.delivery_dining_rounded;
      case 'partner':
        return Icons.storefront_rounded;
      default:
        return Icons.mail_rounded;
    }
  }

  String? _phone(Map<String, dynamic> d) =>
      d['phone'] as String? ?? d['whatsapp'] as String?;

  String? _email(Map<String, dynamic> d) =>
      (d['email'] as String?)?.isNotEmpty == true ? d['email'] as String : null;

  Widget _detailRows(Map<String, dynamic> data) {
    final rows = <(String, String?)>[];
    void add(String k, String? v) {
      if (v != null && v.isNotEmpty) rows.add((k, v));
    }

    add('Téléphone', _phone(data));
    add('Email', _email(data));
    add('Ville', data['city'] as String?);
    add('Vehicule', data['vehicle'] as String?);
    add('Type', data['businessType'] as String?);
    add('Activité', data['activity'] as String?);
    add('Sujet', data['subject'] as String?);
    add('Message', data['message'] as String?);
    add('Description', data['description'] as String?);

    if (rows.isEmpty) {
      return Text('Aucun détail supplémentaire.',
          style: GoogleFonts.inter(fontSize: 13, color: kTextMuted));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows
          .map((r) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 100,
                        child: Text(r.$1,
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                color: kTextMuted,
                                fontWeight: FontWeight.w600)),
                      ),
                      Expanded(
                          child: Text(r.$2!,
                              style: GoogleFonts.inter(
                                  fontSize: 13, color: kText, height: 1.5))),
                    ]),
              ))
          .toList(),
    );
  }
}

// ── Password reset list ───────────────────────────────────────────────────────
class _PasswordResetList extends StatelessWidget {
  const _PasswordResetList();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('password_reset_requests')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (_, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: kOrange));
        }
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return Center(
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.lock_open_rounded,
                  size: 56, color: kTextMuted.withValues(alpha: 0.4)),
              const SizedBox(height: 12),
              Text('Aucune demande de réinitialisation.',
                  style: GoogleFonts.inter(fontSize: 15, color: kTextMuted)),
            ]),
          );
        }

        return Column(
          children: [
            // Bandeau d'instructions
            Container(
              margin: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF9C27B0).withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFF9C27B0).withValues(alpha: 0.2)),
              ),
              child: Row(children: [
                const Icon(Icons.info_outline_rounded,
                    color: Color(0xFF9C27B0), size: 20),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(
                  'Pour réinitialiser : allez sur Firebase Console → Authentication → trouvez l\'utilisateur par UID → "Reset password". Ensuite contactez l\'utilisateur sur WhatsApp avec son nouveau mot de passe.',
                  style: GoogleFonts.inter(
                      fontSize: 12, color: kTextMuted, height: 1.5),
                )),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(20),
                itemCount: snap.data!.docs.length,
                itemBuilder: (_, i) {
                  final doc = snap.data!.docs[i];
                  final data = doc.data() as Map<String, dynamic>;
                  final status = data['status'] as String? ?? 'unread';
                  final ts = data['createdAt'] as Timestamp?;
                  final date = ts != null
                      ? '${ts.toDate().day.toString().padLeft(2, '0')}/${ts.toDate().month.toString().padLeft(2, '0')}/${ts.toDate().year}'
                      : '—';

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: kCard,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: status == 'unread'
                              ? const Color(0xFF9C27B0).withValues(alpha: 0.3)
                              : kDivider),
                    ),
                    child: Row(children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFF9C27B0).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.lock_reset_rounded,
                            color: Color(0xFF9C27B0), size: 20),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                          child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(data['name'] ?? 'Client',
                              style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: kText)),
                          Text('📞 ${data['phone'] ?? '—'}  •  $date',
                              style: GoogleFonts.inter(
                                  fontSize: 12, color: kTextMuted)),
                          if (data['uid'] != null)
                            Text('UID: ${data['uid']}',
                                style: GoogleFonts.inter(
                                    fontSize: 10, color: kTextMuted)),
                        ],
                      )),
                      const SizedBox(width: 8),
                      Column(children: [
                        if (status != 'treated')
                          _ActionBtn(
                            icon: Icons.check_circle_rounded,
                            label: 'Traité',
                            color: kSuccess,
                            onTap: () => FirebaseFirestore.instance
                                .collection('password_reset_requests')
                                .doc(doc.id)
                                .update({'status': 'treated'}),
                          ),
                        const SizedBox(height: 6),
                        if (data['phone'] != null)
                          _ActionBtn(
                            icon: Icons.chat_bubble_rounded,
                            label: 'WhatsApp',
                            color: const Color(0xFF25D366),
                            onTap: () => launchUrl(Uri.parse(
                                'https://wa.me/${(data['phone'] as String).replaceAll(RegExp(r'[^0-9]'), '')}')),
                          ),
                      ]),
                    ]),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── SOS list ──────────────────────────────────────────────────────────────────
class _SosList extends StatelessWidget {
  const _SosList();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('sos_alerts')
          .orderBy('timestamp', descending: true)
          .snapshots(),
      builder: (_, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
              child: CircularProgressIndicator(color: Colors.red));
        }
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return Center(
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.sos_rounded,
                  size: 56, color: kTextMuted.withValues(alpha: 0.4)),
              const SizedBox(height: 12),
              Text('Aucune alerte SOS.',
                  style: GoogleFonts.inter(fontSize: 15, color: kTextMuted)),
            ]),
          );
        }
        final docs = snap.data!.docs;
        return ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: docs.length,
          itemBuilder: (_, i) => _SosCard(doc: docs[i]),
        );
      },
    );
  }
}

class _SosCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _SosCard({required this.doc});

  Future<void> _resolve() async {
    await FirebaseFirestore.instance
        .collection('sos_alerts')
        .doc(doc.id)
        .update({'status': 'resolved'});
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Confirmer',
            style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        content:
            Text('Supprimer cette alerte SOS ?', style: GoogleFonts.inter()),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child:
                  const Text('Supprimer', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) {
      await FirebaseFirestore.instance
          .collection('sos_alerts')
          .doc(doc.id)
          .delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final status = data['status'] as String? ?? 'active';
    final isActive = status == 'active';
    final name = data['clientName'] as String? ??
        data['driverName'] as String? ??
        'Inconnu';
    final type = data['type'] as String? ?? 'client';
    final lat = data['lat'] as num? ?? 0;
    final lng = data['lng'] as num? ?? 0;
    final hasGps = lat != 0 || lng != 0;
    final phone = data['phone'] as String?;
    final ts = data['timestamp'] as Timestamp?;
    final date = ts != null
        ? '${ts.toDate().day.toString().padLeft(2, '0')}/${ts.toDate().month.toString().padLeft(2, '0')}/${ts.toDate().year}  ${ts.toDate().hour.toString().padLeft(2, '0')}h${ts.toDate().minute.toString().padLeft(2, '0')}'
        : '—';

    final cardColor = isActive ? Colors.red : kSuccess;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: cardColor.withValues(alpha: isActive ? 0.4 : 0.2)),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: Colors.red.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                )
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: cardColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.sos_rounded, color: cardColor, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: kText)),
                Text('${type == 'driver' ? 'Livreur' : 'Client'}  •  $date',
                    style: GoogleFonts.inter(fontSize: 12, color: kTextMuted)),
              ],
            )),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: cardColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                isActive ? 'ACTIF' : 'Résolu',
                style: GoogleFonts.inter(
                    fontSize: 11,
                    color: cardColor,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5),
              ),
            ),
          ]),
          if (hasGps) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () =>
                  launchUrl(Uri.parse('https://maps.google.com/?q=$lat,$lng')),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF4285F4).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: const Color(0xFF4285F4).withValues(alpha: 0.2)),
                ),
                child: Row(children: [
                  const Icon(Icons.location_on_rounded,
                      color: Color(0xFF4285F4), size: 16),
                  const SizedBox(width: 8),
                  Text(
                    'GPS: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}  — Ouvrir Maps',
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFF4285F4),
                        fontWeight: FontWeight.w600),
                  ),
                ]),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (isActive)
              _ActionBtn(
                icon: Icons.check_circle_rounded,
                label: 'Résoudre',
                color: kSuccess,
                onTap: _resolve,
              ),
            if (phone != null)
              _ActionBtn(
                icon: Icons.chat_bubble_rounded,
                label: 'WhatsApp',
                color: const Color(0xFF25D366),
                onTap: () => launchUrl(Uri.parse(
                    'https://wa.me/${phone.replaceAll(RegExp(r'[^0-9]'), '')}')),
              ),
            _ActionBtn(
              icon: Icons.delete_outline_rounded,
              label: 'Supprimer',
              color: Colors.red,
              onTap: () => _delete(context),
            ),
          ]),
        ],
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionBtn(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 15),
          const SizedBox(width: 6),
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 12, color: color, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
