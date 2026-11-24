import 'models/vehicle_listing.dart';
import 'models/vehicle_media.dart';

class VehicleListingValidator {
  const VehicleListingValidator._();

  static List<String> validate(
    VehicleListing listing, {
    DateTime? now,
  }) {
    final errors = <String>[];
    final currentYear = (now ?? DateTime.now()).year;

    if (listing.sellerId.trim().isEmpty) {
      errors.add('sellerId est obligatoire.');
    }
    if (listing.title.trim().length < 3 || listing.title.trim().length > 120) {
      errors.add('Le titre doit contenir entre 3 et 120 caractères.');
    }
    if (listing.description.trim().length < 10 ||
        listing.description.trim().length > 3000) {
      errors.add('La description doit contenir entre 10 et 3000 caractères.');
    }
    if (listing.brand.trim().isEmpty || listing.brand.trim().length > 80) {
      errors.add('La marque est obligatoire et limitée à 80 caractères.');
    }
    if (listing.model.trim().isEmpty || listing.model.trim().length > 80) {
      errors.add('Le modèle est obligatoire et limité à 80 caractères.');
    }
    if (listing.price <= 0) errors.add('Le prix doit être supérieur à zéro.');
    if (listing.year case final year?) {
      if (year < 1886 || year > currentYear + 1) {
        errors.add('L’année du véhicule est invalide.');
      }
    }
    if (!_isNormalizedCityId(listing.cityId)) {
      errors.add('cityId doit être non vide et normalisé.');
    }
    if (listing.cityName.trim().length < 2 ||
        listing.cityName.trim().length > 100) {
      errors.add('Le nom de ville doit contenir entre 2 et 100 caractères.');
    }
    if (listing.currency.trim().toUpperCase() != 'XOF') {
      errors.add('La devise prise en charge est XOF.');
    }
    if (listing.vehicleType == VehicleType.unknown) {
      errors.add('Le type de véhicule est inconnu.');
    }
    if (listing.offerType == VehicleOfferType.unknown) {
      errors.add('Le type d’offre est inconnu.');
    }
    if (listing.sellerType == VehicleSellerType.unknown) {
      errors.add('Le type de vendeur est inconnu.');
    }
    if (listing.condition == VehicleCondition.unknown) {
      errors.add('L’état du véhicule est obligatoire.');
    }
    if (listing.color == null ||
        listing.color!.trim().isEmpty ||
        listing.color!.trim().length > 60) {
      errors.add('La couleur est obligatoire.');
    }
    if (listing.condition == VehicleCondition.used &&
        (listing.mileageKm == null || listing.mileageKm! < 0)) {
      errors.add('Le kilométrage est obligatoire pour un véhicule d’occasion.');
    }
    if (listing.mileageKm != null && listing.mileageKm! < 0) {
      errors.add('Le kilométrage ne peut pas être négatif.');
    }
    if (listing.offerType == VehicleOfferType.sale) {
      if (listing.salePrice == null || listing.salePrice! <= 0) {
        errors.add('Le prix de vente doit être supérieur à zéro.');
      }
      if (listing.rentalPricePerDay != null ||
          listing.rentalPricePerWeek != null ||
          listing.depositAmount != null ||
          listing.rentalWithDriver ||
          listing.rentalWithoutDriver) {
        errors.add('Une vente ne doit pas contenir de conditions de location.');
      }
    }
    if (listing.offerType == VehicleOfferType.rental) {
      if (listing.rentalPricePerDay == null ||
          listing.rentalPricePerDay! <= 0) {
        errors.add('Le prix de location par jour doit être supérieur à zéro.');
      }
      if (listing.salePrice != null) {
        errors.add('Une location ne doit pas contenir de prix de vente.');
      }
      if (!listing.rentalWithDriver && !listing.rentalWithoutDriver) {
        errors.add('Choisissez au moins une option de location.');
      }
    }
    if (listing.salePrice != null && listing.price != listing.salePrice) {
      errors.add('Le prix affiché doit correspondre au prix de vente.');
    }
    if (listing.rentalPricePerDay != null &&
        listing.offerType == VehicleOfferType.rental &&
        listing.price != listing.rentalPricePerDay) {
      errors.add('Le prix affiché doit correspondre au tarif journalier.');
    }
    if (listing.rentalPricePerWeek != null &&
        listing.rentalPricePerWeek! <= 0) {
      errors.add('Le tarif hebdomadaire doit être supérieur à zéro.');
    }
    if (listing.depositAmount != null && listing.depositAmount! < 0) {
      errors.add('La caution ne peut pas être négative.');
    }
    if (listing.engineCapacityCc != null && listing.engineCapacityCc! <= 0) {
      errors.add('La cylindrée doit être supérieure à zéro.');
    }
    if (listing.seats != null && listing.seats! <= 0) {
      errors.add('Le nombre de places doit être supérieur à zéro.');
    }
    if (listing.vehicleType == VehicleType.car &&
        (listing.transmission == null ||
            listing.fuelType == null ||
            listing.seats == null ||
            listing.engineCapacityCc != null)) {
      errors.add('Les caractéristiques de la voiture sont incomplètes.');
    }
    if (listing.vehicleType == VehicleType.motorcycle &&
        (listing.engineCapacityCc == null ||
            listing.transmission != null ||
            listing.fuelType != null ||
            listing.seats != null)) {
      errors.add('Les caractéristiques de la moto sont incohérentes.');
    }
    if (listing.vehicleType == VehicleType.tricycle &&
        (listing.engineCapacityCc == null ||
            listing.transmission != null ||
            listing.fuelType != null)) {
      errors.add('Les caractéristiques du tricycle sont incohérentes.');
    }
    final images =
        listing.media.where((item) => item.type == VehicleMediaType.image);
    final videos =
        listing.media.where((item) => item.type == VehicleMediaType.video);
    if (images.length > 8) errors.add('Maximum 8 photos par annonce.');
    if (videos.length > 1) errors.add('Une seule vidéo est autorisée.');
    if (listing.media.any((item) =>
        item.type == VehicleMediaType.unknown ||
        item.id.trim().isEmpty ||
        item.storagePath.trim().isEmpty ||
        item.downloadUrl.trim().isEmpty ||
        !item.storagePath.startsWith(
          'vehicle_listings/${listing.sellerId}/${listing.id}/',
        ))) {
      errors.add('Un média de l’annonce est invalide.');
    }
    if (listing.media.map((item) => item.id).toSet().length !=
        listing.media.length) {
      errors.add('Les identifiants média doivent être uniques.');
    }
    if (images.isEmpty && listing.coverMediaId != null) {
      errors.add('Une annonce sans photo ne peut pas avoir de couverture.');
    }
    if (images.isNotEmpty &&
        !images.any((item) => item.id == listing.coverMediaId)) {
      errors.add('La photo principale est invalide.');
    }
    if (listing.status == VehicleListingStatus.unknown) {
      errors.add('Le statut de l’annonce est inconnu.');
    }
    if (listing.status == VehicleListingStatus.sold &&
        listing.offerType != VehicleOfferType.sale) {
      errors.add('Seule une annonce de vente peut être marquée vendue.');
    }
    if (listing.status == VehicleListingStatus.rented &&
        listing.offerType != VehicleOfferType.rental) {
      errors.add('Seule une annonce de location peut être marquée louée.');
    }
    return errors;
  }

  static void validateOrThrow(VehicleListing listing, {DateTime? now}) {
    final errors = validate(listing, now: now);
    if (errors.isNotEmpty) throw VehicleListingValidationException(errors);
  }

  static bool _isNormalizedCityId(String value) =>
      RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(value.trim()) &&
      value == value.trim();
}

class VehicleListingValidationException implements Exception {
  const VehicleListingValidationException(this.errors);

  final List<String> errors;

  @override
  String toString() => 'VehicleListing invalide: ${errors.join(' ')}';
}
