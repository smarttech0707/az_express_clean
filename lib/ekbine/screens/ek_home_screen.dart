import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../ek_constants.dart';
import '../providers/ek_provider.dart';
import '../models/ek_order.dart';
import '../services/ek_service.dart';
import 'ek_order_form.dart';
import 'ek_order_tracking.dart';
import 'ek_history_screen.dart';
import 'ek_agent_dashboard.dart';
import 'ek_agent_register.dart';
import '../../screens/auth/client_auth_page.dart';

class EkHomeScreen extends StatefulWidget {
  const EkHomeScreen({super.key});

  @override
  State<EkHomeScreen> createState() => _EkHomeScreenState();
}

class _EkHomeScreenState extends State<EkHomeScreen> {
  String? _clientWalletDisplay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<EkProvider>().init();
      _loadWallet();
    });
  }

  Future<void> _loadWallet() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('clients').doc(uid).get();
      final bal = (doc.data()?['wallet'] as num? ?? 0).toInt();
      if (mounted) setState(() => _clientWalletDisplay = _fmt(bal));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final isLoggedIn = user != null && !user.isAnonymous;

    return Scaffold(
      backgroundColor: kEkBg,
      body: CustomScrollView(
        slivers: [
          _buildAppBar(),
          SliverToBoxAdapter(child: _buildHeader(isLoggedIn)),
          SliverToBoxAdapter(child: _buildOperators()),
          SliverToBoxAdapter(child: _buildQuickActions()),
          SliverToBoxAdapter(child: _buildActiveOrders()),
          SliverToBoxAdapter(child: _buildAgentBanner(isLoggedIn)),
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }

  // ── AppBar ────────────────────────────────────────────────────────────────
  SliverAppBar _buildAppBar() {
    return SliverAppBar(
      pinned: true,
      backgroundColor: kEkDark,
      foregroundColor: Colors.white,
      elevation: 0,
      title: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: kEkGreen,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text('E',
              style: GoogleFonts.urbanist(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 18)),
        ),
        const SizedBox(width: 8),
        Text('E-Kbine Services',
            style: GoogleFonts.urbanist(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            )),
      ]),
      actions: [
        Consumer<EkProvider>(builder: (_, ek, __) {
          if (!ek.isAgent) return const SizedBox.shrink();
          return TextButton.icon(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const EkAgentDashboard())),
            icon: Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ek.myAgent?.isOnline == true
                    ? kEkGreen : Colors.grey,
              ),
            ),
            label: Text('Agent',
                style: GoogleFonts.urbanist(
                    color: Colors.white, fontWeight: FontWeight.w600)),
          );
        }),
        IconButton(
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const EkHistoryScreen())),
          tooltip: 'Historique',
          icon: const Icon(Icons.history_rounded, color: Colors.white),
        ),
      ],
    );
  }

  // ── Header wallet + greeting ───────────────────────────────────────────────
  Widget _buildHeader(bool isLoggedIn) {
    return Container(
      color: kEkDark,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Services Télécoms',
                  style: GoogleFonts.urbanist(
                      fontSize: 12, color: Colors.white60)),
              const SizedBox(height: 4),
              Text('Rapide · Fiable · Local',
                  style: GoogleFonts.urbanist(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  )),
            ],
          ),
        ),
        if (isLoggedIn && _clientWalletDisplay != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: kEkGreen.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: kEkGreen.withValues(alpha: 0.4)),
            ),
            child: Column(children: [
              Text('Wallet',
                  style: GoogleFonts.urbanist(
                      fontSize: 10, color: kEkGreen)),
              Text(_clientWalletDisplay!,
                  style: GoogleFonts.urbanist(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  )),
            ]),
          ),
      ]),
    );
  }

  // ── Operator cards ────────────────────────────────────────────────────────
  Widget _buildOperators() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Text('Choisir un opérateur',
              style: GoogleFonts.urbanist(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: kEkText)),
        ),
        SizedBox(
          height: 90,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: ekOperators.map((op) {
              final color = Color(op['color'] as int);
              final bg    = Color(op['bg'] as int);
              return GestureDetector(
                onTap: () => _goToOrderForm(op['id'] as String),
                child: Container(
                  width: 80,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: color.withValues(alpha: 0.3)),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.1),
                        blurRadius: 8, offset: const Offset(0, 3),
                      )
                    ],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.asset(
                          op['logo'] as String,
                          width: 42, height: 42, fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Text(
                            op['emoji'] as String,
                            style: const TextStyle(fontSize: 28),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(op['label'] as String,
                          style: GoogleFonts.urbanist(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: color,
                          )),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // ── Quick action buttons ──────────────────────────────────────────────────
  Widget _buildQuickActions() {
    final actions = [
      {'label': 'Crédit',    'icon': Icons.phone_rounded,           'color': 0xFFFF6600},
      {'label': 'Internet',  'icon': Icons.wifi_rounded,             'color': 0xFF005EB8},
      {'label': 'Mobile\nMoney', 'icon': Icons.account_balance_wallet_rounded, 'color': 0xFF00C853},
      {'label': 'Transfert', 'icon': Icons.swap_horiz_rounded,       'color': 0xFFFFBB00},
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 0),
      child: Row(
        children: actions.map((a) {
          final color = Color(a['color'] as int);
          return Expanded(
            child: GestureDetector(
              onTap: () => _goToOrderForm(null, serviceHint: a['label'] as String),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: kEkCard,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x0A000000),
                        blurRadius: 6,
                        offset: Offset(0, 2))
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(a['icon'] as IconData,
                          color: color, size: 20),
                    ),
                    const SizedBox(height: 6),
                    Text(a['label'] as String,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.urbanist(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: kEkText,
                          height: 1.2,
                        )),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Active orders ─────────────────────────────────────────────────────────
  Widget _buildActiveOrders() {
    return Consumer<EkProvider>(builder: (_, ek, __) {
      if (ek.activeOrders.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
            child: Row(children: [
              Container(
                width: 8, height: 8,
                decoration: const BoxDecoration(
                    color: kEkGreen, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text('Commandes en cours',
                  style: GoogleFonts.urbanist(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: kEkText)),
            ]),
          ),
          ...ek.activeOrders.map((o) => _ActiveOrderCard(order: o)),
        ],
      );
    });
  }

  // ── Agent banner ──────────────────────────────────────────────────────────
  Widget _buildAgentBanner(bool isLoggedIn) {
    return Consumer<EkProvider>(builder: (_, ek, __) {
      if (ek.isAgent) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 24, 12, 0),
        child: GestureDetector(
          onTap: () {
            if (!isLoggedIn) {
              Navigator.push(context, MaterialPageRoute(
                  builder: (_) => const ClientAuthPage()));
              return;
            }
            Navigator.push(context,
                MaterialPageRoute(builder: (_) => const EkAgentRegister()));
          },
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF00C853), Color(0xFF00BFA5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Devenez Agent E-Kbine',
                        style: GoogleFonts.urbanist(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        )),
                    const SizedBox(height: 4),
                    Text('Gagnez de l\'argent en aidant votre communauté',
                        style: GoogleFonts.urbanist(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 12,
                          height: 1.4,
                        )),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('S\'inscrire maintenant',
                          style: GoogleFonts.urbanist(
                            color: kEkGreen,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          )),
                    ),
                  ],
                ),
              ),
              const Text('👤', style: TextStyle(fontSize: 48)),
            ]),
          ),
        ),
      );
    });
  }

  void _goToOrderForm(String? operatorId, {String? serviceHint}) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.isAnonymous) {
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const ClientAuthPage()));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EkOrderForm(
          preselectedOperator: operatorId,
          serviceHint: serviceHint,
        ),
      ),
    ).then((_) => _loadWallet());
  }
}

// ── Active order card ──────────────────────────────────────────────────────────
class _ActiveOrderCard extends StatelessWidget {
  final EkOrder order;
  const _ActiveOrderCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final statusColor = ekStatusColor(order.status);
    final opColor     = EkService.operatorColor(order.operator);

    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => EkOrderTracking(order: order))),
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kEkCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: statusColor.withValues(alpha: 0.3)),
          boxShadow: const [
            BoxShadow(color: Color(0x08000000), blurRadius: 6,
                offset: Offset(0, 2))
          ],
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: opColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                order.operator[0].toUpperCase(),
                style: GoogleFonts.urbanist(
                    color: opColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(order.serviceLabel,
                    style: GoogleFonts.urbanist(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: kEkText)),
                Text(order.beneficiaryNumber,
                    style: GoogleFonts.urbanist(
                        fontSize: 12, color: kEkMuted)),
              ],
            ),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_fmt(order.totalPaid),
                style: GoogleFonts.urbanist(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: kEkGreen)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                ekStatusLabels[order.status] ?? order.status,
                style: GoogleFonts.urbanist(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: statusColor),
              ),
            ),
          ]),
        ]),
      ),
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

