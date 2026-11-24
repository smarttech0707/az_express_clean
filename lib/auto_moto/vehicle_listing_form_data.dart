import 'models/vehicle_listing.dart';
import 'models/vehicle_seller_profile.dart';
import 'vehicle_listing_validator.dart';

class VehicleListingFormData {
  VehicleListingFormData({
    this.offerType = VehicleOfferType.sale,
    this.vehicleType = VehicleType.car,
    this.condition = VehicleCondition.used,
    this.brand = '',
    this.model = '',
    this.year = '',
    this.color = '',
    this.mileageKm = '',
    this.transmission,
    this.fuelType,
    this.engineCapacityCc = '',
    this.seats = '',
    this.salePrice = '',
    this.rentalPricePerDay = '',
    this.rentalPricePerWeek = '',
    this.depositAmount = '',
    this.rentalWithDriver = false,
    this.rentalWithoutDriver = false,
    this.title = '',
    this.description = '',
  });

  factory VehicleListingFormData.fromListing(VehicleListing listing) =>
      VehicleListingFormData(
        offerType: listing.offerType,
        vehicleType: listing.vehicleType,
        condition: listing.condition,
        brand: listing.brand,
        model: listing.model,
        year: listing.year?.toString() ?? '',
        color: listing.color ?? '',
        mileageKm: listing.mileageKm?.toString() ?? '',
        transmission: listing.transmission,
        fuelType: listing.fuelType,
        engineCapacityCc: listing.engineCapacityCc?.toString() ?? '',
        seats: listing.seats?.toString() ?? '',
        salePrice: listing.salePrice?.toString() ?? '',
        rentalPricePerDay: listing.rentalPricePerDay?.toString() ?? '',
        rentalPricePerWeek: listing.rentalPricePerWeek?.toString() ?? '',
        depositAmount: listing.depositAmount?.toString() ?? '',
        rentalWithDriver: listing.rentalWithDriver,
        rentalWithoutDriver: listing.rentalWithoutDriver,
        title: listing.title,
        description: listing.description,
      );

  VehicleOfferType offerType;
  VehicleType vehicleType;
  VehicleCondition condition;
  String brand;
  String model;
  String year;
  String color;
  String mileageKm;
  VehicleTransmission? transmission;
  VehicleFuelType? fuelType;
  String engineCapacityCc;
  String seats;
  String salePrice;
  String rentalPricePerDay;
  String rentalPricePerWeek;
  String depositAmount;
  bool rentalWithDriver;
  bool rentalWithoutDriver;
  String title;
  String description;

  List<String> validateStep(int step, {DateTime? now}) {
    final errors = <String>[];
    switch (step) {
      case 0:
        if (offerType == VehicleOfferType.unknown) {
          errors.add('Choisissez un type d’offre.');
        }
      case 1:
        if (vehicleType == VehicleType.unknown) {
          errors.add('Choisissez un type de véhicule.');
        }
      case 2:
        if (condition == VehicleCondition.unknown) {
          errors.add('Choisissez l’état du véhicule.');
        }
      case 3:
        if (brand.trim().isEmpty) errors.add('La marque est obligatoire.');
        if (model.trim().isEmpty) errors.add('Le modèle est obligatoire.');
        final parsedYear = int.tryParse(year.trim());
        final currentYear = (now ?? DateTime.now()).year;
        if (parsedYear == null ||
            parsedYear < 1886 ||
            parsedYear > currentYear + 1) {
          errors.add('L’année du véhicule est invalide.');
        }
        if (color.trim().isEmpty) errors.add('La couleur est obligatoire.');
      case 4:
        if (condition == VehicleCondition.used &&
            _nonNegativeInt(mileageKm) == null) {
          errors.add('Le kilométrage est obligatoire pour une occasion.');
        }
        if (vehicleType == VehicleType.car) {
          if (transmission == null) {
            errors.add('La transmission est obligatoire.');
          }
          if (fuelType == null) errors.add('Le carburant est obligatoire.');
          if (_positiveInt(seats) == null) {
            errors.add('Le nombre de places est obligatoire.');
          }
        } else if (_positiveInt(engineCapacityCc) == null) {
          errors.add('La cylindrée est obligatoire.');
        }
      case 5:
        if (offerType == VehicleOfferType.sale) {
          if (_positiveInt(salePrice) == null) {
            errors.add('Le prix de vente doit être supérieur à zéro.');
          }
        } else {
          if (_positiveInt(rentalPricePerDay) == null) {
            errors.add('Le prix journalier doit être supérieur à zéro.');
          }
          if (rentalPricePerWeek.trim().isNotEmpty &&
              _positiveInt(rentalPricePerWeek) == null) {
            errors.add('Le prix hebdomadaire est invalide.');
          }
          if (depositAmount.trim().isNotEmpty &&
              _nonNegativeInt(depositAmount) == null) {
            errors.add('La caution est invalide.');
          }
          if (!rentalWithDriver && !rentalWithoutDriver) {
            errors.add('Choisissez au moins une option de location.');
          }
        }
      case 6:
        if (title.trim().length < 3 || title.trim().length > 120) {
          errors.add('Le titre doit contenir entre 3 et 120 caractères.');
        }
        if (description.trim().length < 10 ||
            description.trim().length > 3000) {
          errors
              .add('La description doit contenir entre 10 et 3000 caractères.');
        }
    }
    return errors;
  }

  VehicleListing toListing({
    required String sellerId,
    required VehicleSellerProfile profile,
    required String cityId,
    required String cityName,
    VehicleListing? original,
  }) {
    if (profile.ownerId != sellerId) {
      throw StateError('Le profil vendeur ne correspond pas à la session.');
    }
    final displayedPrice = offerType == VehicleOfferType.sale
        ? _positiveInt(salePrice)
        : _positiveInt(rentalPricePerDay);
    final listing = VehicleListing(
      id: original?.id ?? '',
      sellerId: original?.sellerId ?? sellerId,
      sellerType: profile.sellerType,
      vehicleType: vehicleType,
      offerType: offerType,
      title: title,
      description: description,
      brand: brand,
      model: model,
      year: int.tryParse(year.trim()),
      condition: condition,
      color: color,
      mileageKm: _optionalNonNegativeInt(mileageKm),
      transmission: vehicleType == VehicleType.car ? transmission : null,
      fuelType: vehicleType == VehicleType.car ? fuelType : null,
      engineCapacityCc: vehicleType == VehicleType.car
          ? null
          : _optionalPositiveInt(engineCapacityCc),
      seats: vehicleType == VehicleType.car
          ? _optionalPositiveInt(seats)
          : vehicleType == VehicleType.tricycle
              ? _optionalPositiveInt(seats)
              : null,
      salePrice:
          offerType == VehicleOfferType.sale ? _positiveInt(salePrice) : null,
      rentalPricePerDay: offerType == VehicleOfferType.rental
          ? _positiveInt(rentalPricePerDay)
          : null,
      rentalPricePerWeek: offerType == VehicleOfferType.rental
          ? _optionalPositiveInt(rentalPricePerWeek)
          : null,
      depositAmount: offerType == VehicleOfferType.rental
          ? _optionalNonNegativeInt(depositAmount)
          : null,
      rentalWithDriver:
          offerType == VehicleOfferType.rental && rentalWithDriver,
      rentalWithoutDriver:
          offerType == VehicleOfferType.rental && rentalWithoutDriver,
      price: displayedPrice ?? 0,
      cityId: cityId,
      cityName: cityName,
      status: original?.status ?? VehicleListingStatus.active,
      createdAt: original?.createdAt,
      updatedAt: original?.updatedAt,
    );
    VehicleListingValidator.validateOrThrow(listing);
    if (original != null && listing.sellerId != original.sellerId) {
      throw StateError('Le propriétaire de l’annonce est immuable.');
    }
    return listing;
  }
}

int? _positiveInt(String value) {
  final parsed = int.tryParse(value.trim().replaceAll(' ', ''));
  return parsed != null && parsed > 0 ? parsed : null;
}

int? _nonNegativeInt(String value) {
  final parsed = int.tryParse(value.trim().replaceAll(' ', ''));
  return parsed != null && parsed >= 0 ? parsed : null;
}

int? _optionalPositiveInt(String value) =>
    value.trim().isEmpty ? null : _positiveInt(value);

int? _optionalNonNegativeInt(String value) =>
    value.trim().isEmpty ? null : _nonNegativeInt(value);
