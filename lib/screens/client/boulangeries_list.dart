import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';

import 'boulangerie_order_page.dart';

class BoulangeriesList extends StatelessWidget {
  const BoulangeriesList({super.key});

  bool _isCurrentlyOpen(Map<String, dynamic> data) {
    if (data['isOpen'] != true) return false;
    final openStr  = data['openTime']  as String?;
    final closeStr = data['closeTime'] as String?;
    if (openStr == null || closeStr == null) return true;
    try {
      final now   = TimeOfDay.now();
      final open  = _parseTime(openStr);
      final close = _parseTime(closeStr);
      final nowMin   = now.hour * 60 + now.minute;
      final openMin  = open.hour * 60 + open.minute;
      final closeMin = close.hour * 60 + close.minute;
      return nowMin >= openMin && nowMin < closeMin;
    } catch (_) {
      return true;
    }
  }

  TimeOfDay _parseTime(String t) {
    final parts = t.replaceAll('h', ':').split(':');
    return TimeOfDay(
        hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('Boulangeries & Cafés',
            style: GoogleFonts.urbanist(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF5D4037),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: Column(
        children: [
          // ── Bannière petit-déjeuner ──────────────────────────────
          Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.brown.shade800, Colors.brown.shade500],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(children: [
              const Text('🥐', style: TextStyle(fontSize: 40)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Petit-déjeuner livré',
                        style: GoogleFonts.urbanist(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16)),
                    Text(
                      'Pains, viennoiseries, cafés… livrés chez vous le matin',
                      style: GoogleFonts.urbanist(
                          color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ]),
          ),

          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('boulangeries')
                  .where('isActive', isEqualTo: true)
                  .orderBy('name')
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
                        const Text('🥖',
                            style: TextStyle(fontSize: 64)),
                        const SizedBox(height: 16),
                        Text('Aucune boulangerie disponible',
                            style: GoogleFonts.urbanist(
                                color: Colors.grey, fontSize: 16)),
                        Text('Revenez bientôt !',
                            style: GoogleFonts.urbanist(
                                color: Colors.grey.shade400,
                                fontSize: 13)),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding:
                      const EdgeInsets.fromLTRB(14, 0, 14, 24),
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final doc  = docs[i];
                    final data = doc.data() as Map<String, dynamic>;
                    final isOpen = _isCurrentlyOpen(data);
                    final name     = data['name']      ?? '—';
                    final address  = data['address']   ?? '—';
                    final openTime  = data['openTime']  ?? '—';
                    final closeTime = data['closeTime'] ?? '—';

                    return GestureDetector(
                      onTap: isOpen
                          ? () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => BoulangerieOrderPage(
                                    boulangerieId: doc.id,
                                    boulangerieData: data,
                                  ),
                                ),
                              )
                          : () => ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(
                                content: Text(
                                    '$name est actuellement fermée. Horaires : $openTime – $closeTime'),
                                behavior: SnackBarBehavior.floating,
                              )),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.brown
                                  .withValues(alpha: 0.08),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                          border: Border.all(
                            color: isOpen
                                ? Colors.green.shade100
                                : Colors.grey.shade200,
                          ),
                        ),
                        child: Column(
                          children: [
                            // ── Header ───────────────────────────
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: isOpen
                                      ? [
                                          Colors.brown.shade700,
                                          Colors.brown.shade400,
                                        ]
                                      : [
                                          Colors.grey.shade400,
                                          Colors.grey.shade300,
                                        ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(18)),
                              ),
                              child: Row(children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Colors.white
                                        .withValues(alpha: 0.2),
                                    borderRadius:
                                        BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                      Icons.bakery_dining_rounded,
                                      color: Colors.white,
                                      size: 28),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(name,
                                          style: GoogleFonts.urbanist(
                                              color: Colors.white,
                                              fontWeight:
                                                  FontWeight.bold,
                                              fontSize: 16)),
                                      Text(address,
                                          style: GoogleFonts.urbanist(
                                              color: Colors.white70,
                                              fontSize: 12)),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: isOpen
                                        ? Colors.green
                                        : Colors.red.shade400,
                                    borderRadius:
                                        BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    isOpen ? 'Ouvert' : 'Fermé',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ]),
                            ),

                            // ── Infos ─────────────────────────────
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  16, 12, 16, 14),
                              child: Row(children: [
                                Icon(Icons.schedule_rounded,
                                    size: 14,
                                    color: Colors.grey.shade500),
                                const SizedBox(width: 6),
                                Text(
                                  'Horaires : $openTime – $closeTime',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600),
                                ),
                                const Spacer(),
                                if (isOpen)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Colors.brown.shade700,
                                      borderRadius:
                                          BorderRadius.circular(20),
                                    ),
                                    child: Row(children: [
                                      const Icon(
                                          Icons.shopping_bag_outlined,
                                          color: Colors.white,
                                          size: 14),
                                      const SizedBox(width: 4),
                                      Text('Commander',
                                          style: GoogleFonts.urbanist(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight:
                                                  FontWeight.w600)),
                                    ]),
                                  ),
                              ]),
                            ),
                          ],
                        ),
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
