import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../ek_constants.dart';
import '../models/ek_order.dart';
import '../services/ek_service.dart';
import 'ek_order_tracking.dart';

class EkHistoryScreen extends StatelessWidget {
  const EkHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: kEkBg,
      appBar: AppBar(
        backgroundColor: kEkDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('Historique',
            style: GoogleFonts.urbanist(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
      ),
      body: uid == null
          ? const Center(child: Text('Non connecté'))
          : StreamBuilder<List<EkOrder>>(
              stream: _historyStream(uid),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final orders = snap.data ?? [];
                if (orders.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('📋', style: TextStyle(fontSize: 56)),
                        const SizedBox(height: 16),
                        Text('Aucune commande terminée',
                            style: GoogleFonts.urbanist(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: kEkText)),
                        const SizedBox(height: 8),
                        Text('Vos commandes complètes apparaîtront ici',
                            style: GoogleFonts.urbanist(
                                fontSize: 13, color: kEkMuted)),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: orders.length,
                  itemBuilder: (_, i) => _HistoryCard(order: orders[i]),
                );
              },
            ),
    );
  }

  Stream<List<EkOrder>> _historyStream(String uid) {
    return FirebaseFirestore.instance
        .collection('ekbine_orders')
        .where('clientId', isEqualTo: uid)
        .where('status', whereIn: ['completed', 'cancelled', 'disputed'])
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((s) => s.docs.map(EkOrder.fromDoc).toList());
  }
}

class _HistoryCard extends StatelessWidget {
  final EkOrder order;
  const _HistoryCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final statusColor = ekStatusColor(order.status);
    final opColor = EkService.operatorColor(order.operator);

    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => EkOrderTracking(order: order))),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kEkDivider),
          boxShadow: const [
            BoxShadow(
                color: Color(0x06000000), blurRadius: 6, offset: Offset(0, 2))
          ],
        ),
        child: Row(children: [
          // Operator circle
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: opColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(order.operator[0].toUpperCase(),
                  style: GoogleFonts.urbanist(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: opColor)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(order.serviceLabel,
                    style: GoogleFonts.urbanist(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: kEkText)),
                Text(order.beneficiaryNumber,
                    style: GoogleFonts.urbanist(fontSize: 12, color: kEkMuted)),
                if (order.createdAt != null)
                  Text(_dateStr(order.createdAt!),
                      style:
                          GoogleFonts.urbanist(fontSize: 10, color: kEkMuted)),
              ],
            ),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_fmt(order.totalPaid),
                style: GoogleFonts.urbanist(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: order.status == 'completed' ? kEkGreen : kEkMuted)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                ekStatusLabels[order.status] ?? order.status,
                style: GoogleFonts.urbanist(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: statusColor),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  String _dateStr(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
}

String _fmt(int price) {
  final s = price.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return '${buf.toString()} F';
}
