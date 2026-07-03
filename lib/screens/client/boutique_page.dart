import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';

import '../../l10n/app_text.dart';
import '../../services/firestore_service.dart';
import 'client_wallet_page.dart';

class BoutiquePage extends StatefulWidget {
  const BoutiquePage({super.key});

  @override
  State<BoutiquePage> createState() => _BoutiquePageState();
}

class _BoutiquePageState extends State<BoutiquePage>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  String _selectedCategory = "Tout";
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _checkAutoRefunds();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  // ── REMBOURSEMENT AUTOMATIQUE 48H ─────────────────────────────
  // Délègue à `refundExpiredBoutiqueOrderCF` : l'ancienne version créditait
  // directement le wallet du client (et ne débitait jamais le vendeur, déjà
  // payé à l'achat) depuis une transaction Firestore lancée par le client —
  // la règle `clients/{id}` n'autorise le propriétaire qu'à DIMINUER son
  // propre solde (jamais l'augmenter) et `boutique_orders/{id}` n'autorise
  // l'écriture qu'aux admins : les deux écritures échouaient toujours
  // (`permission-denied`), avalé silencieusement par le catch ci-dessous —
  // ce remboursement automatique n'a donc jamais fonctionné en production
  // (Master Prompt 48 bis).
  Future<void> _checkAutoRefunds() async {
    if (_uid == null) return;
    final now = DateTime.now();
    try {
      final snap = await FirebaseFirestore.instance
          .collection("boutique_orders")
          .where("clientId", isEqualTo: _uid)
          .where("status", isEqualTo: "paid")
          .get();

      final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('refundExpiredBoutiqueOrderCF');
      for (final doc in snap.docs) {
        final data = doc.data();
        final deadline =
            (data["deliveryDeadline"] as Timestamp?)?.toDate();
        if (deadline != null && now.isAfter(deadline)) {
          try {
            await fn.call(<String, dynamic>{'orderId': doc.id});
          } catch (_) {
            // Best-effort — un échec ici sera retenté à la prochaine
            // ouverture de cet écran, comme avant.
          }
        }
      }
    } catch (_) {}
  }

  // ── ACHAT ─────────────────────────────────────────────────────
  // Paiement wallet : délègue entièrement au Cloud Function
  // `payBoutiqueOrderCF` (débit client + crédit vendeur + décrément stock +
  // création de la commande + course de livraison, tout atomique côté
  // serveur). Auparavant, le crédit du vendeur (FirestoreService.
  // creditSellerWallet) était une écriture Firestore directe depuis ce client
  // — la règle `sellers/{id}` n'autorisant que l'admin ou le propriétaire à
  // wallet inchangé, cette écriture échouait toujours (`permission-denied`)
  // alors que le débit client et la commande avaient déjà réussi juste
  // avant : paiement partiel silencieux en production, corrigé ici.
  Future<void> _buyProduct(
      Map<String, dynamic> product, int qty, String payMethod) async {
    if (_uid == null) return;

    // Stock check (raccourci UX — le serveur revalide de façon autoritaire).
    if ((product["stock"] as int? ?? 0) < qty) {
      _snack(context.tr('insufficient_stock'), Colors.red);
      return;
    }

    if (payMethod == 'wallet') {
      try {
        double clientLat = 0, clientLng = 0;
        try {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 5),
            ),
          );
          clientLat = pos.latitude;
          clientLng = pos.longitude;
        } catch (_) {}

        final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
            .httpsCallable('payBoutiqueOrderCF');
        await fn.call(<String, dynamic>{
          'productId': product["id"],
          'qty': qty,
          'deliveryLat': clientLat,
          'deliveryLng': clientLng,
        });

        if (!mounted) return;
        Navigator.pop(context);
        _snack(context.tr('order_confirmed'), Colors.green);
        _tabCtrl.animateTo(1);
      } catch (e) {
        final msg = e.toString();
        if (!mounted) return;
        if (msg.contains("STOCK_EPUISE")) {
          _snack(context.tr('out_of_stock_label'), Colors.red);
        } else if (msg.contains("SOLDE_INSUFFISANT")) {
          _snack(context.tr('insufficient_balance'), Colors.red);
        } else {
          _snack("${context.tr('error')} : $msg", Colors.red);
        }
      }
      return;
    }

    // ── Paiement cash à la livraison — délègue à `payBoutiqueOrderCashCF`
    // (Master Prompt 54). L'ancienne version décrémentait le stock via une
    // écriture directe PUIS tentait de créer `boutique_orders` avec un statut
    // qui violait la règle Firestore de création — cette dernière écriture
    // échouait donc systématiquement, laissant le stock décrémenté sans
    // aucune commande créée (trouvaille du Prompt 48 bis, corrigée ici). Le
    // CF fait les deux dans une seule transaction Firestore : soit le stock
    // ET la commande sont créés ensemble, soit ni l'un ni l'autre.
    try {
      double clientLat = 0, clientLng = 0;
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 5),
          ),
        );
        clientLat = pos.latitude;
        clientLng = pos.longitude;
      } catch (_) {}

      final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('payBoutiqueOrderCashCF');
      await fn.call(<String, dynamic>{
        'productId': product["id"],
        'qty': qty,
        'deliveryLat': clientLat,
        'deliveryLng': clientLng,
      });

      if (!mounted) return;
      Navigator.pop(context);
      _snack("Commande envoyée ! Paiement à la livraison", Colors.green);
      _tabCtrl.animateTo(1);
    } catch (e) {
      final msg = e.toString();
      if (!mounted) return;
      if (msg.contains("STOCK_EPUISE")) {
        _snack(context.tr('out_of_stock_label'), Colors.red);
      } else {
        _snack("${context.tr('error')} : $msg", Colors.red);
      }
    }
  }

  Future<void> _showProductDetail(Map<String, dynamic> product) async {
    // Vérifier si le COD est activé pour ce client
    bool codEnabled = true;
    int walletBalance = 0;
    if (_uid != null) {
      try {
        codEnabled = await FirestoreService().isClientCodEnabled(_uid!);
        final snap = await FirebaseFirestore.instance
            .collection("clients")
            .doc(_uid)
            .get();
        walletBalance = (snap.data()?["wallet"] ?? 0) as int;
      } catch (_) {}
    }

    if (!mounted) return;

    int qty = 1;
    String payMethod = 'wallet';
    bool buying = false; // anti double-tap — payBoutiqueOrderCF n'est pas idempotent

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final stock = product["stock"] as int? ?? 0;
          final total = (product["price"] as num? ?? 0).toInt() * qty;
          final hasWallet = walletBalance >= total;
          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 24,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF6D00).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.shopping_bag,
                          color: Color(0xFFFF6D00), size: 30),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(product["name"],
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 17)),
                          Text(product["category"] ?? "",
                              style: const TextStyle(
                                  color: Colors.grey, fontSize: 13)),
                          Text(
                            "${product['price']} ${ctx.tr('per_unit')}",
                            style: const TextStyle(
                                color: Color(0xFFFF6D00),
                                fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                if ((product["description"] ?? "").isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(product["description"],
                      style: const TextStyle(
                          color: Colors.black87, fontSize: 13, height: 1.5)),
                ],

                const SizedBox(height: 16),

                // Stock
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: stock > 0
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    stock > 0
                        ? ctx.tr('stock_label').replaceAll('{n}', '$stock')
                        : ctx.tr('out_of_stock_label'),
                    style: TextStyle(
                        color: stock > 0 ? Colors.green : Colors.red,
                        fontWeight: FontWeight.bold,
                        fontSize: 13),
                  ),
                ),

                const SizedBox(height: 16),

                // Quantité
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: qty > 1
                          ? () => setS(() => qty--)
                          : null,
                      icon: const Icon(Icons.remove_circle_outline),
                      color: const Color(0xFFFF6D00),
                      iconSize: 30,
                    ),
                    const SizedBox(width: 16),
                    Column(
                      children: [
                        Text("$qty",
                            style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.bold)),
                        Text(ctx.tr('qty_label'),
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      onPressed: qty < stock
                          ? () => setS(() => qty++)
                          : null,
                      icon: const Icon(Icons.add_circle_outline),
                      color: const Color(0xFFFF6D00),
                      iconSize: 30,
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                // Garantie 48h
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.shield_outlined,
                          size: 16, color: Colors.blue.shade700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          ctx.tr('auto_refund'),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.blueGrey),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Sélecteur de paiement
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(12, 10, 12, 6),
                        child: Text("Mode de paiement",
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                      // Option Wallet
                      _PayOption(
                        icon: Icons.account_balance_wallet_rounded,
                        title: "Payer par wallet",
                        subtitle: hasWallet
                            ? "Solde : $walletBalance FCFA"
                            : "Solde insuffisant ($walletBalance FCFA)",
                        color: hasWallet
                            ? const Color(0xFF1565C0)
                            : Colors.red,
                        selected: payMethod == 'wallet',
                        enabled: hasWallet,
                        onTap: hasWallet
                            ? () => setS(() => payMethod = 'wallet')
                            : null,
                      ),
                      const Divider(height: 1, indent: 12, endIndent: 12),
                      // Option Cash
                      _PayOption(
                        icon: Icons.money_rounded,
                        title: "Cash à la livraison",
                        subtitle: codEnabled
                            ? "Payer le livreur à la livraison"
                            : "Désactivé — 3 fausses commandes",
                        color: codEnabled
                            ? const Color(0xFF2E7D32)
                            : Colors.grey,
                        selected: payMethod == 'cash',
                        enabled: codEnabled,
                        onTap: codEnabled
                            ? () => setS(() => payMethod = 'cash')
                            : null,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ScaleButton(
                    onPressed: buying ||
                            stock == 0 ||
                            (payMethod == 'wallet' && !hasWallet) ||
                            (payMethod == 'cash' && !codEnabled)
                        ? null
                        : () async {
                            setS(() => buying = true);
                            await _buyProduct(product, qty, payMethod);
                            // Le sheet peut déjà être fermé (Navigator.pop sur
                            // le chemin wallet réussi) — ne pas rappeler setS
                            // dans ce cas (setState après dispose).
                            if (ctx.mounted) setS(() => buying = false);
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF6D00),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text(
                      payMethod == 'wallet'
                          ? ctx.tr('pay_btn').replaceAll('{amount}', '$total')
                          : "Commander (cash : $total FCFA)",
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverAppBar(
            expandedHeight: (MediaQuery.of(context).size.height * 0.22).clamp(160.0, 240.0),
            pinned: true,
            backgroundColor: const Color(0xFFFF6D00),
            foregroundColor: Colors.white,
            actions: [
              // Wallet button
              StreamBuilder<DocumentSnapshot>(
                stream: FirebaseFirestore.instance
                    .collection("clients")
                    .doc(_uid)
                    .snapshots(),
                builder: (context, snap) {
                  final wallet =
                      (snap.data?.data() as Map?)?["wallet"] ?? 0;
                  return GestureDetector(
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ClientWalletPage())),
                    child: Container(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.account_balance_wallet,
                              size: 14, color: Colors.white),
                          const SizedBox(width: 4),
                          Text("$wallet FCFA",
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFFE65100), Color(0xFFFF8F00)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 20, bottom: 48),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.storefront, color: Colors.white, size: 40),
                        const SizedBox(height: 10),
                        Text(context.tr('shop_title'),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: Text(context.tr('boutique')),
            centerTitle: true,
            bottom: TabBar(
              controller: _tabCtrl,
              indicatorColor: Colors.white,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              tabs: [
                Tab(icon: const Icon(Icons.grid_view, size: 18), text: context.tr('products_tab')),
                Tab(icon: const Icon(Icons.receipt_long, size: 18), text: context.tr('my_orders_tab')),
              ],
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabCtrl,
          children: [
            _ProductsTab(
              selectedCategory: _selectedCategory,
              onCategoryChanged: (c) =>
                  setState(() => _selectedCategory = c),
              onProductTap: _showProductDetail,
            ),
            _MyOrdersTab(
              uid: _uid,
              onRefund: (orderId, amount, name) async {
                await FirebaseFunctions.instanceFor(region: 'europe-west1')
                    .httpsCallable('refundExpiredBoutiqueOrderCF')
                    .call(<String, dynamic>{'orderId': orderId});
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── ONGLET PRODUITS ───────────────────────────────────────────────

class _ProductsTab extends StatelessWidget {
  final String selectedCategory;
  final ValueChanged<String> onCategoryChanged;
  final ValueChanged<Map<String, dynamic>> onProductTap;

  const _ProductsTab({
    required this.selectedCategory,
    required this.onCategoryChanged,
    required this.onProductTap,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection("boutique_products")
          .where("isAvailable", isEqualTo: true)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final allDocs = snap.data?.docs ?? [];
        if (allDocs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.storefront_outlined,
                    size: 64, color: Colors.grey),
                const SizedBox(height: 12),
                Text(context.tr('no_products'),
                    style: const TextStyle(color: Colors.grey, fontSize: 15)),
              ],
            ),
          );
        }

        // Filter out suspended sellers
        final activeDocs = allDocs.where((d) {
          final data = d.data() as Map<String, dynamic>;
          return data['sellerSubscriptionStatus'] != 'suspended';
        }).toList();

        // Sort: VIP first
        activeDocs.sort((a, b) {
          final aVip = (a.data() as Map)['sellerVipActive'] == true;
          final bVip = (b.data() as Map)['sellerVipActive'] == true;
          if (aVip && !bVip) return -1;
          if (!aVip && bVip) return 1;
          return 0;
        });

        // Catégories
        final categories = {"Tout"};
        for (final d in activeDocs) {
          categories.add(
              ((d.data() as Map)["category"] ?? "Autre") as String);
        }

        final filtered = selectedCategory == "Tout"
            ? activeDocs
            : activeDocs
                .where((d) =>
                    ((d.data() as Map)["category"]) ==
                    selectedCategory)
                .toList();

        return Column(
          children: [
            // Filtres catégories
            SizedBox(
              height: 50,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                children: categories
                    .map((cat) => GestureDetector(
                          onTap: () => onCategoryChanged(cat),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 6),
                            decoration: BoxDecoration(
                              color: selectedCategory == cat
                                  ? const Color(0xFFFF6D00)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: selectedCategory == cat
                                    ? const Color(0xFFFF6D00)
                                    : Colors.grey.shade300,
                              ),
                            ),
                            child: Text(
                              cat,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                color: selectedCategory == cat
                                    ? Colors.white
                                    : Colors.black87,
                              ),
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ),

            // Grille produits
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: MediaQuery.of(context).size.width > 900
                      ? 4
                      : MediaQuery.of(context).size.width > 600
                          ? 3
                          : 2,
                  mainAxisExtent: 230,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                ),
                itemCount: filtered.length,
                itemBuilder: (context, i) {
                  final data =
                      filtered[i].data() as Map<String, dynamic>;
                  data["id"] = filtered[i].id;
                  final stock = data["stock"] as int? ?? 0;
                  return GestureDetector(
                    onTap: () => onProductTap(data),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 8)
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Image placeholder with VIP badge
                          Stack(
                            children: [
                              ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(16)),
                                child: (data["imageUrl"] ?? "").isNotEmpty
                                    ? Image.network(
                                        data["imageUrl"],
                                        height: 120,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            _placeholder(),
                                      )
                                    : _placeholder(),
                              ),
                              if (data['sellerVipActive'] == true)
                                Positioned(
                                  top: 6, left: 6,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFFD700),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text('👑 VIP',
                                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.black87)),
                                  ),
                                ),
                            ],
                          ),

                          Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(data["name"],
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13)),
                                const SizedBox(height: 4),
                                Text("${data['price']} FCFA",
                                    style: const TextStyle(
                                        color: Color(0xFFFF6D00),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14)),
                                const SizedBox(height: 4),
                                Text(
                                  stock > 0
                                      ? "${context.tr('in_stock')} $stock"
                                      : context.tr('out_of_stock'),
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: stock > 0
                                          ? Colors.green
                                          : Colors.red),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _placeholder() => Container(
        height: 120,
        color: const Color(0xFFFF6D00).withValues(alpha: 0.08),
        child: const Center(
          child: Icon(Icons.shopping_bag_outlined,
              size: 40, color: Color(0xFFFF6D00)),
        ),
      );
}

// ── ONGLET MES COMMANDES ──────────────────────────────────────────

class _MyOrdersTab extends StatelessWidget {
  final String? uid;
  final Future<void> Function(String orderId, int amount, String name)
      onRefund;

  const _MyOrdersTab({required this.uid, required this.onRefund});

  @override
  Widget build(BuildContext context) {
    if (uid == null) {
      return Center(child: Text(context.tr('conn_required')));
    }
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection("boutique_orders")
          .where("clientId", isEqualTo: uid)
          .orderBy("createdAt", descending: true)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.receipt_long_outlined,
                    size: 56, color: Colors.grey),
                const SizedBox(height: 12),
                Text(context.tr('no_orders'),
                    style: const TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }
        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final data = docs[i].data() as Map<String, dynamic>;
            final status = data["status"] ?? "paid";
            final deadline =
                (data["deliveryDeadline"] as Timestamp?)?.toDate();
            final now = DateTime.now();
            final isExpired = deadline != null &&
                now.isAfter(deadline) &&
                status == "paid";

            Color statusColor;
            String statusLabel;
            IconData statusIcon;
            switch (status) {
              case "pending_payment":
                statusColor = Colors.deepOrange;
                statusLabel = "Cash à la livraison";
                statusIcon = Icons.money_rounded;
                break;
              case "paid":
                statusColor = Colors.orange;
                statusLabel = context.tr('status_pending');
                statusIcon = Icons.hourglass_top;
                break;
              case "preparing":
                statusColor = Colors.blue;
                statusLabel = context.tr('status_preparing');
                statusIcon = Icons.inventory;
                break;
              case "shipped":
                statusColor = const Color(0xFF1565C0);
                statusLabel = context.tr('status_shipping');
                statusIcon = Icons.local_shipping;
                break;
              case "delivered":
                statusColor = Colors.green;
                statusLabel = context.tr('status_delivered');
                statusIcon = Icons.check_circle;
                break;
              case "refunded":
                statusColor = Colors.purple;
                statusLabel = context.tr('status_refunded');
                statusIcon = Icons.refresh;
                break;
              default:
                statusColor = Colors.grey;
                statusLabel = status;
                statusIcon = Icons.circle;
            }

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: isExpired
                    ? Border.all(color: Colors.orange.shade300)
                    : null,
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 8)
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(data["productName"] ?? "—",
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(statusIcon,
                                  size: 12, color: statusColor),
                              const SizedBox(width: 4),
                              Text(statusLabel,
                                  style: TextStyle(
                                      color: statusColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "Qté : ${data['qty']}  •  ${data['totalPrice']} FCFA",
                      style: const TextStyle(
                          color: Colors.grey, fontSize: 13),
                    ),
                    if (deadline != null && status == "paid") ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            isExpired
                                ? Icons.warning_amber
                                : Icons.timer_outlined,
                            size: 14,
                            color: isExpired
                                ? Colors.red
                                : Colors.orange,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isExpired
                                ? context.tr('deadline_exceeded')
                                : context.tr('delivery_before').replaceAll('{date}', _fmt(deadline)),
                            style: TextStyle(
                                fontSize: 11,
                                color: isExpired
                                    ? Colors.red
                                    : Colors.orange),
                          ),
                        ],
                      ),
                    ],
                    if (status == "refunded")
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                            data["refundReason"] ?? context.tr('status_refunded'),
                            style: const TextStyle(
                                color: Colors.purple, fontSize: 11)),
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

  String _fmt(DateTime d) =>
      "${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} "
      "${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}";
}

// ── OPTION DE PAIEMENT (boutique) ─────────────────────────────

class _PayOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  const _PayOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.selected,
    required this.enabled,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: selected ? 0.18 : 0.08),
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
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: enabled ? Colors.black87 : Colors.grey)),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11,
                          color: enabled ? Colors.grey : Colors.red.shade300)),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle_rounded, color: color, size: 20),
          ],
        ),
      ),
    );
  }
}


