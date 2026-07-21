import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../services/firestore_service.dart';
import '../../widgets/wallet_action_sheet.dart';
import '../../theme/app_theme.dart';

class DriverWallet extends StatelessWidget {
  final String driverId;
  final String driverName;

  const DriverWallet({
    super.key,
    required this.driverId,
    required this.driverName,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text("Mon Crédit"),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection("livreurs")
            .doc(driverId)
            .snapshots(),
        builder: (context, driverSnap) {
          int wallet = 0;
          if (driverSnap.hasData && driverSnap.data!.exists) {
            wallet = (driverSnap.data!["wallet"] as num? ?? 0).toInt();
          }

          return StreamBuilder<QuerySnapshot>(
            stream: FirestoreService().walletTransactions(driverId),
            builder: (context, txSnap) {
              final transactions = txSnap.data?.docs ?? [];

              // Calcul des totaux
              int totalRecharge = 0;
              int totalCommission = 0;
              for (final tx in transactions) {
                final data = tx.data() as Map<String, dynamic>;
                final type = data["type"] ?? "";
                final amount = (data["amount"] as num? ?? 0).toInt();
                if (type == "recharge") totalRecharge += amount;
                if (type == "commission") totalCommission += amount;
              }

              return Column(
                children: [
                  // ── CARTE SOLDE ────────────────────────────
                  Container(
                    margin: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.primary, Color(0xFFFF8F00)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.4),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.account_balance_wallet,
                                color: Colors.white70, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              driverName,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 14),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          "Crédit disponible",
                          style:
                              TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              _fmt(wallet),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 44,
                                fontWeight: FontWeight.w900,
                                height: 1,
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.only(bottom: 6, left: 6),
                              child: Text("FCFA",
                                  style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            _miniStat(Icons.arrow_downward,
                                "Rechargé", "$totalRecharge FCFA",
                                Colors.greenAccent),
                            const SizedBox(width: 24),
                            _miniStat(Icons.arrow_upward,
                                "Commissions", "$totalCommission FCFA",
                                Colors.redAccent.shade100),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => WalletActionSheet.show(
                                  context,
                                  action: WalletAction.recharge,
                                  userId: driverId,
                                  userType: 'driver',
                                  userName: driverName,
                                  currentBalance: wallet,
                                ),
                                icon: const Icon(Icons.add,
                                    color: AppColors.primary, size: 18),
                                label: const Text("Recharger",
                                    style: TextStyle(
                                        color: AppColors.primary,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(20)),
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 10),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => WalletActionSheet.show(
                                  context,
                                  action: WalletAction.withdraw,
                                  userId: driverId,
                                  userType: 'driver',
                                  userName: driverName,
                                  currentBalance: wallet,
                                ),
                                icon: const Icon(Icons.arrow_upward,
                                    color: AppColors.primary, size: 18),
                                label: const Text("Retirer",
                                    style: TextStyle(
                                        color: AppColors.primary,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(20)),
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 10),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // ── TITRE HISTORIQUE ────────────────────────
                  const Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "Historique des transactions",
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: Colors.black87),
                      ),
                    ),
                  ),

                  // ── LISTE TRANSACTIONS ──────────────────────
                  Expanded(
                    child: transactions.isEmpty
                        ? const Center(
                            child: Text("Aucune transaction",
                                style: TextStyle(color: Colors.grey)),
                          )
                        : ListView.builder(
                            physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            itemCount: transactions.length,
                            itemBuilder: (context, i) {
                              final data = transactions[i].data()
                                  as Map<String, dynamic>;
                              return _TransactionTile(data: data);
                            },
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _miniStat(
      IconData icon, String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 13),
            const SizedBox(width: 4),
            Text(label,
                style:
                    const TextStyle(color: Colors.white70, fontSize: 11)),
          ],
        ),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13)),
      ],
    );
  }

  String _fmt(int v) {
    if (v >= 1000) {
      final k = v ~/ 1000;
      final r = v % 1000;
      return r == 0 ? "$k 000" : "$k ${r.toString().padLeft(3, '0')}";
    }
    return v.toString();
  }
}

// ── Tuile transaction ─────────────────────────────────────────

class _TransactionTile extends StatelessWidget {
  final Map<String, dynamic> data;
  const _TransactionTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final type = data["type"] ?? "";
    final amount = (data["amount"] as num? ?? 0).toInt();
    final description = data["description"] ?? "";
    final ts = data["createdAt"];
    final date = ts != null
        ? (ts as Timestamp).toDate()
        : DateTime.now();

    final isRecharge = type == "recharge";

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4)
        ],
      ),
      child: Row(
        children: [
          // Icone
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: isRecharge
                  ? Colors.green.shade50
                  : Colors.red.shade50,
              shape: BoxShape.circle,
            ),
            child: Icon(
              isRecharge ? Icons.add_circle : Icons.remove_circle,
              color: isRecharge ? Colors.green : Colors.red,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),

          // Description + date
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  description,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  _formatDate(date),
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 11),
                ),
              ],
            ),
          ),

          // Montant
          Text(
            "${isRecharge ? '+' : '-'}$amount FCFA",
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isRecharge ? Colors.green : Colors.red,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) {
    return "${d.day.toString().padLeft(2, '0')}/"
        "${d.month.toString().padLeft(2, '0')}/"
        "${d.year}  "
        "${d.hour.toString().padLeft(2, '0')}:"
        "${d.minute.toString().padLeft(2, '0')}";
  }
}
