import 'package:cloud_firestore/cloud_firestore.dart';

import 'vehicle_media.dart';

enum VehicleType { car, motorcycle, tricycle, unknown }

enum VehicleOfferType { sale, rental, unknown }

enum VehicleSellerType { individual, professional, unknown }

enum VehicleListingStatus {
  draft,
  active,
  sold,
  rented,
  archived,
  suspended,
  unknown,
}

enum VehicleCondition { newVehicle, used, unknown }

enum VehicleTransmission { manual, automatic, unknown }

enum VehicleFuelType { petrol, diesel, electric, hybrid, other, unknown }

VehicleType vehicleTypeFromFirestore(Object? value) => switch (value) {
      'car' => VehicleType.car,
      'motorcycle' => VehicleType.motorcycle,
      'tricycle' => VehicleType.tricycle,
      _ => VehicleType.unknown,
    };

VehicleOfferType vehicleOfferTypeFromFirestore(Object? value) =>
    switch (value) {
      'sale' => VehicleOfferType.sale,
      'rental' => VehicleOfferType.rental,
      _ => VehicleOfferType.unknown,
    };

VehicleSellerType vehicleSellerTypeFromFirestore(Object? value) =>
    switch (value) {
      'individual' => VehicleSellerType.individual,
      'professional' => VehicleSellerType.professional,
      _ => VehicleSellerType.unknown,
    };

VehicleListingStatus vehicleListingStatusFromFirestore(Object? value) =>
    switch (value) {
      'draft' => VehicleListingStatus.draft,
      'active' => VehicleListingStatus.active,
      'sold' => VehicleListingStatus.sold,
      'rented' => VehicleListingStatus.rented,
      'archived' => VehicleListingStatus.archived,
      'suspended' => VehicleListingStatus.suspended,
      _ => VehicleListingStatus.unknown,
    };

VehicleCondition vehicleConditionFromFirestore(Object? value) =>
    switch (value) {
      'new' => VehicleCondition.newVehicle,
      'used' => VehicleCondition.used,
      _ => VehicleCondition.unknown,
    };

VehicleTransmission? vehicleTransmissionFromFirestore(Object? value) =>
    switch (value) {
      'manual' => VehicleTransmission.manual,
      'automatic' => VehicleTransmission.automatic,
      _ => null,
    };

VehicleFuelType? vehicleFuelTypeFromFirestore(Object? value) => switch (value) {
      'petrol' => VehicleFuelType.petrol,
      'diesel' => VehicleFuelType.diesel,
      'electric' => VehicleFuelType.electric,
      'hybrid' => VehicleFuelType.hybrid,
      'other' => VehicleFuelType.other,
      _ => null,
    };

extension VehicleTypeFirestore on VehicleType {
  String toFirestore() => switch (this) {
        VehicleType.car => 'car',
        VehicleType.motorcycle => 'motorcycle',
        VehicleType.tricycle => 'tricycle',
        VehicleType.unknown => throw StateError('VehicleType inconnu'),
      };
}

extension VehicleOfferTypeFirestore on VehicleOfferType {
  String toFirestore() => switch (this) {
        VehicleOfferType.sale => 'sale',
        VehicleOfferType.rental => 'rental',
        VehicleOfferType.unknown =>
          throw StateError('VehicleOfferType inconnu'),
      };
}

extension VehicleSellerTypeFirestore on VehicleSellerType {
  String toFirestore() => switch (this) {
        VehicleSellerType.individual => 'individual',
        VehicleSellerType.professional => 'professional',
        VehicleSellerType.unknown =>
          throw StateError('VehicleSellerType inconnu'),
      };
}

extension VehicleListingStatusFirestore on VehicleListingStatus {
  String toFirestore() => switch (this) {
        VehicleListingStatus.draft => 'draft',
        VehicleListingStatus.active => 'active',
        VehicleListingStatus.sold => 'sold',
        VehicleListingStatus.rented => 'rented',
        VehicleListingStatus.archived => 'archived',
        VehicleListingStatus.suspended => 'suspended',
        VehicleListingStatus.unknown =>
          throw StateError('VehicleListingStatus inconnu'),
      };
}

extension VehicleConditionFirestore on VehicleCondition {
  String toFirestore() => switch (this) {
        VehicleCondition.newVehicle => 'new',
        VehicleCondition.used => 'used',
        VehicleCondition.unknown =>
          throw StateError('État du véhicule inconnu'),
      };
}

extension VehicleTransmissionFirestore on VehicleTransmission {
  String toFirestore() => switch (this) {
        VehicleTransmission.manual => 'manual',
        VehicleTransmission.automatic => 'automatic',
        VehicleTransmission.unknown =>
          throw StateError('Transmission inconnue'),
      };
}

extension VehicleFuelTypeFirestore on VehicleFuelType {
  String toFirestore() => switch (this) {
        VehicleFuelType.petrol => 'petrol',
        VehicleFuelType.diesel => 'diesel',
        VehicleFuelType.electric => 'electric',
        VehicleFuelType.hybrid => 'hybrid',
        VehicleFuelType.other => 'other',
        VehicleFuelType.unknown => throw StateError('Carburant inconnu'),
      };
}

class VehicleListing {
  const VehicleListing({
    required this.id,
    required this.sellerId,
    required this.sellerType,
    required this.vehicleType,
    required this.offerType,
    required this.title,
    required this.description,
    required this.brand,
    required this.model,
    this.year,
    this.condition = VehicleCondition.unknown,
    this.color,
    this.mileageKm,
    this.transmission,
    this.fuelType,
    this.engineCapacityCc,
    this.seats,
    this.salePrice,
    this.rentalPricePerDay,
    this.rentalPricePerWeek,
    this.depositAmount,
    this.rentalWithDriver = false,
    this.rentalWithoutDriver = false,
    this.media = const [],
    this.coverMediaId,
    required this.price,
    this.currency = 'XOF',
    required this.cityId,
    required this.cityName,
    this.status = VehicleListingStatus.draft,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String sellerId;
  final VehicleSellerType sellerType;
  final VehicleType vehicleType;
  final VehicleOfferType offerType;
  final String title;
  final String description;
  final String brand;
  final String model;
  final int? year;
  final VehicleCondition condition;
  final String? color;
  final int? mileageKm;
  final VehicleTransmission? transmission;
  final VehicleFuelType? fuelType;
  final int? engineCapacityCc;
  final int? seats;
  final int? salePrice;
  final int? rentalPricePerDay;
  final int? rentalPricePerWeek;
  final int? depositAmount;
  final bool rentalWithDriver;
  final bool rentalWithoutDriver;
  final List<VehicleMedia> media;
  final String? coverMediaId;
  final int price;
  final String currency;
  final String cityId;
  final String cityName;
  final VehicleListingStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  VehicleMedia? get coverMedia {
    for (final item in media) {
      if (item.type == VehicleMediaType.image && item.id == coverMediaId) {
        return item;
      }
    }
    for (final item in media) {
      if (item.type == VehicleMediaType.image) return item;
    }
    return null;
  }

  factory VehicleListing.fromMap(String id, Map<String, dynamic> data) {
    return VehicleListing(
      id: id,
      sellerId: data['sellerId'] as String? ?? '',
      sellerType: vehicleSellerTypeFromFirestore(data['sellerType']),
      vehicleType: vehicleTypeFromFirestore(data['vehicleType']),
      offerType: vehicleOfferTypeFromFirestore(data['offerType']),
      title: data['title'] as String? ?? '',
      description: data['description'] as String? ?? '',
      brand: data['brand'] as String? ?? '',
      model: data['model'] as String? ?? '',
      year: (data['year'] as num?)?.toInt(),
      condition: vehicleConditionFromFirestore(data['condition']),
      color: data['color'] as String?,
      mileageKm: (data['mileageKm'] as num?)?.toInt(),
      transmission: vehicleTransmissionFromFirestore(data['transmission']),
      fuelType: vehicleFuelTypeFromFirestore(data['fuelType']),
      engineCapacityCc: (data['engineCapacityCc'] as num?)?.toInt(),
      seats: (data['seats'] as num?)?.toInt(),
      salePrice: (data['salePrice'] as num?)?.toInt(),
      rentalPricePerDay: (data['rentalPricePerDay'] as num?)?.toInt(),
      rentalPricePerWeek: (data['rentalPricePerWeek'] as num?)?.toInt(),
      depositAmount: (data['depositAmount'] as num?)?.toInt(),
      rentalWithDriver: data['rentalWithDriver'] as bool? ?? false,
      rentalWithoutDriver: data['rentalWithoutDriver'] as bool? ?? false,
      media: (data['media'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(VehicleMedia.fromMap)
          .toList(growable: false),
      coverMediaId: data['coverMediaId'] as String?,
      price: (data['price'] as num? ?? 0).toInt(),
      currency: data['currency'] as String? ?? 'XOF',
      cityId: data['cityId'] as String? ?? '',
      cityName: data['cityName'] as String? ?? '',
      status: vehicleListingStatusFromFirestore(data['status']),
      createdAt: _dateTimeFromFirestore(data['createdAt']),
      updatedAt: _dateTimeFromFirestore(data['updatedAt']),
    );
  }

  factory VehicleListing.fromDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
  ) =>
      VehicleListing.fromMap(document.id, document.data() ?? const {});

  Map<String, dynamic> toMap() => {
        'sellerId': sellerId.trim(),
        'sellerType': sellerType.toFirestore(),
        'vehicleType': vehicleType.toFirestore(),
        'offerType': offerType.toFirestore(),
        'title': title.trim(),
        'description': description.trim(),
        'brand': brand.trim(),
        'model': model.trim(),
        if (year != null) 'year': year,
        if (condition != VehicleCondition.unknown)
          'condition': condition.toFirestore(),
        if (_hasText(color)) 'color': color!.trim(),
        if (mileageKm != null) 'mileageKm': mileageKm,
        if (transmission != null) 'transmission': transmission!.toFirestore(),
        if (fuelType != null) 'fuelType': fuelType!.toFirestore(),
        if (engineCapacityCc != null) 'engineCapacityCc': engineCapacityCc,
        if (seats != null) 'seats': seats,
        if (salePrice != null) 'salePrice': salePrice,
        if (rentalPricePerDay != null) 'rentalPricePerDay': rentalPricePerDay,
        if (rentalPricePerWeek != null)
          'rentalPricePerWeek': rentalPricePerWeek,
        if (depositAmount != null) 'depositAmount': depositAmount,
        'rentalWithDriver': rentalWithDriver,
        'rentalWithoutDriver': rentalWithoutDriver,
        'media': media.map((item) => item.toMap()).toList(growable: false),
        if (_hasText(coverMediaId)) 'coverMediaId': coverMediaId,
        'price': price,
        'currency': currency.trim().toUpperCase(),
        'cityId': cityId.trim(),
        'cityName': cityName.trim(),
        'status': status.toFirestore(),
        if (createdAt != null) 'createdAt': Timestamp.fromDate(createdAt!),
        if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      };

  VehicleListing copyWith({
    String? id,
    String? sellerId,
    VehicleSellerType? sellerType,
    VehicleType? vehicleType,
    VehicleOfferType? offerType,
    String? title,
    String? description,
    String? brand,
    String? model,
    int? year,
    VehicleCondition? condition,
    String? color,
    int? mileageKm,
    VehicleTransmission? transmission,
    VehicleFuelType? fuelType,
    int? engineCapacityCc,
    int? seats,
    int? salePrice,
    int? rentalPricePerDay,
    int? rentalPricePerWeek,
    int? depositAmount,
    bool? rentalWithDriver,
    bool? rentalWithoutDriver,
    List<VehicleMedia>? media,
    String? coverMediaId,
    bool clearCoverMediaId = false,
    int? price,
    String? currency,
    String? cityId,
    String? cityName,
    VehicleListingStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return VehicleListing(
      id: id ?? this.id,
      sellerId: sellerId ?? this.sellerId,
      sellerType: sellerType ?? this.sellerType,
      vehicleType: vehicleType ?? this.vehicleType,
      offerType: offerType ?? this.offerType,
      title: title ?? this.title,
      description: description ?? this.description,
      brand: brand ?? this.brand,
      model: model ?? this.model,
      year: year ?? this.year,
      condition: condition ?? this.condition,
      color: color ?? this.color,
      mileageKm: mileageKm ?? this.mileageKm,
      transmission: transmission ?? this.transmission,
      fuelType: fuelType ?? this.fuelType,
      engineCapacityCc: engineCapacityCc ?? this.engineCapacityCc,
      seats: seats ?? this.seats,
      salePrice: salePrice ?? this.salePrice,
      rentalPricePerDay: rentalPricePerDay ?? this.rentalPricePerDay,
      rentalPricePerWeek: rentalPricePerWeek ?? this.rentalPricePerWeek,
      depositAmount: depositAmount ?? this.depositAmount,
      rentalWithDriver: rentalWithDriver ?? this.rentalWithDriver,
      rentalWithoutDriver: rentalWithoutDriver ?? this.rentalWithoutDriver,
      media: media ?? this.media,
      coverMediaId:
          clearCoverMediaId ? null : coverMediaId ?? this.coverMediaId,
      price: price ?? this.price,
      currency: currency ?? this.currency,
      cityId: cityId ?? this.cityId,
      cityName: cityName ?? this.cityName,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

bool _hasText(String? value) => value != null && value.trim().isNotEmpty;

DateTime? _dateTimeFromFirestore(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}
