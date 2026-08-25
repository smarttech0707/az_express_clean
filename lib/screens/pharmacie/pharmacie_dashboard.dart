import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/notification_service.dart';
import '../../services/auth_service.dart';
import '../../widgets/wallet_action_sheet.dart';
import '../../widgets/partner_account_sheet.dart';
import '../../widgets/logout_confirm_dialog.dart';
import 'pharmacie_login.dart' show kPharmacieLastIdPrefKey;

class PharmacieDashboard extends StatefulWidget {
  final String pharmacieId;
  final Map<String, dynamic> pharmacieData;

  const PharmacieDashboard({
    super.key,
    required this.pharmacieId,
    required this.pharmacieData,
  });

  @override
  State<PharmacieDashboard> createState() => _PharmacieDashboardState();
}

class _PharmacieDashboardState extends State<PharmacieDashboard>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  late bool _isOnDuty;
  bool _toggling = false;
  String? _photoUrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _isOnDuty = widget.pharmacieData['isOnDuty'] == true;
    _photoUrl = widget.pharmacieData['logoUrl'] as String?;
    NotificationService.registerTapHandler((type, orderId, status) {
      if (!mounted) return;
      if (type == 'new_pharmacie_order') _tabCtrl.animateTo(0);
    });
  }

  @override
  void dispose() {
    NotificationService.unregisterTapHandler();
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _toggle(bool value) async {
    setState(() => _toggling = true);
    try {
      await FirebaseFirestore.instance
          .collection('pharmacies')
          .doc(widget.pharmacieId)
          .update({'isOnDuty': value});
      setState(() => _isOnDuty = value);
    } catch (e) {
      _snack('Erreur : $e', Colors.red);
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  // Master Prompt 135 — _logout() affiche désormais une confirmation avant
  // d'appeler _doLogout(), qui porte l'intégralité de la logique déjà
  // existante et inchangée (signOut, nettoyage SharedPreferences, redirection).
  void _logout() => showLogoutConfirmDialog(context, onConfirm: _doLogout);

  Future<void> _doLogout() async {
    AuthService().logAuthEvent('logout', 'pharmacie');
    // Master Prompt 128 (Partie 8) — la déconnexion volontaire est le seul
    // moment où l'identifiant local de reprise de session est effacé.
    (await SharedPreferences.getInstance()).remove(kPharmacieLastIdPrefKey);
    await FirebaseAuth.instance.signOut();
    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (_) {}
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.pharmacieData['name'] ?? 'Ma pharmacie';

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(name,
            style: GoogleFonts.urbanist(fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.red.shade700,
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'Mon compte',
            onPressed: () => showPartnerAccountSheet(
              context,
              role: 'pharmacie',
              roleLabel: 'Pharmacie',
              name: name as String?,
              phone: widget.pharmacieData['phone'] as String?,
              onLogout: _logout,
              photoUrl: _photoUrl,
              photoStoragePath:
                  'pharmacie_logos/${widget.pharmacieId}/logo.jpg',
              onPhotoUploaded: (url) async {
                await FirebaseFirestore.instance
                    .collection('pharmacies')
                    .doc(widget.pharmacieId)
                    .update({'logoUrl': url});
                if (mounted) setState(() => _photoUrl = url);
              },
              onPhotoDeleted: () async {
                await FirebaseFirestore.instance
                    .collection('pharmacies')
                    .doc(widget.pharmacieId)
                    .update({'logoUrl': FieldValue.delete()});
                if (mounted) setState(() => _photoUrl = null);
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Déconnexion',
            onPressed: _logout,
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          labelStyle:
              GoogleFonts.urbanist(fontWeight: FontWeight.w600, fontSize: 13),
          tabs: const [
            Tab(icon: Icon(Icons.emergency_rounded), text: 'Statut'),
            Tab(icon: Icon(Icons.local_shipping_rounded), text: 'Commandes'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: [
          _StatusTab(
            pharmacieId: widget.pharmacieId,
            pharmacieData: widget.pharmacieData,
            isOnDuty: _isOnDuty,
            toggling: _toggling,
            onToggle: _toggle,
          ),
          _OrdersTab(pharmacieId: widget.pharmacieId),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ONGLET STATUT
// ─────────────────────────────────────────────────────────────────────────────

class _StatusTab extends StatelessWidget {
  final String pharmacieId;
  final Map<String, dynamic> pharmacieData;
  final bool isOnDuty;
  final bool toggling;
  final ValueChanged<bool> onToggle;

  const _StatusTab({
    required this.pharmacieId,
    required this.pharmacieData,
    required this.isOnDuty,
    required this.toggling,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final name = pharmacieData['name'] ?? 'Ma pharmacie';
    final address = pharmacieData['address'] ?? '';
    final phone = pharmacieData['phone'] ?? '';
    final hours = pharmacieData['hours'] ?? '';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Carte identité
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.red.shade800, Colors.red.shade500],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withValues(alpha: 0.3),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              children: [
                const Icon(Icons.local_pharmacy_rounded,
                    color: Colors.white, size: 48),
                const SizedBox(height: 10),
                Text(name,
                    style: GoogleFonts.urbanist(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center),
                if (address.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(address,
                      style: GoogleFonts.urbanist(
                          color: Colors.white70, fontSize: 12),
                      textAlign: TextAlign.center),
                ],
                if (phone.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(phone,
                      style: GoogleFonts.urbanist(
                          color: Colors.white70, fontSize: 12)),
                ],
                if (hours.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('Horaires : $hours',
                      style: GoogleFonts.urbanist(
                          color: Colors.white60, fontSize: 11)),
                ],
              ],
            ),
          ),

          const SizedBox(height: 28),

          // Toggle de garde
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isOnDuty ? Colors.red.shade200 : Colors.grey.shade200,
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: isOnDuty
                      ? Colors.red.withValues(alpha: 0.1)
                      : Colors.black.withValues(alpha: 0.05),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: isOnDuty ? Colors.red.shade50 : Colors.grey.shade100,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color:
                          isOnDuty ? Colors.red.shade200 : Colors.grey.shade300,
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    isOnDuty
                        ? Icons.emergency_rounded
                        : Icons.local_pharmacy_outlined,
                    color:
                        isOnDuty ? Colors.red.shade700 : Colors.grey.shade400,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  isOnDuty ? 'Vous êtes de garde' : 'Vous n\'êtes pas de garde',
                  style: GoogleFonts.urbanist(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color:
                        isOnDuty ? Colors.red.shade700 : Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  isOnDuty
                      ? 'Votre pharmacie apparaît dans "De garde"'
                      : 'Activez pour apparaître dans "De garde"',
                  style: GoogleFonts.urbanist(
                      fontSize: 12, color: Colors.grey.shade500),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                toggling
                    ? const CircularProgressIndicator()
                    : GestureDetector(
                        onTap: () => onToggle(!isOnDuty),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: double.infinity,
                          height: 56,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: isOnDuty
                                  ? [Colors.grey.shade400, Colors.grey.shade500]
                                  : [Colors.red.shade700, Colors.red.shade500],
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                            ),
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: isOnDuty
                                    ? Colors.grey.withValues(alpha: 0.3)
                                    : Colors.red.withValues(alpha: 0.35),
                                blurRadius: 12,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                isOnDuty
                                    ? Icons.toggle_off_rounded
                                    : Icons.toggle_on_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                isOnDuty
                                    ? 'Je ne suis plus de garde'
                                    : 'Je suis de garde',
                                style: GoogleFonts.urbanist(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.red.shade100),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.red.shade700, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Lorsque vous êtes "de garde", les clients AZ Express peuvent voir votre pharmacie et envoyer un livreur récupérer leurs médicaments.',
                    style: TextStyle(fontSize: 12, color: Colors.red.shade700),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ── WALLET PHARMACIE ──────────────────────────
          _PharmacieWallet(pharmacieId: pharmacieId),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WALLET PHARMACIE
// ─────────────────────────────────────────────────────────────────────────────

class _PharmacieWallet extends StatelessWidget {
  final String pharmacieId;
  const _PharmacieWallet({required this.pharmacieId});

  String _fmt(int v) {
    if (v >= 1000) {
      return "${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}";
    }
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('pharmacies')
          .doc(pharmacieId)
          .snapshots(),
      builder: (context, snap) {
        final wallet = (snap.data?.data() as Map?)?['wallet'] as num? ?? 0;
        final balance = wallet.toInt();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mon wallet',
              style: GoogleFonts.urbanist(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87),
            ),
            const SizedBox(height: 12),

            // Solde card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.green.shade700, Colors.green.shade500],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.green.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Icon(Icons.account_balance_wallet_rounded,
                          color: Colors.white70, size: 22),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('Solde disponible',
                            style: GoogleFonts.urbanist(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.w500)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _fmt(balance),
                    style: GoogleFonts.urbanist(
                        color: Colors.white,
                        fontSize: 40,
                        fontWeight: FontWeight.w900,
                        height: 1),
                  ),
                  Text('FCFA',
                      style: GoogleFonts.urbanist(
                          color: Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => WalletActionSheet.show(
                        context,
                        action: WalletAction.withdraw,
                        userId: pharmacieId,
                        userType: 'pharmacie',
                        userName: 'Pharmacie',
                        currentBalance: balance,
                      ),
                      icon: const Icon(Icons.arrow_upward_rounded,
                          color: Color(0xFF2E7D32), size: 18),
                      label: Text('Retirer de l\'argent',
                          style: GoogleFonts.urbanist(
                              color: const Color(0xFF2E7D32),
                              fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Historique transactions
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('pharmacies')
                  .doc(pharmacieId)
                  .collection('wallet_transactions')
                  .orderBy('createdAt', descending: true)
                  .limit(10)
                  .snapshots(),
              builder: (context, txSnap) {
                final txs = txSnap.data?.docs ?? [];
                if (txs.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Center(
                      child: Text('Aucune transaction',
                          style: GoogleFonts.urbanist(
                              color: Colors.grey, fontSize: 13)),
                    ),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Dernières transactions',
                        style: GoogleFonts.urbanist(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade600)),
                    const SizedBox(height: 8),
                    ...txs.map((doc) {
                      final d = doc.data() as Map<String, dynamic>;
                      final type = d['type'] as String? ?? '';
                      final amount = (d['amount'] as num? ?? 0).toInt();
                      final desc = d['description'] as String? ?? '';
                      final ts = d['createdAt'] as Timestamp?;
                      final date = ts != null
                          ? '${ts.toDate().day}/${ts.toDate().month} ${ts.toDate().hour}:${ts.toDate().minute.toString().padLeft(2, '0')}'
                          : '';
                      final isCredit = type == 'earning' ||
                          type == 'recharge' ||
                          type == 'credit';

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: isCredit
                                    ? Colors.green.shade50
                                    : Colors.red.shade50,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                isCredit
                                    ? Icons.add_circle_rounded
                                    : Icons.remove_circle_rounded,
                                color: isCredit
                                    ? Colors.green.shade700
                                    : Colors.red.shade700,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(desc,
                                      style: GoogleFonts.urbanist(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  Text(date,
                                      style: GoogleFonts.urbanist(
                                          fontSize: 10,
                                          color: Colors.grey.shade400)),
                                ],
                              ),
                            ),
                            Text(
                              '${isCredit ? '+' : '-'}${_fmt(amount)} F',
                              style: GoogleFonts.urbanist(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: isCredit
                                    ? Colors.green.shade700
                                    : Colors.red.shade700,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ONGLET COMMANDES
// ─────────────────────────────────────────────────────────────────────────────

class _OrdersTab extends StatelessWidget {
  final String pharmacieId;
  const _OrdersTab({required this.pharmacieId});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Container(
            color: Colors.white,
            child: TabBar(
              labelColor: Colors.red.shade700,
              unselectedLabelColor: Colors.grey,
              indicatorColor: Colors.red.shade700,
              labelStyle: GoogleFonts.urbanist(
                  fontWeight: FontWeight.w600, fontSize: 12),
              tabs: const [
                Tab(text: 'En cours'),
                Tab(text: 'Historique'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _OrderList(
                  pharmacieId: pharmacieId,
                  activeOnly: true,
                ),
                _OrderList(
                  pharmacieId: pharmacieId,
                  activeOnly: false,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderList extends StatelessWidget {
  final String pharmacieId;
  final bool activeOnly;

  const _OrderList({
    required this.pharmacieId,
    required this.activeOnly,
  });

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> query = FirebaseFirestore.instance
        .collection('orders')
        .where('pharmacieId', isEqualTo: pharmacieId)
        .orderBy('createdAt', descending: true)
        .limit(20);

    if (activeOnly) {
      query = FirebaseFirestore.instance
          .collection('orders')
          .where('pharmacieId', isEqualTo: pharmacieId)
          .where('status', whereIn: [
        'pending',
        'assigned',
        'accepted',
        'picked_up'
      ]).orderBy('createdAt', descending: true);
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.local_shipping_outlined,
                    size: 64, color: Colors.grey.shade300),
                const SizedBox(height: 12),
                Text(
                  activeOnly ? 'Aucune commande en cours' : 'Aucun historique',
                  style: GoogleFonts.urbanist(color: Colors.grey),
                ),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final data = docs[i].data() as Map<String, dynamic>;
            return _PharmacieOrderCard(data: data);
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _PharmacieOrderCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _PharmacieOrderCard({required this.data});

  static const _statusLabels = {
    'pending': 'En attente d\'un livreur',
    'assigned': 'Livreur assigné',
    'accepted': 'Livreur en route vers vous',
    'picked_up': 'Colis récupéré — en livraison',
    'delivered': 'Livré',
    'cancelled': 'Annulé',
  };

  static const _statusColors = {
    'pending': Color(0xFFFF8F00),
    'assigned': Color(0xFF1565C0),
    'accepted': Color(0xFF1565C0),
    'picked_up': Color(0xFF2E7D32),
    'delivered': Color(0xFF2E7D32),
    'cancelled': Color(0xFFC62828),
  };

  @override
  Widget build(BuildContext context) {
    final status = data['status'] as String? ?? 'pending';
    final driverId = data['driverId'] as String?;
    final color = _statusColors[status] ?? Colors.grey;
    final label = _statusLabels[status] ?? status;
    final ts = data['createdAt'] as Timestamp?;
    final timeStr = ts != null ? _fmt(ts.toDate()) : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(18)),
              border: Border(left: BorderSide(color: color, width: 4)),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label,
                      style: GoogleFonts.urbanist(
                          fontWeight: FontWeight.w600,
                          color: color,
                          fontSize: 13)),
                ),
                Text(timeStr,
                    style: GoogleFonts.urbanist(
                        fontSize: 11, color: Colors.grey.shade400)),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data['description'] ?? 'Commande pharmacie',
                  style: GoogleFonts.urbanist(
                      fontWeight: FontWeight.bold, fontSize: 14),
                ),
                if ((data['clientName'] as String? ?? '').isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.person_outline,
                          size: 14, color: Colors.grey.shade400),
                      const SizedBox(width: 4),
                      Text(data['clientName'],
                          style: GoogleFonts.urbanist(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                ],

                // ── CARTE LIVREUR ──────────────────────────
                if (driverId != null) ...[
                  const SizedBox(height: 12),
                  _DriverInfoCard(driverId: driverId, status: status),
                ] else if (status == 'pending') ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.orange.shade700,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Recherche d\'un livreur...',
                          style: GoogleFonts.urbanist(
                              fontSize: 13,
                              color: Colors.orange.shade700,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return 'Il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'Il y a ${diff.inHours}h';
    return '${dt.day}/${dt.month}';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CARTE LIVREUR — chargement depuis Firestore en temps réel
// ─────────────────────────────────────────────────────────────────────────────

class _DriverInfoCard extends StatelessWidget {
  final String driverId;
  final String status;

  const _DriverInfoCard({required this.driverId, required this.status});

  Future<void> _call(String phone) async {
    final url = Uri.parse('tel:$phone');
    if (await canLaunchUrl(url)) launchUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('livreurs')
          .doc(driverId)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData || !snap.data!.exists) {
          return const SizedBox.shrink();
        }
        final d = snap.data!.data() as Map<String, dynamic>;
        final name = d['name'] as String? ?? 'Livreur';
        final phone = d['phone'] as String? ?? '';
        final photo = d['photoUrl'] as String?;
        final moto = d['motoModel'] as String? ?? '';

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F5E9),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFA5D6A7), width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Titre sécurité
              Row(
                children: [
                  const Icon(Icons.verified_user_rounded,
                      color: Color(0xFF2E7D32), size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'Livreur assigné — Vérification sécurité',
                    style: GoogleFonts.urbanist(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: const Color(0xFF2E7D32)),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  // Photo livreur
                  GestureDetector(
                    onTap: photo != null && photo.isNotEmpty
                        ? () => _showPhoto(context, photo, name)
                        : null,
                    child: Stack(
                      children: [
                        CircleAvatar(
                          radius: 32,
                          backgroundColor: Colors.green.shade200,
                          backgroundImage: photo != null && photo.isNotEmpty
                              ? NetworkImage(photo)
                              : null,
                          child: photo == null || photo.isEmpty
                              ? const Icon(Icons.delivery_dining_rounded,
                                  color: Colors.white, size: 28)
                              : null,
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: const BoxDecoration(
                              color: Color(0xFF2E7D32),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.check,
                                color: Colors.white, size: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),

                  // Infos
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: GoogleFonts.urbanist(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: Colors.black87)),
                        if (moto.isNotEmpty)
                          Text(moto,
                              style: GoogleFonts.urbanist(
                                  fontSize: 12, color: Colors.grey.shade600)),
                        const SizedBox(height: 4),
                        _StatusChip(status: status),
                      ],
                    ),
                  ),

                  // Bouton appel
                  if (phone.isNotEmpty)
                    GestureDetector(
                      onTap: () => _call(phone),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E7D32),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.green.withValues(alpha: 0.4),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.call_rounded,
                            color: Colors.white, size: 22),
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline,
                        size: 14, color: Color(0xFF2E7D32)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Vérifiez que le livreur correspond à la photo ci-dessus avant de lui remettre le colis.',
                        style: GoogleFonts.urbanist(
                            fontSize: 11, color: const Color(0xFF2E7D32)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPhoto(BuildContext context, String url, String name) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Photo du livreur : $name',
                  style: GoogleFonts.urbanist(
                      fontWeight: FontWeight.bold, fontSize: 14),
                  textAlign: TextAlign.center),
            ),
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(20)),
              child: Image.network(url,
                  fit: BoxFit.cover,
                  loadingBuilder: (_, child, progress) => progress == null
                      ? child
                      : const SizedBox(
                          height: 200,
                          child: Center(child: CircularProgressIndicator()))),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    String label;
    Color color;
    IconData icon;

    switch (status) {
      case 'assigned':
        label = 'Assigné';
        color = const Color(0xFF1565C0);
        icon = Icons.assignment_ind_rounded;
        break;
      case 'accepted':
        label = 'En route vers vous';
        color = const Color(0xFF1565C0);
        icon = Icons.directions_bike_rounded;
        break;
      case 'picked_up':
        label = 'Colis récupéré';
        color = const Color(0xFF2E7D32);
        icon = Icons.inventory_2_rounded;
        break;
      default:
        label = status;
        color = Colors.grey;
        icon = Icons.circle;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
