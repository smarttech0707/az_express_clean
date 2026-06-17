import 'dart:async';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/notification_service.dart';
import '../../widgets/wallet_action_sheet.dart';

class RestaurantOwnerDashboard extends StatefulWidget {
  final String ownerId;
  final String restaurantId;
  final Map<String, dynamic> restaurantData;

  const RestaurantOwnerDashboard({
    super.key,
    required this.ownerId,
    required this.restaurantId,
    required this.restaurantData,
  });

  @override
  State<RestaurantOwnerDashboard> createState() =>
      _RestaurantOwnerDashboardState();
}

class _RestaurantOwnerDashboardState extends State<RestaurantOwnerDashboard>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  bool _isOpen = false;
  int _wallet = 0;
  StreamSubscription? _walletSub;
  StreamSubscription<QuerySnapshot>? _orderSub;
  int _prevPendingCount = -1;

  String get _name => widget.restaurantData['name'] ?? 'Mon restaurant';

  String _fmtWallet(int v) {
    if (v >= 1000) return "${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}";
    return v.toString();
  }

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _isOpen = widget.restaurantData['isOpen'] == true;
    NotificationService.registerTapHandler((type, orderId, status) {
      if (!mounted) return;
      if (type == 'new_seller_order') _tabCtrl.animateTo(1);
    });
    _walletSub = FirebaseFirestore.instance
        .collection('restaurants')
        .doc(widget.restaurantId)
        .snapshots()
        .listen((s) {
      if (mounted) setState(() => _wallet = (s.data()?['wallet'] as num? ?? 0).toInt());
    });

    _orderSub = FirebaseFirestore.instance
        .collection('orders')
        .where('sellerId', isEqualTo: widget.restaurantId)
        .where('sellerType', isEqualTo: 'restaurant')
        .where('status', whereIn: ['pending', 'assigned'])
        .snapshots()
        .listen((snap) {
      final count = snap.docs.length;
      if (_prevPendingCount >= 0 && count > _prevPendingCount) {
        HapticFeedback.heavyImpact();
        if (mounted) _showNewOrderAlert();
      }
      _prevPendingCount = count;
    });
  }

  @override
  void dispose() {
    _walletSub?.cancel();
    _orderSub?.cancel();
    NotificationService.unregisterTapHandler();
    _tabCtrl.dispose();
    super.dispose();
  }

  void _showNewOrderAlert() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.notifications_active_rounded, color: Colors.orange, size: 28),
            SizedBox(width: 10),
            Text('Nouvelle commande !'),
          ],
        ),
        content: const Text('Une nouvelle commande vient d\'arriver.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _tabCtrl.animateTo(1);
            },
            child: const Text('Voir maintenant',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1565C0))),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleOpen(bool v) async {
    setState(() => _isOpen = v);
    await FirebaseFirestore.instance
        .collection('restaurants')
        .doc(widget.restaurantId)
        .update({'isOpen': v});
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.restaurantData['name'] ?? 'Mon restaurant';

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(name,
            style: GoogleFonts.inter(fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart_rounded),
            tooltip: 'Statistiques',
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => _RestaurantAnalyticsSheet(
                  restaurantId: widget.restaurantId),
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
          labelStyle: GoogleFonts.inter(
              fontWeight: FontWeight.w600, fontSize: 13),
          tabs: const [
            Tab(icon: Icon(Icons.restaurant_menu_rounded), text: 'Menu'),
            Tab(icon: Icon(Icons.receipt_long_rounded), text: 'Commandes'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Status bar
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                // Wallet chip
                GestureDetector(
                  onTap: () => showModalBottomSheet(
                    context: context,
                    backgroundColor: Colors.transparent,
                    builder: (_) => _WalletSheet(
                      restaurantId: widget.restaurantId,
                      name: _name,
                      wallet: _wallet,
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1565C0), Color(0xFF1E88E5)],
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(children: [
                      const Icon(Icons.account_balance_wallet_rounded,
                          color: Colors.white, size: 15),
                      const SizedBox(width: 5),
                      Text('${_fmtWallet(_wallet)} F',
                          style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold)),
                    ]),
                  ),
                ),
                const Spacer(),
                Text(_isOpen ? 'Ouvert' : 'Fermé',
                    style: GoogleFonts.inter(
                        color: _isOpen
                            ? const Color(0xFF2E7D32)
                            : Colors.grey.shade600,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                const SizedBox(width: 8),
                Switch(
                  value: _isOpen,
                  onChanged: _toggleOpen,
                  activeThumbColor: const Color(0xFF1565C0),
                  activeTrackColor: const Color(0x331565C0),
                ),
              ],
            ),
          ),

          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                _MenuTab(restaurantId: widget.restaurantId),
                _OrdersTab(restaurantId: widget.restaurantId),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MENU TAB
// ─────────────────────────────────────────────────────────────────────────────

class _MenuTab extends StatelessWidget {
  final String restaurantId;
  const _MenuTab({required this.restaurantId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showItemDialog(context),
        backgroundColor: const Color(0xFF1565C0),
        icon: const Icon(Icons.add, color: Colors.white),
        label: Text('Ajouter',
            style: GoogleFonts.inter(
                color: Colors.white, fontWeight: FontWeight.w600)),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('restaurants')
            .doc(restaurantId)
            .collection('menu')
            .orderBy('createdAt', descending: true)
            .snapshots(),
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
                  Icon(Icons.restaurant_menu_rounded,
                      size: 64, color: Colors.grey.shade300),
                  const SizedBox(height: 12),
                  Text('Aucun article dans le menu',
                      style: GoogleFonts.inter(color: Colors.grey)),
                  const SizedBox(height: 4),
                  Text('Appuyez sur + pour ajouter',
                      style: GoogleFonts.inter(
                          color: Colors.grey.shade400, fontSize: 12)),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final doc = docs[i];
              final d = doc.data() as Map<String, dynamic>;
              return _MenuItemCard(
                docId: doc.id,
                restaurantId: restaurantId,
                data: d,
                onEdit: () => _showItemDialog(context, docId: doc.id, data: d),
              );
            },
          );
        },
      ),
    );
  }

  void _showItemDialog(BuildContext context,
      {String? docId, Map<String, dynamic>? data}) {
    final nameCtrl  = TextEditingController(text: data?['name'] ?? '');
    final priceCtrl = TextEditingController(
        text: data?['price'] != null ? '${data!['price']}' : '');
    final descCtrl  = TextEditingController(text: data?['description'] ?? '');
    final stockCtrl = TextEditingController(
        text: data?['stock'] != null ? '${data!['stock']}' : '0');
    bool available  = data?['available'] ?? true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Text(docId == null ? 'Nouvel article' : 'Modifier l\'article',
                  style: GoogleFonts.inter(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              _dialogField(nameCtrl, 'Nom du plat *', Icons.fastfood_rounded),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: _dialogField(priceCtrl, 'Prix (FCFA) *',
                      Icons.payments_rounded, type: TextInputType.number),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _dialogField(stockCtrl, 'Stock (0=illimité)',
                      Icons.warehouse_outlined, type: TextInputType.number),
                ),
              ]),
              const SizedBox(height: 12),
              _dialogField(
                  descCtrl, 'Description (optionnel)', Icons.notes_rounded),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('Disponible',
                      style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
                  const Spacer(),
                  Switch(
                    value: available,
                    onChanged: (v) => setS(() => available = v),
                    activeThumbColor: const Color(0xFF1565C0),
                    activeTrackColor: const Color(0x331565C0),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (docId != null)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await FirebaseFirestore.instance
                              .collection('restaurants')
                              .doc(restaurantId)
                              .collection('menu')
                              .doc(docId)
                              .delete();
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.red),
                        label: Text('Supprimer',
                            style: GoogleFonts.inter(color: Colors.red)),
                        style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.red)),
                      ),
                    ),
                  if (docId != null) const SizedBox(width: 12),
                  Expanded(
                    child: ScaleButton(
                      onPressed: () async {
                        final name = nameCtrl.text.trim();
                        final price =
                            double.tryParse(priceCtrl.text.trim()) ?? 0;
                        final stock = int.tryParse(stockCtrl.text.trim()) ?? 0;
                        if (name.isEmpty || price <= 0) return;

                        final payload = {
                          'name': name,
                          'price': price,
                          'description': descCtrl.text.trim(),
                          'stock': stock,
                          'available': available && (stock == 0 || stock > 0),
                          'createdAt': FieldValue.serverTimestamp(),
                        };

                        final menuRef = FirebaseFirestore.instance
                            .collection('restaurants')
                            .doc(restaurantId)
                            .collection('menu');

                        if (docId == null) {
                          await menuRef.add(payload);
                        } else {
                          await menuRef.doc(docId).update(payload);
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text('Enregistrer',
                          style: GoogleFonts.inter(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dialogField(TextEditingController ctrl, String label, IconData icon,
      {TextInputType? type}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: const Color(0xFF1565C0)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF1565C0), width: 2),
        ),
        filled: true,
        fillColor: const Color(0xFFF5F5F5),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _MenuItemCard extends StatelessWidget {
  final String docId;
  final String restaurantId;
  final Map<String, dynamic> data;
  final VoidCallback onEdit;

  const _MenuItemCard({
    required this.docId,
    required this.restaurantId,
    required this.data,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final available = data['available'] ?? true;
    final price = (data['price'] as num? ?? 0).toInt();
    final stock = (data['stock'] as num? ?? 0).toInt();

    Color? stockColor;
    String? stockLabel;
    if (stock > 0 && stock <= 5) {
      stockColor = Colors.orange;
      stockLabel = 'Stock: $stock';
    } else if (stock == 0 && data.containsKey('stock')) {
      // 0 = unlimited (field present but zero means unlimited)
      stockColor = null;
      stockLabel = null;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: available
                ? const Color(0xFF1565C0).withValues(alpha: 0.1)
                : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.fastfood_rounded,
            color: available
                ? const Color(0xFF1565C0)
                : Colors.grey.shade400,
          ),
        ),
        title: Text(
          data['name'] ?? '',
          style: GoogleFonts.inter(
              fontWeight: FontWeight.w600,
              color: available ? Colors.black87 : Colors.grey),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (data['description'] != null &&
                (data['description'] as String).isNotEmpty)
              Text(data['description'],
                  style: GoogleFonts.inter(
                      fontSize: 11, color: Colors.grey.shade500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            if (stockLabel != null)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: stockColor!.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(stockLabel,
                    style: TextStyle(
                        color: stockColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w600)),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$price F',
                style: GoogleFonts.inter(
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1565C0),
                    fontSize: 14)),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onEdit,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.edit_rounded,
                    size: 18, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ORDERS TAB
// ─────────────────────────────────────────────────────────────────────────────

class _OrdersTab extends StatelessWidget {
  final String restaurantId;
  const _OrdersTab({required this.restaurantId});

  static const _statusColors = {
    'pending':    Color(0xFFFF8F00),
    'preparing':  Color(0xFF1565C0),
    'ready':      Color(0xFF2E7D32),
    'delivering': Color(0xFFFF5A3C),
    'delivered':  Color(0xFF2E7D32),
    'cancelled':  Color(0xFFC62828),
  };

  static const _statusLabels = {
    'pending':    'En attente',
    'preparing':  'En préparation',
    'ready':      'Prêt',
    'delivering': 'En livraison',
    'delivered':  'Livré',
    'cancelled':  'Annulé',
  };

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('orders')
          .where('sellerId', isEqualTo: restaurantId)
          .where('sellerType', isEqualTo: 'restaurant')
          .orderBy('createdAt', descending: true)
          .limit(30)
          .snapshots(),
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
                Icon(Icons.receipt_long_rounded,
                    size: 64, color: Colors.grey.shade300),
                const SizedBox(height: 12),
                Text('Aucune commande pour l\'instant',
                    style: GoogleFonts.inter(color: Colors.grey)),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final d = docs[i].data() as Map<String, dynamic>;
            final status = d['status'] as String? ?? 'pending';
            final color = _statusColors[status] ?? Colors.grey;
            final label = _statusLabels[status] ?? status;
            final amount = (d['budget'] as num? ?? 0).toInt();
            final ts = d['createdAt'] as Timestamp?;
            final time = ts != null
                ? _formatTime(ts.toDate())
                : '';

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.receipt_rounded, color: color, size: 22),
                ),
                title: Text(
                  d['description'] ?? 'Commande',
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.w600, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(time,
                    style: GoogleFonts.inter(
                        fontSize: 11, color: Colors.grey.shade400)),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('$amount F',
                        style: GoogleFonts.inter(
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF1565C0),
                            fontSize: 14)),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(label,
                          style: TextStyle(
                              color: color,
                              fontSize: 10,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return 'Il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'Il y a ${diff.inHours}h';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WALLET BOTTOM SHEET
// ─────────────────────────────────────────────────────────────────────────────

class _WalletSheet extends StatelessWidget {
  final String restaurantId;
  final String name;
  final int wallet;

  const _WalletSheet({
    required this.restaurantId,
    required this.name,
    required this.wallet,
  });

  String _fmt(int v) {
    if (v >= 1000) return "${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}";
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          Text('${_fmt(wallet)} FCFA',
              style: GoogleFonts.inter(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: const Color(0xFF1565C0))),
          Text('Solde wallet restaurant',
              style: GoogleFonts.inter(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 50),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('Recharger'),
                onPressed: () {
                  Navigator.pop(context);
                  WalletActionSheet.show(
                    context,
                    action: WalletAction.recharge,
                    userId: restaurantId,
                    userType: 'restaurant',
                    userName: name,
                    currentBalance: wallet,
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 50),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.arrow_circle_up_outlined),
                label: const Text('Retirer'),
                onPressed: () {
                  Navigator.pop(context);
                  WalletActionSheet.show(
                    context,
                    action: WalletAction.withdraw,
                    userId: restaurantId,
                    userType: 'restaurant',
                    userName: name,
                    currentBalance: wallet,
                  );
                },
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESTAURANT ANALYTICS SHEET
// ─────────────────────────────────────────────────────────────────────────────

class _RestaurantAnalyticsSheet extends StatefulWidget {
  final String restaurantId;
  const _RestaurantAnalyticsSheet({required this.restaurantId});

  @override
  State<_RestaurantAnalyticsSheet> createState() =>
      _RestaurantAnalyticsSheetState();
}

class _RestaurantAnalyticsSheetState
    extends State<_RestaurantAnalyticsSheet> {
  bool _loading = true;
  List<double> _dailyRevenues = List.filled(7, 0);
  int _totalRevenue = 0;
  int _totalOrders = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final cutoff = Timestamp.fromDate(
        DateTime.now().subtract(const Duration(days: 7)));
    try {
      final snap = await FirebaseFirestore.instance
          .collection('orders')
          .where('sellerId', isEqualTo: widget.restaurantId)
          .where('sellerType', isEqualTo: 'restaurant')
          .where('status', isEqualTo: 'delivered')
          .where('createdAt', isGreaterThanOrEqualTo: cutoff)
          .get();

      final revenues = List<double>.filled(7, 0);
      int total = 0;
      final now = DateTime.now();

      for (final doc in snap.docs) {
        final data = doc.data();
        final ts = data['createdAt'] as Timestamp?;
        if (ts == null) continue;
        final date = ts.toDate();
        final daysAgo = DateTime(now.year, now.month, now.day)
            .difference(DateTime(date.year, date.month, date.day))
            .inDays;
        if (daysAgo >= 0 && daysAgo < 7) {
          final amount = (data['budget'] as num? ?? 0).toInt();
          revenues[6 - daysAgo] += amount;
          total += amount;
        }
      }

      if (mounted) {
        setState(() {
          _dailyRevenues = revenues;
          _totalRevenue = total;
          _totalOrders = snap.docs.length;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmt(int v) {
    if (v >= 1000) {
      return "${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}";
    }
    return v.toString();
  }

  List<String> _last7Days() {
    const days = ['Di', 'Lu', 'Ma', 'Me', 'Je', 'Ve', 'Sa'];
    final now = DateTime.now();
    return List.generate(7, (i) {
      final date = now.subtract(Duration(days: 6 - i));
      return days[date.weekday % 7];
    });
  }

  @override
  Widget build(BuildContext context) {
    final dayLabels = _last7Days();
    final maxRev =
        _dailyRevenues.fold<double>(0, (a, b) => a > b ? a : b);

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          Row(children: [
            const Icon(Icons.bar_chart_rounded, color: Color(0xFF1565C0)),
            const SizedBox(width: 8),
            Text('Statistiques — 7 derniers jours',
                style: GoogleFonts.inter(
                    fontSize: 15, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            )
          else ...[
            Row(children: [
              _RStatCard(
                label: 'Revenus',
                value: '${_fmt(_totalRevenue)} F',
                icon: Icons.payments_rounded,
                color: const Color(0xFF2E7D32),
              ),
              const SizedBox(width: 10),
              _RStatCard(
                label: 'Commandes',
                value: '$_totalOrders',
                icon: Icons.receipt_long_rounded,
                color: const Color(0xFF1565C0),
              ),
              const SizedBox(width: 10),
              _RStatCard(
                label: 'Moyenne',
                value: _totalOrders > 0
                    ? '${_fmt(_totalRevenue ~/ _totalOrders)} F'
                    : '0 F',
                icon: Icons.trending_up_rounded,
                color: Colors.orange,
              ),
            ]),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Revenus par jour',
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: Colors.grey)),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 140,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(7, (i) {
                  final rev = _dailyRevenues[i];
                  final barH = maxRev > 0 ? (rev / maxRev) * 100 : 0.0;
                  return Expanded(
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 3),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (rev > 0)
                            Text(
                              rev >= 1000
                                  ? '${(rev / 1000).toStringAsFixed(0)}k'
                                  : '${rev.toInt()}',
                              style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF1565C0)),
                            ),
                          const SizedBox(height: 2),
                          AnimatedContainer(
                            duration:
                                Duration(milliseconds: 300 + i * 50),
                            height: barH.clamp(4.0, 100.0),
                            decoration: BoxDecoration(
                              color: rev > 0
                                  ? const Color(0xFF1565C0)
                                  : Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(dayLabels[i],
                              style: const TextStyle(
                                  fontSize: 9, color: Colors.grey)),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RStatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _RStatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(height: 6),
            Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
            Text(label,
                style: TextStyle(
                    color: color.withValues(alpha: 0.7), fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

