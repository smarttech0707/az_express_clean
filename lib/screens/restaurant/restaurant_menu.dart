import 'dart:async';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../../models/order_model.dart';
import '../../services/firestore_service.dart';
import '../../providers/active_city_provider.dart';

class RestaurantMenu extends StatefulWidget {
  final String restaurantId;
  final String restaurantName;

  const RestaurantMenu({
    super.key,
    required this.restaurantId,
    required this.restaurantName,
  });

  @override
  State<RestaurantMenu> createState() => _RestaurantMenuState();
}

class _RestaurantMenuState extends State<RestaurantMenu> {
  final Map<String, int> _cart = {};
  final Map<String, Map<String, dynamic>> _cartData = {};
  bool _ordering = false;
  String _paymentMethod = 'cash';
  int _walletBalance = 0;
  StreamSubscription? _walletSub;

  int get _totalItems => _cart.values.fold(0, (a, b) => a + b);
  int get _totalPrice => _cartData.entries
      .map((e) => (e.value["price"] as num? ?? 0).toInt() * (_cart[e.key] ?? 0))
      .fold(0, (a, b) => a + b);

  @override
  void initState() {
    super.initState();
    _listenWallet();
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

  @override
  void dispose() {
    _walletSub?.cancel();
    super.dispose();
  }

  void _increment(String id, String name, int price) {
    setState(() {
      _cart[id] = (_cart[id] ?? 0) + 1;
      _cartData[id] = {"name": name, "price": price};
    });
  }

  void _decrement(String id) {
    setState(() {
      if ((_cart[id] ?? 0) > 1) {
        _cart[id] = _cart[id]! - 1;
      } else {
        _cart.remove(id);
        _cartData.remove(id);
      }
    });
  }

  Future<void> _order() async {
    if (_cart.isEmpty) return;

    // Minimum 500 FCFA (frais de livraison inclus)
    if (_totalPrice < 500) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Commande minimum 500 FCFA'),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    if (_paymentMethod == 'wallet' && _walletBalance < _totalPrice) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            "Solde insuffisant. Vous avez $_walletBalance FCFA, il faut $_totalPrice FCFA"),
        backgroundColor: Colors.red,
      ));
      return;
    }

    setState(() => _ordering = true);

    try {
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
      final uid = FirebaseAuth.instance.currentUser!.uid;

      final description = _cartData.entries
          .map((e) =>
              "${_cart[e.key]}x ${e.value['name']} (${(e.value['price'] as num? ?? 0).toInt() * (_cart[e.key] ?? 0)} FCFA)")
          .join(", ");

      final id = const Uuid().v4();
      final restaurantDoc = await FirebaseFirestore.instance
          .collection('restaurants')
          .doc(widget.restaurantId)
          .get();
      final restaurantData = restaurantDoc.data();
      final pickupLat = (restaurantData?['lat'] as num?)?.toDouble();
      final pickupLng = (restaurantData?['lng'] as num?)?.toDouble();
      if (pickupLat == null ||
          pickupLng == null ||
          (pickupLat == 0 && pickupLng == 0)) {
        throw StateError(
          'Les coordonnées du restaurant ne sont pas renseignées. '
          'La commande ne peut pas être envoyée.',
        );
      }
      final clientPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      if (!mounted) return;
      final cityProvider = context.read<ActiveCityProvider>();
      final cityService = cityProvider.service;
      final geography = await cityService.resolveDispatchGeography(
        pickupLatitude: pickupLat,
        pickupLongitude: pickupLng,
        deliveryLatitude: clientPosition.latitude,
        deliveryLongitude: clientPosition.longitude,
      );
      final order = OrderModel(
        id: id,
        description: "🍽️ ${widget.restaurantName} : $description",
        budget: _totalPrice,
        status: "pending",
        latitude: pickupLat,
        longitude: pickupLng,
        destLat: clientPosition.latitude,
        destLng: clientPosition.longitude,
        deliveryAddress: 'Ma position actuelle',
        type: "restaurant",
        clientId: uid,
        sellerId: widget.restaurantId,
        sellerName: widget.restaurantName,
        sellerType: "restaurant",
        paymentMethod: _paymentMethod,
        isPaid: _paymentMethod == 'wallet',
        pickupCityId: geography.pickupCityId,
        pickupZoneId: geography.pickupZoneId,
        deliveryCityId: geography.deliveryCityId,
        deliveryZoneId: geography.deliveryZoneId,
        pickupCoordinateSource: 'local_place',
        deliveryCoordinateSource: 'gps',
        gpsDetectedCityId: cityService.gpsDetectedCityId,
        activeCityId: cityService.activeCityId,
        citySelectionSource: cityService.citySelectionSource,
        cityResolutionStatus: geography.cityResolutionStatus,
      );

      if (_paymentMethod == 'wallet') {
        final clientRef =
            FirebaseFirestore.instance.collection('clients').doc(uid);
        final orderRef =
            FirebaseFirestore.instance.collection('orders').doc(id);

        // Le restaurant est crédité plus tard par deliverOrderCF (côté
        // serveur, quand le livreur marque la commande livrée) — pas ici.
        // Le créditer directement échouait déjà systématiquement
        // (`restaurants/{id}` n'autorise l'écriture qu'aux admins), donc le
        // paiement wallet restaurant ne fonctionnait pas du tout avant ce
        // correctif (Master Prompt 46).
        await FirebaseFirestore.instance.runTransaction((tx) async {
          final snap = await tx.get(clientRef);
          final wallet = (snap.data()?['wallet'] as num? ?? 0).toInt();
          if (wallet < _totalPrice) throw Exception('SOLDE_INSUFFISANT');
          tx.update(clientRef, {'wallet': wallet - _totalPrice});
          tx.set(orderRef, order.toMap());
        });

        // Log client wallet transaction
        await FirebaseFirestore.instance
            .collection('clients')
            .doc(uid)
            .collection('wallet_transactions')
            .add({
          'type': 'purchase',
          'amount': _totalPrice,
          'description': 'Commande ${widget.restaurantName} (wallet)',
          'orderId': id,
          'createdAt': Timestamp.now(),
        });
      } else {
        await FirestoreService().createOrder(order);
      }

      if (!mounted) return;
      setState(() => _ordering = false);

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green, size: 28),
              SizedBox(width: 10),
              Text("Commande envoyée"),
            ],
          ),
          content: Text(
            "Votre commande chez ${widget.restaurantName} a été envoyée.\n\n"
            "Total : $_totalPrice FCFA\n\n"
            "Un livreur va bientôt prendre en charge votre commande.",
            style: const TextStyle(fontSize: 14),
          ),
          actions: [
            ScaleButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              child: const Text("OK"),
            ),
          ],
        ),
      );

      setState(() => _cart.clear());
    } catch (e) {
      if (!mounted) return;
      setState(() => _ordering = false);
      final msg = e.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg.contains('SOLDE_INSUFFISANT')
              ? "Solde wallet insuffisant"
              : "Erreur : $e"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _paymentSelector() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 3))
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
                        ? const Color(0xFF1565C0)
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
                        ? const Color(0xFF1565C0)
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
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: CustomScrollView(
        slivers: [
          // ── HEADER ───────────────────────────────────────
          SliverAppBar(
            expandedHeight: 140,
            floating: false,
            pinned: true,
            backgroundColor: const Color(0xFF1565C0),
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF1565C0), Color(0xFF1E88E5)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 60, 20, 16),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.restaurant,
                              color: Colors.white, size: 26),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                widget.restaurantName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Text(
                                "Choisissez vos plats",
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: Text(widget.restaurantName,
                style: const TextStyle(color: Colors.white, fontSize: 18)),
            centerTitle: true,
          ),

          // ── MENU ITEMS ───────────────────────────────────
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection("restaurants")
                .doc(widget.restaurantId)
                .collection("menu")
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              final docs = snapshot.data?.docs ?? [];

              if (docs.isEmpty) {
                return SliverFillRemaining(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.no_food,
                          size: 72, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      const Text(
                        "Menu non disponible",
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                    ],
                  ),
                );
              }

              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final doc = docs[i];
                      final data = doc.data() as Map<String, dynamic>;
                      final name = data["name"] ?? "";
                      final price = (data["price"] as num? ?? 0).toInt();
                      final desc = data["description"] ?? "";
                      final imageUrl = data["imageUrl"] as String?;
                      final qty = _cart[doc.id] ?? 0;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Container(
                                  width: 64,
                                  height: 64,
                                  color: const Color(0xFF1565C0)
                                      .withValues(alpha: 0.1),
                                  child:
                                      (imageUrl != null && imageUrl.isNotEmpty)
                                          ? Image.network(
                                              imageUrl,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  const Icon(
                                                Icons.fastfood_rounded,
                                                color: Color(0xFF1565C0),
                                                size: 30,
                                              ),
                                            )
                                          : const Icon(
                                              Icons.fastfood_rounded,
                                              color: Color(0xFF1565C0),
                                              size: 30,
                                            ),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                    if (desc.isNotEmpty) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        desc,
                                        style: TextStyle(
                                          color: Colors.grey.shade600,
                                          fontSize: 12,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                    const SizedBox(height: 6),
                                    Text(
                                      "$price FCFA",
                                      style: const TextStyle(
                                        color: Color(0xFF1565C0),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (qty == 0)
                                GestureDetector(
                                  onTap: () => _increment(doc.id, name, price),
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1565C0),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Icon(Icons.add,
                                        color: Colors.white, size: 22),
                                  ),
                                )
                              else
                                Row(
                                  children: [
                                    GestureDetector(
                                      onTap: () => _decrement(doc.id),
                                      child: Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade200,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child:
                                            const Icon(Icons.remove, size: 18),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8),
                                      child: Text(
                                        "$qty",
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () =>
                                          _increment(doc.id, name, price),
                                      child: Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1565C0),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: const Icon(Icons.add,
                                            color: Colors.white, size: 18),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                    childCount: docs.length,
                  ),
                ),
              );
            },
          ),
        ],
      ),

      // ── BOTTOM BAR PANIER ────────────────────────────────
      bottomNavigationBar: _totalItems == 0
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Payment selector above cart bar
                _paymentSelector(),
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1565C0), Color(0xFF1E88E5)],
                    ),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF1565C0).withValues(alpha: 0.4),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: _ordering ? null : _order,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 16),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                "$_totalItems",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _paymentMethod == 'wallet'
                                    ? "Payer par Wallet"
                                    : "Commander",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            if (_ordering)
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2),
                              )
                            else
                              Text(
                                "$_totalPrice FCFA",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
