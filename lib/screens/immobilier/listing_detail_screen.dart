import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../models/real_estate_listing.dart';
import '../../services/real_estate_service.dart';
import '../../theme/app_theme.dart';

class ListingDetailScreen extends StatefulWidget {
  final String listingId;
  const ListingDetailScreen({super.key, required this.listingId});

  @override
  State<ListingDetailScreen> createState() => _ListingDetailScreenState();
}

class _ListingDetailScreenState extends State<ListingDetailScreen> {
  @override
  void initState() {
    super.initState();
    RealEstateService.incrementViews(widget.listingId);
  }

  Future<void> _requestVisit(RealEstateListing listing) async {
    final dateCtrl = TextEditingController();
    final messageCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Demander une visite'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: dateCtrl,
              decoration: const InputDecoration(labelText: 'Date/moment souhaité (ex. samedi matin)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: messageCtrl,
              decoration: const InputDecoration(labelText: 'Message (optionnel)'),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Envoyer')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await RealEstateService.requestVisit(
        listingId: widget.listingId,
        preferredDate: dateCtrl.text.trim().isEmpty ? null : dateCtrl.text.trim(),
        message: messageCtrl.text.trim().isEmpty ? null : messageCtrl.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Demande de visite envoyée à l\'agent.'), backgroundColor: Colors.green),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur : $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('real_estate_listings').doc(widget.listingId).snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          if (!snap.data!.exists) return const Center(child: Text('Annonce introuvable'));
          final listing = RealEstateListing.fromDoc(snap.data!);

          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                expandedHeight: 220,
                flexibleSpace: FlexibleSpaceBar(
                  background: listing.images.isNotEmpty
                      ? Image.network(listing.images.first, fit: BoxFit.cover)
                      : Container(color: AppColors.primaryBg, child: const Icon(Icons.home_outlined, size: 56, color: AppColors.primary)),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(listing.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('${listing.city} · ${listing.propertyType}', style: TextStyle(color: Colors.grey.shade600)),
                      const SizedBox(height: 8),
                      Text(
                        '${listing.price} FCFA${listing.priceType == 'rent' ? ' / mois' : ''}',
                        style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 22),
                      ),
                      const SizedBox(height: 16),
                      const Text('Description', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(listing.description, style: TextStyle(color: Colors.grey.shade800)),
                      const SizedBox(height: 16),
                      if (listing.agentName != null) ...[
                        const Text('Agent', style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text('${listing.agentName}${listing.agentPhone != null ? ' — ${listing.agentPhone}' : ''}'),
                        const SizedBox(height: 16),
                      ],
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => _requestVisit(listing),
                          icon: const Icon(Icons.calendar_month_outlined),
                          label: const Text('Demander une visite'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
