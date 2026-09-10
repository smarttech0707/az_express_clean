import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../models/delivery_zone.dart';
import '../../services/notification_service.dart';
import '../market_city_catalog_service.dart';
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
typedef MarketCitiesLoader = Future<List<DeliveryZone>> Function();

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
    this.marketCitiesLoader,
  });

  /// Injection utile aux tests du filtre Marketplace local.
  final String? cityId;
  final VehicleListingsPageLoader? pageLoader;
  final CurrentVehicleUserId? currentUserId;
  final VehicleHomeProfileLoader? profileLoader;
  final VehicleListingSaver? saveListing;
  final SellerListingsLoader? myListingsLoader;
  final VehicleSellerProfileSaver? saveProfile;
  final MarketCitiesLoader? marketCitiesLoader;

  @override
  State<VehicleHomeScreen> createState() => _VehicleHomeScreenState();
}

class _VehicleHomeScreenState extends State<VehicleHomeScreen> {
  VehicleOfferType _offerType = VehicleOfferType.sale;
  bool _checkingProfile = false;
  String? _marketCityId;
  List<DeliveryZone> _marketCities = const [];
  bool _loadingMarketCities = false;

  @override
  void initState() {
    super.initState();
    _syncExistingSellerToken();
    _loadMarketCities();
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
    final cityId = widget.cityId ?? _marketCityId;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.directions_car_filled_rounded,
                          color: colors.onPrimary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Auto & Moto',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                color: colors.onPrimaryContainer,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Achetez, louez et vendez partout en Côte d’Ivoire',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onPrimaryContainer,
                        ),
                  ),
                  const SizedBox(height: 18),
                  _MarketScopeControl(
                    key: const Key('market_city_scope'),
                    label: cityId == null
                        ? 'Toute la Côte d’Ivoire'
                        : _cityName(cityId),
                    enabled: widget.cityId == null && !_loadingMarketCities,
                    onTap: _chooseMarketCity,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SegmentedButton<VehicleOfferType>(
              showSelectedIcon: false,
              style: ButtonStyle(
                minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? colors.onPrimary
                      : colors.onSurfaceVariant,
                ),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? colors.primary
                      : colors.surfaceContainerHigh,
                ),
                side: WidgetStatePropertyAll(
                  BorderSide(color: colors.outlineVariant),
                ),
              ),
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
            const SizedBox(height: 28),
            const _HomeSectionTitle('Choisir un véhicule'),
            const SizedBox(height: 12),
            _VehicleCategoryTile(
              label: 'Voitures',
              subtitle: 'Citadines, SUV et berlines',
              icon: Icons.directions_car_rounded,
              onTap: () => _openListings(cityId, VehicleType.car),
            ),
            const SizedBox(height: 10),
            _VehicleCategoryTile(
              label: 'Motos',
              subtitle: 'Urbaines, sportives et utilitaires',
              icon: Icons.two_wheeler_rounded,
              onTap: () => _openListings(cityId, VehicleType.motorcycle),
            ),
            const SizedBox(height: 10),
            _VehicleCategoryTile(
              label: 'Tricycles',
              subtitle: 'Transport et activité professionnelle',
              icon: Icons.electric_rickshaw_rounded,
              onTap: () => _openListings(cityId, VehicleType.tricycle),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              key: const Key('vehicle_publish_cta'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: _checkingProfile ? null : _preparePublication,
              icon: _checkingProfile
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_circle_outline_rounded),
              label: const Text('Publier une annonce'),
            ),
            const SizedBox(height: 28),
            const _HomeSectionTitle('Mon espace Auto & Moto'),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final itemWidth = (constraints.maxWidth - 10) / 2;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _PersonalShortcut(
                      key: const Key('vehicle_personal_listings'),
                      width: itemWidth,
                      label: 'Mes annonces',
                      icon: Icons.list_alt_rounded,
                      onTap: _checkingProfile ? null : _openMyListings,
                    ),
                    _PersonalShortcut(
                      key: const Key('vehicle_personal_profile'),
                      width: itemWidth,
                      label: 'Mon profil vendeur',
                      icon: Icons.account_circle_outlined,
                      onTap: _checkingProfile ? null : _openSellerProfile,
                    ),
                    _PersonalShortcut(
                      key: const Key('vehicle_personal_messages'),
                      width: itemWidth,
                      label: 'Messages',
                      icon: Icons.chat_bubble_outline_rounded,
                      onTap: _checkingProfile ? null : _openMessages,
                    ),
                    _PersonalShortcut(
                      key: const Key('vehicle_personal_favorites'),
                      width: itemWidth,
                      label: 'Mes favoris',
                      icon: Icons.favorite_border_rounded,
                      onTap: _openFavorites,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openListings(String? cityId, VehicleType vehicleType) {
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

  Future<void> _loadMarketCities() async {
    if (widget.cityId != null) return;
    setState(() => _loadingMarketCities = true);
    try {
      final cities = await (widget.marketCitiesLoader ??
          MarketCityCatalogService().loadCities)();
      if (mounted) setState(() => _marketCities = cities);
    } catch (_) {
      // Le filtre reste national si le catalogue est momentanément indisponible.
    } finally {
      if (mounted) setState(() => _loadingMarketCities = false);
    }
  }

  String _cityName(String cityId) {
    for (final city in _marketCities) {
      if (city.cityId == cityId || city.id == cityId) {
        return city.name ?? cityId;
      }
    }
    return cityId;
  }

  Future<void> _chooseMarketCity() async {
    const allCities = '__all_cote_ivoire__';
    final search = TextEditingController();
    final cityId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final query = search.text.trim().toLowerCase();
          final cities = _marketCities
              .where((city) => city.cityId != null)
              .where((city) => query.isEmpty ||
                  (city.name ?? city.cityId!).toLowerCase().contains(query))
              .toList();
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * .78,
                child: Column(children: [
                  const ListTile(title: Text('Choisir une ville')),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      key: const Key('market_city_search'),
                      controller: search,
                      onChanged: (_) => setSheetState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Rechercher une ville',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: query.isEmpty ? null : IconButton(
                          key: const Key('market_city_search_clear'),
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: () { search.clear(); setSheetState(() {}); },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(child: ListView(children: [
                    ListTile(
                      title: const Text('Toute la Côte d’Ivoire'),
                      trailing: _marketCityId == null ? const Icon(Icons.check_rounded) : null,
                      selected: _marketCityId == null,
                      selectedColor: Theme.of(context).colorScheme.primary,
                      onTap: () => Navigator.pop(sheetContext, allCities),
                    ),
                    if (cities.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('Aucune ville trouvée')),
                      ),
                    ...cities.map((city) => ListTile(
                      title: Text(city.name ?? city.cityId!),
                      trailing: city.cityId == _marketCityId
                          ? const Icon(Icons.check_rounded)
                          : null,
                      selected: city.cityId == _marketCityId,
                      selectedColor: Theme.of(context).colorScheme.primary,
                      onTap: () => Navigator.pop(sheetContext, city.cityId),
                    )),
                  ])),
                ]),
              ),
            ),
          );
        },
      ),
    );
    search.dispose();
    if (cityId != null && mounted) {
      setState(() => _marketCityId = cityId == allCities ? null : cityId);
    }
  }

  Future<void> _preparePublication() async {
    final cityId = widget.cityId ?? _marketCityId;
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
            cities: _profileCities(cityId) ?? _marketCities,
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
    final cityId = widget.cityId ?? _marketCityId;
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
    final cityId = widget.cityId ?? _marketCityId;
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
    if (widget.cityId == null) return _marketCities;
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
    for (final city in _marketCities) {
      if (city.cityId == id || city.id == id) return (id, city.name ?? id);
    }
    return (id, id);
  }
}

class _VehicleCategoryTile extends StatelessWidget {
  const _VehicleCategoryTile({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
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
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: colors.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  ],
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

class _HomeSectionTitle extends StatelessWidget {
  const _HomeSectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
        label,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
      );
}

class _MarketScopeControl extends StatelessWidget {
  const _MarketScopeControl({
    super.key,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface.withValues(alpha: .72),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.location_on_outlined, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                ],
              ),
              if (enabled) ...[
                const SizedBox(height: 2),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Text(
                    'Changer',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: colors.primary,
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PersonalShortcut extends StatelessWidget {
  const _PersonalShortcut({
    super.key,
    required this.width,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final double width;
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: 124,
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: colors.primary),
                ),
                const Spacer(),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
