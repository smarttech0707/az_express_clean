import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/vehicle_listing.dart';
import '../vehicle_formatters.dart';
import '../vehicle_listing_repository.dart';
import '../vehicle_listing_query.dart';
import '../vehicle_favorite_repository.dart';
import '../vehicle_trust_repository.dart';
import '../widgets/vehicle_listing_card.dart';
import '../widgets/vehicle_filter_sheet.dart';
import 'vehicle_listing_detail_screen.dart';

typedef VehicleListingsPageLoader = Future<VehicleListingsPage> Function({
  required String cityId,
  required VehicleOfferType offerType,
  required VehicleType vehicleType,
  required int pageSize,
  DocumentSnapshot<Map<String, dynamic>>? startAfter,
});

typedef VehicleSearchPageLoader = Future<VehicleListingsPage> Function({
  required VehicleListingRequest request,
  required int pageSize,
  DocumentSnapshot<Map<String, dynamic>>? startAfter,
});

class VehicleListingsScreen extends StatefulWidget {
  const VehicleListingsScreen({
    super.key,
    required this.offerType,
    required this.vehicleType,
    required this.cityId,
    this.pageLoader,
    this.detailProfileLoader,
    this.searchPageLoader,
    this.currentUserId,
  });

  final VehicleOfferType offerType;
  final VehicleType vehicleType;
  final String cityId;
  final VehicleListingsPageLoader? pageLoader;
  final VehicleSellerProfileLoader? detailProfileLoader;
  final VehicleSearchPageLoader? searchPageLoader;
  final String? currentUserId;

  @override
  State<VehicleListingsScreen> createState() => _VehicleListingsScreenState();
}

class _VehicleListingsScreenState extends State<VehicleListingsScreen> {
  static const _pageSize = 15;

  late final VehicleListingRepository? _repository;
  final _scrollController = ScrollController();
  final _listings = <VehicleListing>[];
  DocumentSnapshot<Map<String, dynamic>>? _cursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  Object? _error;
  final _searchController = TextEditingController();
  Timer? _debounce;
  VehicleListingFilters _filters = const VehicleListingFilters();
  VehicleListingSort _sort = VehicleListingSort.newest;
  final _favoriteIds = <String>{};
  Set<String> _blockedSellerIds = const {};
  late final VehicleFavoriteRepository? _favoriteRepository =
      widget.currentUserId == '__test__' ? null : VehicleFavoriteRepository();

  String? get _uid {
    if (widget.currentUserId != null) return widget.currentUserId;
    try {
      final user = FirebaseAuth.instance.currentUser;
      return user?.isAnonymous == false ? user?.uid : null;
    } catch (_) {
      return null;
    }
  }

  VehicleListingRequest get _request => VehicleListingRequest(
        cityId: widget.cityId,
        offerType: widget.offerType,
        vehicleType: widget.vehicleType,
        searchText: _searchController.text,
        filters: _filters,
        sort: _sort,
      );

  @override
  void initState() {
    super.initState();
    _repository = widget.pageLoader == null && widget.searchPageLoader == null
        ? VehicleListingRepository()
        : null;
    _scrollController.addListener(_onScroll);
    _loadFirstPage();
  }

  @override
  void didUpdateWidget(covariant VehicleListingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cityId != widget.cityId ||
        oldWidget.offerType != widget.offerType ||
        oldWidget.vehicleType != widget.vehicleType) {
      _loadFirstPage();
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 320) _loadMore();
  }

  Future<VehicleListingsPage> _loadPage(
    DocumentSnapshot<Map<String, dynamic>>? cursor,
  ) {
    final searchLoader = widget.searchPageLoader;
    if (searchLoader != null) {
      return searchLoader(
        request: _request,
        pageSize: _pageSize,
        startAfter: cursor,
      );
    }
    final loader = widget.pageLoader;
    if (loader != null &&
        _searchController.text.isEmpty &&
        _filters.isEmpty &&
        _sort == VehicleListingSort.newest) {
      return loader(
        cityId: widget.cityId,
        offerType: widget.offerType,
        vehicleType: widget.vehicleType,
        pageSize: _pageSize,
        startAfter: cursor,
      );
    }
    return _repository!.searchActiveListings(
      request: _request,
      pageSize: _pageSize,
      startAfter: cursor,
    );
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _error = null;
      _hasMore = true;
      _cursor = null;
      _listings.clear();
    });
    try {
      final uid = _uid;
      if (uid != null && uid != '__test__') {
        _blockedSellerIds =
            await VehicleTrustRepository().getBlockedUserIds(uid);
      }
      final page = await _loadPage(null);
      if (!mounted) return;
      setState(() {
        _listings.addAll(
          page.listings.where(
            (listing) => !_blockedSellerIds.contains(listing.sellerId),
          ),
        );
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
      await _loadFavoriteState(page.listings);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _loadPage(_cursor);
      if (!mounted) return;
      final knownIds = _listings.map((listing) => listing.id).toSet();
      setState(() {
        _listings.addAll(
          page.listings.where((listing) =>
              !_blockedSellerIds.contains(listing.sellerId) &&
              knownIds.add(listing.id)),
        );
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
      await _loadFavoriteState(page.listings);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${vehicleOfferLabel(widget.offerType)} • ${vehicleTypeLabel(widget.vehicleType)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(top: false, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        _controls(),
        Expanded(child: _results()),
      ],
    );
  }

  Widget _results() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _listings.isEmpty) {
      return _MessageState(
        icon: Icons.cloud_off_rounded,
        message: 'Impossible de charger les annonces.',
        actionLabel: 'Réessayer',
        onAction: _loadFirstPage,
      );
    }
    if (_listings.isEmpty) {
      return _MessageState(
        icon: Icons.directions_car_outlined,
        message: 'Aucune annonce disponible pour le moment.',
        actionLabel: _hasMore ? 'Chercher dans la suite' : null,
        onAction: _hasMore ? _loadMore : null,
      );
    }
    return RefreshIndicator(
      onRefresh: _loadFirstPage,
      child: ListView.separated(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        itemCount: _listings.length + (_loadingMore || !_hasMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          if (index == _listings.length) {
            if (_loadingMore) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'Toutes les annonces ont été chargées.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            );
          }
          final listing = _listings[index];
          return VehicleListingCard(
            listing: listing,
            isFavorite: _favoriteIds.contains(listing.id),
            onFavoriteChanged: _uid == null
                ? null
                : (favorite) => _setFavorite(listing, favorite),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => VehicleListingDetailScreen(
                  listing: listing,
                  profileLoader: widget.detailProfileLoader,
                  currentUserId: widget.currentUserId == null
                      ? null
                      : () => widget.currentUserId,
                  isFavorite: _favoriteIds.contains(listing.id),
                  onFavoriteChanged: _uid == null
                      ? null
                      : (favorite) => _setFavorite(listing, favorite),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _controls() {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(children: [
          TextField(
            key: const Key('vehicle_search'),
            controller: _searchController,
            textInputAction: TextInputAction.search,
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(
                const Duration(milliseconds: 450),
                _loadFirstPage,
              );
            },
            decoration: const InputDecoration(
              hintText: 'Marque, modèle ou titre',
              prefixIcon: Icon(Icons.search_rounded),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('vehicle_filters'),
                onPressed: _openFilters,
                icon: const Icon(Icons.tune_rounded),
                label: Text(_filters.isEmpty
                    ? 'Filtres'
                    : 'Filtres (${_filters.activeCount})'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('vehicle_sort'),
                onPressed: _chooseSort,
                icon: const Icon(Icons.sort_rounded),
                label: const Text('Trier'),
              ),
            ),
          ]),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Ville : ${widget.cityId}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _openFilters() async {
    FocusScope.of(context).unfocus();
    final result = await showModalBottomSheet<VehicleListingFilters>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => VehicleFilterSheet(
        initial: _filters,
        offerType: widget.offerType,
        vehicleType: widget.vehicleType,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _filters = result);
    _loadFirstPage();
  }

  Future<void> _chooseSort() async {
    final selected = await showModalBottomSheet<VehicleListingSort>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: VehicleListingSort.values
              .map((sort) => ListTile(
                    leading: Icon(
                      sort == _sort
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                    ),
                    title: Text(_sortLabel(sort)),
                    onTap: () => Navigator.pop(context, sort),
                  ))
              .toList(),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _sort = selected);
    _loadFirstPage();
  }

  String _sortLabel(VehicleListingSort sort) => switch (sort) {
        VehicleListingSort.newest => 'Plus récentes',
        VehicleListingSort.priceAscending => 'Prix croissant',
        VehicleListingSort.priceDescending => 'Prix décroissant',
        VehicleListingSort.yearNewest => 'Année récente',
      };

  Future<void> _loadFavoriteState(List<VehicleListing> listings) async {
    final uid = _uid;
    if (uid == null || listings.isEmpty) return;
    final repository = _favoriteRepository;
    if (repository == null) return;
    try {
      final ids = await repository.getFavoriteIds(
        uid,
        listings.map((listing) => listing.id),
      );
      if (mounted) setState(() => _favoriteIds.addAll(ids));
    } catch (_) {}
  }

  Future<void> _setFavorite(VehicleListing listing, bool favorite) async {
    final uid = _uid;
    final repository = _favoriteRepository;
    if (uid == null || repository == null) return;
    setState(() => favorite
        ? _favoriteIds.add(listing.id)
        : _favoriteIds.remove(listing.id));
    try {
      await repository.setFavorite(
        uid: uid,
        listing: listing,
        favorite: favorite,
      );
    } catch (_) {
      if (mounted) {
        setState(() => favorite
            ? _favoriteIds.remove(listing.id)
            : _favoriteIds.add(listing.id));
      }
    }
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 54, color: colors.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onAction != null && actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
