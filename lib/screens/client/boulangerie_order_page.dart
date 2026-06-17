import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';

import '../../services/tarif_service.dart';
import '../../services/firestore_service.dart';

class BoulangerieOrderPage extends StatefulWidget {
  final String boulangerieId;
  final Map<String, dynamic> boulangerieData;

  const BoulangerieOrderPage({
    super.key,
    required this.boulangerieId,
    required this.boulangerieData,
  });

  @override
  State<BoulangerieOrderPage> createState() => _BoulangerieOrderPageState();
}

class _BoulangerieOrderPageState extends State<BoulangerieOrderPage> {
  // Panier : itemId → quantité
  final Map<String, int> _cart = {};
  // Cache des données menu
  final Map<String, Map<String, dynamic>> _itemData = {};

  String _paymentMethod = 'cash';
  String? _requestedTime;
  bool _placing = false;
  bool _loadingWallet = true;
  int _walletBalance = 0;
  bool _cashEnabled  = true;

  final _addressCtrl = TextEditingController();
  double? _lat;
  double? _lng;
  bool _gpsLoading = false;

  static const _timeSlots = [
    'Maintenant',
    '06:30', '07:00', '07:30', '08:00',
    '08:30', '09:00', '09:30', '10:00',
    '10:30', '11:00', '11:30', '12:00',
  ];

  @override
  void initState() {
    super.initState();
    _requestedTime = _timeSlots.first;
    _loadClientInfo();
    _getGPS();
  }

  @override
  void dispose() {
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadClientInfo() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('clients')
          .doc(uid)
          .get();
      if (doc.exists && mounted) {
        setState(() {
          _walletBalance =
              (doc.data()?['wallet'] as num?)?.toInt() ?? 0;
          _cashEnabled = doc.data()?['cashOnDeliveryEnabled'] ?? true;
          _loadingWallet = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingWallet = false);
    }
  }

  Future<void> _getGPS() async {
    setState(() => _gpsLoading = true);
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
      final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      if (mounted) {
        setState(() {
          _lat = pos.latitude;
          _lng = pos.longitude;
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _gpsLoading = false);
  }

  int get _itemsTotal {
    int total = 0;
    for (final entry in _cart.entries) {
      final price =
          (_itemData[entry.key]?['price'] as num?)?.toInt() ?? 0;
      total += price * entry.value;
    }
    return total;
  }

  double? get _distanceToClient {
    if (_lat == null || _lng == null) return null;
    final bLat = (widget.boulangerieData['lat'] as num?)?.toDouble();
    final bLng = (widget.boulangerieData['lng'] as num?)?.toDouble();
    if (bLat == null || bLng == null) return null;
    return TarifService.haversineKm(bLat, bLng, _lat!, _lng!);
  }

  int get _deliveryFee {
    if (_lat == null || _lng == null) return 500;
    return TarifService.compute(
      clientLat: _lat!,
      clientLng: _lng!,
      routeDistanceKm: _distanceToClient,
    ).standardPrice;
  }

  int get _totalAmount => _itemsTotal + _deliveryFee;
  int get _cartCount => _cart.values.fold(0, (a, b) => a + b);

  String _fmt(int amount) {
    final s = amount.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return '${buf.toString()} FCFA';
  }

  List<Map<String, dynamic>> get _cartItems {
    return _cart.entries
        .where((e) => e.value > 0)
        .map((e) => {
              'id':    e.key,
              'name':  _itemData[e.key]?['name'] ?? '—',
              'price': (_itemData[e.key]?['price'] as num?)?.toInt() ?? 0,
              'qty':   e.value,
            })
        .toList();
  }

  Future<void> _placeOrder() async {
    if (_cart.isEmpty || _itemsTotal == 0) {
      _snack('Sélectionnez au moins un article', Colors.orange);
      return;
    }

    final tarif = TarifService.compute(
      clientLat: _lat ?? TarifService.centerLat,
      clientLng: _lng ?? TarifService.centerLng,
      routeDistanceKm: _distanceToClient,
    );
    if (!tarif.canOrder) {
      _snack(tarif.rejectionMessage ?? 'Livraison non disponible', Colors.red);
      return;
    }

    if (_paymentMethod == 'wallet' && _walletBalance < _totalAmount) {
      _snack(
          'Solde insuffisant. Wallet : $_walletBalance FCFA — Nécessaire : $_totalAmount FCFA',
          Colors.red);
      return;
    }

    setState(() => _placing = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        _snack('Connexion requise', Colors.red);
        return;
      }

      final clientDoc = await FirebaseFirestore.instance
          .collection('clients')
          .doc(user.uid)
          .get();
      final clientName  = clientDoc.data()?['name']  ?? 'Client';
      final clientPhone = clientDoc.data()?['phone'] ?? '';

      final orderId = const Uuid().v4();
      final deliveryAddress = _addressCtrl.text.trim().isNotEmpty
          ? _addressCtrl.text.trim()
          : 'Position GPS';

      await FirebaseFirestore.instance.collection('orders').doc(orderId).set({
        'id':             orderId,
        'type':           'boulangerie',
        'sellerType':     'boulangerie',
        'sellerId':       widget.boulangerieId,
        'sellerName':     widget.boulangerieData['name'] ?? '',
        'clientId':       user.uid,
        'clientName':     clientName,
        'clientPhone':    clientPhone,
        'description':    deliveryAddress,
        'items':          _cartItems,
        'itemsAmount':    _itemsTotal,
        'budget':         _deliveryFee,
        'totalAmount':    _totalAmount,
        'paymentMethod':  _paymentMethod,
        'isPaid':         false,
        'status':         'pending',
        'sellerStatus':   null,
        'requestedTime':  _requestedTime == 'Maintenant'
            ? null
            : _requestedTime,
        'latitude':       _lat ?? 6.7273,
        'longitude':      _lng ?? -3.4961,
        'createdAt':      FieldValue.serverTimestamp(),
      });

      try {
        await FirestoreService().findNearestDriver(
          _lat ?? 6.7273, _lng ?? -3.4961, orderId, budget: _deliveryFee,
        );
      } catch (_) {}

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Row(children: [
          Icon(Icons.check_circle_rounded,
              color: Colors.white, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Commande envoyée ! La boulangerie va la préparer.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ]),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ));
    } catch (e) {
      _snack('Erreur : $e', Colors.red);
    } finally {
      if (mounted) setState(() => _placing = false);
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

  @override
  Widget build(BuildContext context) {
    final name = widget.boulangerieData['name'] ?? 'Boulangerie';
    const brown = Color(0xFF5D4037);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(name,
            style: GoogleFonts.inter(fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis),
        backgroundColor: brown,
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          if (_cartCount > 0)
            Stack(
              alignment: Alignment.topRight,
              children: [
                IconButton(
                  icon: const Icon(Icons.shopping_basket_rounded),
                  onPressed: _showOrderSummary,
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                    child: Center(
                      child: Text('$_cartCount',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 10)),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          // ── Adresse livraison ────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 8)
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Adresse
                        TextField(
                          controller: _addressCtrl,
                          decoration: InputDecoration(
                            labelText: 'Adresse de livraison',
                            hintText: 'Ex: Quartier Morofé, Rue 12',
                            prefixIcon: const Icon(Icons.location_on_outlined,
                                color: brown),
                            suffixIcon: _gpsLoading
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2)))
                                : IconButton(
                                    icon: const Icon(Icons.my_location_rounded,
                                        color: brown),
                                    onPressed: _getGPS,
                                    tooltip: 'Ma position',
                                  ),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12)),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: brown),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Heure souhaitée
                        const Row(children: [
                          Icon(Icons.schedule_rounded,
                              size: 16, color: brown),
                          SizedBox(width: 8),
                          Text('Heure souhaitée :',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                        ]),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 44,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _timeSlots.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 8),
                            itemBuilder: (context, i) {
                              final slot = _timeSlots[i];
                              final selected = _requestedTime == slot;
                              return GestureDetector(
                                onTap: () =>
                                    setState(() => _requestedTime = slot),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? brown
                                        : Colors.grey.shade100,
                                    borderRadius:
                                        BorderRadius.circular(20),
                                    border: Border.all(
                                        color: selected
                                            ? brown
                                            : Colors.grey.shade300),
                                  ),
                                  child: Text(slot,
                                      style: TextStyle(
                                          color: selected
                                              ? Colors.white
                                              : Colors.grey.shade700,
                                          fontSize: 12,
                                          fontWeight: selected
                                              ? FontWeight.bold
                                              : FontWeight.normal)),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
              ),
            ),
          ),

          // ── Bannière Gâteau d'anniversaire ──────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: GestureDetector(
                onTap: () => _showCustomCakeSheet(),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6D1B7B), Color(0xFFAD1457)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF6D1B7B).withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(children: [
                    const Text('🎂', style: TextStyle(fontSize: 38)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Gâteau d\'anniversaire',
                              style: GoogleFonts.inter(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15)),
                          Text('Commande personnalisée — décrivez votre gâteau',
                              style: GoogleFonts.inter(
                                  color: Colors.white70, fontSize: 11.5)),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('Commander',
                          style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ),
                  ]),
                ),
              ),
            ),
          ),

          // ── Menu par catégories ──────────────────────────────────
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('boulangeries')
                .doc(widget.boulangerieId)
                .collection('menu_items')
                .where('isAvailable', isEqualTo: true)
                .orderBy('category')
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const SliverToBoxAdapter(
                    child: Center(child: CircularProgressIndicator()));
              }
              final docs = snap.data?.docs ?? [];
              // Mettre à jour le cache des données
              for (final doc in docs) {
                _itemData[doc.id] = doc.data() as Map<String, dynamic>;
              }

              if (docs.isEmpty) {
                return const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(
                        child: Text('Aucun article disponible pour le moment.',
                            style: TextStyle(color: Colors.grey))),
                  ),
                );
              }

              // Grouper par catégorie
              final Map<String, List<DocumentSnapshot>> byCategory = {};
              for (final doc in docs) {
                final cat = (doc.data() as Map<String, dynamic>)['category']
                    as String? ?? 'Autres';
                byCategory.putIfAbsent(cat, () => []).add(doc);
              }

              final categories = byCategory.keys.toList()..sort();
              final widgets = <Widget>[];

              for (final cat in categories) {
                widgets.add(
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                    child: Row(children: [
                      Container(
                        width: 4,
                        height: 16,
                        decoration: BoxDecoration(
                          color: brown,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(cat,
                          style: GoogleFonts.inter(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: const Color(0xFF3E2723))),
                    ]),
                  ),
                );
                for (final doc in byCategory[cat]!) {
                  final d     = doc.data() as Map<String, dynamic>;
                  final itemId = doc.id;
                  final iName = d['name']        ?? '—';
                  final price = (d['price'] as num?)?.toInt() ?? 0;
                  final desc  = d['description'] as String?;
                  final qty   = _cart[itemId] ?? 0;

                  widgets.add(
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withValues(alpha: 0.04),
                                blurRadius: 6)
                          ],
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.fromLTRB(
                              14, 8, 10, 8),
                          leading: Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: Colors.brown.shade50,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Text(
                                _categoryEmoji(cat),
                                style: const TextStyle(fontSize: 22),
                              ),
                            ),
                          ),
                          title: Text(iName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (desc != null && desc.isNotEmpty)
                                Text(desc,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade500)),
                              Text('$price FCFA',
                                  style: TextStyle(
                                      color: Colors.brown.shade700,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13)),
                            ],
                          ),
                          trailing: qty == 0
                              ? GestureDetector(
                                  onTap: () => setState(
                                      () => _cart[itemId] = 1),
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: brown,
                                      borderRadius:
                                          BorderRadius.circular(10),
                                    ),
                                    child: const Icon(Icons.add_rounded,
                                        color: Colors.white, size: 22),
                                  ),
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _qtyBtn(Icons.remove_rounded,
                                        () => setState(() {
                                              if (qty <= 1) {
                                                _cart.remove(itemId);
                                              } else {
                                                _cart[itemId] = qty - 1;
                                              }
                                            })),
                                    SizedBox(
                                      width: 28,
                                      child: Text('$qty',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15)),
                                    ),
                                    _qtyBtn(Icons.add_rounded,
                                        () => setState(
                                            () => _cart[itemId] = qty + 1)),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  );
                }
                widgets.add(const SizedBox(height: 6));
              }

              return SliverList(
                delegate: SliverChildListDelegate(widgets),
              );
            },
          ),

          // ── Paiement ────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 8)
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Mode de paiement',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 10),
                    _PayChoice(
                      selected: _paymentMethod == 'wallet',
                      label: 'Wallet',
                      subtitle: _loadingWallet
                          ? 'Chargement...'
                          : 'Solde : $_walletBalance FCFA',
                      icon: Icons.account_balance_wallet_rounded,
                      color: Colors.green.shade700,
                      onTap: () =>
                          setState(() => _paymentMethod = 'wallet'),
                    ),
                    const SizedBox(height: 8),
                    _PayChoice(
                      selected: _paymentMethod == 'cash',
                      label: 'Cash à la livraison',
                      subtitle: _cashEnabled
                          ? 'Payer en espèces au livreur'
                          : 'Option non disponible pour votre compte',
                      icon: Icons.payments_outlined,
                      color: Colors.orange.shade700,
                      disabled: !_cashEnabled,
                      onTap: _cashEnabled
                          ? () => setState(() => _paymentMethod = 'cash')
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Espace bas pour le bouton flottant
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),

      // ── Récap + Bouton commander ─────────────────────────────────
      bottomNavigationBar: _cartCount == 0
          ? null
          : Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, -4))
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Row(children: [
                      const Icon(Icons.shopping_basket_rounded,
                          size: 14, color: Color(0xFF5D4037)),
                      const SizedBox(width: 6),
                      Text('$_cartCount article${_cartCount > 1 ? "s" : ""}',
                          style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade700)),
                    ]),
                    const Spacer(),
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('Articles : ${_fmt(_itemsTotal)}',
                              style: GoogleFonts.inter(
                                  fontSize: 12, color: Colors.grey.shade600)),
                          Text('Livraison : ${_fmt(_deliveryFee)}',
                              style: GoogleFonts.inter(
                                  fontSize: 12, color: Colors.grey.shade600)),
                          Text(_fmt(_totalAmount),
                              style: GoogleFonts.inter(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                  color: const Color(0xFF5D4037))),
                        ]),
                  ]),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _placing ? null : _placeOrder,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF5D4037),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      child: _placing
                          ? const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.delivery_dining_rounded,
                                    size: 20),
                                const SizedBox(width: 10),
                                Text('Commander — ${_fmt(_totalAmount)}',
                                    style: GoogleFonts.inter(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15)),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  void _showOrderSummary() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.receipt_long_rounded,
                  color: Color(0xFF5D4037), size: 20),
              const SizedBox(width: 10),
              Text('Récapitulatif',
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.bold, fontSize: 17)),
            ]),
            const SizedBox(height: 16),
            ..._cartItems.map((item) {
              final total = (item['price'] as int) * (item['qty'] as int);
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(children: [
                  Container(
                    width: 26, height: 26,
                    decoration: BoxDecoration(
                      color: const Color(0xFF5D4037).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Center(
                      child: Text('${item['qty']}',
                          style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF5D4037))),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text('${item['name']}',
                      style: GoogleFonts.inter(fontSize: 14))),
                  Text(_fmt(total),
                      style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
                ]),
              );
            }),
            Divider(color: Colors.grey.shade200, height: 20),
            Row(children: [
              const Icon(Icons.electric_bike_rounded,
                  size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Text('Livraison',
                  style: GoogleFonts.inter(
                      fontSize: 14, color: Colors.grey.shade700)),
              const Spacer(),
              Text(_fmt(_deliveryFee),
                  style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF5D4037).withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Text('Total',
                    style: GoogleFonts.inter(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                const Spacer(),
                Text(_fmt(_totalAmount),
                    style: GoogleFonts.inter(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: const Color(0xFF5D4037))),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _qtyBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.brown.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.brown.shade200),
          ),
          child: Icon(icon, size: 18, color: const Color(0xFF5D4037)),
        ),
      );

  String _categoryEmoji(String category) {
    switch (category.toLowerCase()) {
      case 'pains':         return '🍞';
      case 'viennoiseries': return '🥐';
      case 'gâteaux':       return '🎂';
      case 'boissons':      return '☕';
      case 'formules':      return '🍱';
      default:              return '🧁';
    }
  }

  // ── GÂTEAU PERSONNALISÉ ─────────────────────────────────────────────

  void _showCustomCakeSheet() {
    final descCtrl    = TextEditingController();
    final budgetCtrl  = TextEditingController();
    DateTime? deadline;
    String payMethod  = _cashEnabled ? 'cash' : 'wallet';
    bool placing      = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            child: SingleChildScrollView(
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
                          borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
                  Row(children: [
                    const Text('🎂', style: TextStyle(fontSize: 28)),
                    const SizedBox(width: 10),
                    Text('Gâteau d\'anniversaire',
                        style: GoogleFonts.inter(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 4),
                  Text('Décrivez votre gâteau, nous le préparons pour vous.',
                      style: GoogleFonts.inter(
                          fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 20),

                  // Description
                  TextField(
                    controller: descCtrl,
                    maxLines: 4,
                    decoration: InputDecoration(
                      labelText: 'Description du gâteau',
                      hintText: 'Ex: Gâteau chocolat 2 étages, prénom "Marie", fleurs en crème, 20 parts...',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: Color(0xFF6D1B7B), width: 2),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Budget
                  TextField(
                    controller: budgetCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Votre budget (FCFA)',
                      hintText: 'Ex: 15000',
                      prefixIcon: const Icon(Icons.payments_outlined,
                          color: Color(0xFF6D1B7B)),
                      suffixText: 'FCFA',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: Color(0xFF6D1B7B), width: 2),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Date de livraison
                  GestureDetector(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: DateTime.now().add(
                            const Duration(days: 1)),
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now()
                            .add(const Duration(days: 60)),
                        builder: (context, child) => Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: const ColorScheme.light(
                                primary: Color(0xFF6D1B7B)),
                          ),
                          child: child!,
                        ),
                      );
                      if (picked != null) setS(() => deadline = picked);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: deadline != null
                              ? const Color(0xFF6D1B7B)
                              : Colors.grey.shade400,
                        ),
                      ),
                      child: Row(children: [
                        const Icon(Icons.calendar_today_rounded,
                            color: Color(0xFF6D1B7B), size: 20),
                        const SizedBox(width: 10),
                        Text(
                          deadline == null
                              ? 'Date de livraison souhaitée'
                              : '${deadline!.day}/${deadline!.month}/${deadline!.year}',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: deadline == null
                                ? Colors.grey.shade600
                                : Colors.black87,
                          ),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Paiement
                  Text('Paiement',
                      style: GoogleFonts.inter(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 8),
                  Row(children: [
                    _PayChip(
                      label: 'Wallet',
                      icon: Icons.account_balance_wallet_rounded,
                      selected: payMethod == 'wallet',
                      onTap: () => setS(() => payMethod = 'wallet'),
                    ),
                    const SizedBox(width: 10),
                    _PayChip(
                      label: 'Cash',
                      icon: Icons.payments_outlined,
                      selected: payMethod == 'cash',
                      disabled: !_cashEnabled,
                      onTap: _cashEnabled
                          ? () => setS(() => payMethod = 'cash')
                          : null,
                    ),
                  ]),
                  const SizedBox(height: 20),

                  // Bouton commander
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ScaleButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6D1B7B),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: placing
                          ? null
                          : () async {
                              final desc   = descCtrl.text.trim();
                              final budget = int.tryParse(
                                      budgetCtrl.text.trim()) ??
                                  0;
                              if (desc.isEmpty) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Décrivez votre gâteau')));
                                return;
                              }
                              if (budget < 1000) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Budget minimum : 1 000 FCFA')));
                                return;
                              }
                              if (deadline == null) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Choisissez une date de livraison')));
                                return;
                              }
                              setS(() => placing = true);
                              final ok = await _placeCustomCakeOrder(
                                  desc, budget, deadline!, payMethod);
                              if (ok && ctx.mounted) Navigator.pop(ctx);
                            },
                      child: placing
                          ? const CircularProgressIndicator(
                              color: Colors.white)
                          : Text('Envoyer la commande 🎂',
                              style: GoogleFonts.inter(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _placeCustomCakeOrder(
      String description, int budget, DateTime deadline, String payMethod) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) { _snack('Connexion requise', Colors.red); return false; }

      if (payMethod == 'wallet' && _walletBalance < budget + _deliveryFee) {
        _snack('Solde insuffisant. Wallet : $_walletBalance FCFA', Colors.red);
        return false;
      }

      final clientDoc = await FirebaseFirestore.instance
          .collection('clients').doc(user.uid).get();
      final clientName  = clientDoc.data()?['name']  ?? 'Client';
      final clientPhone = clientDoc.data()?['phone'] ?? '';

      final orderId = const Uuid().v4();
      final deliveryFee = _deliveryFee;
      final totalAmount = budget + deliveryFee;
      final deliveryAddress = _addressCtrl.text.trim().isNotEmpty
          ? _addressCtrl.text.trim()
          : 'Position GPS';

      final orderData = {
        'id':              orderId,
        'type':            'boulangerie',
        'sellerType':      'boulangerie',
        'orderSubType':    'custom_cake',
        'sellerId':        widget.boulangerieId,
        'sellerName':      widget.boulangerieData['name'] ?? '',
        'clientId':        user.uid,
        'clientName':      clientName,
        'clientPhone':     clientPhone,
        'description':     deliveryAddress,
        'cakeDescription': description,
        'cakeDeadline':    Timestamp.fromDate(deadline),
        'items':           [],
        'itemsAmount':     budget,
        'budget':          deliveryFee,
        'totalAmount':     totalAmount,
        'paymentMethod':   payMethod,
        'status':          'pending',
        'sellerStatus':    null,
        'isPaid':          payMethod == 'wallet',
        'createdAt':       FieldValue.serverTimestamp(),
        if (_lat != null) 'clientLat': _lat,
        if (_lng != null) 'clientLng': _lng,
      };

      if (payMethod == 'wallet') {
        final clientRef = FirebaseFirestore.instance
            .collection('clients').doc(user.uid);
        final orderRef  = FirebaseFirestore.instance
            .collection('orders').doc(orderId);
        await FirebaseFirestore.instance.runTransaction((tx) async {
          final snap   = await tx.get(clientRef);
          final wallet = (snap.data()?['wallet'] as num? ?? 0).toInt();
          if (wallet < totalAmount) throw Exception('SOLDE_INSUFFISANT');
          tx.update(clientRef, {'wallet': wallet - totalAmount});
          tx.set(orderRef, orderData);
        });
      } else {
        await FirebaseFirestore.instance
            .collection('orders').doc(orderId).set(orderData);
      }

      if (mounted) {
        _snack('🎂 Commande envoyée ! La boulangerie vous contactera.', Colors.green);
      }
      return true;
    } catch (e) {
      _snack('Erreur : $e', Colors.red);
      return false;
    }
  }
}

// ── Widget choix de paiement ──────────────────────────────────────────

class _PayChoice extends StatelessWidget {
  final bool selected;
  final String label;
  final String subtitle;
  final IconData icon;
  final Color color;
  final bool disabled;
  final VoidCallback? onTap;

  const _PayChoice({
    required this.selected,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.color,
    this.disabled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: disabled
              ? Colors.grey.shade50
              : selected
                  ? color.withValues(alpha: 0.08)
                  : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: disabled
                  ? Colors.grey.shade200
                  : selected
                      ? color
                      : Colors.grey.shade200,
              width: selected ? 2 : 1),
        ),
        child: Row(children: [
          Icon(icon,
              color: disabled ? Colors.grey : color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: disabled ? Colors.grey : null)),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade500)),
              ],
            ),
          ),
          if (selected && !disabled)
            Icon(Icons.check_circle_rounded, color: color, size: 20),
        ]),
      ),
    );
  }
}

// ── Chip paiement compact (pour le sheet gâteau) ─────────────────────────────

class _PayChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final bool disabled;
  final VoidCallback? onTap;

  const _PayChip({
    required this.label,
    required this.icon,
    required this.selected,
    this.disabled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF6D1B7B).withValues(alpha: 0.1)
              : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? const Color(0xFF6D1B7B) : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 16,
              color: disabled
                  ? Colors.grey
                  : selected
                      ? const Color(0xFF6D1B7B)
                      : Colors.grey.shade600),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: disabled
                    ? Colors.grey
                    : selected
                        ? const Color(0xFF6D1B7B)
                        : Colors.grey.shade700,
              )),
        ]),
      ),
    );
  }
}

