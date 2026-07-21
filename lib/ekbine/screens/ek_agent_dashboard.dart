import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../ek_constants.dart';
import '../models/ek_order.dart';
import '../models/ek_agent.dart';
import '../services/ek_service.dart';
import '../providers/ek_provider.dart';
import 'ek_order_tracking.dart';
import '../../services/subscription_service.dart';
import '../../services/auth_service.dart';
import '../../screens/home/home_screen.dart';
import '../../widgets/partner_account_sheet.dart';
import '../../widgets/stream_error_state.dart';
import '../../widgets/logout_confirm_dialog.dart';

class EkAgentDashboard extends StatefulWidget {
  const EkAgentDashboard({super.key});

  @override
  State<EkAgentDashboard> createState() => _EkAgentDashboardState();
}

class _EkAgentDashboardState extends State<EkAgentDashboard>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      SubscriptionService.checkAndRenew(
          'ekbine_agents', uid,
          customAmount: SubscriptionService.ekbineAgentAmount,
          walletKey: 'walletBalance');
    }
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<EkProvider>(builder: (_, ek, __) {
      final agent = ek.myAgent;
      if (agent == null) {
        return Scaffold(
          appBar: AppBar(backgroundColor: kEkDark, foregroundColor: Colors.white,
              title: const Text('Dashboard Agent')),
          body: const Center(child: CircularProgressIndicator()),
        );
      }

      // Bloc si non approuvé
      if (!agent.isVerified) {
        return Scaffold(
          backgroundColor: kEkBg,
          appBar: AppBar(
            backgroundColor: kEkDark,
            foregroundColor: Colors.white,
            title: const Text('Dashboard Agent'),
            actions: [
              IconButton(
                icon: const Icon(Icons.logout_rounded),
                tooltip: 'Déconnexion',
                onPressed: _logout,
              ),
            ],
          ),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF8E1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(Icons.hourglass_top_rounded,
                      size: 64, color: Color(0xFFF57F17)),
                ),
                const SizedBox(height: 24),
                Text('Candidature en cours d\'examen',
                    style: GoogleFonts.urbanist(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: kEkText),
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(
                  'Notre équipe vérifie votre profil. '
                  'Vous serez notifié dès que votre compte est activé (24–48h).',
                  style: GoogleFonts.urbanist(
                      fontSize: 13, color: kEkMuted, height: 1.6),
                  textAlign: TextAlign.center,
                ),
              ]),
            ),
          ),
        );
      }

      return Scaffold(
        backgroundColor: kEkBg,
        body: NestedScrollView(
          headerSliverBuilder: (_, __) => [
            _buildHeader(agent, ek),
          ],
          body: TabBarView(
            controller: _tabCtrl,
            children: [
              _PendingTab(agent: agent),
              _ActiveTab(agentId: agent.id),
              _AgentHistoryTab(agentId: agent.id),
            ],
          ),
        ),
      );
    });
  }

  // Master Prompt 135 — _logout() affiche désormais une confirmation avant
  // d'appeler _doLogout(), qui porte l'intégralité de la logique déjà
  // existante et inchangée (signOut, redirection).
  void _logout() => showLogoutConfirmDialog(context, onConfirm: _doLogout);

  Future<void> _doLogout() async {
    AuthService().logAuthEvent('logout', 'ekbine_agent');
    await FirebaseAuth.instance.signOut();
    try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  Widget _buildHeader(EkAgent agent, EkProvider ek) {
    return SliverAppBar(
      pinned: true,
      expandedHeight: 200,
      backgroundColor: kEkDark,
      foregroundColor: Colors.white,
      actions: [
        IconButton(
          icon: const Icon(Icons.account_circle_outlined),
          tooltip: 'Mon compte',
          onPressed: () => showPartnerAccountSheet(
            context,
            role: 'ekbine_agent',
            roleLabel: 'Agent Ekbine',
            name: agent.name,
            phone: agent.phone,
            onLogout: _logout,
            photoUrl: agent.photoUrl,
            photoStoragePath: 'ekbine_agent_photos/${agent.id}/photo.jpg',
            onPhotoUploaded: (url) =>
                EkService.updateAgentProfile(agent.id, {'photoUrl': url}),
          ),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.pin,
        background: Container(
          color: kEkDark,
          padding: const EdgeInsets.fromLTRB(20, 80, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: kEkGreen,
                  child: Text(
                    agent.name.isNotEmpty ? agent.name[0].toUpperCase() : 'A',
                    style: GoogleFonts.urbanist(
                        fontSize: 22, fontWeight: FontWeight.w800,
                        color: Colors.white),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(agent.name,
                        style: GoogleFonts.urbanist(
                            fontSize: 16, fontWeight: FontWeight.w800,
                            color: Colors.white)),
                    Row(children: [
                      const Icon(Icons.star_rounded,
                          color: Color(0xFFFFBB00), size: 14),
                      const SizedBox(width: 4),
                      Text(agent.displayRating,
                          style: GoogleFonts.urbanist(
                              fontSize: 12, color: Colors.white70)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text('${agent.totalCompleted} commandes',
                            style: GoogleFonts.urbanist(
                                fontSize: 12, color: Colors.white70),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ]),
                  ]),
                ),
                // Online toggle
                Column(children: [
                  Switch(
                    value: agent.isOnline,
                    onChanged: (_) => ek.toggleAgentOnline(),
                    activeThumbColor: kEkGreen,
                    activeTrackColor: kEkGreen.withValues(alpha: 0.4),
                  ),
                  Text(agent.isOnline ? 'En ligne' : 'Hors ligne',
                      style: GoogleFonts.urbanist(
                          fontSize: 9,
                          color: agent.isOnline ? kEkGreen : Colors.white38)),
                ]),
              ]),
              const SizedBox(height: 12),
              // Wallet + stats row
              Row(children: [
                _StatChip(
                  label: 'Wallet',
                  value: _fmt(agent.walletBalance),
                  color: kEkGreen,
                ),
                const SizedBox(width: 8),
                _StatChip(
                  label: 'Complétés',
                  value: agent.totalCompleted.toString(),
                  color: const Color(0xFF2196F3),
                ),
                const SizedBox(width: 8),
                _StatChip(
                  label: 'Note',
                  value: agent.ratingCount == 0 ? '-' : agent.rating.toStringAsFixed(1),
                  color: const Color(0xFFFFBB00),
                ),
              ]),
            ],
          ),
        ),
      ),
      bottom: TabBar(
        controller: _tabCtrl,
        labelColor: kEkGreen,
        unselectedLabelColor: Colors.white60,
        indicatorColor: kEkGreen,
        indicatorWeight: 3,
        labelStyle: GoogleFonts.urbanist(
            fontSize: 12, fontWeight: FontWeight.w700),
        tabs: const [
          Tab(text: 'Nouvelles'),
          Tab(text: 'En cours'),
          Tab(text: 'Historique'),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(children: [
          Text(value,
              style: GoogleFonts.urbanist(
                  fontSize: 14, fontWeight: FontWeight.w800, color: color)),
          Text(label,
              style: GoogleFonts.urbanist(fontSize: 11, color: Colors.white70)),
        ]),
      ),
    );
  }
}

// ── Tab: Pending orders ────────────────────────────────────────────────────────
class _PendingTab extends StatelessWidget {
  final EkAgent agent;

  const _PendingTab({required this.agent});

  @override
  Widget build(BuildContext context) {
    if (!agent.isOnline) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text('💤', style: TextStyle(fontSize: 52)),
          const SizedBox(height: 16),
          Text('Vous êtes hors ligne',
              style: GoogleFonts.urbanist(
                  fontSize: 16, fontWeight: FontWeight.w700, color: kEkText)),
          const SizedBox(height: 8),
          Text('Activez votre statut pour voir les nouvelles commandes',
              style: GoogleFonts.urbanist(
                  fontSize: 13, color: kEkMuted, height: 1.5),
              textAlign: TextAlign.center),
        ]),
      );
    }

    return StreamBuilder<List<EkOrder>>(
      stream: EkService.streamPendingForAgent(agent.operators),
      builder: (context, snap) {
        if (snap.hasError) {
          return const StreamErrorState(message: "Impossible de charger les demandes en attente.");
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final orders = snap.data!;
        if (orders.isEmpty) {
          return Center(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('🔍', style: TextStyle(fontSize: 52)),
              const SizedBox(height: 16),
              Text('Aucune nouvelle commande',
                  style: GoogleFonts.urbanist(
                      fontSize: 16, fontWeight: FontWeight.w700,
                      color: kEkText)),
              const SizedBox(height: 8),
              Text('Restez connecté, les commandes arrivent !',
                  style: GoogleFonts.urbanist(fontSize: 13, color: kEkMuted)),
            ]),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: orders.length,
          itemBuilder: (_, i) => _PendingOrderCard(
            order: orders[i],
            agent: agent,
          ),
        );
      },
    );
  }
}

class _PendingOrderCard extends StatefulWidget {
  final EkOrder order;
  final EkAgent agent;

  const _PendingOrderCard({required this.order, required this.agent});

  @override
  State<_PendingOrderCard> createState() => _PendingOrderCardState();
}

class _PendingOrderCardState extends State<_PendingOrderCard> {
  bool _accepting = false;

  @override
  Widget build(BuildContext context) {
    final order    = widget.order;
    final opColor  = EkService.operatorColor(order.operator);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kEkDivider),
        boxShadow: const [
          BoxShadow(color: Color(0x08000000), blurRadius: 8,
              offset: Offset(0, 3))
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: opColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(order.operator[0].toUpperCase(),
                  style: GoogleFonts.urbanist(
                      fontSize: 18, fontWeight: FontWeight.w900,
                      color: opColor)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(order.serviceLabel,
                  style: GoogleFonts.urbanist(
                      fontSize: 14, fontWeight: FontWeight.w700,
                      color: kEkText)),
              Text('Pour : ${order.beneficiaryNumber}',
                  style: GoogleFonts.urbanist(fontSize: 12, color: kEkMuted)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_fmt(order.amount),
                style: GoogleFonts.urbanist(
                    fontSize: 15, fontWeight: FontWeight.w800, color: kEkText)),
            Text(
              order.agentEarning > 0
                  ? '+${_fmt(order.agentEarning)}'
                  : 'Paiement direct',
              style: GoogleFonts.urbanist(
                  fontSize: 11, fontWeight: FontWeight.w700,
                  color: order.agentEarning > 0 ? kEkGreen : kEkMuted),
            ),
          ]),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => EkOrderTracking(order: order))),
              style: OutlinedButton.styleFrom(
                foregroundColor: kEkMuted,
                side: const BorderSide(color: kEkDivider),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text('Voir détails',
                  style: GoogleFonts.urbanist(fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ScaleButton(
              onPressed: _accepting ? null : _accept,
              style: ElevatedButton.styleFrom(
                backgroundColor: kEkGreen,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                elevation: 0,
              ),
              child: _accepting
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : Text(
                      order.agentEarning > 0
                          ? 'Accepter +${_fmt(order.agentEarning)}'
                          : 'Accepter',
                      style: GoogleFonts.urbanist(
                          fontSize: 12, fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
      ]),
    );
  }

  Future<void> _accept() async {
    setState(() => _accepting = true);
    try {
      await EkService.agentAcceptOrder(
          widget.order.id, widget.agent,
          widget.order.paymentMethod, widget.order.operator);
      if (mounted) {
        Navigator.push(context, MaterialPageRoute(
            builder: (_) => EkOrderTracking(order: widget.order)));
      }
    } catch (_) {
      if (mounted) setState(() => _accepting = false);
    }
  }
}

// ── Tab: Active orders ─────────────────────────────────────────────────────────
class _ActiveTab extends StatelessWidget {
  final String agentId;

  const _ActiveTab({required this.agentId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<EkOrder>>(
      stream: EkService.streamAgentActiveOrders(agentId),
      builder: (context, snap) {
        if (snap.hasError) {
          return const StreamErrorState(message: "Impossible de charger les courses actives.");
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final orders = snap.data!;
        if (orders.isEmpty) {
          return Center(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('✅', style: TextStyle(fontSize: 52)),
              const SizedBox(height: 16),
              Text('Aucune commande en cours',
                  style: GoogleFonts.urbanist(
                      fontSize: 16, fontWeight: FontWeight.w700,
                      color: kEkText)),
            ]),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: orders.length,
          itemBuilder: (_, i) => _ActiveOrderAgentCard(order: orders[i]),
        );
      },
    );
  }
}

class _ActiveOrderAgentCard extends StatefulWidget {
  final EkOrder order;
  const _ActiveOrderAgentCard({required this.order});

  @override
  State<_ActiveOrderAgentCard> createState() => _ActiveOrderAgentCardState();
}

class _ActiveOrderAgentCardState extends State<_ActiveOrderAgentCard> {
  bool _uploading  = false;
  bool _starting   = false;
  bool _verifying  = false;

  @override
  Widget build(BuildContext context) {
    final order     = widget.order;
    final opColor   = EkService.operatorColor(order.operator);
    final statusCol = ekStatusColor(order.status);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusCol.withValues(alpha: 0.3)),
        boxShadow: const [
          BoxShadow(color: Color(0x08000000), blurRadius: 8,
              offset: Offset(0, 3))
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: opColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(order.operator[0].toUpperCase(),
                  style: GoogleFonts.urbanist(
                      fontSize: 18, fontWeight: FontWeight.w900,
                      color: opColor)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(order.serviceLabel,
                  style: GoogleFonts.urbanist(
                      fontSize: 14, fontWeight: FontWeight.w700,
                      color: kEkText)),
              Text(order.beneficiaryNumber,
                  style: GoogleFonts.urbanist(fontSize: 12, color: kEkMuted)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_fmt(order.amount),
                style: GoogleFonts.urbanist(
                    fontSize: 14, fontWeight: FontWeight.w800,
                    color: kEkText)),
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusCol.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                ekStatusLabels[order.status] ?? order.status,
                style: GoogleFonts.urbanist(
                    fontSize: 9, fontWeight: FontWeight.w700,
                    color: statusCol),
              ),
            ),
          ]),
        ]),
        const SizedBox(height: 12),
        // Deposit proof section (non-wallet orders)
        if (order.status == 'awaiting_deposit') ...[
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: const Color(0xFFE65100).withValues(alpha: 0.4)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(
                order.depositProofUrl == null
                    ? 'En attente de la preuve de paiement du client…'
                    : 'Preuve reçue — vérifiez avant de commencer.',
                style: GoogleFonts.urbanist(
                    fontSize: 12, color: const Color(0xFFE65100), height: 1.4),
              ),
              if (order.depositProofUrl != null) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => _viewDepositProof(order.depositProofUrl!),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      order.depositProofUrl!,
                      height: 120, width: double.infinity,
                      fit: BoxFit.cover,
                      loadingBuilder: (_, child, prog) =>
                          prog == null ? child : Container(
                              height: 120, color: kEkDivider,
                              child: const Center(
                                  child: CircularProgressIndicator())),
                      errorBuilder: (_, __, ___) =>
                          Container(height: 120, color: kEkDivider,
                              child: const Icon(Icons.broken_image,
                                  color: kEkMuted)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity, height: 42,
                  child: ElevatedButton.icon(
                    onPressed: _verifying ? null : _verifyDeposit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF9C27B0),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                    icon: _verifying
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.verified_rounded, size: 16),
                    label: Text('Dépôt reçu — Commencer',
                        style: GoogleFonts.urbanist(
                            fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ]),
          ),
        ],
        Row(children: [
          if (order.status == 'assigned')
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _starting ? null : _start,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9C27B0),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                icon: _starting
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.play_arrow_rounded, size: 18),
                label: Text('Commencer',
                    style: GoogleFonts.urbanist(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
          if (order.status == 'in_progress') ...[
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _uploading ? null : () => _uploadProof(order),
                style: ElevatedButton.styleFrom(
                  backgroundColor: kEkGreen,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                icon: _uploading
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.upload_rounded, size: 18),
                label: Text(_uploading ? 'Upload...' : 'Envoyer preuve',
                    style: GoogleFonts.urbanist(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
          if (order.status == 'proof_sent')
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF00BCD4).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF00BCD4)),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                  const Icon(Icons.hourglass_top_rounded,
                      color: Color(0xFF00BCD4), size: 16),
                  const SizedBox(width: 8),
                  Text('En attente de confirmation',
                      style: GoogleFonts.urbanist(
                          fontSize: 12, fontWeight: FontWeight.w700,
                          color: const Color(0xFF00BCD4))),
                ]),
              ),
            ),
        ]),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => EkOrderTracking(order: order))),
          child: Text('Voir les détails →',
              style: GoogleFonts.urbanist(
                  fontSize: 12, color: kEkGreen,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    await EkService.agentStartOrder(widget.order.id);
    if (mounted) setState(() => _starting = false);
  }

  Future<void> _verifyDeposit() async {
    setState(() => _verifying = true);
    await EkService.agentVerifyDeposit(widget.order.id);
    if (mounted) setState(() => _verifying = false);
  }

  void _viewDepositProof(String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(children: [
          InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)),
          Positioned(
            top: 40, right: 16,
            child: IconButton(
              onPressed: () => Navigator.pop(context),
              tooltip: 'Fermer',
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _uploadProof(EkOrder order) async {
    final picker = ImagePicker();
    final file   = await picker.pickImage(
        source: ImageSource.gallery, imageQuality: 80);
    if (file == null) return;

    setState(() => _uploading = true);
    try {
      final url = await EkService.uploadProof(file, order.id);
      await EkService.agentSendProof(order.id, url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Erreur upload: $e'),
                backgroundColor: Colors.red));
      }
    }
    if (mounted) setState(() => _uploading = false);
  }
}

// ── Tab: History ───────────────────────────────────────────────────────────────
class _AgentHistoryTab extends StatelessWidget {
  final String agentId;
  const _AgentHistoryTab({required this.agentId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<EkOrder>>(
      stream: EkService.streamAgentHistory(agentId),
      builder: (context, snap) {
        if (snap.hasError) {
          return const StreamErrorState(message: "Impossible de charger l'historique.");
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final orders = snap.data!;
        if (orders.isEmpty) {
          return Center(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('📋', style: TextStyle(fontSize: 52)),
              const SizedBox(height: 16),
              Text('Aucun historique',
                  style: GoogleFonts.urbanist(
                      fontSize: 16, fontWeight: FontWeight.w700,
                      color: kEkText)),
            ]),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: orders.length,
          itemBuilder: (_, i) {
            final o          = orders[i];
            final statusCol  = ekStatusColor(o.status);
            final opColor    = EkService.operatorColor(o.operator);
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kEkDivider),
              ),
              child: Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: opColor.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(o.operator[0].toUpperCase(),
                        style: GoogleFonts.urbanist(
                            fontSize: 15, fontWeight: FontWeight.w800,
                            color: opColor)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(o.serviceLabel,
                        style: GoogleFonts.urbanist(
                            fontSize: 13, fontWeight: FontWeight.w700,
                            color: kEkText)),
                    Text(o.beneficiaryNumber,
                        style: GoogleFonts.urbanist(
                            fontSize: 11, color: kEkMuted)),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(o.status == 'completed'
                      ? (o.agentEarning > 0 ? '+${_fmt(o.agentEarning)}' : _fmt(o.totalPaid))
                      : _fmt(o.totalPaid),
                      style: GoogleFonts.urbanist(
                          fontSize: 13, fontWeight: FontWeight.w800,
                          color: o.status == 'completed'
                              ? kEkGreen : kEkMuted)),
                  const SizedBox(height: 3),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusCol.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      ekStatusLabels[o.status] ?? o.status,
                      style: GoogleFonts.urbanist(
                          fontSize: 8, fontWeight: FontWeight.w700,
                          color: statusCol),
                    ),
                  ),
                ]),
              ]),
            );
          },
        );
      },
    );
  }
}

String _fmt(int price) {
  final s = price.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return '${buf.toString()} F';
}

