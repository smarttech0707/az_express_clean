import 'dart:async';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/order_model.dart';
import '../../services/firestore_service.dart';
import '../../services/notification_service.dart';
import '../../services/auth_service.dart';
import '../../widgets/wallet_action_sheet.dart';
import '../../widgets/partner_account_sheet.dart';
import '../../widgets/logout_confirm_dialog.dart';
import '../home/home_screen.dart';
import '../../theme/app_theme.dart';

class SellerDashboard extends StatefulWidget {
  final String sellerId;
  final Map<String, dynamic> sellerData;

  const SellerDashboard({
    super.key,
    required this.sellerId,
    required this.sellerData,
  });

  @override
  State<SellerDashboard> createState() => _SellerDashboardState();
}

class _SellerDashboardState extends State<SellerDashboard>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  int _wallet = 0;
  StreamSubscription? _walletSub;
  StreamSubscription<QuerySnapshot>? _orderSub;
  int _prevPendingCount = -1;
  String? _photoUrl;

  String get _sellerType => widget.sellerData['type'] ?? '';
  String get _sellerName => widget.sellerData['name'] ?? 'Vendeur';

  @override
  void initState() {
    super.initState();
    _photoUrl = widget.sellerData['photoUrl'] as String?;
    _tabCtrl = TabController(length: 4, vsync: this);
    NotificationService.registerTapHandler((type, orderId, status) {
      if (!mounted) return;
      if (type == 'new_seller_order') _tabCtrl.animateTo(0);
    });
    _walletSub = FirestoreService().sellerWallet(widget.sellerId).listen((v) {
      if (mounted) setState(() => _wallet = v);
    });

    _orderSub = FirebaseFirestore.instance
        .collection('orders')
        .where('sellerId', isEqualTo: widget.sellerId)
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
            Icon(Icons.notifications_active_rounded,
                color: Colors.orange, size: 28),
            SizedBox(width: 10),
            Text('Nouvelle commande !'),
          ],
        ),
        content: const Text('Une nouvelle commande vient d\'arriver.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _tabCtrl.animateTo(0);
            },
            child: const Text('Voir maintenant',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Color(0xFF1565C0))),
          ),
        ],
      ),
    );
  }

  String _fmtWallet(int v) {
    if (v >= 1000)
      return "${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}";
    return v.toString();
  }

  void _showWalletOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            Text(
              "${_fmtWallet(_wallet)} FCFA",
              style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1565C0)),
            ),
            const Text("Solde wallet",
                style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: _walletBtn(
                    context,
                    icon: Icons.add_circle_outline,
                    label: "Recharger",
                    color: const Color(0xFF2E7D32),
                    onTap: () {
                      Navigator.pop(context);
                      WalletActionSheet.show(
                        context,
                        action: WalletAction.recharge,
                        userId: widget.sellerId,
                        userType: 'seller',
                        userName: _sellerName,
                        currentBalance: _wallet,
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _walletBtn(
                    context,
                    icon: Icons.arrow_circle_up_outlined,
                    label: "Retirer",
                    color: const Color(0xFF1565C0),
                    onTap: () {
                      Navigator.pop(context);
                      WalletActionSheet.show(
                        context,
                        action: WalletAction.withdraw,
                        userId: widget.sellerId,
                        userType: 'seller',
                        userName: _sellerName,
                        currentBalance: _wallet,
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _walletBtn(BuildContext context,
      {required IconData icon,
      required String label,
      required Color color,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.bold, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  // Master Prompt 135 — _logout() affiche désormais une confirmation avant
  // d'appeler _doLogout(), qui porte l'intégralité de la logique déjà
  // existante et inchangée (signOut, redirection).
  void _logout() => showLogoutConfirmDialog(context, onConfirm: _doLogout);

  Future<void> _doLogout() async {
    AuthService().logAuthEvent('logout', 'seller');
    await FirebaseAuth.instance.signOut();
    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (_) {}
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_sellerName,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text(_sellerType,
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
        actions: [
          GestureDetector(
            onTap: () => _showWalletOptions(context),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  const Icon(Icons.account_balance_wallet,
                      size: 14, color: Colors.white),
                  const SizedBox(width: 4),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.3),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    child: Text(
                      "${_fmtWallet(_wallet)} FCFA",
                      key: ValueKey(_wallet),
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more,
                      size: 14, color: Colors.white70),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.bar_chart_rounded),
            tooltip: "Statistiques",
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => _AnalyticsSheet(sellerId: widget.sellerId),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: "Mon compte",
            onPressed: () => showPartnerAccountSheet(
              context,
              role: 'seller',
              roleLabel: 'Vendeur Marketplace',
              name: _sellerName,
              phone: widget.sellerData['phone'] as String?,
              onLogout: _logout,
              photoUrl: _photoUrl,
              photoStoragePath: 'seller_photos/${widget.sellerId}/profile.jpg',
              onPhotoUploaded: (url) async {
                await FirebaseFirestore.instance
                    .collection('sellers')
                    .doc(widget.sellerId)
                    .set({'photoUrl': url}, SetOptions(merge: true));
                if (mounted) setState(() => _photoUrl = url);
              },
              onPhotoDeleted: () async {
                await FirebaseFirestore.instance
                    .collection('sellers')
                    .doc(widget.sellerId)
                    .update({'photoUrl': FieldValue.delete()});
                if (mounted) setState(() => _photoUrl = null);
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            onPressed: _logout,
            tooltip: "Déconnexion",
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          labelStyle:
              const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          tabs: const [
            Tab(text: "Nouvelles"),
            Tab(text: "En cours"),
            Tab(text: "Livrées"),
            Tab(text: "Produits"),
          ],
        ),
      ),
      body: Column(
        children: [
          _SubscriptionBanner(sellerData: widget.sellerData),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                _OrdersTab(
                    sellerId: widget.sellerId,
                    sellerType: _sellerType,
                    statusFilter: const ['pending', 'assigned']),
                _OrdersTab(
                    sellerId: widget.sellerId,
                    sellerType: _sellerType,
                    statusFilter: const ['accepted', 'picked_up']),
                _OrdersTab(
                    sellerId: widget.sellerId,
                    sellerType: _sellerType,
                    statusFilter: const ['delivered']),
                _ProductsTab(sellerId: widget.sellerId),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── SUBSCRIPTION BANNER ──────────────────────────────────────

class _SubscriptionBanner extends StatelessWidget {
  final Map<String, dynamic> sellerData;
  const _SubscriptionBanner({required this.sellerData});

  @override
  Widget build(BuildContext context) {
    final subStatus = sellerData['subscriptionStatus'] as String? ?? 'active';
    final vipStatus = sellerData['vipStatus'] as String? ?? 'none';
    final vipExpiry = sellerData['vipExpiresAt'];

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
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
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
                      ? 'Compte VIP actif — Vos produits apparaissent en premier. Expire le ${_fmtDate(vipExpiry)}.'
                      : 'Compte VIP actif — Vos produits apparaissent en premier.',
                  style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
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

// ── ONGLET COMMANDES ─────────────────────────────────────────

class _OrdersTab extends StatelessWidget {
  final String sellerId;
  final String sellerType;
  final List<String> statusFilter;

  const _OrdersTab({
    required this.sellerId,
    required this.sellerType,
    required this.statusFilter,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<OrderModel>>(
      stream: FirestoreService().sellerOrders(sellerId, sellerType),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final all = snap.data ?? [];
        final orders =
            all.where((o) => statusFilter.contains(o.status)).toList();

        if (orders.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  statusFilter.contains('delivered')
                      ? Icons.check_circle_outline_rounded
                      : Icons.inbox_outlined,
                  size: 64,
                  color: Colors.grey.shade300,
                ),
                const SizedBox(height: 16),
                Text(
                  statusFilter.contains('delivered')
                      ? "Aucune livraison complétée"
                      : statusFilter.contains('accepted')
                          ? "Aucune commande en cours"
                          : "Aucune nouvelle commande",
                  style: const TextStyle(color: Colors.grey, fontSize: 15),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          physics: const BouncingScrollPhysics(),
          itemCount: orders.length,
          itemBuilder: (_, i) => _FadeSlideIn(
            delay: Duration(milliseconds: i * 60),
            child: _OrderCard(order: orders[i]),
          ),
        );
      },
    );
  }
}

// ── ONGLET PRODUITS ──────────────────────────────────────────

class _ProductsTab extends StatefulWidget {
  final String sellerId;
  const _ProductsTab({required this.sellerId});

  @override
  State<_ProductsTab> createState() => _ProductsTabState();
}

class _ProductsTabState extends State<_ProductsTab> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showProductDialog(context),
        backgroundColor: const Color(0xFF1565C0),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Ajouter', style: TextStyle(color: Colors.white)),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('boutique_products')
            .where('sellerId', isEqualTo: widget.sellerId)
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.inventory_2_outlined,
                      size: 64, color: Colors.grey),
                  SizedBox(height: 12),
                  Text('Aucun produit',
                      style: TextStyle(color: Colors.grey, fontSize: 15)),
                  SizedBox(height: 4),
                  Text('Appuyez sur + pour ajouter',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
            itemCount: docs.length,
            itemBuilder: (ctx, i) {
              final doc = docs[i];
              final data = doc.data() as Map<String, dynamic>;
              return _ProductCard(
                docId: doc.id,
                data: data,
                onEdit: () =>
                    _showProductDialog(ctx, docId: doc.id, existing: data),
              );
            },
          );
        },
      ),
    );
  }

  void _showProductDialog(BuildContext context,
      {String? docId, Map<String, dynamic>? existing}) {
    final nameCtrl = TextEditingController(text: existing?['name'] ?? '');
    final priceCtrl = TextEditingController(
        text: existing?['price'] != null ? '${existing!['price']}' : '');
    final descCtrl =
        TextEditingController(text: existing?['description'] ?? '');
    final stockCtrl = TextEditingController(
        text: existing?['stock'] != null ? '${existing!['stock']}' : '0');
    bool available = existing?['available'] ?? true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Text(docId == null ? 'Nouveau produit' : 'Modifier le produit',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              _pField(nameCtrl, 'Nom du produit *', Icons.inventory_2_outlined),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: _pField(
                      priceCtrl, 'Prix (FCFA) *', Icons.payments_outlined,
                      type: TextInputType.number),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _pField(stockCtrl, 'Stock', Icons.warehouse_outlined,
                      type: TextInputType.number),
                ),
              ]),
              const SizedBox(height: 10),
              _pField(descCtrl, 'Description (optionnel)', Icons.notes_rounded),
              const SizedBox(height: 10),
              Row(children: [
                const Text('Disponible',
                    style: TextStyle(fontWeight: FontWeight.w500)),
                const Spacer(),
                Switch(
                  value: available,
                  onChanged: (v) => setS(() => available = v),
                  activeThumbColor: const Color(0xFF1565C0),
                  activeTrackColor: const Color(0x331565C0),
                ),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                if (docId != null) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await FirebaseFirestore.instance
                            .collection('boutique_products')
                            .doc(docId)
                            .delete();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      label: const Text('Supprimer',
                          style: TextStyle(color: Colors.red)),
                      style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.red)),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: ScaleButton(
                    onPressed: () async {
                      final name = nameCtrl.text.trim();
                      final price = int.tryParse(priceCtrl.text.trim()) ?? 0;
                      final stock = int.tryParse(stockCtrl.text.trim()) ?? 0;
                      if (name.isEmpty || price <= 0) return;

                      final payload = <String, dynamic>{
                        'name': name,
                        'price': price,
                        'description': descCtrl.text.trim(),
                        'stock': stock,
                        'available': available && stock != 0,
                        'sellerId': widget.sellerId,
                        'updatedAt': FieldValue.serverTimestamp(),
                      };

                      final col = FirebaseFirestore.instance
                          .collection('boutique_products');
                      if (docId == null) {
                        payload['createdAt'] = FieldValue.serverTimestamp();
                        await col.add(payload);
                      } else {
                        await col.doc(docId).update(payload);
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Enregistrer',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pField(TextEditingController ctrl, String label, IconData icon,
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

// ── CARTE PRODUIT ─────────────────────────────────────────────

class _ProductCard extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> data;
  final VoidCallback onEdit;

  const _ProductCard(
      {required this.docId, required this.data, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final name = data['name'] ?? 'Produit';
    final price = (data['price'] as num? ?? 0).toInt();
    final stock = (data['stock'] as num? ?? 0).toInt();
    final available = data['available'] ?? true;

    Color stockColor;
    String stockLabel;
    if (stock == 0) {
      stockColor = Colors.red;
      stockLabel = 'Épuisé';
    } else if (stock <= 5) {
      stockColor = Colors.orange;
      stockLabel = 'Stock: $stock';
    } else {
      stockColor = Colors.green;
      stockLabel = 'Stock: $stock';
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
              offset: const Offset(0, 2)),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
            Icons.inventory_2_rounded,
            color: available ? const Color(0xFF1565C0) : Colors.grey.shade400,
          ),
        ),
        title: Text(name,
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: available ? Colors.black87 : Colors.grey)),
        subtitle: Row(children: [
          Text('$price FCFA',
              style: const TextStyle(
                  color: Color(0xFF1565C0),
                  fontWeight: FontWeight.w600,
                  fontSize: 12)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: stockColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(stockLabel,
                style: TextStyle(
                    color: stockColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ),
          if (!available) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('Indisponible',
                  style: TextStyle(fontSize: 10, color: Colors.grey)),
            ),
          ],
        ]),
        trailing: GestureDetector(
          onTap: onEdit,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.edit_rounded, size: 18, color: Colors.grey),
          ),
        ),
      ),
    );
  }
}

// ── ANALYTICS SHEET ───────────────────────────────────────────

class _AnalyticsSheet extends StatefulWidget {
  final String sellerId;
  const _AnalyticsSheet({required this.sellerId});

  @override
  State<_AnalyticsSheet> createState() => _AnalyticsSheetState();
}

class _AnalyticsSheetState extends State<_AnalyticsSheet> {
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
    final cutoff =
        Timestamp.fromDate(DateTime.now().subtract(const Duration(days: 7)));
    try {
      final snap = await FirebaseFirestore.instance
          .collection('boutique_orders')
          .where('sellerId', isEqualTo: widget.sellerId)
          .where('status', whereIn: ['paid', 'delivered'])
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
          final amount = (data['totalPrice'] as num? ?? 0).toInt();
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
    if (v >= 1000)
      return "${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}";
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
    final maxRev = _dailyRevenues.fold<double>(0, (a, b) => a > b ? a : b);

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
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const Row(children: [
            Icon(Icons.bar_chart_rounded, color: Color(0xFF1565C0)),
            SizedBox(width: 8),
            Text('Statistiques — 7 derniers jours',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            )
          else ...[
            Row(children: [
              _StatCard(
                label: 'Revenus',
                value: '${_fmt(_totalRevenue)} F',
                icon: Icons.payments_rounded,
                color: const Color(0xFF2E7D32),
              ),
              const SizedBox(width: 10),
              _StatCard(
                label: 'Commandes',
                value: '$_totalOrders',
                icon: Icons.receipt_long_rounded,
                color: const Color(0xFF1565C0),
              ),
              const SizedBox(width: 10),
              _StatCard(
                label: 'Moyenne',
                value: _totalOrders > 0
                    ? '${_fmt(_totalRevenue ~/ _totalOrders)} F'
                    : '0 F',
                icon: Icons.trending_up_rounded,
                color: Colors.orange,
              ),
            ]),
            const SizedBox(height: 20),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Revenus par jour',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
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
                      padding: const EdgeInsets.symmetric(horizontal: 3),
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
                            duration: Duration(milliseconds: 300 + i * 50),
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

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
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
                    color: color, fontSize: 12, fontWeight: FontWeight.bold)),
            Text(label,
                style: TextStyle(
                    color: color.withValues(alpha: 0.7), fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// ── CARTE COMMANDE ───────────────────────────────────────────

class _OrderCard extends StatelessWidget {
  final OrderModel order;
  const _OrderCard({required this.order});

  Color get _statusColor {
    switch (order.status) {
      case 'pending':
        return Colors.orange;
      case 'assigned':
        return const Color(0xFF1565C0);
      case 'accepted':
        return Colors.teal;
      case 'picked_up':
        return Colors.deepPurple;
      case 'delivered':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  String get _statusLabel {
    switch (order.status) {
      case 'pending':
        return 'En attente de livreur';
      case 'assigned':
        return 'Livreur assigné';
      case 'accepted':
        return 'Livreur en route';
      case 'picked_up':
        return 'Commande récupérée';
      case 'delivered':
        return 'Livré ✓';
      default:
        return order.status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasDriver = order.driverId != null && order.driverId!.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: _statusColor.withValues(alpha: 0.1),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(18)),
            ),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _statusLabel,
                  style: TextStyle(
                    color: _statusColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                Text(
                  "#${order.id.substring(0, order.id.length.clamp(0, 8)).toUpperCase()}",
                  style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 11,
                      fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.description,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  "${order.budget} FCFA — ${order.paymentMethod == 'wallet' ? '💳 Wallet' : '💵 Espèces'}",
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
                const Divider(height: 20),
                _InfoSection(
                  icon: Icons.person_rounded,
                  color: AppColors.primary,
                  title: "Client",
                  lines: [
                    order.clientName ?? "Nom non renseigné",
                    if (order.clientPhone != null) order.clientPhone!,
                  ],
                  phone: order.clientPhone,
                  lat: order.latitude != 0 ? order.latitude : null,
                  lng: order.longitude != 0 ? order.longitude : null,
                ),
                const SizedBox(height: 12),
                if (hasDriver)
                  _DriverSection(driverId: order.driverId!)
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.hourglass_empty_rounded,
                            color: Colors.orange, size: 16),
                        const SizedBox(width: 8),
                        Text(
                          "Recherche d'un livreur disponible…",
                          style: TextStyle(
                              color: Colors.orange.shade700, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── SECTION INFO CLIENT ──────────────────────────────────────

class _InfoSection extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final List<String> lines;
  final String? phone;
  final double? lat;
  final double? lng;

  const _InfoSection({
    required this.icon,
    required this.color,
    required this.title,
    required this.lines,
    this.phone,
    this.lat,
    this.lng,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5)),
                const SizedBox(height: 3),
                ...lines.map((l) => Text(l,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600))),
                if (lat != null && lng != null) ...[
                  const SizedBox(height: 4),
                  GestureDetector(
                    onTap: () async {
                      final uri =
                          Uri.parse('https://maps.google.com/?q=$lat,$lng');
                      if (await canLaunchUrl(uri)) launchUrl(uri);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.map_rounded, size: 12, color: color),
                          const SizedBox(width: 4),
                          Text("Voir sur la carte",
                              style: TextStyle(
                                  fontSize: 11,
                                  color: color,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (phone != null)
            IconButton(
              onPressed: () async {
                final uri = Uri.parse('tel:$phone');
                if (await canLaunchUrl(uri)) launchUrl(uri);
              },
              icon: Icon(Icons.phone_rounded, color: color, size: 20),
              tooltip: "Appeler",
            ),
        ],
      ),
    );
  }
}

// ── SECTION LIVREUR ──────────────────────────────────────────

class _DriverSection extends StatelessWidget {
  final String driverId;
  const _DriverSection({required this.driverId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('livreurs')
          .doc(driverId)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const SizedBox(
              height: 48,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final data = snap.data!.data() as Map<String, dynamic>?;
        if (data == null) return const SizedBox.shrink();

        final name = data['name'] ?? 'Livreur';
        final phone = data['phone'] as String?;
        final lat = (data['lat'] as num?)?.toDouble();
        final lng = (data['lng'] as num?)?.toDouble();
        final isOnline = data['isOnline'] ?? false;

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1565C0).withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: const Color(0xFF1565C0).withValues(alpha: 0.15)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1565C0).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.delivery_dining_rounded,
                        color: Color(0xFF1565C0), size: 20),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: isOnline ? Colors.green : Colors.grey,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Livreur",
                        style: TextStyle(
                            color: Color(0xFF1565C0),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5)),
                    const SizedBox(height: 3),
                    Text(name,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    if (phone != null)
                      Text(phone,
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 12)),
                    if (lat != null && lng != null && lat != 0) ...[
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: () async {
                          final uri =
                              Uri.parse('https://maps.google.com/?q=$lat,$lng');
                          if (await canLaunchUrl(uri)) launchUrl(uri);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF1565C0).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.gps_fixed_rounded,
                                  size: 12, color: Color(0xFF1565C0)),
                              const SizedBox(width: 4),
                              Text(
                                isOnline
                                    ? "Position en direct"
                                    : "Dernière position",
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF1565C0),
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (phone != null)
                IconButton(
                  onPressed: () async {
                    final uri = Uri.parse('tel:$phone');
                    if (await canLaunchUrl(uri)) launchUrl(uri);
                  },
                  icon: const Icon(Icons.phone_rounded,
                      color: Color(0xFF1565C0), size: 20),
                  tooltip: "Appeler le livreur",
                ),
            ],
          ),
        );
      },
    );
  }
}

// ── ANIMATION FADE + SLIDE ───────────────────────────────────

class _FadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  const _FadeSlideIn({required this.child, this.delay = Duration.zero});

  @override
  State<_FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<_FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    Future.delayed(widget.delay, () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _fade,
        child: SlideTransition(position: _slide, child: widget.child),
      );
}
