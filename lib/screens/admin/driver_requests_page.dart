import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../theme/app_theme.dart';

class DriverRequestsPage extends StatelessWidget {
  const DriverRequestsPage({super.key});

  // Approuver → copie dans "livreurs" avec le même UID, supprime la demande (WriteBatch atomique)
  Future<void> _approve(BuildContext context, DocumentSnapshot doc) async {
    final data = doc.data() as Map<String, dynamic>;
    final uid = data["uid"] ?? doc.id;

    // Vérifier si déjà approuvé (évite la double-approbation)
    final existing =
        await FirebaseFirestore.instance.collection("livreurs").doc(uid).get();
    if (existing.exists) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Ce livreur est déjà approuvé."),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    final batch = FirebaseFirestore.instance.batch();

    batch.set(FirebaseFirestore.instance.collection("livreurs").doc(uid), {
      "name": data["name"] ?? "",
      "phone": data["phone"] ?? "",
      "email": data["email"] ?? "",
      "identifiant": data["identifiant"] ?? "",
      "photoUrl": data["photoUrl"] ?? "",
      "idPhotoUrl": data["idPhotoUrl"] ?? "",
      "selfieUrl": data["selfieUrl"] ?? "",
      "wallet": 500,
      "isOnline": false,
      "lat": 0,
      "lng": 0,
      "deliveries": 0,
      "avgRating": 0.0,
      "ratingCount": 0,
      "createdAt": Timestamp.now(),
    });

    batch.delete(doc.reference);

    await batch.commit();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text("${data['name']} approuvé — peut maintenant se connecter"),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  // Refuser → supprime la demande
  Future<void> _reject(BuildContext context, DocumentSnapshot doc) async {
    final name = (doc.data() as Map)["name"] ?? "ce livreur";
    await doc.reference.delete();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Demande de $name refusée"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text("Demandes livreurs"),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection("driver_requests")
            .orderBy("createdAt", descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.inbox_rounded,
                      size: 64, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  const Text(
                    "Aucune demande en attente",
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          final requests = snapshot.data!.docs;

          return ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(14),
            itemCount: requests.length,
            itemBuilder: (context, index) {
              final doc = requests[index];
              final data = doc.data() as Map<String, dynamic>;

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(color: Colors.black12, blurRadius: 6)
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Infos livreur
                      Row(
                        children: [
                          data["photoUrl"] != null
                              ? GestureDetector(
                                  onTap: () => showDialog(
                                    context: context,
                                    builder: (_) => Dialog(
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(16)),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(16),
                                        child: Image.network(data["photoUrl"]),
                                      ),
                                    ),
                                  ),
                                  child: CircleAvatar(
                                    radius: 28,
                                    backgroundImage:
                                        NetworkImage(data["photoUrl"]),
                                  ),
                                )
                              : Container(
                                  width: 56,
                                  height: 56,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF167DB7)
                                        .withValues(alpha: 0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.delivery_dining,
                                      color: Color(0xFF167DB7), size: 28),
                                ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  data["name"] ?? "—",
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16),
                                ),
                                Text(
                                  data["phone"] ?? "—",
                                  style: const TextStyle(
                                      color: Colors.grey, fontSize: 13),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "ID : ${data['identifiant'] ?? '—'}",
                                  style: TextStyle(
                                      color: Colors.blue.shade700,
                                      fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade50,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.orange.shade200),
                            ),
                            child: const Text(
                              "En attente",
                              style: TextStyle(
                                  color: Colors.orange,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 14),
                      const Divider(height: 1),
                      const SizedBox(height: 12),

                      // Boutons
                      Row(
                        children: [
                          // APPROUVER
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _approve(context, doc),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.check_circle, size: 18),
                              label: const Text("Approuver"),
                            ),
                          ),
                          const SizedBox(width: 10),
                          // REFUSER
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _reject(context, doc),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red,
                                side: const BorderSide(color: Colors.red),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.cancel, size: 18),
                              label: const Text("Refuser"),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
