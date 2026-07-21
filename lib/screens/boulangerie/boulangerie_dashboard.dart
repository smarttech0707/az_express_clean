import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/notification_service.dart';
import '../../services/auth_service.dart';
import '../../widgets/wallet_action_sheet.dart';
import '../../widgets/partner_account_sheet.dart';
import '../../widgets/logout_confirm_dialog.dart';

class BoulangerieDashboard extends StatefulWidget {
  final String boulangerieId;
  final Map<String, dynamic> boulangerieData;

  const BoulangerieDashboard({
    super.key,
    required this.boulangerieId,
    required this.boulangerieData,
  });

  @override
  State<BoulangerieDashboard> createState() => _BoulangerieDashboardState();
}

class _BoulangerieDashboardState extends State<BoulangerieDashboard>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  late bool _isOpen;
  bool _toggling = false;
  int _prevNewCount = -1;
  String? _photoUrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this);
    _isOpen  = widget.boulangerieData['isOpen'] == true;
    _photoUrl = widget.boulangerieData['logoUrl'] as String?;
    NotificationService.registerTapHandler((type, orderId, status) {
      if (!mounted) return;
      if (type == 'new_boulangerie_order') _tabCtrl.animateTo(0);
    });
  }

  @override
  void dispose() {
    NotificationService.unregisterTapHandler();
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _toggleOpen(bool value) async {
    setState(() => _toggling = true);
    try {
      await FirebaseFirestore.instance
          .collection('boulangeries')
          .doc(widget.boulangerieId)
          .update({'isOpen': value});
      setState(() => _isOpen = value);
    } catch (e) {
      _snack('Erreur : $e', Colors.red);
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // Master Prompt 135 — _logout() affiche désormais une confirmation avant
  // d'appeler _doLogout(), qui porte l'intégralité de la logique déjà
  // existante et inchangée (signOut, redirection).
  void _logout() => showLogoutConfirmDialog(context, onConfirm: _doLogout);

  Future<void> _doLogout() async {
    AuthService().logAuthEvent('logout', 'boulangerie');
    await FirebaseAuth.instance.signOut();
    try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _checkNewOrders(int count) {
    if (_prevNewCount >= 0 && count > _prevNewCount) {
      HapticFeedback.heavyImpact();
      if (mounted) _showNewOrderAlert();
    }
    _prevNewCount = count;
  }

  void _showNewOrderAlert() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.notifications_active_rounded,
              color: Colors.orange, size: 28),
          SizedBox(width: 10),
          Text('Nouvelle commande !'),
        ]),
        content:
            const Text('Une nouvelle commande vient d\'arriver.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _tabCtrl.animateTo(0);
            },
            child: const Text('Voir maintenant',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF5D4037))),
          ),
        ],
      ),
    );
  }

  // Mettre à jour le statut de préparation
  Future<void> _updateSellerStatus(String orderId, String status) async {
    await FirebaseFirestore.instance
        .collection('orders')
        .doc(orderId)
        .update({'sellerStatus': status});
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.boulangerieData['name'] ?? 'Ma boulangerie';
    const brown = Color(0xFF5D4037);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: brown,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name,
                style: GoogleFonts.urbanist(
                    fontWeight: FontWeight.bold, fontSize: 15),
                overflow: TextOverflow.ellipsis),
            Text(
              _isOpen ? '🟢 Ouvert' : '🔴 Fermé',
              style: GoogleFonts.urbanist(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          // Wallet
          StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('boulangeries')
                .doc(widget.boulangerieId)
                .snapshots(),
            builder: (context, snap) {
              final wallet =
                  (snap.data?.data() as Map<String, dynamic>?)?['wallet'] ?? 0;
              return GestureDetector(
                onTap: () => WalletActionSheet.show(
                  context,
                  action: WalletAction.recharge,
                  userId: widget.boulangerieId,
                  userType: 'boulangerie',
                  userName: name,
                  currentBalance: (wallet as num).toInt(),
                ),
                child: Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(children: [
                    const Icon(Icons.account_balance_wallet_rounded,
                        size: 16),
                    const SizedBox(width: 4),
                    Text('$wallet F',
                        style: GoogleFonts.urbanist(
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ]),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'Mon compte',
            onPressed: () => showPartnerAccountSheet(
              context,
              role: 'boulangerie',
              roleLabel: 'Boulangerie',
              name: name as String?,
              phone: widget.boulangerieData['phone'] as String?,
              onLogout: _logout,
              photoUrl: _photoUrl,
              photoStoragePath: 'boulangerie_logos/${widget.boulangerieId}/logo.jpg',
              onPhotoUploaded: (url) async {
                await FirebaseFirestore.instance
                    .collection('boulangeries')
                    .doc(widget.boulangerieId)
                    .update({'logoUrl': url});
                if (mounted) setState(() => _photoUrl = url);
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            onPressed: _logout,
            tooltip: 'Déconnexion',
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelStyle: GoogleFonts.urbanist(
              fontWeight: FontWeight.w600, fontSize: 12),
          tabs: const [
            Tab(icon: Icon(Icons.fiber_new_rounded, size: 18), text: 'Nouvelles'),
            Tab(icon: Icon(Icons.local_fire_department_rounded, size: 18), text: 'Préparation'),
            Tab(icon: Icon(Icons.check_circle_outline_rounded, size: 18), text: 'Prêtes'),
            Tab(icon: Icon(Icons.history_rounded, size: 18), text: 'Livrées'),
          ],
        ),
      ),
      body: Column(
        children: [
          // ── Subscription/VIP status banners ──────────────────────
          _BoulangerieSubscriptionBanner(boulangerieData: widget.boulangerieData),

          // ── Toggle ouvert / fermé ──────────────────────────────────
          Container(
            color: Colors.white,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              Icon(
                _isOpen
                    ? Icons.storefront_rounded
                    : Icons.store_mall_directory_outlined,
                color: _isOpen ? Colors.green : Colors.grey,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _isOpen
                      ? 'Votre boulangerie est ouverte'
                      : 'Votre boulangerie est fermée',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: _isOpen
                          ? Colors.green.shade700
                          : Colors.grey.shade600),
                ),
              ),
              _toggling
                  ? const SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Switch(
                      value: _isOpen,
                      activeThumbColor: Colors.green,
                      activeTrackColor: Colors.green.withValues(alpha: 0.5),
                      onChanged: _toggleOpen,
                    ),
            ]),
          ),
          const Divider(height: 1),

          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                _OrderList(
                  boulangerieId: widget.boulangerieId,
                  statuses: const ['pending', 'assigned'],
                  sellerStatuses: const [null, ''],
                  emptyLabel: 'Aucune nouvelle commande',
                  emptyIcon: Icons.inbox_outlined,
                  actionLabel: 'Commencer la préparation',
                  actionColor: Colors.orange.shade700,
                  onAction: (id) => _updateSellerStatus(id, 'preparing'),
                  onNewCount: _checkNewOrders,
                ),
                _OrderList(
                  boulangerieId: widget.boulangerieId,
                  statuses: const ['pending', 'assigned', 'accepted'],
                  sellerStatuses: const ['preparing'],
                  emptyLabel: 'Rien en préparation',
                  emptyIcon: Icons.local_fire_department_outlined,
                  actionLabel: 'Marquer comme prête',
                  actionColor: Colors.green.shade700,
                  onAction: (id) => _updateSellerStatus(id, 'ready'),
                  onNewCount: null,
                ),
                _OrderList(
                  boulangerieId: widget.boulangerieId,
                  statuses: const ['pending', 'assigned', 'accepted'],
                  sellerStatuses: const ['ready'],
                  emptyLabel: 'Aucune commande prête',
                  emptyIcon: Icons.check_circle_outline_rounded,
                  actionLabel: null,
                  actionColor: null,
                  onAction: null,
                  onNewCount: null,
                ),
                _OrderList(
                  boulangerieId: widget.boulangerieId,
                  statuses: const ['picked_up', 'delivered'],
                  sellerStatuses: null,
                  emptyLabel: 'Aucune livraison encore',
                  emptyIcon: Icons.history_rounded,
                  actionLabel: null,
                  actionColor: null,
                  onAction: null,
                  onNewCount: null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// LISTE DE COMMANDES
// ═══════════════════════════════════════════════════════════════════════

class _OrderList extends StatelessWidget {
  final String boulangerieId;
  final List<String> statuses;
  final List<String?>? sellerStatuses; // null = ignorer le filtre
  final String emptyLabel;
  final IconData emptyIcon;
  final String? actionLabel;
  final Color? actionColor;
  final void Function(String orderId)? onAction;
  final void Function(int count)? onNewCount;

  const _OrderList({
    required this.boulangerieId,
    required this.statuses,
    required this.sellerStatuses,
    required this.emptyLabel,
    required this.emptyIcon,
    required this.actionLabel,
    required this.actionColor,
    required this.onAction,
    required this.onNewCount,
  });

  @override
  Widget build(BuildContext context) {
    Query query = FirebaseFirestore.instance
        .collection('orders')
        .where('sellerId', isEqualTo: boulangerieId)
        .where('status', whereIn: statuses)
        .orderBy('createdAt', descending: true);

    return StreamBuilder<QuerySnapshot>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        var docs = snap.data?.docs ?? [];

        // Filtrer par sellerStatus côté client
        if (sellerStatuses != null) {
          docs = docs.where((d) {
            final ss = (d.data() as Map<String, dynamic>)['sellerStatus'];
            return sellerStatuses!.contains(ss);
          }).toList();
        }

        // Déclencher alerte sonore si nouvelles commandes
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onNewCount?.call(docs.length);
        });

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(emptyIcon, size: 56, color: Colors.grey.shade300),
                const SizedBox(height: 12),
                Text(emptyLabel,
                    style: const TextStyle(
                        color: Colors.grey, fontSize: 15)),
              ],
            ),
          );
        }

        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final doc  = docs[i];
            final data = doc.data() as Map<String, dynamic>;
            return _OrderCard(
              orderId: doc.id,
              data: data,
              actionLabel: actionLabel,
              actionColor: actionColor,
              onAction: onAction,
            );
          },
        );
      },
    );
  }
}

// ── Carte commande ────────────────────────────────────────────────────

class _OrderCard extends StatelessWidget {
  final String orderId;
  final Map<String, dynamic> data;
  final String? actionLabel;
  final Color? actionColor;
  final void Function(String)? onAction;

  const _OrderCard({
    required this.orderId,
    required this.data,
    required this.actionLabel,
    required this.actionColor,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final clientName    = data['clientName']    ?? 'Client';
    final clientPhone   = data['clientPhone']   ?? '';
    final address       = data['description']   ?? data['deliveryAddress'] ?? '—';
    final items         = (data['items'] as List?)?.cast<Map>() ?? [];
    final itemsAmount   = (data['itemsAmount']  as num?)?.toInt() ?? 0;
    final deliveryFee   = (data['budget']       as num?)?.toInt() ?? 0;
    final totalAmount   = (data['totalAmount']  as num?)?.toInt() ?? 0;
    final payMethod     = data['paymentMethod'] ?? 'cash';
    final requestedTime = data['requestedTime'] as String?;
    final status        = data['status']        ?? 'pending';
    final sellerStatus  = data['sellerStatus']  as String?;
    final driverId      = data['driverId']      as String?;
    final orderSubType    = data['orderSubType']    as String?;
    final cakeDescription = data['cakeDescription'] as String?;
    final cakeDeadline    = (data['cakeDeadline'] as Timestamp?)?.toDate();

    Color statusColor;
    String statusLabel;
    switch (sellerStatus ?? '') {
      case 'preparing':
        statusColor = Colors.orange;
        statusLabel = 'En préparation';
        break;
      case 'ready':
        statusColor = Colors.green;
        statusLabel = 'Prête';
        break;
      default:
        if (status == 'delivered') {
          statusColor = Colors.blue;
          statusLabel = 'Livrée';
        } else if (status == 'picked_up') {
          statusColor = Colors.purple;
          statusLabel = 'En livraison';
        } else {
          statusColor = Colors.red;
          statusLabel = 'Nouvelle';
        }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: statusColor.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── En-tête statut ───────────────────────────────────────
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.08),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(18)),
            ),
            child: Row(children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    color: statusColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(statusLabel,
                  style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
              const Spacer(),
              if (requestedTime != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber.shade200),
                  ),
                  child: Row(children: [
                    Icon(Icons.schedule_rounded,
                        size: 12, color: Colors.amber.shade700),
                    const SizedBox(width: 4),
                    Text(requestedTime,
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.amber.shade800,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
            ]),
          ),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Badge gâteau personnalisé ──────────────────────
                if (orderSubType == 'custom_cake') ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF6D1B7B), Color(0xFFAD1457)],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(children: [
                      Text('🎂',
                          style: TextStyle(fontSize: 16)),
                      SizedBox(width: 6),
                      Text('Gâteau personnalisé',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  if (cakeDescription != null && cakeDescription.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6D1B7B).withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: const Color(0xFF6D1B7B).withValues(alpha: 0.25)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Description',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF6D1B7B))),
                          const SizedBox(height: 4),
                          Text(cakeDescription,
                              style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  if (cakeDeadline != null) ...[
                    const SizedBox(height: 6),
                    Row(children: [
                      const Icon(Icons.event_rounded,
                          size: 14, color: Color(0xFFAD1457)),
                      const SizedBox(width: 5),
                      Text(
                        'À livrer pour le ${cakeDeadline.day.toString().padLeft(2, '0')}/${cakeDeadline.month.toString().padLeft(2, '0')}/${cakeDeadline.year}',
                        style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFAD1457),
                            fontWeight: FontWeight.w600),
                      ),
                    ]),
                  ],
                  const Divider(height: 14),
                ] else if (items.isNotEmpty) ...[
                // ── Articles (commande normale) ────────────────────
                  const Text('Articles',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 6),
                  ...items.map((item) => Padding(
                        padding:
                            const EdgeInsets.only(bottom: 3),
                        child: Row(children: [
                          const Icon(Icons.circle,
                              size: 6, color: Colors.brown),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${item['qty']}x ${item['name']}',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          Text(
                            '${(item['price'] as num?)?.toInt() ?? 0} F',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600),
                          ),
                        ]),
                      )),
                  const Divider(height: 12),
                ],

                // ── Adresse livraison ──────────────────────────────
                Row(children: [
                  const Icon(Icons.location_on_outlined,
                      size: 15, color: Colors.grey),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(address,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.grey)),
                  ),
                ]),
                const SizedBox(height: 8),

                // ── Client ─────────────────────────────────────────
                Row(children: [
                  const Icon(Icons.person_outline, size: 15),
                  const SizedBox(width: 6),
                  Text(clientName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => launchUrl(
                        Uri.parse('tel:$clientPhone')),
                    child: Text(clientPhone,
                        style: TextStyle(
                            color: Colors.blue.shade700,
                            fontSize: 12)),
                  ),
                ]),
                const SizedBox(height: 8),

                // ── Livreur (si assigné) ───────────────────────────
                if (driverId != null)
                  StreamBuilder<DocumentSnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('livreurs')
                        .doc(driverId)
                        .snapshots(),
                    builder: (context, dSnap) {
                      final dd = dSnap.data?.data()
                          as Map<String, dynamic>?;
                      if (dd == null) return const SizedBox.shrink();
                      final dName  = dd['name']  ?? 'Livreur';
                      final dPhone = dd['phone'] ?? '';
                      final online = dd['isOnline'] == true;
                      return Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(children: [
                          Icon(Icons.delivery_dining_rounded,
                              color: Colors.blue.shade700, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(dName,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13)),
                                Row(children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: online
                                          ? Colors.green
                                          : Colors.grey,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    online ? 'En ligne' : 'Hors ligne',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey),
                                  ),
                                ]),
                              ],
                            ),
                          ),
                          GestureDetector(
                            onTap: () => launchUrl(
                                Uri.parse('tel:$dPhone')),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade700,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.phone_rounded,
                                  color: Colors.white, size: 16),
                            ),
                          ),
                        ]),
                      );
                    },
                  ),

                const SizedBox(height: 10),

                // ── Montants ───────────────────────────────────────
                Row(children: [
                  _amountChip(
                      'Articles', '$itemsAmount FCFA', Colors.brown),
                  const SizedBox(width: 8),
                  _amountChip(
                      'Livraison', '$deliveryFee FCFA', Colors.blue),
                  const SizedBox(width: 8),
                  _amountChip('Total',
                      '${totalAmount > 0 ? totalAmount : itemsAmount + deliveryFee} FCFA',
                      Colors.green),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  Icon(
                    payMethod == 'wallet'
                        ? Icons.account_balance_wallet_rounded
                        : Icons.payments_outlined,
                    size: 14,
                    color: payMethod == 'wallet'
                        ? Colors.green.shade700
                        : Colors.orange.shade700,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    payMethod == 'wallet'
                        ? 'Payé par wallet'
                        : 'Cash à la livraison',
                    style: TextStyle(
                        fontSize: 12,
                        color: payMethod == 'wallet'
                            ? Colors.green.shade700
                            : Colors.orange.shade700,
                        fontWeight: FontWeight.w600),
                  ),
                ]),

                // ── Bouton action ──────────────────────────────────
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: Text(actionLabel!),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: actionColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => onAction!(orderId),
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

  Widget _amountChip(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(children: [
          Text(label,
              style: TextStyle(
                  fontSize: 9,
                  color: color,
                  fontWeight: FontWeight.w600)),
          Text(value,
              style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.bold)),
        ]),
      ),
    );
  }
}

// ── SUBSCRIPTION BANNER FOR BOULANGERIE ──────────────────────────────────────

class _BoulangerieSubscriptionBanner extends StatelessWidget {
  final Map<String, dynamic> boulangerieData;
  const _BoulangerieSubscriptionBanner({required this.boulangerieData});

  @override
  Widget build(BuildContext context) {
    final subStatus = boulangerieData['subscriptionStatus'] as String? ?? 'active';
    final vipStatus = boulangerieData['vipStatus'] as String? ?? 'none';
    final vipExpiry = boulangerieData['vipExpiresAt'];

    if (subStatus != 'suspended' && vipStatus != 'active') {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        if (subStatus == 'suspended')
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.red.shade700,
            child: const Row(children: [
              Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Abonnement suspendu — Rechargez votre wallet pour réactiver votre compte.',
                  style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ]),
          ),
        if (vipStatus == 'active')
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFFFD700), Color(0xFFFFA000)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
            child: Row(children: [
              const Text('👑', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  vipExpiry != null
                      ? 'Compte VIP actif — Votre boulangerie apparaît en premier. Expire le ${_fmtDate(vipExpiry)}.'
                      : 'Compte VIP actif — Votre boulangerie apparaît en premier.',
                  style: const TextStyle(
                      color: Colors.black87, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ]),
          ),
      ],
    );
  }

  String _fmtDate(dynamic ts) {
    if (ts == null) return '';
    try {
      final dt = (ts as dynamic).toDate() as DateTime;
      return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
    } catch (_) {
      return '';
    }
  }
}
