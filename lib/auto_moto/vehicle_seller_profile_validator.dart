import 'models/vehicle_listing.dart';
import 'models/vehicle_seller_private_location.dart';
import 'models/vehicle_seller_profile.dart';

class VehicleSellerProfileValidator {
  const VehicleSellerProfileValidator._();

  static List<String> validate(VehicleSellerProfile profile) {
    final errors = <String>[];
    if (profile.ownerId.trim().isEmpty) errors.add('ownerId est obligatoire.');
    if (!_lengthBetween(profile.displayName, 2, 100)) {
      errors.add('Le nom doit contenir entre 2 et 100 caractères.');
    }
    if (!_lengthBetween(profile.phone, 8, 25)) {
      errors.add('Le téléphone doit contenir entre 8 et 25 caractères.');
    }
    if (!_isNormalizedId(profile.cityId)) {
      errors.add('cityId doit être non vide et normalisé.');
    }
    if (profile.zoneId != null && !_isNormalizedId(profile.zoneId!)) {
      errors.add('zoneId doit être normalisé lorsqu’il est renseigné.');
    }
    if (profile.sellerType == VehicleSellerType.unknown) {
      errors.add('Le type de vendeur est inconnu.');
    }
    if (profile.verificationStatus == VehicleSellerVerificationStatus.unknown) {
      errors.add('Le statut de vérification est inconnu.');
    }

    if (profile.sellerType == VehicleSellerType.individual) {
      if (profile.shopName != null ||
          profile.businessType != null ||
          profile.professionalPhone != null ||
          profile.address != null ||
          profile.locationVisibility != null ||
          profile.logoUrl != null ||
          profile.logoStoragePath != null ||
          profile.description != null ||
          profile.openingHours != null) {
        errors.add('Un particulier ne doit pas contenir de données magasin.');
      }
    }

    if (profile.sellerType == VehicleSellerType.professional) {
      if (!_lengthBetween(profile.shopName ?? '', 2, 120)) {
        errors.add('Le nom du magasin est obligatoire.');
      }
      if (profile.businessType == null ||
          profile.businessType == VehicleBusinessType.unknown) {
        errors.add('L’activité professionnelle est obligatoire et valide.');
      }
      if (!_lengthBetween(profile.professionalPhone ?? '', 8, 25)) {
        errors.add('Le téléphone professionnel est obligatoire.');
      }
      if (!_lengthBetween(profile.address ?? '', 2, 300)) {
        errors.add('L’adresse du magasin est obligatoire.');
      }
      if (profile.locationVisibility == null ||
          profile.locationVisibility == VehicleLocationVisibility.unknown) {
        errors.add('La visibilité de localisation est obligatoire.');
      }
      if ((profile.description?.length ?? 0) > 1000) {
        errors.add('La description est limitée à 1000 caractères.');
      }
      if ((profile.openingHours?.length ?? 0) > 500) {
        errors.add('Les horaires sont limités à 500 caractères.');
      }
      if (profile.logoStoragePath != null &&
          (!profile.logoStoragePath!.startsWith(
                'vehicle_seller_profiles/${profile.ownerId}/logo/',
              ) ||
              !RegExp(r'\.(jpg|png)$').hasMatch(profile.logoStoragePath!))) {
        errors.add('Le chemin du logo est invalide.');
      }
    }
    return errors;
  }

  static List<String> validatePrivateLocation(
    VehicleSellerPrivateLocation location,
  ) {
    final errors = <String>[];
    if (location.ownerId.trim().isEmpty) {
      errors.add('ownerId est obligatoire.');
    }
    if (location.latitude < -90 || location.latitude > 90) {
      errors.add('La latitude est invalide.');
    }
    if (location.longitude < -180 || location.longitude > 180) {
      errors.add('La longitude est invalide.');
    }
    if (!_isNormalizedId(location.cityId)) {
      errors.add('cityId doit être non vide et normalisé.');
    }
    if (location.zoneId != null && !_isNormalizedId(location.zoneId!)) {
      errors.add('zoneId doit être normalisé lorsqu’il est renseigné.');
    }
    if ((location.addressLabel?.length ?? 0) > 300) {
      errors.add('Le libellé d’adresse est limité à 300 caractères.');
    }
    return errors;
  }

  static void validateOrThrow(VehicleSellerProfile profile) {
    final errors = validate(profile);
    if (errors.isNotEmpty) {
      throw VehicleSellerProfileValidationException(errors);
    }
  }

  static void validatePrivateLocationOrThrow(
    VehicleSellerPrivateLocation location,
  ) {
    final errors = validatePrivateLocation(location);
    if (errors.isNotEmpty) {
      throw VehicleSellerProfileValidationException(errors);
    }
  }

  static bool _lengthBetween(String value, int min, int max) {
    final length = value.trim().length;
    return length >= min && length <= max;
  }

  static bool _isNormalizedId(String value) =>
      RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(value.trim()) &&
      value == value.trim();
}

class VehicleSellerProfileValidationException implements Exception {
  const VehicleSellerProfileValidationException(this.errors);

  final List<String> errors;

  @override
  String toString() => 'Profil vendeur invalide: ${errors.join(' ')}';
}
