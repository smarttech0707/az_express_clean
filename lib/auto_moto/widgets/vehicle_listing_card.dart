import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

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
      color: colors.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _VehicleCover(listing: listing),
                  if (listing.condition != VehicleCondition.unknown)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _ImageBadge(
                        label: listing.condition == VehicleCondition.newVehicle
                            ? 'Neuf'
                            : 'Occasion',
                      ),
                    ),
                  if (onFavoriteChanged != null)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Material(
                        color: colors.surface.withValues(alpha: .9),
                        shape: const CircleBorder(),
                        child: IconButton(
                          key: ValueKey('favorite_${listing.id}'),
                          visualDensity: VisualDensity.compact,
                          tooltip: isFavorite
                              ? 'Retirer des favoris'
                              : 'Ajouter aux favoris',
                          onPressed: () => onFavoriteChanged!(!isFavorite),
                          icon: Icon(
                            isFavorite
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            color: isFavorite
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${listing.brand} ${listing.model}'.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 5),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        formatVehiclePrice(
                          listing.price,
                          currency: listing.currency,
                        ),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: colors.primary,
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (listing.year != null)
                      Text(
                        listing.mileageKm == null
                            ? '${listing.year}'
                            : '${listing.year} · ${listing.mileageKm} km',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                      ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 14,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            listing.cityName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Expanded(
                          child: _Badge(
                            label: vehicleOfferLabel(listing.offerType),
                          ),
                        ),
                        if (isVerified) ...[
                          const SizedBox(width: 4),
                          const _Badge(
                            label: 'Vérifié',
                            icon: Icons.verified_rounded,
                            highlighted: true,
                          ),
                        ],
                      ],
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

class _VehicleCover extends StatelessWidget {
  const _VehicleCover({required this.listing});

  final VehicleListing listing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final media = listing.coverMedia;
    if (media == null) {
      return ColoredBox(
        color: colors.surfaceContainerHighest,
        child: Icon(
          listing.vehicleType == VehicleType.motorcycle
              ? Icons.two_wheeler_rounded
              : Icons.directions_car_rounded,
          size: 40,
          color: colors.onSurfaceVariant,
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: media.thumbnailUrl ?? media.downloadUrl,
      fit: BoxFit.cover,
      placeholder: (_, __) => ColoredBox(
        color: colors.surfaceContainerHighest,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      errorWidget: (_, __, ___) => ColoredBox(
        color: colors.surfaceContainerHighest,
        child: const Icon(Icons.broken_image_outlined),
      ),
    );
  }
}

class _ImageBadge extends StatelessWidget {
  const _ImageBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.onSurface,
              fontWeight: FontWeight.w800,
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
    final foreground = highlighted ? colors.primary : colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlighted
            ? colors.primaryContainer
            : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: foreground),
            const SizedBox(width: 3),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
