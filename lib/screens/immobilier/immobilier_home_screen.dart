import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/real_estate_listing.dart';
import '../../models/real_estate_property_type.dart';
import '../../models/real_estate_search_filters.dart';
import '../../services/real_estate_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/immobilier/property_filter_sheet.dart';
import '../../widgets/stream_error_state.dart';
import 'listing_detail_screen.dart';
import 'agent_dashboard_screen.dart';

class ImmobilierHomeScreen extends StatefulWidget {
  final String? initialPriceType;
  final String? initialPropertyType;
  final bool? initialFurnished;

  const ImmobilierHomeScreen({
    super.key,
    this.initialPriceType,
    this.initialPropertyType,
    this.initialFurnished,
  });

  @override
  State<ImmobilierHomeScreen> createState() => _ImmobilierHomeScreenState();
}

class _ImmobilierHomeScreenState extends State<ImmobilierHomeScreen> {
  final _searchCtrl = TextEditingController();
  String? _priceTypeFilter; // null = tous, 'sale', 'rent'
  RealEstateSearchFilters _filters = const RealEstateSearchFilters();
  List<RealEstateListing>? _searchResults;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _priceTypeFilter = widget.initialPriceType;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    setState(() => _searching = true);
    try {
      final f = _filters;
      final results = await RealEstateService.search(
        query: _searchCtrl.text.trim().isEmpty ? null : _searchCtrl.text.trim(),
        priceType: _priceTypeFilter,
        propertyType: widget.initialPropertyType,
        furnished: widget.initialFurnished ?? f.furnished,
        city: f.city,
        quartier: f.quartier,
        minPrice: f.minPrice,
        maxPrice: f.maxPrice,
        minSurface: f.minSurface,
        maxSurface: f.maxSurface,
        minBedrooms: f.minBedrooms,
        hasPool: f.hasPool,
        hasGarage: f.hasGarage,
        hasParking: f.hasParking,
        hasInternet: f.hasInternet,
        availableOnly: f.availableOnly,
        landOnly: f.landOnly,
        commercialOnly: f.commercialOnly,
        furnishedResidenceOnly: f.furnishedResidenceOnly,
        fromLatitude: f.fromLatitude,
        fromLongitude: f.fromLongitude,
        maxDistanceKm: f.maxDistanceKm,
      );
      if (mounted) setState(() => _searchResults = results);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _openFilters() async {
    final result = await showPropertyFilterSheet(context, current: _filters);
    if (result == null || !mounted) return;
    setState(() => _filters = result);
    _runSearch();
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() {
      _searchResults = null;
      _priceTypeFilter = null;
      _filters = const RealEstateSearchFilters();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Immobilier'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.storefront_outlined),
            tooltip: 'Espace agent',
            onPressed: () => Navigator.push(context,
                AppTransitions.fadeSlide(const AgentDashboardScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    onSubmitted: (_) => _runSearch(),
                    decoration: InputDecoration(
                      hintText: 'Rechercher une maison, un terrain...',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: (_searchResults != null)
                          ? IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: _clearSearch)
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconButton.filledTonal(
                      onPressed: _openFilters,
                      icon: const Icon(Icons.tune_rounded),
                      tooltip: 'Filtres',
                    ),
                    if (!_filters.isEmpty)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                              color: AppColors.primary, shape: BoxShape.circle),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _searching ? null : _runSearch,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white),
                  child: _searching
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Chercher'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _FilterChip(
                  label: 'Vente',
                  selected: _priceTypeFilter == 'sale',
                  onTap: () {
                    setState(() => _priceTypeFilter =
                        _priceTypeFilter == 'sale' ? null : 'sale');
                    _runSearch();
                  },
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Location',
                  selected: _priceTypeFilter == 'rent',
                  onTap: () {
                    setState(() => _priceTypeFilter =
                        _priceTypeFilter == 'rent' ? null : 'rent');
                    _runSearch();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _searchResults != null
                ? _ListingGrid(listings: _searchResults!)
                : StreamBuilder<List<RealEstateListing>>(
                    stream: RealEstateService.streamActive(
                      propertyType: widget.initialPropertyType,
                      priceType: _priceTypeFilter,
                      furnished: widget.initialFurnished,
                    ),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return const StreamErrorState(
                            message: "Impossible de charger les annonces.");
                      }
                      if (!snap.hasData)
                        return const Center(child: CircularProgressIndicator());
                      return _ListingGrid(listings: snap.data!);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.primary.withValues(alpha: 0.15),
      labelStyle: TextStyle(
          color: selected ? AppColors.primary : Colors.black87,
          fontWeight: FontWeight.w600),
    );
  }
}

class _ListingGrid extends StatelessWidget {
  final List<RealEstateListing> listings;
  const _ListingGrid({required this.listings});

  @override
  Widget build(BuildContext context) {
    if (listings.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.home_outlined, size: 56, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('Aucune annonce pour le moment',
                style: TextStyle(color: Colors.grey.shade600)),
          ],
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: listings.length,
      itemBuilder: (context, i) => _ListingCard(listing: listings[i]),
    );
  }
}

class _ListingCard extends StatelessWidget {
  final RealEstateListing listing;
  const _ListingCard({required this.listing});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(context,
          AppTransitions.fadeSlide(ListingDetailScreen(listingId: listing.id))),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(
                color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1.4,
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(14)),
                child: listing.images.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: listing.images.first,
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: Colors.grey.shade200),
                        errorWidget: (_, __, ___) => Container(
                            color: Colors.grey.shade200,
                            child: Icon(Icons.broken_image_outlined,
                                color: Colors.grey.shade400, size: 32)),
                      )
                    : Container(
                        color: Colors.grey.shade200,
                        child: Icon(Icons.home_outlined,
                            color: Colors.grey.shade400, size: 32)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(listing.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(
                      '${listing.city} · ${RealEstatePropertyType.label(listing.propertyType)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  // Mission 5 : uniquement l'info la plus pertinente selon le
                  // type — surface pour un terrain, chambres pour un bien
                  // habitable, rien pour un type sans donnée renseignée.
                  if (RealEstatePropertyType.isLand(listing.propertyType) &&
                      listing.surfaceTerrain != null)
                    Text('${listing.surfaceTerrain!.toStringAsFixed(0)} m²',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade600))
                  else if (listing.bedrooms != null)
                    Text('${listing.bedrooms} ch.',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Text(
                    '${listing.price} FCFA${listing.priceType == 'rent' ? '/mois' : ''}',
                    style: const TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
