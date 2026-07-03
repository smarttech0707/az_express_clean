import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:geolocator/geolocator.dart';
import '../../services/tarif_service.dart';
import '../../services/firestore_service.dart';

class PharmacieGardePage extends StatefulWidget {
  const PharmacieGardePage({super.key});

  @override
  State<PharmacieGardePage> createState() => _PharmacieGardePageState();
}

class _PharmacieGardePageState extends State<PharmacieGardePage>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverAppBar(
            expandedHeight: 150,
            pinned: true,
            backgroundColor: Colors.red.shade700,
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.red.shade900, Colors.red.shade500],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 30),
                      const Icon(Icons.local_pharmacy,
                          color: Colors.white, size: 44),
                      const SizedBox(height: 8),
                      Text(
                        'Pharmacies',
                        style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'Abengourou',
                        style: GoogleFonts.inter(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            title: Text('Pharmacies',
                style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
            centerTitle: true,
            bottom: TabBar(
              controller: _tabCtrl,
              indicatorColor: Colors.white,
              indicatorWeight: 3,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white60,
              labelStyle: GoogleFonts.inter(
                  fontWeight: FontWeight.w600, fontSize: 13),
              tabs: const [
                Tab(icon: Icon(Icons.list_rounded), text: 'Toutes'),
                Tab(icon: Icon(Icons.emergency_rounded), text: 'De garde'),
              ],
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabCtrl,
          children: const [
            _PharmacieList(onlyOnDuty: false),
            _PharmacieList(onlyOnDuty: true),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _PharmacieList extends StatefulWidget {
  final bool onlyOnDuty;
  const _PharmacieList({required this.onlyOnDuty});

  @override
  State<_PharmacieList> createState() => _PharmacieListState();
}

class _PharmacieListState extends State<_PharmacieList> {
  // Anti double-tap — _orderDelivery lance une transaction Firestore sans
  // clé d'idempotence ; sans ce garde-fou, un double-tap sur "Livraison"
  // crée deux commandes indépendantes et débite le client deux fois
  // (Master Prompt 49, même famille que le bug boutique_page.dart corrigé
  // au Prompt 48).
  bool _busy = false;

  Future<void> _call(String phone) async {
    final url = Uri.parse('tel:$phone');
    if (await canLaunchUrl(url)) launchUrl(url);
  }

  Future<void> _openMap(double lat, double lng, String name) async {
    final url = Uri.parse('https://maps.google.com/?q=$lat,$lng');
    if (await canLaunchUrl(url)) {
      launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _orderDelivery(
      BuildContext context, String name, String pharmacieId) async {
    final payment = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _PaymentPickerSheet(),
    );
    if (payment == null || _busy) return;

    setState(() => _busy = true);
    int deliveryFee = 0;
    try {
      var user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        await FirebaseAuth.instance.signInAnonymously();
        user = FirebaseAuth.instance.currentUser;
      }
      if (user == null) return;

      double lat = 0, lng = 0;
      try {
        await Geolocator.requestPermission();
        final pos = await Geolocator.getCurrentPosition(
            locationSettings:
                const LocationSettings(accuracy: LocationAccuracy.medium))
            .timeout(const Duration(seconds: 8));
        lat = pos.latitude;
        lng = pos.longitude;
      } catch (_) {}

      final tarif = TarifService.compute(clientLat: lat, clientLng: lng);
      if (!tarif.canOrder) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tarif.rejectionMessage ?? 'Livraison non disponible'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ));
        }
        return;
      }
      deliveryFee = tarif.standardPrice;

      final id = const Uuid().v4();
      final orderData = {
        'id':            id,
        'description':   'Livraison pharmacie : $name',
        'budget':        deliveryFee,
        'shoppingBudget': 0,
        'status':        'pending',
        'isPaid':        false,
        'type':          'pharmacie',
        'pharmacieId':   pharmacieId,
        'pharmacieName': name,
        'latitude':      lat,
        'longitude':     lng,
        'clientId':      user.uid,
        'paymentMethod': payment,
        'createdAt':     FieldValue.serverTimestamp(),
      };

      if (payment == 'wallet') {
        final clientRef =
            FirebaseFirestore.instance.collection('clients').doc(user.uid);
        final orderRef =
            FirebaseFirestore.instance.collection('orders').doc(id);
        await FirebaseFirestore.instance.runTransaction((tx) async {
          final snap = await tx.get(clientRef);
          final balance =
              (snap.data()?['wallet'] as num? ?? 0).toInt();
          if (balance < deliveryFee) throw Exception('SOLDE_INSUFFISANT:$balance');
          tx.update(clientRef,
              {'wallet': FieldValue.increment(-deliveryFee)});
          tx.set(orderRef, orderData);
          tx.set(
            clientRef.collection('wallet_transactions').doc(),
            {
              'type': 'debit',
              'amount': deliveryFee,
              'description': 'Livraison pharmacie : $name',
              'orderId': id,
              'createdAt': FieldValue.serverTimestamp(),
            },
          );
        });
      } else {
        await FirebaseFirestore.instance
            .collection('orders')
            .doc(id)
            .set(orderData);
      }

      try {
        await FirestoreService().findNearestDriver(lat, lng, id, budget: deliveryFee);
      } catch (_) {}

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Demande de livraison envoyée !'),
              backgroundColor: Colors.green,
              behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (context.mounted) {
        final msg = e.toString().contains('SOLDE_INSUFFISANT')
            ? 'Solde wallet insuffisant ($deliveryFee FCFA requis)'
            : 'Erreur : $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(msg),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> query =
        FirebaseFirestore.instance.collection('pharmacies').orderBy('name');

    if (widget.onlyOnDuty) {
      query = FirebaseFirestore.instance
          .collection('pharmacies')
          .where('isOnDuty', isEqualTo: true);
    }

    return StreamBuilder<QuerySnapshot>(
      stream: query.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.local_pharmacy_outlined,
                    size: 72, color: Colors.grey.shade300),
                const SizedBox(height: 16),
                Text(
                  widget.onlyOnDuty
                      ? 'Aucune pharmacie de garde\nen ce moment'
                      : 'Aucune pharmacie enregistrée',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 15, color: Colors.grey),
                ),
                if (widget.onlyOnDuty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Revenez plus tard ou appelez le 15',
                    style: GoogleFonts.inter(
                        color: Colors.grey.shade400, fontSize: 12),
                  ),
                ],
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          physics: const BouncingScrollPhysics(),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final doc  = docs[i];
            final data = doc.data() as Map<String, dynamic>;
            final name     = data['name'] as String? ?? '—';
            final address  = data['address'] as String? ?? '';
            final phone    = data['phone'] as String? ?? '';
            final hours    = data['hours'] as String? ?? '';
            final lat      = (data['lat'] as num?)?.toDouble() ?? 0.0;
            final lng      = (data['lng'] as num?)?.toDouble() ?? 0.0;
            final isOnDuty = data['isOnDuty'] == true;
            final hasCoords = lat != 0.0 && lng != 0.0;

            return _PharmacieCard(
              name: name,
              address: address,
              phone: phone,
              hours: hours,
              lat: lat,
              lng: lng,
              isOnDuty: isOnDuty,
              hasCoords: hasCoords,
              onCall: phone.isNotEmpty ? () => _call(phone) : null,
              onMap: hasCoords ? () => _openMap(lat, lng, name) : null,
              onDeliver: _busy ? null : () => _orderDelivery(context, name, doc.id),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _PharmacieCard extends StatelessWidget {
  final String name, address, phone, hours;
  final double lat, lng;
  final bool isOnDuty, hasCoords;
  final VoidCallback? onCall, onMap, onDeliver;

  const _PharmacieCard({
    required this.name,
    required this.address,
    required this.phone,
    required this.hours,
    required this.lat,
    required this.lng,
    required this.isOnDuty,
    required this.hasCoords,
    this.onCall,
    this.onMap,
    this.onDeliver,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: isOnDuty
            ? Border.all(color: Colors.red.shade200, width: 1.5)
            : Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: isOnDuty
                ? Colors.red.withValues(alpha: 0.07)
                : Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            decoration: BoxDecoration(
              color: isOnDuty
                  ? Colors.red.withValues(alpha: 0.04)
                  : Colors.grey.withValues(alpha: 0.03),
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20)),
            ),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: isOnDuty
                        ? Colors.red.shade50
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.local_pharmacy,
                      color: isOnDuty
                          ? Colors.red.shade700
                          : Colors.grey.shade400,
                      size: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: GoogleFonts.inter(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: const Color(0xFF1A1A2E))),
                      if (hours.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(Icons.access_time,
                                size: 13,
                                color: Colors.orange.shade700),
                            const SizedBox(width: 4),
                            Text(hours,
                                style: GoogleFonts.inter(
                                    fontSize: 12,
                                    color: Colors.orange.shade700)),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                // Badge
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: isOnDuty
                        ? Colors.red.shade50
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: isOnDuty
                            ? Colors.red.shade200
                            : Colors.grey.shade300),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: isOnDuty ? Colors.red : Colors.grey,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        isOnDuty ? 'De garde' : 'Fermée',
                        style: TextStyle(
                            color: isOnDuty
                                ? Colors.red.shade700
                                : Colors.grey.shade600,
                            fontWeight: FontWeight.bold,
                            fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              children: [
                // Phone
                if (phone.isNotEmpty)
                  _ActionRow(
                    icon: Icons.phone_rounded,
                    iconBg: Colors.green.shade100,
                    iconColor: Colors.green.shade700,
                    bg: Colors.green.shade50,
                    border: Colors.green.shade200,
                    label: 'Téléphone',
                    value: phone,
                    trailingIcon: Icons.call,
                    onTap: onCall,
                  ),

                if (phone.isNotEmpty) const SizedBox(height: 8),

                // Address/Map
                _ActionRow(
                  icon: Icons.location_on_rounded,
                  iconBg: hasCoords
                      ? Colors.blue.shade100
                      : Colors.grey.shade200,
                  iconColor: hasCoords
                      ? Colors.blue.shade700
                      : Colors.grey,
                  bg: hasCoords
                      ? Colors.blue.shade50
                      : Colors.grey.shade50,
                  border: hasCoords
                      ? Colors.blue.shade200
                      : Colors.grey.shade200,
                  label: 'Localisation',
                  value: address.isNotEmpty
                      ? address
                      : hasCoords
                          ? 'Voir sur la carte'
                          : 'Non renseignée',
                  trailingIcon: hasCoords ? Icons.open_in_new : null,
                  onTap: onMap,
                ),
              ],
            ),
          ),

          // Delivery button
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onDeliver,
                icon: const Icon(Icons.delivery_dining,
                    size: 18, color: Colors.white),
                label: Text('Commander une livraison',
                    style: GoogleFonts.inter(
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                  padding:
                      const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _PaymentPickerSheet extends StatefulWidget {
  const _PaymentPickerSheet();

  @override
  State<_PaymentPickerSheet> createState() => _PaymentPickerSheetState();
}

class _PaymentPickerSheetState extends State<_PaymentPickerSheet> {
  int? _walletBalance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadBalance();
  }

  Future<void> _loadBalance() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        final doc = await FirebaseFirestore.instance
            .collection('clients')
            .doc(uid)
            .get();
        if (mounted) {
          setState(() {
            _walletBalance =
                (doc.data()?['wallet'] as num? ?? 0).toInt();
            _loading = false;
          });
        }
      } else {
        if (mounted) setState(() { _walletBalance = 0; _loading = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _walletBalance = 0; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final canWallet = (_walletBalance ?? 0) >= 500;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),
          Text('Mode de paiement',
              style: GoogleFonts.inter(
                  fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Frais de livraison : 500 FCFA',
              style: GoogleFonts.inter(
                  fontSize: 13, color: Colors.grey.shade600)),
          const SizedBox(height: 20),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else ...[
            _PayOption(
              icon: Icons.account_balance_wallet_rounded,
              color: canWallet ? Colors.green : Colors.grey,
              title: 'Wallet AZ Express',
              subtitle: _walletBalance != null
                  ? 'Solde : $_walletBalance FCFA'
                      '${!canWallet ? ' — insuffisant' : ''}'
                  : 'Solde indisponible',
              enabled: canWallet,
              onTap: canWallet
                  ? () => Navigator.pop(context, 'wallet')
                  : null,
            ),
            const SizedBox(height: 12),
            _PayOption(
              icon: Icons.payments_rounded,
              color: Colors.orange.shade700,
              title: 'Espèces à la livraison',
              subtitle: 'Vous payez le livreur en liquide',
              enabled: true,
              onTap: () => Navigator.pop(context, 'cash'),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _PayOption extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback? onTap;

  const _PayOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.enabled,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: enabled
              ? color.withValues(alpha: 0.06)
              : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: enabled
                ? color.withValues(alpha: 0.3)
                : Colors.grey.shade200,
          ),
        ),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: enabled
                  ? color.withValues(alpha: 0.12)
                  : Colors.grey.shade100,
              shape: BoxShape.circle,
            ),
            child: Icon(icon,
                color: enabled ? color : Colors.grey, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(title,
                  style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: enabled ? Colors.black87 : Colors.grey)),
              Text(subtitle,
                  style: GoogleFonts.inter(
                      fontSize: 12, color: Colors.grey.shade600)),
            ]),
          ),
          if (enabled)
            Icon(Icons.arrow_forward_ios_rounded,
                size: 14, color: color),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final Color iconBg, iconColor, bg, border;
  final String label, value;
  final IconData? trailingIcon;
  final VoidCallback? onTap;

  const _ActionRow({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.bg,
    required this.border,
    required this.label,
    required this.value,
    this.trailingIcon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration:
                  BoxDecoration(color: iconBg, shape: BoxShape.circle),
              child: Icon(icon, color: iconColor, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                          fontWeight: FontWeight.w500)),
                  Text(value,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: iconColor),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (trailingIcon != null)
              Icon(trailingIcon, color: iconColor, size: 20),
          ],
        ),
      ),
    );
  }
}
