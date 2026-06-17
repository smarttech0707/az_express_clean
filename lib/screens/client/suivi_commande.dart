import 'dart:async';
import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/firestore_service.dart';
import '../../models/order_model.dart';
import '../chat/chat_page.dart';
import '../../widgets/order_status_stepper.dart';
import '../../widgets/rating_dialog.dart';
import 'order_tracking_map.dart';

class SuiviCommandePage extends StatelessWidget {
  const SuiviCommandePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Mes commandes"),
        backgroundColor: const Color(0xFFFF7A1A),
        centerTitle: true,
      ),
      body: SafeArea(
        child: StreamBuilder<List<OrderModel>>(
          stream: FirestoreService().clientOrders(
              FirebaseAuth.instance.currentUser?.uid ?? ''),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final orders = snapshot.data!
                .where((o) => o.status != "cancelled")
                .toList();

            if (orders.isEmpty) {
              return const Center(
                child: Text("Aucune commande en cours",
                    style: TextStyle(fontSize: 16, color: Colors.grey)),
              );
            }

            return ListView.builder(
              physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: orders.length,
              itemBuilder: (context, index) =>
                  _OrderCard(order: orders[index]),
            );
          },
        ),
      ),
    );
  }
}

// ============================================================
// CARTE COMMANDE STYLE YANGO
// ============================================================

class _OrderCard extends StatelessWidget {
  final OrderModel order;
  const _OrderCard({required this.order});

  void _showPhotoDialog(BuildContext context, String url, String title) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(16)),
              child: Image.network(url, fit: BoxFit.cover),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _callDriver(BuildContext context, String driverId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection("livreurs")
          .doc(driverId)
          .get();
      if (!doc.exists) return;
      final phone = ((doc.data() as Map?)??{})["phone"]?.toString().trim() ?? "";
      if (phone.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Numéro du livreur indisponible")),
          );
        }
        return;
      }
      await launchUrl(
        Uri.parse("tel:$phone"),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Impossible de lancer l'appel")),
        );
      }
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case "pending":
        return "En attente d'un livreur";
      case "assigned":
        return "Livreur trouvé — en attente";
      case "accepted":
        return "Livreur en route vers vous";
      case "picked_up":
        return "Colis récupéré — en livraison";
      case "delivered":
        return "Livré";
      default:
        return status;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case "pending":
      case "assigned":
        return Colors.orange;
      case "accepted":
        return Colors.blue;
      case "picked_up":
        return const Color(0xFF167DB7);
      case "delivered":
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool hasDriver = order.driverId != null;
    final bool isActive = order.status == "accepted" ||
        order.status == "picked_up" ||
        order.status == "assigned";
    final bool isDelivered = order.status == "delivered";

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status banner
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: _statusColor(order.status).withValues(alpha: 0.1),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              border: Border(
                left: BorderSide(
                    color: _statusColor(order.status), width: 4),
              ),
            ),
            child: Text(
              _statusLabel(order.status),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: _statusColor(order.status),
                fontSize: 13,
              ),
            ),
          ),

          // Status stepper
          OrderStatusStepper(status: order.status),

          // Order details
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.description,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text("${order.budget} FCFA",
                    style: const TextStyle(
                        fontSize: 14, color: Color(0xFFFF7A1A))),
              ],
            ),
          ),

          // Bannière pharmacie
          if (order.type == 'pharmacie')
            _PharmacieOrderBanner(order: order),

          // Driver info (if assigned)
          if (hasDriver)
            FutureBuilder<DocumentSnapshot>(
              future: FirebaseFirestore.instance
                  .collection("livreurs")
                  .doc(order.driverId)
                  .get(),
              builder: (context, snap) {
                if (!snap.hasData || !snap.data!.exists) {
                  return const SizedBox.shrink();
                }
                final driver = snap.data!.data() as Map<String, dynamic>;
                final driverPhoto = driver["photoUrl"] as String?;
                final acceptanceSelfie = order.driverAcceptanceSelfie;
                final hasVerification = driverPhoto != null &&
                    driverPhoto.isNotEmpty &&
                    acceptanceSelfie != null;

                return Container(
                  margin: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 6),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: hasVerification
                          ? Colors.green.shade200
                          : Colors.grey.shade200,
                    ),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 6)
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Infos livreur
                      Row(
                        children: [
                          // Photo de profil
                          GestureDetector(
                            onTap: driverPhoto != null && driverPhoto.isNotEmpty
                                ? () => _showPhotoDialog(context, driverPhoto,
                                    "Photo de profil du livreur")
                                : null,
                            child: CircleAvatar(
                              radius: 26,
                              backgroundColor: const Color(0xFFFF7A1A),
                              backgroundImage:
                                  driverPhoto != null && driverPhoto.isNotEmpty
                                      ? NetworkImage(driverPhoto)
                                      : null,
                              child: driverPhoto == null || driverPhoto.isEmpty
                                  ? const Icon(Icons.delivery_dining,
                                      color: Colors.white, size: 22)
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  driver["name"] ?? "Livreur",
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15),
                                ),
                                Text(driver["phone"] ?? "",
                                    style: const TextStyle(
                                        color: Colors.grey, fontSize: 12)),
                              ],
                            ),
                          ),
                          if (hasVerification)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color: Colors.green.shade200),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.verified,
                                      color: Colors.green, size: 14),
                                  SizedBox(width: 4),
                                  Text(
                                    "Vérifié",
                                    style: TextStyle(
                                        color: Colors.green,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),

                      // Photos de vérification
                      if (hasVerification) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.green.shade50,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.security,
                                      color: Colors.green, size: 14),
                                  SizedBox(width: 6),
                                  Text(
                                    "Vérification d'identité",
                                    style: TextStyle(
                                      color: Colors.green,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  // Photo de profil (inscription)
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () => _showPhotoDialog(
                                          context,
                                          driverPhoto,
                                          "Photo d'inscription"),
                                      child: Column(
                                        children: [
                                          ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            child: Image.network(
                                              driverPhoto,
                                              height: 90,
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            "Inscription",
                                            style: TextStyle(
                                                color: Colors.grey.shade600,
                                                fontSize: 11),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const Icon(Icons.compare_arrows,
                                      color: Colors.green),
                                  const SizedBox(width: 8),
                                  // Selfie d'acceptation
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () => _showPhotoDialog(
                                          context,
                                          acceptanceSelfie,
                                          "Selfie de confirmation"),
                                      child: Column(
                                        children: [
                                          ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            child: Image.network(
                                              acceptanceSelfie,
                                              height: 90,
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            "Confirmation",
                                            style: TextStyle(
                                                color: Colors.grey.shade600,
                                                fontSize: 11),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                "Comparez les deux photos pour confirmer\nque c'est bien votre livreur.",
                                style: TextStyle(
                                    color: Colors.green,
                                    fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),

          // ETA when active
          if (isActive && !isDelivered)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.access_time, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text("Mise à jour en temps réel",
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),

          // ── Bouton paiement wallet (uniquement si mode paiement = wallet) ──
          if (isDelivered && !order.isPaid && order.paymentMethod == 'wallet')
            _WalletPayButton(order: order),

          // Bouton notation si livré et pas encore noté
          if (isDelivered && order.rating == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: ElevatedButton.icon(
                onPressed: () async {
                  String driverName = "le livreur";
                  if (order.driverId != null) {
                    final doc = await FirebaseFirestore.instance
                        .collection("livreurs")
                        .doc(order.driverId)
                        .get();
                    if (doc.exists) driverName = doc["name"] ?? driverName;
                  }
                  if (context.mounted) {
                    showDialog(
                      context: context,
                      builder: (_) => RatingDialog(
                        orderId: order.id,
                        driverName: driverName,
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 44),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.star),
                label: const Text("Noter le livreur"),
              ),
            ),

          // Note déjà donnée
          if (isDelivered && order.rating != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  ...List.generate(5, (i) => Icon(
                    i < order.rating! ? Icons.star : Icons.star_border,
                    color: Colors.amber, size: 18,
                  )),
                  const SizedBox(width: 6),
                  Text("Vous avez noté ${order.rating}/5",
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),

          // Notation vendeur/restaurant
          if (isDelivered && order.sellerId != null && order.sellerRating == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: ElevatedButton.icon(
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => SellerReviewDialog(
                    orderId: order.id,
                    sellerName: order.sellerName ?? 'le prestataire',
                    sellerId: order.sellerId!,
                    sellerType: order.sellerType,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 44),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.star_rate_rounded),
                label: Text(
                  order.sellerType == 'restaurant'
                      ? 'Noter le restaurant'
                      : order.sellerType == 'boulangerie'
                          ? 'Noter la boulangerie'
                          : 'Noter le vendeur',
                ),
              ),
            ),

          // Note vendeur déjà donnée
          if (isDelivered && order.sellerRating != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  ...List.generate(5, (i) => Icon(
                    i < order.sellerRating! ? Icons.star : Icons.star_border,
                    color: const Color(0xFF1565C0), size: 18,
                  )),
                  const SizedBox(width: 6),
                  Text("Vendeur noté ${order.sellerRating}/5",
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),

          // Photo preuve de livraison
          if (order.deliveryPhoto != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: GestureDetector(
                onTap: () => showDialog(
                  context: context,
                  builder: (_) => Dialog(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(order.deliveryPhoto!),
                    ),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    order.deliveryPhoto!,
                    height: 120,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),

          // Action buttons
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Track on map
                if (hasDriver && isActive)
                  _actionButton(
                    icon: Icons.map,
                    label: "Suivre",
                    color: const Color(0xFFFF7A1A),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => OrderTrackingMap(order: order),
                      ),
                    ),
                  ),

                if (hasDriver && isActive) const SizedBox(width: 8),

                // Chat
                if (hasDriver)
                  _actionButton(
                    icon: Icons.chat_bubble,
                    label: "Chat",
                    color: const Color(0xFF167DB7),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatPage(orderId: order.id),
                      ),
                    ),
                  ),

                if (hasDriver) const SizedBox(width: 8),

                // Call driver
                if (hasDriver)
                  _actionButton(
                    icon: Icons.call,
                    label: "Appeler",
                    color: Colors.green,
                    onTap: () => _callDriver(context, order.driverId ?? ''),
                  ),

                const Spacer(),

                // Cancel (only if pending)
                if (order.status == "pending")
                  TextButton.icon(
                    icon: const Icon(Icons.cancel, color: Colors.red),
                    label: const Text("Annuler",
                        style: TextStyle(color: Colors.red)),
                    onPressed: () => showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text("Annuler la commande ?"),
                        content: const Text(
                            "Cette action est irréversible. Confirmes-tu l'annulation ?"),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text("Non"),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text("Oui, annuler",
                                style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      ),
                    ).then((confirmed) {
                      if (confirmed == true) {
                        FirestoreService().cancelOrder(order.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Text(label,
                style:
                    TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// BOUTON PAIEMENT WALLET
// ============================================================

class _WalletPayButton extends StatefulWidget {
  final OrderModel order;
  const _WalletPayButton({required this.order});

  @override
  State<_WalletPayButton> createState() => _WalletPayButtonState();
}

class _WalletPayButtonState extends State<_WalletPayButton> {
  bool _paying = false;
  final _medCtrl = TextEditingController();

  @override
  void dispose() {
    _medCtrl.dispose();
    super.dispose();
  }

  Future<void> _showPayDialog() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    // Lire le solde client
    final clientSnap = await FirebaseFirestore.instance
        .collection('clients')
        .doc(uid)
        .get();
    final balance = (clientSnap.data()?['wallet'] as num? ?? 0).toInt();

    final isPharmacy = widget.order.type == 'pharmacie';
    int? medAmount;

    if (!mounted) return;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final deliveryFee = widget.order.budget;
          final medFee = isPharmacy
              ? (int.tryParse(_medCtrl.text.trim()) ?? 0)
              : 0;
          final total = deliveryFee + medFee;
          final hasEnough = balance >= total;

          return Padding(
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

                // Titre
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF6D00).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.account_balance_wallet_rounded,
                          color: Color(0xFFFF6D00), size: 22),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Payer depuis mon wallet',
                            style: TextStyle(
                                fontSize: 17, fontWeight: FontWeight.bold)),
                        Text('Solde disponible : ${_fmt(balance)} FCFA',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600)),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // Frais de livraison
                _PayRow(
                  icon: Icons.delivery_dining_rounded,
                  label: 'Frais de livraison',
                  amount: deliveryFee,
                  color: const Color(0xFFFF6D00),
                ),

                // Médicaments (pharmacie)
                if (isPharmacy) ...[
                  const SizedBox(height: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.local_pharmacy_rounded,
                              size: 16, color: Colors.red),
                          SizedBox(width: 6),
                          Text('Médicaments (optionnel)',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _medCtrl,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setS(() {}),
                        decoration: InputDecoration(
                          hintText: 'Montant médicaments (FCFA)',
                          hintStyle: const TextStyle(fontSize: 13),
                          prefixIcon: const Icon(Icons.payments_rounded,
                              size: 18),
                          filled: true,
                          fillColor: Colors.grey.shade50,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                  color: Colors.grey.shade300)),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                  color: Colors.grey.shade300)),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                        ),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 16),

                // Total
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: hasEnough
                        ? const Color(0xFFF0F7FF)
                        : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: hasEnough
                            ? const Color(0xFF1565C0).withValues(alpha: 0.2)
                            : Colors.red.shade200),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Total à payer',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: hasEnough
                                  ? Colors.black87
                                  : Colors.red.shade700)),
                      Text('${_fmt(total)} FCFA',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                              color: hasEnough
                                  ? const Color(0xFFFF6D00)
                                  : Colors.red.shade700)),
                    ],
                  ),
                ),

                if (!hasEnough) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber,
                            color: Colors.red.shade700, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Solde insuffisant. Rechargez votre wallet.',
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.red.shade700),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 20),

                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Annuler'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: hasEnough
                            ? () {
                                medAmount = isPharmacy
                                    ? (int.tryParse(
                                            _medCtrl.text.trim()) ??
                                        0)
                                    : 0;
                                Navigator.pop(ctx, true);
                              }
                            : null,
                        icon: const Icon(Icons.check_circle_rounded,
                            color: Colors.white, size: 18),
                        label: Text('Payer ${_fmt(total)} FCFA',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF6D00),
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );

    if (confirmed != true || !mounted) return;

    if (widget.order.driverId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Attendez qu\'un livreur soit assigné avant de payer.'),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    setState(() => _paying = true);
    try {
      await FirestoreService().payOrderFromWallet(
        orderId: widget.order.id,
        clientId: uid,
        driverId: widget.order.driverId!,
        deliveryAmount: widget.order.budget,
        pharmacieId: widget.order.pharmacieId,
        medicineAmount: medAmount ?? 0,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Paiement effectué ! Merci.'),
          backgroundColor: Color(0xFF2E7D32),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg.contains('SOLDE_INSUFFISANT')
              ? 'Solde insuffisant. Rechargez votre wallet.'
              : 'Erreur paiement : $msg'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  String _fmt(int v) {
    if (v >= 1000) return "${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}";
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: GestureDetector(
        onTap: _paying ? null : _showPayDialog,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFF6D00), Color(0xFFFF8F00)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFF6D00).withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: _paying
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(
                        Icons.account_balance_wallet_rounded,
                        color: Colors.white,
                        size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Payer depuis mon wallet',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                    Text(
                      'Appuyez pour payer le livreur en ligne',
                      style: TextStyle(
                          color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios,
                  color: Colors.white, size: 14),
            ],
          ),
        ),
      ),
    );
  }
}

class _PayRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final int amount;
  final Color color;
  const _PayRow(
      {required this.icon,
      required this.label,
      required this.amount,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500)),
        ),
        Text('$amount FCFA',
            style: TextStyle(
                fontWeight: FontWeight.bold, color: color, fontSize: 14)),
      ],
    );
  }
}

// ============================================================
// BANNIÈRE PHARMACIE — info spécifique pour commandes pharmacie
// ============================================================

class _PharmacieOrderBanner extends StatelessWidget {
  final OrderModel order;
  const _PharmacieOrderBanner({required this.order});

  @override
  Widget build(BuildContext context) {
    final driverId = order.driverId;
    final hasDriver = driverId != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.local_pharmacy_rounded,
                    color: Colors.red.shade700, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Commande pharmacie',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.red.shade700,
                      fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              hasDriver
                  ? '✓ Un livreur a été assigné. La pharmacie a reçu sa photo et peut vérifier son identité avant de lui remettre vos médicaments.'
                  : 'Un livreur va se rendre à la pharmacie pour récupérer vos médicaments et vous les livrer.',
              style: TextStyle(
                  fontSize: 12, color: Colors.red.shade800),
            ),
            if (hasDriver) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.verified_user_rounded,
                      size: 13, color: Colors.green.shade700),
                  const SizedBox(width: 4),
                  Text(
                    'La pharmacie vérifie aussi l\'identité du livreur',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.green.shade700,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================
// CARTE TRACKING — LIVREUR + CLIENT
// ============================================================

class OrderMapPage extends StatefulWidget {
  final OrderModel order;
  const OrderMapPage({super.key, required this.order});

  @override
  State<OrderMapPage> createState() => _OrderMapPageState();
}

class _OrderMapPageState extends State<OrderMapPage> {
  Set<Marker> _markers = {};
  StreamSubscription<DocumentSnapshot>? _driverSub;

  @override
  void initState() {
    super.initState();
    _initClientMarker();
    _listenDriver();
  }

  @override
  void dispose() {
    _driverSub?.cancel();
    super.dispose();
  }

  void _initClientMarker() {
    _markers = {
      Marker(
        markerId: const MarkerId("client"),
        position: LatLng(widget.order.latitude, widget.order.longitude),
        infoWindow: const InfoWindow(title: "Point de collecte"),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
      ),
    };
  }

  void _listenDriver() {
    if (widget.order.driverId == null) return;
    _driverSub = FirebaseFirestore.instance
        .collection("livreurs")
        .doc(widget.order.driverId)
        .snapshots()
        .listen((doc) {
      if (!doc.exists || !mounted) return;
      final lat = (doc["lat"] ?? 0).toDouble();
      final lng = (doc["lng"] ?? 0).toDouble();
      if (lat == 0) return;
      setState(() {
        _markers = {
          ..._markers,
          Marker(
            markerId: const MarkerId("driver"),
            position: LatLng(lat, lng),
            infoWindow: const InfoWindow(title: "Livreur"),
            icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueOrange),
          ),
        };
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Suivi de la commande"),
        backgroundColor: const Color(0xFFFF7A1A),
      ),
      body: GoogleMap(
        initialCameraPosition: CameraPosition(
          target: LatLng(widget.order.latitude, widget.order.longitude),
          zoom: 14,
        ),
        markers: _markers,
        myLocationEnabled: true,
        zoomControlsEnabled: false,
        compassEnabled: false,
        onMapCreated: (_) {},
      ),
    );
  }
}

// ============================================================
// DIALOGUE NOTATION VENDEUR / RESTAURANT
// ============================================================

class SellerReviewDialog extends StatefulWidget {
  final String orderId;
  final String sellerName;
  final String sellerId;
  final String? sellerType;

  const SellerReviewDialog({
    super.key,
    required this.orderId,
    required this.sellerName,
    required this.sellerId,
    this.sellerType,
  });

  @override
  State<SellerReviewDialog> createState() => _SellerReviewDialogState();
}

class _SellerReviewDialogState extends State<SellerReviewDialog> {
  int _rating = 0;
  bool _loading = false;
  final _commentCtrl = TextEditingController();

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rating == 0) return;
    setState(() => _loading = true);
    try {
      await FirebaseFirestore.instance
          .collection('orders')
          .doc(widget.orderId)
          .update({'sellerRating': _rating});

      final collection = widget.sellerType == 'restaurant'
          ? 'restaurants'
          : widget.sellerType == 'boulangerie'
              ? 'boulangeries'
              : 'sellers';

      final sellerRef =
          FirebaseFirestore.instance.collection(collection).doc(widget.sellerId);

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(sellerRef);
        final data = snap.data() ?? {};
        final currentAvg = (data['avgRating'] as num? ?? 0).toDouble();
        final currentCount = (data['ratingCount'] as num? ?? 0).toInt();
        final newCount = currentCount + 1;
        final newAvg = ((currentAvg * currentCount) + _rating) / newCount;
        tx.update(sellerRef, {
          'avgRating': double.parse(newAvg.toStringAsFixed(1)),
          'ratingCount': newCount,
        });
      });

      await FirebaseFirestore.instance.collection('reviews').add({
        'orderId': widget.orderId,
        'sellerId': widget.sellerId,
        'sellerType': widget.sellerType,
        'rating': _rating,
        'comment': _commentCtrl.text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Merci pour votre avis !'),
          backgroundColor: Color(0xFF2E7D32),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(children: [
        const Icon(Icons.star_rate_rounded, color: Color(0xFF1565C0)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Noter ${widget.sellerName}',
            style: const TextStyle(fontSize: 15),
          ),
        ),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (i) => GestureDetector(
              onTap: () => setState(() => _rating = i + 1),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  i < _rating
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  color: const Color(0xFF1565C0),
                  size: 36,
                ),
              ),
            )),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _commentCtrl,
            maxLines: 2,
            decoration: InputDecoration(
              hintText: 'Commentaire (optionnel)',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF1565C0)),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Passer'),
        ),
        ScaleButton(
          onPressed: _rating == 0 || _loading ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1565C0),
            foregroundColor: Colors.white,
          ),
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : const Text('Envoyer'),
        ),
      ],
    );
  }
}

