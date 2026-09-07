import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../models/vehicle_listing.dart';
import '../models/vehicle_seller_profile.dart';
import '../vehicle_formatters.dart';

class VehicleListingCard extends StatelessWidget {
  const VehicleListingCard({
    super.key,
    required this.listing,
    required this.onTap,
    this.verificationStatus,
    this.isFavorite = false,
    this.onFavoriteChanged,
  });

  final VehicleListing listing;
  final VoidCallback onTap;
  final VehicleSellerVerificationStatus? verificationStatus;
  final bool isFavorite;
  final ValueChanged<bool>? onFavoriteChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isVerified = listing.sellerType == VehicleSellerType.professional &&
        verificationStatus == VehicleSellerVerificationStatus.verified;
    return Card(
      margin: EdgeInsets.zero,
      color: colors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 112,
              height: 142,
              color: colors.surfaceContainerHighest,
              child: listing.coverMedia == null
                  ? Icon(
                      listing.vehicleType == VehicleType.motorcycle
                          ? Icons.two_wheeler_rounded
                          : Icons.directions_car_rounded,
                      size: 48,
                      color: colors.onSurfaceVariant,
                    )
                  : CachedNetworkImage(
                      imageUrl: listing.coverMedia!.thumbnailUrl ??
                          listing.coverMedia!.downloadUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      errorWidget: (_, __, ___) =>
                          const Icon(Icons.broken_image_outlined),
                    ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${listing.brand} ${listing.model}'.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    if (listing.year != null) ...[
                      const SizedBox(height: 2),
                      Text('${listing.year}',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      formatVehiclePrice(
                        listing.price,
                        currency: listing.currency,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '${vehicleOfferLabel(listing.offerType)} • ${listing.cityName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _Badge(
                          label: listing.sellerType ==
                                  VehicleSellerType.professional
                              ? 'Professionnel'
                              : 'Particulier',
                        ),
                        if (isVerified)
                          const _Badge(
                            label: 'Vérifié',
                            icon: Icons.verified_rounded,
                            highlighted: true,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (onFavoriteChanged != null)
              IconButton(
                key: ValueKey('favorite_${listing.id}'),
                tooltip:
                    isFavorite ? 'Retirer des favoris' : 'Ajouter aux favoris',
                onPressed: () => onFavoriteChanged!(!isFavorite),
                icon: Icon(
                  isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color:
                      isFavorite ? AppColors.primary : colors.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    this.icon,
    this.highlighted = false,
  });

  final String label;
  final IconData? icon;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground =
        highlighted ? AppColors.primary : colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color:
            highlighted ? AppColors.primary10 : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: foreground),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}
