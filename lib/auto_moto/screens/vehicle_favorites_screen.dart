import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../models/vehicle_favorite.dart';
import '../models/vehicle_listing.dart';
import '../vehicle_favorite_repository.dart';
import '../vehicle_listing_repository.dart';
import '../widgets/vehicle_listing_card.dart';
import 'vehicle_listing_detail_screen.dart';

typedef VehicleFavoritesLoader = Future<VehicleFavoritesPage> Function({
  required String uid,
  required int pageSize,
  DocumentSnapshot<Map<String, dynamic>>? startAfter,
});

class VehicleFavoritesScreen extends StatefulWidget {
  const VehicleFavoritesScreen({
    super.key,
    required this.currentUserId,
    this.pageLoader,
  });

  final String currentUserId;
  final VehicleFavoritesLoader? pageLoader;

  @override
  State<VehicleFavoritesScreen> createState() => _VehicleFavoritesScreenState();
}

class _VehicleFavoritesScreenState extends State<VehicleFavoritesScreen> {
  final _favorites = <VehicleFavorite>[];
  DocumentSnapshot<Map<String, dynamic>>? _cursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  Object? _error;
  late final VehicleFavoriteRepository? _repository =
      widget.pageLoader == null ? VehicleFavoriteRepository() : null;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (!reset && (_loadingMore || !_hasMore)) return;
    setState(() {
      if (reset) {
        _loading = true;
        _error = null;
        _favorites.clear();
        _cursor = null;
        _hasMore = true;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final loader = widget.pageLoader;
      final page = loader != null
          ? await loader(
              uid: widget.currentUserId,
              pageSize: 20,
              startAfter: reset ? null : _cursor,
            )
          : await _repository!.getFavorites(
              uid: widget.currentUserId,
              pageSize: 20,
              startAfter: reset ? null : _cursor,
            );
      if (!mounted) return;
      final ids = _favorites.map((item) => item.listing.id).toSet();
      setState(() {
        _favorites.addAll(
          page.favorites.where((item) => ids.add(item.listing.id)),
        );
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mes favoris')),
      body: SafeArea(top: false, child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _favorites.isEmpty) {
      return Center(
        child: FilledButton(
          onPressed: () => _load(reset: true),
          child: const Text('Réessayer'),
        ),
      );
    }
    if (_favorites.isEmpty) {
      return const Center(child: Text('Aucune annonce favorite.'));
    }
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _favorites.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          if (index == _favorites.length) {
            return TextButton(
              onPressed: _loadingMore ? null : () => _load(reset: false),
              child: _loadingMore
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : const Text('Charger plus'),
            );
          }
          final favorite = _favorites[index];
          return VehicleListingCard(
            listing: favorite.listing,
            isFavorite: true,
            onFavoriteChanged: (_) => _remove(favorite),
            onTap: () => _openFavorite(favorite),
          );
        },
      ),
    );
  }

  Future<void> _remove(VehicleFavorite favorite) async {
    setState(() => _favorites.remove(favorite));
    try {
      await _repository?.setFavorite(
        uid: widget.currentUserId,
        listing: favorite.listing,
        favorite: false,
      );
    } catch (_) {
      if (mounted) setState(() => _favorites.insert(0, favorite));
    }
  }

  Future<void> _openFavorite(VehicleFavorite favorite) async {
    if (_repository == null) return;
    final listing =
        await VehicleListingRepository().getListingById(favorite.listing.id);
    if (!mounted) return;
    if (listing == null || listing.status != VehicleListingStatus.active) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cette annonce n’est plus disponible.')),
      );
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => VehicleListingDetailScreen(listing: listing),
      ),
    );
  }
}
