import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';
import '../../widgets/premium_background.dart';
import '../../widgets/premium_empty_state.dart';
import 'boulangerie_order_page.dart';

class BoulangeriesList extends StatelessWidget {
  const BoulangeriesList({super.key});

  bool _isCurrentlyOpen(Map<String, dynamic> data) {
    if (data['isOpen'] != true) return false;
    final openStr = data['openTime'] as String?;
    final closeStr = data['closeTime'] as String?;
    if (openStr == null || closeStr == null) return true;
    try {
      final now = TimeOfDay.now();
      final open = _parseTime(openStr);
      final close = _parseTime(closeStr);
      final nowMin = now.hour * 60 + now.minute;
      final openMin = open.hour * 60 + open.minute;
      final closeMin = close.hour * 60 + close.minute;
      return nowMin >= openMin && nowMin < closeMin;
    } catch (_) {
      return true;
    }
  }

  TimeOfDay _parseTime(String t) {
    final parts = t.replaceAll('h', ':').split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final textColor = AppColors.premiumTextPrimary(brightness);
    final mutedColor = AppColors.premiumTextSecondary(brightness);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text('Boulangeries & Cafés',
            style: AppTypography.titleLargeStyle(context, color: textColor)),
        backgroundColor: AppColors.premiumSurface(brightness),
        foregroundColor: textColor,
        centerTitle: false,
      ),
      body: PremiumBackground(
          child: Column(
        children: [
          // ── Bannière petit-déjeuner ──────────────────────────────
          Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.premiumSurfaceElevated(brightness),
              borderRadius: AppRadius.xlR,
              border: Border.all(color: AppColors.premiumBorder(brightness)),
              boxShadow: AppShadow.xs,
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
                            color: textColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 16)),
                    Text(
                      'Pains, viennoiseries, cafés… livrés chez vous le matin',
                      style:
                          GoogleFonts.urbanist(color: mutedColor, fontSize: 12),
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
                  return const PremiumEmptyState(
                    icon: Icons.bakery_dining_rounded,
                    title: 'Aucune boulangerie disponible',
                    message:
                        'Revenez bientôt pour découvrir les établissements.',
                    accent: Color(0xFF795548),
                  );
                }

                return ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final doc = docs[i];
                    final data = doc.data() as Map<String, dynamic>;
                    final isOpen = _isCurrentlyOpen(data);
                    final name = data['name'] ?? '—';
                    final address = data['address'] ?? '—';
                    final openTime = data['openTime'] ?? '—';
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
                          color: AppColors.premiumSurfaceElevated(brightness),
                          borderRadius: AppRadius.xlR,
                          boxShadow: AppShadow.xs,
                          border: Border.all(
                            color: isOpen
                                ? AppColors.green.withValues(alpha: 0.25)
                                : AppColors.premiumBorder(brightness),
                          ),
                        ),
                        child: Column(
                          children: [
                            // ── Header ───────────────────────────
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: const Color(0xFF795548)
                                    .withValues(alpha: isOpen ? 0.13 : 0.07),
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(18)),
                              ),
                              child: Row(children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF795548)
                                        .withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(Icons.bakery_dining_rounded,
                                      color: Color(0xFF795548), size: 28),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(name,
                                          style: GoogleFonts.urbanist(
                                              color: textColor,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16)),
                                      Text(address,
                                          style: GoogleFonts.urbanist(
                                              color: mutedColor, fontSize: 12)),
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
                                    borderRadius: BorderRadius.circular(20),
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
                              padding:
                                  const EdgeInsets.fromLTRB(16, 12, 16, 14),
                              child: Row(children: [
                                Icon(Icons.schedule_rounded,
                                    size: 14, color: mutedColor),
                                const SizedBox(width: 6),
                                Text(
                                  'Horaires : $openTime – $closeTime',
                                  style: TextStyle(
                                      fontSize: 12, color: mutedColor),
                                ),
                                const Spacer(),
                                if (isOpen)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Colors.brown.shade700,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Row(children: [
                                      const Icon(Icons.shopping_bag_outlined,
                                          color: Colors.white, size: 14),
                                      const SizedBox(width: 4),
                                      Text('Commander',
                                          style: GoogleFonts.urbanist(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600)),
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
      )),
    );
  }
}
