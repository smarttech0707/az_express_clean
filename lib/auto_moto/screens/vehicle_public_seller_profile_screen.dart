import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../models/vehicle_listing.dart';
import '../models/vehicle_seller_profile.dart';
import 'vehicle_seller_profile_screen.dart';

class VehiclePublicSellerProfileScreen extends StatelessWidget {
  const VehiclePublicSellerProfileScreen({
    super.key,
    required this.profile,
    required this.cityName,
    this.onReport,
    this.onBlock,
  });

  final VehicleSellerProfile profile;
  final String cityName;
  final VoidCallback? onReport;
  final VoidCallback? onBlock;

  @override
  Widget build(BuildContext context) {
    final professional = profile.sellerType == VehicleSellerType.professional;
    final verified = professional &&
        profile.verificationStatus == VehicleSellerVerificationStatus.verified;
    final logo = professional ? profile.logoUrl : profile.profilePhotoUrl;
    return Scaffold(
      appBar: AppBar(title: const Text('Profil vendeur')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: SizedBox.square(
                  dimension: 104,
                  child: logo?.isNotEmpty == true
                      ? CachedNetworkImage(
                          imageUrl: logo!,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              _avatarFallback(context, professional),
                        )
                      : _avatarFallback(context, professional),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              professional ? profile.shopName! : profile.displayName,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  Chip(
                    label: Text(professional ? 'Professionnel' : 'Particulier'),
                  ),
                  if (verified)
                    const Chip(
                      avatar: Icon(Icons.verified_rounded, size: 17),
                      label: Text('Vérifié par AZ Express'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            if (professional && profile.businessType != null)
              _InfoRow(
                icon: Icons.business_center_outlined,
                label: 'Activité',
                value: vehicleBusinessLabel(profile.businessType!),
              ),
            _InfoRow(
              icon: Icons.phone_outlined,
              label: 'Téléphone',
              value: professional ? profile.professionalPhone! : profile.phone,
            ),
            _InfoRow(
              icon: Icons.location_on_outlined,
              label: 'Localisation',
              value: publicVehicleSellerLocation(profile, cityName),
            ),
            const SizedBox(height: 22),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                if (onReport != null)
                  TextButton.icon(
                    onPressed: onReport,
                    icon: const Icon(Icons.flag_outlined),
                    label: const Text('Signaler'),
                  ),
                if (onBlock != null)
                  TextButton.icon(
                    onPressed: onBlock,
                    icon: const Icon(Icons.block_rounded),
                    label: const Text('Bloquer'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded, color: AppColors.primary),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'AZ Express met les utilisateurs en relation mais n’est pas partie à la transaction. Vérifiez le véhicule, l’identité du vendeur et les documents avant tout paiement.',
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

  Widget _avatarFallback(BuildContext context, bool professional) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(
          professional ? Icons.storefront_rounded : Icons.person_rounded,
          size: 48,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
}

String publicVehicleSellerLocation(
  VehicleSellerProfile profile,
  String cityName,
) {
  final parts = <String>[cityName];
  if (profile.locationVisibility != VehicleLocationVisibility.hidden &&
      profile.zoneId?.isNotEmpty == true) {
    parts.add(profile.zoneId!);
  }
  if (profile.locationVisibility == VehicleLocationVisibility.exact &&
      profile.address?.isNotEmpty == true) {
    parts.add(profile.address!);
  }
  return parts.join(' • ');
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(
      {required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 2),
                  Text(value),
                ],
              ),
            ),
          ],
        ),
      );
}
