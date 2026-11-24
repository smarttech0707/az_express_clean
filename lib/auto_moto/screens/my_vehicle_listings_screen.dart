import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../models/vehicle_listing.dart';
import '../models/vehicle_seller_profile.dart';
import '../vehicle_formatters.dart';
import '../vehicle_listing_repository.dart';
import 'vehicle_listing_form_screen.dart';

typedef SellerListingsLoader = Future<VehicleListingsPage> Function({
  required String sellerId,
  required int pageSize,
  DocumentSnapshot<Map<String, dynamic>>? startAfter,
});

class MyVehicleListingsScreen extends StatefulWidget {
  const MyVehicleListingsScreen({
    super.key,
    required this.profile,
    required this.cityName,
    this.pageLoader,
    this.saveListing,
  });

  final VehicleSellerProfile profile;
  final String cityName;
  final SellerListingsLoader? pageLoader;
  final VehicleListingSaver? saveListing;

  @override
  State<MyVehicleListingsScreen> createState() =>
      _MyVehicleListingsScreenState();
}

class _MyVehicleListingsScreenState extends State<MyVehicleListingsScreen> {
  static const _pageSize = 15;
  final _listings = <VehicleListing>[];
  late final VehicleListingRepository? _repository;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  Object? _error;
  DocumentSnapshot<Map<String, dynamic>>? _cursor;

  @override
  void initState() {
    super.initState();
    _repository = widget.pageLoader == null ? VehicleListingRepository() : null;
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loadingMore || !_hasMore)) return;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final loader = widget.pageLoader ?? _repository!.getSellerListings;
      final page = await loader(
        sellerId: widget.profile.ownerId,
        pageSize: _pageSize,
        startAfter: more ? _cursor : null,
      );
      if (!mounted) return;
      setState(() {
        if (!more) _listings.clear();
        final ids = _listings.map((item) => item.id).toSet();
        _listings.addAll(page.listings.where((item) => ids.add(item.id)));
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Mes annonces Auto & Moto')),
        body: SafeArea(top: false, child: _body()),
      );

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _listings.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Impossible de charger vos annonces.'),
          const SizedBox(height: 10),
          FilledButton(onPressed: _load, child: const Text('Réessayer')),
        ]),
      );
    }
    if (_listings.isEmpty) {
      return const Center(child: Text('Vous n’avez encore aucune annonce.'));
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 300) _load(more: true);
        return false;
      },
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: _listings.length + (_loadingMore ? 1 : 0),
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            if (index == _listings.length) {
              return const Center(child: CircularProgressIndicator());
            }
            final listing = _listings[index];
            return Card(
              child: ListTile(
                title: Text(listing.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${vehicleOfferLabel(listing.offerType)} • '
                  '${formatVehiclePrice(listing.price)} • '
                  '${vehicleListingStatusLabel(listing.status)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: 'Modifier',
                  icon: const Icon(Icons.edit_rounded),
                  onPressed: () => _edit(listing),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _edit(VehicleListing listing) async {
    if (listing.sellerId != widget.profile.ownerId) return;
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => VehicleListingFormScreen(
          profile: widget.profile,
          cityId: listing.cityId,
          cityName: listing.cityName,
          original: listing,
          saveListing: widget.saveListing,
        ),
      ),
    );
    if (changed == true) await _load();
  }
}
