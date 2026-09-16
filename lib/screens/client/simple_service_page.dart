import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_text.dart';
import '../../theme/app_theme.dart';
import '../../widgets/premium_background.dart';
import '../../widgets/premium_empty_state.dart';

class SimpleServicePage extends StatelessWidget {
  final String serviceType; // "tricycle" | "taxi_nuit"
  final String title;
  final String subtitle;
  final IconData icon;
  final List<Color> gradient;
  final Color color;

  const SimpleServicePage({
    super.key,
    required this.serviceType,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradient,
    required this.color,
  });

  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:${phone.replaceAll(RegExp(r'[\s\-()]'), '')}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Widget _photoFallback(List<Color> grad, IconData ic) {
    return Container(
      decoration: BoxDecoration(gradient: LinearGradient(colors: grad)),
      child: Center(child: Icon(ic, color: Colors.white38, size: 40)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final textColor = AppColors.premiumTextPrimary(brightness);
    final mutedColor = AppColors.premiumTextSecondary(brightness);
    final directoryMessage = serviceType == 'taxi_nuit'
        ? 'Annuaire de chauffeurs. Appelez directement le chauffeur pour convenir du trajet.'
        : 'Annuaire de prestataires. Appelez directement le prestataire pour convenir du service.';
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: PremiumBackground(
          child: CustomScrollView(
        slivers: [
          // Header
          SliverAppBar(
            expandedHeight:
                (MediaQuery.of(context).size.height * 0.20).clamp(140.0, 200.0),
            pinned: true,
            backgroundColor: AppColors.premiumSurface(brightness),
            foregroundColor: textColor,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  color: AppColors.premiumSurface(brightness),
                  border: Border(
                    bottom: BorderSide(color: color.withValues(alpha: 0.25)),
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 44),
                        Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.12),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(icon, color: color, size: 24),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                title,
                                style: AppTypography.headlineStyle(
                                  context,
                                  color: textColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: AppTypography.bodySmallStyle(
                            context,
                            color: mutedColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: Text(title,
                style:
                    AppTypography.titleLargeStyle(context, color: textColor)),
            centerTitle: false,
          ),

          // Liste
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                directoryMessage,
                style: AppTypography.bodySmallStyle(context, color: mutedColor),
              ),
            ),
          ),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection("simple_services")
                .where("serviceType", isEqualTo: serviceType)
                .where("isAvailable", isEqualTo: true)
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              final docs = snap.data?.docs ?? [];

              if (docs.isEmpty) {
                return SliverFillRemaining(
                  child: PremiumEmptyState(
                    icon: icon,
                    title: context.tr('no_provider'),
                    message: context.tr('come_back'),
                    accent: color,
                  ),
                );
              }

              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final data = docs[i].data() as Map<String, dynamic>;
                      final name = data["name"] ?? "Sans nom";
                      final phone = data["phone"] ?? "";

                      final photoUrl = data["photoUrl"] as String?;
                      final hasPhoto = photoUrl != null && photoUrl.isNotEmpty;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: AppColors.premiumSurfaceElevated(brightness),
                          borderRadius: AppRadius.xlR,
                          border: Border.all(
                            color: AppColors.premiumBorder(brightness),
                          ),
                          boxShadow: AppShadow.xs,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Photo du prestataire
                            if (hasPhoto)
                              ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(16)),
                                child: SizedBox(
                                  height: 150,
                                  width: double.infinity,
                                  child: Image.network(
                                    photoUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        _photoFallback(gradient, icon),
                                  ),
                                ),
                              )
                            else
                              ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(16)),
                                child: SizedBox(
                                  height: 80,
                                  width: double.infinity,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      gradient:
                                          LinearGradient(colors: gradient),
                                    ),
                                    child: Center(
                                        child: Icon(icon,
                                            color: Colors.white38, size: 36)),
                                  ),
                                ),
                              ),

                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15,
                                          ),
                                        ),
                                        if (phone.isNotEmpty) ...[
                                          const SizedBox(height: 3),
                                          Text(
                                            phone,
                                            style: TextStyle(
                                              color: Colors.grey.shade600,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Icon(Icons.verified_user_rounded,
                                                size: 12,
                                                color: Colors.green.shade600),
                                            const SizedBox(width: 4),
                                            Text(
                                              context.tr('verified_provider'),
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.green.shade600),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),

                                  // Bouton appel
                                  if (phone.isNotEmpty)
                                    GestureDetector(
                                      onTap: () => _call(phone),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: Colors.green,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(Icons.phone_rounded,
                                                color: Colors.white, size: 16),
                                            const SizedBox(width: 6),
                                            Text(
                                              context.tr('call'),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                    childCount: docs.length,
                  ),
                ),
              );
            },
          ),
        ],
      )),
    );
  }
}
