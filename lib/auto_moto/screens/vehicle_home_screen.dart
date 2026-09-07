import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/active_city_provider.dart';
import '../../models/delivery_zone.dart';
import '../../services/notification_service.dart';
import '../../theme/app_theme.dart';
import '../models/vehicle_listing.dart';
import '../models/vehicle_seller_profile.dart';
import '../vehicle_seller_profile_repository.dart';
import 'my_vehicle_listings_screen.dart';
import 'vehicle_listing_form_screen.dart';
import 'vehicle_listings_screen.dart';
import 'vehicle_seller_profile_screen.dart';
import 'vehicle_conversations_screen.dart';
import 'vehicle_favorites_screen.dart';

typedef CurrentVehicleUserId = String? Function();
typedef VehicleHomeProfileLoader = Future<VehicleSellerProfile?> Function(
  String uid,
);

class VehicleHomeScreen extends StatefulWidget {
  const VehicleHomeScreen({
    super.key,
    this.cityId,
    this.pageLoader,
    this.currentUserId,
    this.profileLoader,
    this.saveListing,
    this.myListingsLoader,
    this.saveProfile,
  });

  /// Injection utile aux tests; en production la ville active AZ Express est
  /// utilisée via ActiveCityProvider.
  final String? cityId;
  final VehicleListingsPageLoader? pageLoader;
  final CurrentVehicleUserId? currentUserId;
  final VehicleHomeProfileLoader? profileLoader;
  final VehicleListingSaver? saveListing;
  final SellerListingsLoader? myListingsLoader;
  final VehicleSellerProfileSaver? saveProfile;

  @override
  State<VehicleHomeScreen> createState() => _VehicleHomeScreenState();
}

class _VehicleHomeScreenState extends State<VehicleHomeScreen> {
  VehicleOfferType _offerType = VehicleOfferType.sale;
  bool _checkingProfile = false;

  @override
  void initState() {
    super.initState();
    _syncExistingSellerToken();
  }

  Future<void> _syncExistingSellerToken() async {
    // Les injections identifient les tests widget : aucun accès Firebase réel.
    if (widget.currentUserId != null) return;
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || user.isAnonymous) return;
      final profile =
          await VehicleSellerProfileRepository().getSellerProfile(user.uid);
      if (profile != null) _saveSellerToken(user.uid);
    } catch (_) {}
  }

  void _saveSellerToken(String uid) {
    NotificationService().saveToken(
      uid,
      VehicleSellerProfileRepository.profilesCollectionName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cityId =
        widget.cityId ?? context.watch<ActiveCityProvider>().activeCityId;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Auto & Moto')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            Text(
              'Achetez ou louez votre prochain véhicule',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              cityId == null
                  ? 'Sélectionnez d’abord votre ville AZ Express.'
                  : 'Annonces disponibles dans votre ville active.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 22),
            SegmentedButton<VehicleOfferType>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: VehicleOfferType.sale,
                  label: Text('Acheter'),
                  icon: Icon(Icons.sell_rounded),
                ),
                ButtonSegment(
                  value: VehicleOfferType.rental,
                  label: Text('Louer'),
                  icon: Icon(Icons.key_rounded),
                ),
              ],
              selected: {_offerType},
              onSelectionChanged: (selection) {
                setState(() => _offerType = selection.first);
              },
            ),
            const SizedBox(height: 26),
            Text(
              'Type de véhicule',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
            _VehicleCategoryTile(
              label: 'Voitures',
              icon: Icons.directions_car_rounded,
              onTap: () => _openListings(cityId, VehicleType.car),
            ),
            const SizedBox(height: 10),
            _VehicleCategoryTile(
              label: 'Motos',
              icon: Icons.two_wheeler_rounded,
              onTap: () => _openListings(cityId, VehicleType.motorcycle),
            ),
            const SizedBox(height: 10),
            _VehicleCategoryTile(
              label: 'Tricycles',
              icon: Icons.electric_rickshaw_rounded,
              onTap: () => _openListings(cityId, VehicleType.tricycle),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _checkingProfile ? null : _preparePublication,
              icon: _checkingProfile
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_circle_outline_rounded),
              label: const Text('Publier une annonce'),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: _checkingProfile ? null : _openMyListings,
              icon: const Icon(Icons.list_alt_rounded),
              label: const Text('Mes annonces Auto & Moto'),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _checkingProfile ? null : _openSellerProfile,
              icon: const Icon(Icons.account_circle_outlined),
              label: const Text('Mon profil vendeur'),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _checkingProfile ? null : _openMessages,
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              label: const Text('Messages'),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _openFavorites,
              icon: const Icon(Icons.favorite_border_rounded),
              label: const Text('Mes favoris'),
            ),
          ],
        ),
      ),
    );
  }

  void _openListings(String? cityId, VehicleType vehicleType) {
    if (cityId == null || cityId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Sélectionnez une ville avant de continuer.')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VehicleListingsScreen(
          offerType: _offerType,
          vehicleType: vehicleType,
          cityId: cityId,
          pageLoader: widget.pageLoader,
        ),
      ),
    );
  }

  Future<void> _preparePublication() async {
    final cityId =
        widget.cityId ?? context.read<ActiveCityProvider>().activeCityId;
    final uid = widget.currentUserId != null
        ? widget.currentUserId!()
        : FirebaseAuth.instance.currentUser?.isAnonymous == false
            ? FirebaseAuth.instance.currentUser?.uid
            : null;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Connectez-vous pour publier une annonce.')),
      );
      return;
    }
    setState(() => _checkingProfile = true);
    try {
      var profile = await (widget.profileLoader ??
          VehicleSellerProfileRepository().getSellerProfile)(uid);
      if (!mounted) return;
      if (profile == null) {
        profile = await Navigator.push<VehicleSellerProfile>(
          context,
          MaterialPageRoute(
            builder: (_) => VehicleSellerProfileScreen(
              ownerId: uid,
              initialCityId: cityId,
              cities: _profileCities(cityId),
              saveProfile: widget.saveProfile,
            ),
          ),
        );
        if (!mounted || profile == null) return;
      }
      final readyProfile = profile;
      if (widget.currentUserId == null) _saveSellerToken(uid);
      final city = _activeCity(cityId, readyProfile);
      if (city == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Sélectionnez une ville avant de publier.')),
        );
        return;
      }
      await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => VehicleListingFormScreen(
            profile: readyProfile,
            cityId: city.$1,
            cityName: city.$2,
            saveListing: widget.saveListing,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Impossible de vérifier le profil vendeur.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _checkingProfile = false);
    }
  }

  Future<void> _openMyListings() async {
    final cityId =
        widget.cityId ?? context.read<ActiveCityProvider>().activeCityId;
    final uid = widget.currentUserId != null
        ? widget.currentUserId!()
        : FirebaseAuth.instance.currentUser?.isAnonymous == false
            ? FirebaseAuth.instance.currentUser?.uid
            : null;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connectez-vous pour voir vos annonces.')),
      );
      return;
    }
    setState(() => _checkingProfile = true);
    try {
      final profile = await (widget.profileLoader ??
          VehicleSellerProfileRepository().getSellerProfile)(uid);
      if (!mounted) return;
      if (profile == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Aucun profil vendeur Auto & Moto.')),
        );
        return;
      }
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => MyVehicleListingsScreen(
            profile: profile,
            cityName: _activeCity(cityId, profile)?.$2 ?? profile.cityId,
            pageLoader: widget.myListingsLoader,
            saveListing: widget.saveListing,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Impossible de charger vos annonces.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _checkingProfile = false);
    }
  }

  Future<void> _openSellerProfile() async {
    final cityId =
        widget.cityId ?? context.read<ActiveCityProvider>().activeCityId;
    final uid = widget.currentUserId != null
        ? widget.currentUserId!()
        : FirebaseAuth.instance.currentUser?.isAnonymous == false
            ? FirebaseAuth.instance.currentUser?.uid
            : null;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Connectez-vous pour gérer votre profil.')),
      );
      return;
    }
    setState(() => _checkingProfile = true);
    try {
      final profile = await (widget.profileLoader ??
          VehicleSellerProfileRepository().getSellerProfile)(uid);
      if (!mounted) return;
      final savedProfile = await Navigator.push<VehicleSellerProfile>(
        context,
        MaterialPageRoute(
          builder: (_) => VehicleSellerProfileScreen(
            ownerId: uid,
            initialProfile: profile,
            initialCityId: cityId,
            cities: _profileCities(cityId),
            saveProfile: widget.saveProfile,
          ),
        ),
      );
      if (savedProfile != null && widget.currentUserId == null) {
        _saveSellerToken(uid);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Impossible de charger le profil vendeur.')),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingProfile = false);
    }
  }

  void _openMessages() {
    final uid = widget.currentUserId != null
        ? widget.currentUserId!()
        : FirebaseAuth.instance.currentUser?.isAnonymous == false
            ? FirebaseAuth.instance.currentUser?.uid
            : null;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connectez-vous pour voir vos messages.')),
      );
      return;
    }
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => VehicleConversationsScreen(currentUserId: uid),
      ),
    );
  }

  void _openFavorites() {
    final uid = widget.currentUserId != null
        ? widget.currentUserId!()
        : FirebaseAuth.instance.currentUser?.isAnonymous == false
            ? FirebaseAuth.instance.currentUser?.uid
            : null;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connectez-vous pour voir vos favoris.')),
      );
      return;
    }
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => VehicleFavoritesScreen(currentUserId: uid),
      ),
    );
  }

  List<DeliveryZone>? _profileCities(String? cityId) {
    if (widget.cityId == null) return null;
    if (cityId == null) return const [];
    return [DeliveryZone(id: cityId, cityId: cityId, name: cityId)];
  }

  (String, String)? _activeCity(
    String? cityId,
    VehicleSellerProfile profile,
  ) {
    final id = cityId ?? profile.cityId;
    if (id.isEmpty) return null;
    if (widget.cityId != null) return (id, id);
    final cities = context.read<ActiveCityProvider>().activeCities;
    for (final city in cities) {
      if (city.cityId == id || city.id == id) return (id, city.name ?? id);
    }
    return (id, id);
  }
}

class _VehicleCategoryTile extends StatelessWidget {
  const _VehicleCategoryTile({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.primary10,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: AppColors.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
