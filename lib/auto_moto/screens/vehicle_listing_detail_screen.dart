import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/immobilier/listing_gallery_viewer.dart';
import '../models/vehicle_listing.dart';
import '../models/vehicle_media.dart';
import '../models/vehicle_seller_profile.dart';
import '../models/vehicle_conversation.dart';
import '../vehicle_conversation_repository.dart';
import '../vehicle_formatters.dart';
import '../vehicle_seller_profile_repository.dart';
import '../vehicle_trust_repository.dart';
import '../widgets/vehicle_report_sheet.dart';
import 'vehicle_public_seller_profile_screen.dart';
import 'vehicle_seller_profile_screen.dart';
import 'vehicle_chat_screen.dart';

typedef VehicleConversationOpener = Future<VehicleConversation> Function({
  required VehicleListing listing,
  required VehicleSellerProfile sellerProfile,
  required String buyerId,
});

typedef VehicleSellerProfileLoader = Future<VehicleSellerProfile?> Function(
  String sellerId,
);

class VehicleListingDetailScreen extends StatefulWidget {
  const VehicleListingDetailScreen({
    super.key,
    required this.listing,
    this.profileLoader,
    this.currentUserId,
    this.conversationOpener,
    this.chatRepository,
    this.isFavorite = false,
    this.onFavoriteChanged,
  });

  final VehicleListing listing;
  final VehicleSellerProfileLoader? profileLoader;
  final String? Function()? currentUserId;
  final VehicleConversationOpener? conversationOpener;
  final VehicleConversationDataSource? chatRepository;
  final bool isFavorite;
  final ValueChanged<bool>? onFavoriteChanged;

  @override
  State<VehicleListingDetailScreen> createState() =>
      _VehicleListingDetailScreenState();
}

class _VehicleListingDetailScreenState
    extends State<VehicleListingDetailScreen> {
  late final Future<VehicleSellerProfile?> _profileFuture;
  late bool _isFavorite;

  @override
  void initState() {
    super.initState();
    _isFavorite = widget.isFavorite;
    _profileFuture = (widget.profileLoader ??
        VehicleSellerProfileRepository().getSellerProfile)(
      widget.listing.sellerId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final listing = widget.listing;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Détail de l’annonce'),
        actions: [
          if (widget.onFavoriteChanged != null)
            IconButton(
              tooltip:
                  _isFavorite ? 'Retirer des favoris' : 'Ajouter aux favoris',
              onPressed: () {
                setState(() => _isFavorite = !_isFavorite);
                widget.onFavoriteChanged!(_isFavorite);
              },
              icon: Icon(
                _isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: _isFavorite ? AppColors.primary : null,
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            if (listing.media.isEmpty)
              Container(
                height: 230,
                color: colors.surfaceContainerHighest,
                alignment: Alignment.center,
                child: Icon(
                  listing.vehicleType == VehicleType.motorcycle
                      ? Icons.two_wheeler_rounded
                      : Icons.directions_car_rounded,
                  size: 86,
                  color: colors.onSurfaceVariant,
                ),
              )
            else
              ListingGalleryHeader(
                images: _orderedImages(listing),
                videos: listing.media
                    .where((item) => item.type == VehicleMediaType.video)
                    .map((item) => item.downloadUrl)
                    .toList(),
                height: 230,
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${listing.brand} ${listing.model}'.trim(),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  if (listing.year != null)
                    Text('${listing.year}',
                        style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 12),
                  Text(
                    formatVehiclePrice(
                      listing.price,
                      currency: listing.currency,
                    ),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(label: Text(vehicleOfferLabel(listing.offerType))),
                      Chip(label: Text(vehicleTypeLabel(listing.vehicleType))),
                      Chip(label: Text(listing.cityName)),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _Section(
                    title: 'Caractéristiques',
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: _characteristics(listing)
                          .map((value) => Chip(label: Text(value)))
                          .toList(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _reportListing,
                      icon: const Icon(Icons.flag_outlined),
                      label: const Text('Signaler cette annonce'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _Section(
                    title: 'Description',
                    child: Text(listing.description),
                  ),
                  const SizedBox(height: 24),
                  _Section(
                    title: 'Vendeur',
                    child: FutureBuilder<VehicleSellerProfile?>(
                      future: _profileFuture,
                      builder: (context, snapshot) => _SellerContent(
                        listing: listing,
                        profile: snapshot.data,
                        onContact: snapshot.data == null
                            ? null
                            : () => _contactSeller(snapshot.data!),
                        onReport: () => _reportSeller(),
                        onBlock: () => _blockSeller(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _Section(
                    title: 'Localisation',
                    child: FutureBuilder<VehicleSellerProfile?>(
                      future: _profileFuture,
                      builder: (context, snapshot) => _PublicLocationContent(
                        listing: listing,
                        profile: snapshot.data,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.info_outline_rounded,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'AZ Express met en relation acheteurs, vendeurs et loueurs. '
                            'Vérifiez le véhicule et les informations du vendeur avant '
                            'toute transaction. AZ Express n’est pas garant des échanges '
                            'conclus directement entre utilisateurs.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _contactSeller(VehicleSellerProfile profile) async {
    final injectedUid = widget.currentUserId?.call();
    final firebaseUser =
        injectedUid == null ? FirebaseAuth.instance.currentUser : null;
    final uid = injectedUid ??
        (firebaseUser?.isAnonymous == false ? firebaseUser?.uid : null);
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Connectez-vous pour contacter le vendeur.')),
      );
      return;
    }
    if (uid == widget.listing.sellerId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Vous ne pouvez pas contacter votre propre annonce.')),
      );
      return;
    }
    try {
      final conversation = await (widget.conversationOpener ??
          VehicleConversationRepository().openConversation)(
        listing: widget.listing,
        sellerProfile: profile,
        buyerId: uid,
      );
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => VehicleChatScreen(
            conversation: conversation,
            currentUserId: uid,
            repository: widget.chatRepository,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible d’ouvrir la conversation.')),
        );
      }
    }
  }

  String? get _authenticatedUid {
    final injected = widget.currentUserId?.call();
    if (injected != null) return injected;
    final user = FirebaseAuth.instance.currentUser;
    return user?.isAnonymous == false ? user?.uid : null;
  }

  Future<void> _reportListing() => _report(
        target: VehicleReportTarget.listing,
        targetId: widget.listing.id,
        seller: false,
      );

  Future<void> _reportSeller() => _report(
        target: VehicleReportTarget.seller,
        targetId: widget.listing.sellerId,
        seller: true,
      );

  Future<void> _report({
    required VehicleReportTarget target,
    required String targetId,
    required bool seller,
  }) async {
    final uid = _authenticatedUid;
    if (uid == null || uid == widget.listing.sellerId) {
      _notice(uid == null
          ? 'Connectez-vous pour effectuer un signalement.'
          : 'Vous ne pouvez pas vous signaler vous-même.');
      return;
    }
    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => VehicleReportSheet(seller: seller),
    );
    if (result == null || !mounted) return;
    try {
      await VehicleTrustRepository().report(
        target: target,
        targetId: targetId,
        sellerId: widget.listing.sellerId,
        reporterUid: uid,
        reason: result.$1,
        details: result.$2,
      );
      _notice('Signalement envoyé. Merci.');
    } catch (_) {
      _notice('Ce signalement existe déjà ou n’a pas pu être envoyé.');
    }
  }

  Future<void> _blockSeller() async {
    final uid = _authenticatedUid;
    if (uid == null || uid == widget.listing.sellerId) {
      _notice(uid == null
          ? 'Connectez-vous pour bloquer ce vendeur.'
          : 'Vous ne pouvez pas vous bloquer vous-même.');
      return;
    }
    final repository = VehicleTrustRepository();
    final alreadyBlocked = await repository.isBlocked(
      uid,
      widget.listing.sellerId,
    );
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
            alreadyBlocked ? 'Débloquer ce vendeur ?' : 'Bloquer ce vendeur ?'),
        content: Text(
          alreadyBlocked
              ? 'Les nouvelles interactions Auto & Moto seront de nouveau possibles.'
              : 'Vous ne pourrez plus démarrer ni poursuivre une conversation avec ce vendeur.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(alreadyBlocked ? 'Débloquer' : 'Bloquer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      if (alreadyBlocked) {
        await repository.unblock(
          uid: uid,
          blockedUid: widget.listing.sellerId,
        );
        _notice('Vendeur débloqué.');
      } else {
        await repository.block(
          uid: uid,
          blockedUid: widget.listing.sellerId,
        );
        _notice('Vendeur bloqué.');
      }
    } catch (_) {
      _notice('Blocage impossible. Réessayez.');
    }
  }

  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  List<String> _characteristics(VehicleListing listing) {
    final values = <String>[
      listing.condition == VehicleCondition.newVehicle ? 'Neuf' : 'Occasion',
      if (listing.color != null) 'Couleur : ${listing.color}',
      if (listing.mileageKm != null) '${listing.mileageKm} km',
      if (listing.transmission != null)
        listing.transmission == VehicleTransmission.automatic
            ? 'Automatique'
            : 'Manuelle',
      if (listing.engineCapacityCc != null) '${listing.engineCapacityCc} cm³',
      if (listing.seats != null) '${listing.seats} places',
      if (listing.rentalWithDriver) 'Avec chauffeur',
      if (listing.rentalWithoutDriver) 'Sans chauffeur',
    ];
    return values;
  }

  List<String> _orderedImages(VehicleListing listing) {
    final images = listing.media
        .where((item) => item.type == VehicleMediaType.image)
        .toList()
      ..sort((left, right) => left.position.compareTo(right.position));
    final coverIndex =
        images.indexWhere((item) => item.id == listing.coverMediaId);
    if (coverIndex > 0) images.insert(0, images.removeAt(coverIndex));
    return images.map((item) => item.downloadUrl).toList(growable: false);
  }
}

class _SellerContent extends StatelessWidget {
  const _SellerContent({
    required this.listing,
    required this.profile,
    required this.onContact,
    required this.onReport,
    required this.onBlock,
  });

  final VehicleListing listing;
  final VehicleSellerProfile? profile;
  final VoidCallback? onContact;
  final VoidCallback onReport;
  final VoidCallback onBlock;

  @override
  Widget build(BuildContext context) {
    final professional = listing.sellerType == VehicleSellerType.professional;
    final verified = professional &&
        profile?.verificationStatus == VehicleSellerVerificationStatus.verified;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            Chip(label: Text(professional ? 'Professionnel' : 'Particulier')),
            if (verified)
              const Chip(
                avatar: Icon(Icons.verified_rounded, size: 17),
                label: Text('Vérifié par AZ Express'),
              ),
          ],
        ),
        if (professional && profile?.shopName != null) ...[
          const SizedBox(height: 8),
          Text(profile!.shopName!,
              style: Theme.of(context).textTheme.titleMedium),
        ],
        if (professional && profile?.professionalPhone != null) ...[
          const SizedBox(height: 5),
          Text('Téléphone : ${profile!.professionalPhone}'),
        ] else if (!professional && profile?.phone != null) ...[
          const SizedBox(height: 5),
          Text('Téléphone : ${profile!.phone}'),
        ],
        if (professional && profile?.businessType != null) ...[
          const SizedBox(height: 5),
          Text(vehicleBusinessLabel(profile!.businessType!)),
        ],
        if (profile != null) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => VehiclePublicSellerProfileScreen(
                  profile: profile!,
                  cityName: listing.cityName,
                  onReport: onReport,
                  onBlock: onBlock,
                ),
              ),
            ),
            icon: const Icon(Icons.account_circle_outlined),
            label: const Text('Voir le profil vendeur'),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: onReport,
                icon: const Icon(Icons.flag_outlined),
                label: const Text('Signaler le vendeur'),
              ),
              TextButton.icon(
                onPressed: onBlock,
                icon: const Icon(Icons.block_rounded),
                label: const Text('Bloquer'),
              ),
            ],
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onContact,
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              label: const Text('Contacter le vendeur'),
            ),
          ),
        ],
      ],
    );
  }
}

class _PublicLocationContent extends StatelessWidget {
  const _PublicLocationContent({required this.listing, required this.profile});

  final VehicleListing listing;
  final VehicleSellerProfile? profile;

  @override
  Widget build(BuildContext context) {
    return Text(profile == null
        ? listing.cityName
        : publicVehicleSellerLocation(profile!, listing.cityName));
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}
