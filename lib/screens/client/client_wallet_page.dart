import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../l10n/app_text.dart';
import '../../widgets/wallet_action_sheet.dart';
import '../../theme/app_theme.dart';

class ClientWalletPage extends StatefulWidget {
  const ClientWalletPage({super.key});

  @override
  State<ClientWalletPage> createState() => _ClientWalletPageState();
}

class _ClientWalletPageState extends State<ClientWalletPage> {
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  Widget build(BuildContext context) {
    if (_uid == null) {
      return Scaffold(
        body: Center(child: Text(context.tr('conn_required'))),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection("clients")
            .doc(_uid)
            .snapshots(),
        builder: (context, snap) {
          final wallet =
              ((snap.data?.data() as Map?)?["wallet"] as num?)?.toInt() ?? 0;

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: (MediaQuery.of(context).size.height * 0.30).clamp(220.0, 300.0),
                pinned: true,
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
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
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.account_balance_wallet,
                              color: Colors.white70, size: 36),
                          const SizedBox(height: 8),
                          Text(context.tr('my_wallet'),
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 14)),
                          const SizedBox(height: 4),
                          Text(
                            _fmt(wallet),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 46,
                              fontWeight: FontWeight.w900,
                              height: 1,
                            ),
                          ),
                          const Text("FCFA",
                              style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ElevatedButton.icon(
                                onPressed: () => WalletActionSheet.show(
                                  context,
                                  action: WalletAction.recharge,
                                  userId: _uid!,
                                  userType: 'client',
                                  userName: 'Client',
                                  currentBalance: (wallet as num? ?? 0).toInt(),
                                ),
                                icon: const Icon(Icons.add,
                                    color: Color(0xFFE65100), size: 18),
                                label: Text(context.tr('top_up'),
                                    style: const TextStyle(
                                        color: Color(0xFFE65100),
                                        fontWeight: FontWeight.bold)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(20)),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20, vertical: 10),
                                ),
                              ),
                              const SizedBox(width: 10),
                              ElevatedButton.icon(
                                onPressed: () => WalletActionSheet.show(
                                  context,
                                  action: WalletAction.withdraw,
                                  userId: _uid!,
                                  userType: 'client',
                                  userName: 'Client',
                                  currentBalance: (wallet as num? ?? 0).toInt(),
                                ),
                                icon: const Icon(Icons.arrow_upward,
                                    color: Color(0xFFE65100), size: 18),
                                label: const Text("Retirer",
                                    style: TextStyle(
                                        color: Color(0xFFE65100),
                                        fontWeight: FontWeight.bold)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(20)),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20, vertical: 10),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                title: Text(context.tr('my_wallet')),
                centerTitle: true,
              ),

              // Historique transactions
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection("clients")
                    .doc(_uid)
                    .collection("wallet_transactions")
                    .orderBy("createdAt", descending: true)
                    .limit(50)
                    .snapshots(),
                builder: (context, txSnap) {
                  final txs = txSnap.data?.docs ?? [];

                  if (txs.isEmpty) {
                    return SliverFillRemaining(
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.receipt_long_outlined,
                                size: 56, color: Colors.grey),
                            const SizedBox(height: 12),
                            Text(context.tr('no_transactions'),
                                style: const TextStyle(color: Colors.grey)),
                          ],
                        ),
                      ),
                    );
                  }

                  return SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) {
                          if (i == 0) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                context.tr('tx_history'),
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15),
                              ),
                            );
                          }
                          final data = txs[i - 1].data()
                              as Map<String, dynamic>;
                          return _TxTile(data: data);
                        },
                        childCount: txs.length + 1,
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  String _fmt(int v) {
    if (v >= 1000) {
      return "${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}";
    }
    return v.toString();
  }
}

class _TxTile extends StatelessWidget {
  final Map<String, dynamic> data;
  const _TxTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final type = data["type"] ?? "";
    final amount = (data["amount"] as num? ?? 0).toInt();
    final desc = data["description"] ?? "";
    final ts = data["createdAt"] as Timestamp?;
    final date = ts?.toDate() ?? DateTime.now();

    final isCredit = type == "recharge" || type == "refund";
    final color = isCredit ? Colors.green : Colors.red;
    final icon = type == "recharge"
        ? Icons.add_circle
        : type == "refund"
            ? Icons.refresh
            : type == "withdrawal"
                ? Icons.arrow_circle_up
                : Icons.remove_circle;

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
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(desc,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                Text(
                  "${date.day.toString().padLeft(2, '0')}/"
                  "${date.month.toString().padLeft(2, '0')}/"
                  "${date.year}  "
                  "${date.hour.toString().padLeft(2, '0')}:"
                  "${date.minute.toString().padLeft(2, '0')}",
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 11),
                ),
              ],
            ),
          ),
          Text(
            "${isCredit ? '+' : '-'}$amount FCFA",
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: color,
                fontSize: 14),
          ),
        ],
      ),
    );
  }
}
