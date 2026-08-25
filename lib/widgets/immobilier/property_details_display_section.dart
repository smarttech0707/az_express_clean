import 'package:flutter/material.dart';

import '../../models/real_estate_listing.dart';
import '../../models/real_estate_property_type.dart';
import '../../theme/app_theme.dart';

/// Master Prompt "Immobilier V6" — Mission 5 : affichage adapté au type de
/// bien. Un terrain n'affiche que la surface/zone (le reste — pièces,
/// équipements — n'a pas de sens pour un terrain nu) ; un bien habitable
/// affiche pièces/chambres/salles de bain/équipements pertinents ; un local
/// commercial met en avant la surface et le stationnement. Ne montre jamais
/// un champ non renseigné (`null`/`false`) — une annonce ancienne, créée
/// avant cette passe, n'affiche simplement aucune de ces informations,
/// jamais une valeur inventée ni un "0" trompeur.
class PropertyDetailsDisplaySection extends StatelessWidget {
  final RealEstateListing listing;
  const PropertyDetailsDisplaySection({super.key, required this.listing});

  @override
  Widget build(BuildContext context) {
    final isLand = RealEstatePropertyType.isLand(listing.propertyType);
    final chips = <Widget>[];

    if (isLand) {
      if (listing.surfaceTerrain != null) {
        chips.add(_Chip(
            icon: Icons.crop_square_rounded,
            label:
                '${listing.surfaceTerrain!.toStringAsFixed(0)} m² (terrain)'));
      }
    } else {
      if (listing.surface != null) {
        chips.add(_Chip(
            icon: Icons.square_foot_rounded,
            label: '${listing.surface!.toStringAsFixed(0)} m²'));
      }
      if (listing.rooms != null) {
        chips.add(_Chip(
            icon: Icons.door_front_door_outlined,
            label: '${listing.rooms} pièces'));
      }
      if (listing.bedrooms != null) {
        chips.add(_Chip(
            icon: Icons.bed_outlined, label: '${listing.bedrooms} chambres'));
      }
      if (listing.bathrooms != null) {
        chips.add(_Chip(
            icon: Icons.bathtub_outlined, label: '${listing.bathrooms} SDB'));
      }
      if (listing.floor != null) {
        chips.add(_Chip(
            icon: Icons.stairs_outlined, label: 'Étage ${listing.floor}'));
      }
    }

    // Bug réel trouvé (Mission 4, V6.1) : ces équipements (piscine, garage,
    // climatisation...) n'ont aucun sens pour un terrain nu, mais rien ne
    // les empêchait de s'afficher si le document les avait à `true` — un
    // scénario réel dès qu'une future édition changerait le type d'un bien
    // bâti vers "terrain" sans effacer ses anciens booléens (aucune UI
    // d'édition n'existe encore, voir Mission 4, mais le document Firestore
    // le permettrait déjà). Gardé cohérent avec le formulaire de création
    // (Mission 3), qui n'affiche déjà aucun de ces équipements pour un
    // terrain : la section entière est ignorée pour `isLand`.
    final amenities = <Widget>[];
    if (!isLand) {
      void addAmenity(bool value, IconData icon, String label) {
        if (value) amenities.add(_Chip(icon: icon, label: label, filled: true));
      }

      addAmenity(listing.furnished, Icons.chair_outlined, 'Meublé');
      addAmenity(listing.hasGarage, Icons.garage_outlined, 'Garage');
      addAmenity(listing.hasParking, Icons.local_parking_outlined, 'Parking');
      addAmenity(listing.hasTerrace, Icons.deck_outlined, 'Terrasse');
      addAmenity(listing.hasBalcony, Icons.balcony_outlined, 'Balcon');
      addAmenity(listing.hasKitchen, Icons.kitchen_outlined, 'Cuisine équipée');
      addAmenity(
          listing.hasAirConditioning, Icons.ac_unit_rounded, 'Climatisation');
      addAmenity(listing.hasInternet, Icons.wifi_rounded, 'Internet');
      addAmenity(
          listing.hasGenerator, Icons.bolt_outlined, 'Groupe électrogène');
      addAmenity(listing.hasPool, Icons.pool_outlined, 'Piscine');
      addAmenity(listing.hasBorehole, Icons.water_drop_outlined, 'Forage');
      addAmenity(listing.hasGuard, Icons.security_outlined, 'Gardien');
      addAmenity(listing.hasElevator, Icons.elevator_outlined, 'Ascenseur');
      addAmenity(listing.chargesIncluded, Icons.receipt_long_outlined,
          'Charges incluses');
    }

    final prices = <Widget>[];
    if (listing.pricePerDay != null) {
      prices.add(_PriceRow(label: 'Par jour', amount: listing.pricePerDay!));
    }
    if (listing.pricePerWeek != null) {
      prices
          .add(_PriceRow(label: 'Par semaine', amount: listing.pricePerWeek!));
    }
    if (listing.pricePerMonth != null) {
      prices.add(_PriceRow(label: 'Par mois', amount: listing.pricePerMonth!));
    }

    if (chips.isEmpty &&
        amenities.isEmpty &&
        prices.isEmpty &&
        listing.isAvailable) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!listing.isAvailable)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.12),
                borderRadius: AppRadius.cardR),
            child: Row(children: [
              const Icon(Icons.event_busy_outlined,
                  color: AppColors.warning, size: 18),
              const SizedBox(width: 8),
              Text(
                  listing.availabilityDate != null
                      ? 'Disponible à partir du ${listing.availabilityDate!.day}/${listing.availabilityDate!.month}/${listing.availabilityDate!.year}'
                      : 'Actuellement indisponible',
                  style: const TextStyle(
                      color: AppColors.warning, fontWeight: FontWeight.w600)),
            ]),
          ),
        if (chips.isNotEmpty) ...[
          Wrap(spacing: 8, runSpacing: 8, children: chips),
          const SizedBox(height: 12),
        ],
        if (amenities.isNotEmpty) ...[
          const Text('Équipements',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: amenities),
          const SizedBox(height: 12),
        ],
        if (prices.isNotEmpty) ...[
          const Text('Tarifs',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 6),
          ...prices,
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool filled;
  const _Chip({required this.icon, required this.label, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: filled ? AppColors.primary15 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: 14,
              color: filled ? AppColors.primary : Colors.grey.shade700),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: filled ? AppColors.primary : Colors.grey.shade800,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _PriceRow extends StatelessWidget {
  final String label;
  final int amount;
  const _PriceRow({required this.label, required this.amount});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
          Text('$amount FCFA',
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }
}
