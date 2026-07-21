import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'chat_page.dart';
import '../../widgets/stream_error_state.dart';
import '../../theme/app_theme.dart';

class ConversationsPage extends StatelessWidget {
  const ConversationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text("Messages"),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: uid == null
          ? const Center(
              child: Text("Connectez-vous pour voir vos messages",
                  style: TextStyle(color: Colors.grey)))
          : StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection("orders")
                  .where("clientId", isEqualTo: uid)
                  .where("driverId", isNull: false)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return const StreamErrorState(message: "Impossible de charger vos conversations.");
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final orders = snap.data!.docs
                    .where((d) =>
                        (d.data() as Map)["status"] != "cancelled" &&
                        (d.data() as Map)["status"] != "pending")
                    .toList();

                if (orders.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline,
                            size: 64, color: Colors.grey.shade300),
                        const SizedBox(height: 16),
                        const Text(
                          "Aucune conversation",
                          style: TextStyle(
                              fontSize: 16, color: Colors.grey),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          "Les chats apparaissent quand\nun livreur accepte votre commande",
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(12),
                  itemCount: orders.length,
                  itemBuilder: (context, i) {
                    final data =
                        orders[i].data() as Map<String, dynamic>;
                    final orderId = orders[i].id;
                    final status = data["status"] ?? "";
                    final desc = data["description"] ?? "Commande";
                    final driverId = data["driverId"];

                    return _ConversationTile(
                      orderId: orderId,
                      status: status,
                      desc: desc,
                      driverId: driverId,
                    );
                  },
                );
              },
            ),
    );
  }
}

// Widget dédié (au lieu d'un FutureBuilder construit inline dans itemBuilder)
// pour que le fetch du livreur ne soit lancé qu'une fois par tuile, en cache
// pour la durée de vie du State — un FutureBuilder inline aurait relancé un
// nouveau .get() sur "livreurs/{driverId}" à CHAQUE émission du StreamBuilder
// parent (dès qu'une commande active change de statut, pas seulement celle-ci),
// multiplié par le nombre de conversations affichées (Master Prompt 59).
class _ConversationTile extends StatefulWidget {
  final String orderId;
  final String status;
  final String desc;
  final String? driverId;
  const _ConversationTile({
    required this.orderId,
    required this.status,
    required this.desc,
    required this.driverId,
  });

  @override
  State<_ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<_ConversationTile> {
  late final Future<DocumentSnapshot> _driverFuture = FirebaseFirestore
      .instance
      .collection("livreurs")
      .doc(widget.driverId)
      .get();

  static Color _statusColor(String status) {
    switch (status) {
      case "accepted":
        return Colors.blue;
      case "picked_up":
        return const Color(0xFF167DB7);
      case "delivered":
        return Colors.green;
      default:
        return Colors.orange;
    }
  }

  static String _statusLabel(String status) {
    switch (status) {
      case "accepted":
        return "En route";
      case "picked_up":
        return "En livraison";
      case "delivered":
        return "Livré";
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot>(
      future: _driverFuture,
      builder: (context, driverSnap) {
        final driverName = driverSnap.hasData && driverSnap.data!.exists
            ? (driverSnap.data!.data() as Map)["name"] ?? "Livreur"
            : "Livreur";

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(color: Colors.black12, blurRadius: 6)
            ],
          ),
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.delivery_dining,
                  color: AppColors.primary),
            ),
            title: Text(
              driverName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              widget.desc,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _statusColor(widget.status).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _statusLabel(widget.status),
                    style: TextStyle(
                      color: _statusColor(widget.status),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Icon(Icons.chevron_right,
                    color: Colors.grey, size: 18),
              ],
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatPage(orderId: widget.orderId),
              ),
            ),
          ),
        );
      },
    );
  }
}