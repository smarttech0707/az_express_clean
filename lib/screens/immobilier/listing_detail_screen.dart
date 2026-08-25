import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../models/real_estate_display_location.dart';
import '../../models/real_estate_listing.dart';
import '../../models/real_estate_private_location.dart';
import '../../models/real_estate_property_type.dart';
import '../../models/real_estate_visit_request.dart';
import '../../services/map_navigation_service.dart';
import '../../services/real_estate_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/immobilier/listing_gallery_viewer.dart';
import '../../widgets/immobilier/property_details_display_section.dart';
import '../../widgets/immobilier/real_estate_location_card.dart';
import '../../widgets/stream_error_state.dart';

class ListingDetailScreen extends StatefulWidget {
  final String listingId;
  const ListingDetailScreen({super.key, required this.listingId});

  @override
  State<ListingDetailScreen> createState() => _ListingDetailScreenState();
}

class _ListingDetailScreenState extends State<ListingDetailScreen> {
  RealEstatePrivateLocation? _privateLocation;

  /// Empêche une nouvelle lecture privée à chaque reconstruction de l'écran
  /// (Mission 12 : "pas de lecture privée répétée à chaque rebuild") — une
  /// seule tentative par état de confirmation de visite (voir
  /// `_reloadedForConfirmedRequestId` pour le rechargement post-confirmation).
  bool _privateLocationChecked = false;
  String? _reloadedForConfirmedRequestId;

  // ── Position du client (Mission 6) — jamais demandée automatiquement.
  double? _clientLat;
  double? _clientLng;
  ClientGpsState? _clientGpsState;
  bool _locatingClient = false;

  @override
  void initState() {
    super.initState();
    RealEstateService.incrementViews(widget.listingId);
  }

  Future<void> _maybeLoadPrivateLocation(RealEstateListing listing) async {
    if (_privateLocationChecked) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final needsAccess = listing.locationPrivacy == 'hidden' ||
        listing.locationPrivacy == 'approximate';
    _privateLocationChecked = true;
    if (uid == null || !needsAccess) return;
    final loc = await RealEstateService.resolveAuthorizedPrivateLocation(
      listingId: widget.listingId,
      clientId: uid,
    );
    if (!mounted) return;
    setState(() => _privateLocation = loc);
  }

  Future<void> _requestClientPosition() async {
    setState(() => _locatingClient = true);
    final result = await MapNavigationService.requestClientPosition();
    if (!mounted) return;
    setState(() {
      _locatingClient = false;
      _clientGpsState = result.state;
      if (result.isGranted) {
        _clientLat = result.latitude;
        _clientLng = result.longitude;
      }
    });
  }

  Future<void> _requestVisit() async {
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
              decoration: const InputDecoration(
                  labelText: 'Date/moment souhaité (ex. samedi matin)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: messageCtrl,
              decoration:
                  const InputDecoration(labelText: 'Message (optionnel)'),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Envoyer')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await RealEstateService.requestVisit(
        listingId: widget.listingId,
        preferredDate:
            dateCtrl.text.trim().isEmpty ? null : dateCtrl.text.trim(),
        message:
            messageCtrl.text.trim().isEmpty ? null : messageCtrl.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Demande de visite envoyée à l\'agent.'),
            backgroundColor: Colors.green),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur : $e'), backgroundColor: Colors.red),
      );
    }
  }

  String _visitStatusLabel(String status) {
    switch (status) {
      case 'pending':
        return 'en attente de réponse de l\'agent';
      case 'proposed':
        return 'nouvelle date proposée par l\'agent';
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('real_estate_listings')
            .doc(widget.listingId)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const StreamErrorState(
                message: "Impossible de charger cette annonce.");
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snap.data!.exists) {
            return const Center(child: Text('Annonce introuvable'));
          }
          final listing = RealEstateListing.fromDoc(snap.data!);

          // Fire-and-forget, déjà idempotent par instance d'écran — pas de
          // setState synchrone pendant build().
          _maybeLoadPrivateLocation(listing);

          return StreamBuilder<List<RealEstateVisitRequest>>(
            stream: uid != null
                ? RealEstateService.visitRequestsAsClient(uid)
                : Stream.value(const <RealEstateVisitRequest>[]),
            builder: (context, visitSnap) {
              final forThisListing = (visitSnap.data ?? [])
                  .where((r) => r.listingId == widget.listingId)
                  .toList();

              RealEstateVisitRequest? active;
              RealEstateVisitRequest? confirmed;
              for (final r in forThisListing) {
                if (r.status == 'pending' || r.status == 'proposed') {
                  active ??= r;
                } else if (r.status == 'confirmed') {
                  confirmed ??= r;
                }
              }

              // Visite confirmée depuis le dernier chargement : redéclenche
              // une lecture de la position privée (Mission 10 — "recharger
              // la localisation privée... sans obliger à redémarrer
              // l'application"), une seule fois par demande confirmée.
              if (confirmed != null &&
                  confirmed.id != _reloadedForConfirmedRequestId) {
                _reloadedForConfirmedRequestId = confirmed.id;
                _privateLocationChecked = false;
                _maybeLoadPrivateLocation(listing);
              }

              final displayLocation = RealEstateDisplayLocation.resolve(
                listing: listing,
                privateLocation: _privateLocation,
              );

              return CustomScrollView(
                slivers: [
                  SliverAppBar(
                    pinned: true,
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    expandedHeight: 240,
                    flexibleSpace: FlexibleSpaceBar(
                      background: ListingGalleryHeader(
                        images: listing.images,
                        videos: listing.videos,
                        height: 240,
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(listing.title,
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          // Bug réel trouvé sur appareil (Mission 9, V6.1) :
                          // affichait la valeur canonique brute ("house")
                          // plutôt que le libellé français — contrairement à
                          // la carte de liste, déjà correcte via `.label()`.
                          Text(
                              '${listing.city} · ${RealEstatePropertyType.label(listing.propertyType)}',
                              style: TextStyle(color: Colors.grey.shade600)),
                          const SizedBox(height: 8),
                          Text(
                            '${listing.price} FCFA${listing.priceType == 'rent' ? ' / mois' : ''}',
                            style: const TextStyle(
                                color: AppColors.primary,
                                fontWeight: FontWeight.bold,
                                fontSize: 22),
                          ),
                          const SizedBox(height: 16),
                          PropertyDetailsDisplaySection(listing: listing),
                          const Text('Description',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(listing.description,
                              style: TextStyle(color: Colors.grey.shade800)),
                          const SizedBox(height: 16),
                          if (listing.agentName != null) ...[
                            const Text('Agent',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            Text(
                                '${listing.agentName}${listing.agentPhone != null ? ' — ${listing.agentPhone}' : ''}'),
                            const SizedBox(height: 16),
                          ],
                          RealEstateLocationCard(
                            listingTitle: listing.title,
                            propertyType: listing.propertyType,
                            location: displayLocation,
                            clientLatitude: _clientLat,
                            clientLongitude: _clientLng,
                            clientGpsState: _clientGpsState,
                            isLocatingClient: _locatingClient,
                            onRequestClientPosition: _requestClientPosition,
                          ),
                          const SizedBox(height: 16),
                          if (active != null)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: const BoxDecoration(
                                color: AppColors.blueBg,
                                borderRadius: AppRadius.cardR,
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.calendar_month_outlined,
                                      color: AppColors.info),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Demande de visite : ${_visitStatusLabel(active.status)}',
                                      style: const TextStyle(
                                          color: AppColors.info),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else if (confirmed != null)
                            // Bug confirmé sur appareil réel (Mission 7/14) :
                            // sans ce cas, "Demander une visite" restait
                            // affiché même après confirmation, permettant une
                            // nouvelle demande sans raison sur une annonce
                            // déjà visitée.
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: const BoxDecoration(
                                color: AppColors.greenBg,
                                borderRadius: AppRadius.cardR,
                              ),
                              child: const Row(
                                children: [
                                  Icon(Icons.check_circle_outline,
                                      color: AppColors.success),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Visite confirmée avec l\'agent',
                                      style:
                                          TextStyle(color: AppColors.success),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _requestVisit,
                                icon: const Icon(Icons.calendar_month_outlined),
                                label: const Text('Demander une visite'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: Colors.white,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
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
          );
        },
      ),
    );
  }
}
