import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Cash restaurant/pharmacie non encore réglé au marchand par le livreur.
///
/// Contexte (Master Prompt 76, 2026-07-09) : pour une commande cash avec un
/// marchand (restaurant/pharmacie), le livreur collecte en espèces le prix
/// du produit ET la livraison — mais rien ne remonte au wallet AZ de ce
/// marchand (0% commission déjà pris ailleurs, sur le wallet du livreur à
/// l'acceptation). Le livreur doit donc remettre physiquement cette part au
/// marchand, un processus jusqu'ici invisible côté app. `deliverOrderCF`
/// marque désormais `merchantCashSettled: false` sur ces commandes ; cet
/// écran liste les commandes non réglées et permet à l'admin de confirmer
/// le règlement (après vérification manuelle avec le marchand/le livreur).
/// Aucun mouvement de wallet — champ purement déclaratif, jamais lu par la
/// logique de paiement existante.
class AdminCashSettlementPage extends StatelessWidget {
  const AdminCashSettlementPage({super.key});

  Future<void> _markSettled(BuildContext context, DocumentSnapshot doc) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Confirmer le règlement ?'),
        content: const Text(
            'Confirme que le livreur a bien remis les espèces au marchand '
            'pour cette commande. Action déclarative uniquement — aucun '
            'wallet n\'est modifié.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmer')),
        ],
      ),
    );
    if (confirm != true) return;
    await doc.reference.update({
      'merchantCashSettled': true,
      'merchantCashSettledAt': FieldValue.serverTimestamp(),
      'merchantCashSettledBy': FirebaseAuth.instance.currentUser?.uid,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Cash à régler — Marchands'),
        backgroundColor: Colors.red.shade700,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    color: Colors.orange.shade700, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Commandes cash restaurant/pharmacie où le livreur a collecté '
                    'la part du marchand mais ne l\'a pas encore remise. '
                    'À vérifier chaque jour avant clôture.',
                    style:
                        TextStyle(fontSize: 12, color: Colors.orange.shade800),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              // limit() par prudence (Master Prompt 79, 2026-07-09) : cette
              // liste doit rester courte par construction (réglée chaque
              // jour), mais sans plafond une négligence prolongée du
              // règlement cash ferait grossir indéfiniment le nombre de
              // documents lus à chaque frappe du StreamBuilder.
              stream: FirebaseFirestore.instance
                  .collection('orders')
                  .where('merchantCashSettled', isEqualTo: false)
                  .limit(100)
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
                        Icon(Icons.check_circle_rounded,
                            size: 64, color: Colors.green.shade300),
                        const SizedBox(height: 12),
                        const Text('Tout est réglé',
                            style: TextStyle(color: Colors.grey, fontSize: 15)),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final doc = docs[i];
                    final data = doc.data() as Map<String, dynamic>;
                    final merchant = (data['sellerName'] as String?) ??
                        (data['pharmacieName'] as String?) ??
                        'Marchand';
                    final amount = (data['budget'] as num?)?.toInt() ?? 0;
                    final driverId = (data['driverId'] as String?) ?? '—';
                    final deliveredAt =
                        (data['deliveredAt'] as Timestamp?)?.toDate();

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.red.shade100),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 6),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(merchant,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14)),
                              ),
                              Text('$amount FCFA',
                                  style: TextStyle(
                                      color: Colors.red.shade700,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Livreur : ${driverId.length > 8 ? driverId.substring(0, 8) : driverId}…'
                            '${deliveredAt != null ? ' · ${deliveredAt.day}/${deliveredAt.month} ${deliveredAt.hour}:${deliveredAt.minute.toString().padLeft(2, '0')}' : ''}',
                            style: TextStyle(
                                color: Colors.grey.shade600, fontSize: 12),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.green.shade700,
                                side: BorderSide(color: Colors.green.shade300),
                              ),
                              onPressed: () => _markSettled(context, doc),
                              child: const Text('Marquer réglé'),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
