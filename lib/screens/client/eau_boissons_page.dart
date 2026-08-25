import 'dart:async';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

class EauBoissonsPage extends StatefulWidget {
  const EauBoissonsPage({super.key});

  @override
  State<EauBoissonsPage> createState() => _EauBoissonsPageState();
}

class _EauBoissonsPageState extends State<EauBoissonsPage> {
  final Map<String, int> _cart = {};
  final _addressCtrl = TextEditingController();
  bool _loading = false;
  String _paymentMethod = 'cash';
  int _walletBalance = 0;
  StreamSubscription? _walletSub;

  List<Map<String, dynamic>> _products = [];
  int _deliveryFee = 500;

  static final _catAssets = <String, List<dynamic>>{
    'Eau': [Icons.water_drop, const Color(0xFF0288D1)],
    'Sodas': [Icons.local_drink, const Color(0xFFD32F2F)],
    'Jus': [Icons.emoji_food_beverage, const Color(0xFFF57F17)],
    'Laitiers': [Icons.coffee, const Color(0xFF5D4037)],
    'Énergisants': [Icons.bolt, const Color(0xFFFFD600)],
  };

  static const _fallbackProducts = <Map<String, dynamic>>[
    {"id": "eau_500", "name": "Eau 500ml", "category": "Eau", "price": 200},
    {"id": "eau_1500", "name": "Eau 1.5L", "category": "Eau", "price": 400},
    {
      "id": "casier_eau",
      "name": "Casier d'eau (12×1.5L)",
      "category": "Eau",
      "price": 3500
    },
    {
      "id": "coca_33",
      "name": "Coca-Cola 33cl",
      "category": "Sodas",
      "price": 500
    },
    {"id": "fanta_33", "name": "Fanta 33cl", "category": "Sodas", "price": 500},
    {
      "id": "sprite_33",
      "name": "Sprite 33cl",
      "category": "Sodas",
      "price": 500
    },
    {
      "id": "jus_tropics",
      "name": "Jus de fruits 50cl",
      "category": "Jus",
      "price": 600
    },
    {
      "id": "lait_500",
      "name": "Lait 500ml",
      "category": "Laitiers",
      "price": 700
    },
    {
      "id": "energie",
      "name": "Boisson énergisante",
      "category": "Énergisants",
      "price": 800
    },
  ];

  Map<String, dynamic> _enrich(Map<String, dynamic> p) {
    final cat = p['category'] as String? ?? '';
    final assets =
        _catAssets[cat] ?? [Icons.shopping_bag, const Color(0xFF607D8B)];
    return {...p, 'icon': assets[0] as IconData, 'color': assets[1] as Color};
  }

  @override
  void initState() {
    super.initState();
    _products = _fallbackProducts.map(_enrich).toList();
    _listenWallet();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('eau_boissons')
          .get();
      if (!doc.exists || !mounted) return;
      final data = doc.data()!;
      setState(() {
        if (data['products'] is List) {
          _products = (data['products'] as List)
              .map((e) => _enrich(Map<String, dynamic>.from(e as Map)))
              .toList();
        }
        if (data['deliveryFee'] is num) {
          _deliveryFee = (data['deliveryFee'] as num).toInt();
        }
      });
    } catch (_) {}
  }

  void _listenWallet() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _walletSub = FirebaseFirestore.instance
        .collection('clients')
        .doc(uid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(
          () => _walletBalance = (snap.data()?['wallet'] as num? ?? 0).toInt());
    });
  }

  int get _totalPrice {
    int total = 0;
    for (final p in _products) {
      final qty = _cart[p["id"]] ?? 0;
      total += qty * (p["price"] as num? ?? 0).toInt();
    }
    return total;
  }

  int get _totalItems {
    return _cart.values.fold(0, (a, b) => a + b);
  }

  int get _totalToPay => _totalPrice + _deliveryFee;

  Future<void> _placeOrder() async {
    if (_totalItems == 0) {
      _snack("Ajoutez au moins un article au panier", Colors.red);
      return;
    }
    if (_addressCtrl.text.trim().isEmpty) {
      _snack("Veuillez entrer votre adresse de livraison", Colors.red);
      return;
    }
    if (_paymentMethod == 'wallet' && _walletBalance < _totalToPay) {
      _snack(
          "Solde insuffisant. Vous avez $_walletBalance FCFA, il faut $_totalToPay FCFA",
          Colors.red);
      return;
    }

    setState(() => _loading = true);
    try {
      var user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        await FirebaseAuth.instance.signInAnonymously();
        user = FirebaseAuth.instance.currentUser;
      }
      final uid = user!.uid;
      final id = const Uuid().v4();

      final items = <Map<String, dynamic>>[];
      final descParts = <String>[];
      for (final p in _products) {
        final qty = _cart[p["id"]] ?? 0;
        if (qty > 0) {
          items.add({
            "id": p["id"],
            "name": p["name"],
            "price": p["price"],
            "qty": qty,
            "subtotal": qty * (p["price"] as num? ?? 0).toInt(),
          });
          descParts.add("${p['name']} ×$qty");
        }
      }

      final orderData = {
        "id": id,
        "description":
            "Eau & Boissons :\n${descParts.join('\n')}\nAdresse : ${_addressCtrl.text.trim()}",
        "budget": 500,
        "shoppingBudget": _totalPrice,
        "status": "pending",
        "type": "eau_boissons",
        "items": items,
        "address": _addressCtrl.text.trim(),
        "latitude": 0,
        "longitude": 0,
        "clientId": uid,
        "paymentMethod": _paymentMethod,
        "isPaid": _paymentMethod == 'wallet',
        "createdAt": FieldValue.serverTimestamp(),
      };

      if (_paymentMethod == 'wallet') {
        final clientRef =
            FirebaseFirestore.instance.collection('clients').doc(uid);
        final orderRef =
            FirebaseFirestore.instance.collection('orders').doc(id);

        await FirebaseFirestore.instance.runTransaction((tx) async {
          final snap = await tx.get(clientRef);
          final wallet = (snap.data()?['wallet'] as num? ?? 0).toInt();
          if (wallet < _totalToPay) throw Exception('SOLDE_INSUFFISANT');
          tx.update(clientRef, {'wallet': wallet - _totalToPay});
          tx.set(orderRef, orderData);
        });

        // Log transaction client
        await FirebaseFirestore.instance
            .collection('clients')
            .doc(uid)
            .collection('wallet_transactions')
            .add({
          'type': 'purchase',
          'amount': _totalToPay,
          'description': 'Eau & Boissons (${descParts.join(', ')}) + livraison',
          'orderId': id,
          'createdAt': Timestamp.now(),
        });
      } else {
        await FirebaseFirestore.instance
            .collection("orders")
            .doc(id)
            .set(orderData);
      }

      if (mounted) {
        _snack("Commande passée ! Livraison en cours...", Colors.green);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
      }
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('SOLDE_INSUFFISANT')) {
        _snack("Solde wallet insuffisant", Colors.red);
      } else {
        _snack("Erreur : $e", Colors.red);
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  @override
  void dispose() {
    _walletSub?.cancel();
    _addressCtrl.dispose();
    super.dispose();
  }

  Widget _paymentSelector() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Mode de paiement",
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _paymentMethod = 'cash'),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: _paymentMethod == 'cash'
                        ? Colors.teal.shade700
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.money,
                            color: _paymentMethod == 'cash'
                                ? Colors.white
                                : Colors.grey,
                            size: 18),
                        const SizedBox(width: 6),
                        Text("Espèces",
                            style: TextStyle(
                                color: _paymentMethod == 'cash'
                                    ? Colors.white
                                    : Colors.grey,
                                fontWeight: FontWeight.bold)),
                      ]),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _paymentMethod = 'wallet'),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: _paymentMethod == 'wallet'
                        ? Colors.teal.shade700
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.account_balance_wallet,
                          color: _paymentMethod == 'wallet'
                              ? Colors.white
                              : Colors.grey,
                          size: 18),
                      const SizedBox(width: 6),
                      Text("Wallet",
                          style: TextStyle(
                              color: _paymentMethod == 'wallet'
                                  ? Colors.white
                                  : Colors.grey,
                              fontWeight: FontWeight.bold)),
                    ]),
                    Text("$_walletBalance FCFA",
                        style: TextStyle(
                            color: _paymentMethod == 'wallet'
                                ? Colors.white70
                                : Colors.grey.shade400,
                            fontSize: 11)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categories = <String>{};
    for (final p in _products) {
      categories.add(p["category"] as String);
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 150,
            pinned: true,
            backgroundColor: Colors.teal.shade700,
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.teal.shade800, Colors.teal.shade500],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const SafeArea(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(height: 40),
                      Icon(Icons.water_drop, color: Colors.white, size: 48),
                      SizedBox(height: 8),
                      Text("Eau & Boissons",
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                      Text("Livraison rapide à domicile",
                          style:
                              TextStyle(color: Colors.white70, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            ),
            title: const Text("Eau & Boissons"),
            centerTitle: true,
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── ADRESSE ─────────────────────────────────
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 8)
                      ],
                    ),
                    child: TextField(
                      controller: _addressCtrl,
                      decoration: InputDecoration(
                        hintText: "Adresse de livraison...",
                        prefixIcon: Icon(Icons.location_on,
                            color: Colors.teal.shade700),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // ── PAIEMENT ────────────────────────────────
                  _paymentSelector(),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // ── PRODUCTS BY CATEGORY ───────────────────────────
          for (final cat in categories) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(cat,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final catProducts =
                        _products.where((p) => p["category"] == cat).toList();
                    if (i >= catProducts.length) return null;
                    final p = catProducts[i];
                    final qty = _cart[p["id"]] ?? 0;
                    final color = p["color"] as Color;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 6)
                        ],
                      ),
                      child: ListTile(
                        leading: Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(p["icon"] as IconData,
                              color: color, size: 24),
                        ),
                        title: Text(p["name"],
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          "${p['price']} FCFA",
                          style: TextStyle(
                              color: Colors.teal.shade700,
                              fontWeight: FontWeight.bold),
                        ),
                        trailing: qty == 0
                            ? GestureDetector(
                                onTap: () => setState(() => _cart[p["id"]] = 1),
                                child: Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: Colors.teal.shade700,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(Icons.add,
                                      color: Colors.white, size: 22),
                                ),
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  GestureDetector(
                                    onTap: () => setState(() {
                                      if (qty == 1) {
                                        _cart.remove(p["id"]);
                                      } else {
                                        _cart[p["id"]] = qty - 1;
                                      }
                                    }),
                                    child: Container(
                                      width: 30,
                                      height: 30,
                                      decoration: BoxDecoration(
                                        color: Colors.grey.shade200,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Icon(Icons.remove, size: 18),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10),
                                    child: Text("$qty",
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16)),
                                  ),
                                  GestureDetector(
                                    onTap: () => setState(
                                        () => _cart[p["id"]] = qty + 1),
                                    child: Container(
                                      width: 30,
                                      height: 30,
                                      decoration: BoxDecoration(
                                        color: Colors.teal.shade700,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Icon(Icons.add,
                                          color: Colors.white, size: 18),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    );
                  },
                  childCount:
                      _products.where((p) => p["category"] == cat).length,
                ),
              ),
            ),
          ],

          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),

      // ── CART BAR ────────────────────────────────────────────
      bottomNavigationBar: _totalItems == 0
          ? null
          : Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              decoration: const BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                      color: Colors.black12,
                      blurRadius: 12,
                      offset: Offset(0, -3))
                ],
              ),
              child: ScaleButton(
                onPressed: _loading ? null : _placeOrder,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal.shade700,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                                "$_totalItems article${_totalItems > 1 ? 's' : ''}",
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold)),
                          ),
                          Text(
                            _paymentMethod == 'wallet'
                                ? "Payer par Wallet"
                                : "Commander",
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold),
                          ),
                          Text("$_totalToPay FCFA",
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
              ),
            ),
    );
  }
}
