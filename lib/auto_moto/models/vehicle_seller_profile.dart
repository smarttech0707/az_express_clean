import 'package:cloud_firestore/cloud_firestore.dart';

import 'vehicle_listing.dart';

enum VehicleBusinessType {
  dealership,
  garage,
  motorcycleShop,
  vehicleRental,
  other,
  unknown,
}

enum VehicleSellerVerificationStatus {
  unverified,
  pending,
  verified,
  rejected,
  unknown,
}

enum VehicleLocationVisibility { exact, approximate, hidden, unknown }

VehicleBusinessType vehicleBusinessTypeFromFirestore(Object? value) =>
    switch (value) {
      'dealership' => VehicleBusinessType.dealership,
      'garage' => VehicleBusinessType.garage,
      'motorcycle_shop' => VehicleBusinessType.motorcycleShop,
      'vehicle_rental' => VehicleBusinessType.vehicleRental,
      'other' => VehicleBusinessType.other,
      _ => VehicleBusinessType.unknown,
    };

VehicleSellerVerificationStatus verificationStatusFromFirestore(
  Object? value,
) =>
    switch (value) {
      'unverified' => VehicleSellerVerificationStatus.unverified,
      'pending' => VehicleSellerVerificationStatus.pending,
      'verified' => VehicleSellerVerificationStatus.verified,
      'rejected' => VehicleSellerVerificationStatus.rejected,
      _ => VehicleSellerVerificationStatus.unknown,
    };

VehicleLocationVisibility locationVisibilityFromFirestore(Object? value) =>
    switch (value) {
      'exact' => VehicleLocationVisibility.exact,
      'approximate' => VehicleLocationVisibility.approximate,
      'hidden' => VehicleLocationVisibility.hidden,
      _ => VehicleLocationVisibility.unknown,
    };

extension VehicleBusinessTypeFirestore on VehicleBusinessType {
  String toFirestore() => switch (this) {
        VehicleBusinessType.dealership => 'dealership',
        VehicleBusinessType.garage => 'garage',
        VehicleBusinessType.motorcycleShop => 'motorcycle_shop',
        VehicleBusinessType.vehicleRental => 'vehicle_rental',
        VehicleBusinessType.other => 'other',
        VehicleBusinessType.unknown =>
          throw StateError('VehicleBusinessType inconnu'),
      };
}

extension VehicleSellerVerificationStatusFirestore
    on VehicleSellerVerificationStatus {
  String toFirestore() => switch (this) {
        VehicleSellerVerificationStatus.unverified => 'unverified',
        VehicleSellerVerificationStatus.pending => 'pending',
        VehicleSellerVerificationStatus.verified => 'verified',
        VehicleSellerVerificationStatus.rejected => 'rejected',
        VehicleSellerVerificationStatus.unknown =>
          throw StateError('VehicleSellerVerificationStatus inconnu'),
      };
}

extension VehicleLocationVisibilityFirestore on VehicleLocationVisibility {
  String toFirestore() => switch (this) {
        VehicleLocationVisibility.exact => 'exact',
        VehicleLocationVisibility.approximate => 'approximate',
        VehicleLocationVisibility.hidden => 'hidden',
        VehicleLocationVisibility.unknown =>
          throw StateError('VehicleLocationVisibility inconnue'),
      };
}

class VehicleSellerProfile {
  const VehicleSellerProfile({
    required this.ownerId,
    required this.sellerType,
    required this.displayName,
    required this.phone,
    required this.cityId,
    this.zoneId,
    this.profilePhotoUrl,
    this.shopName,
    this.businessType,
    this.professionalPhone,
    this.address,
    this.locationVisibility,
    this.logoUrl,
    this.logoStoragePath,
    this.description,
    this.openingHours,
    this.verificationStatus = VehicleSellerVerificationStatus.unverified,
    this.suspended = false,
    this.suspensionReason,
    this.suspendedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String ownerId;
  final VehicleSellerType sellerType;
  final String displayName;
  final String phone;
  final String cityId;
  final String? zoneId;
  final String? profilePhotoUrl;
  final String? shopName;
  final VehicleBusinessType? businessType;
  final String? professionalPhone;
  final String? address;
  final VehicleLocationVisibility? locationVisibility;
  final String? logoUrl;
  final String? logoStoragePath;
  final String? description;
  final String? openingHours;
  final VehicleSellerVerificationStatus verificationStatus;
  final bool suspended;
  final String? suspensionReason;
  final DateTime? suspendedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory VehicleSellerProfile.fromMap(Map<String, dynamic> data) {
    return VehicleSellerProfile(
      ownerId: data['ownerId'] as String? ?? '',
      sellerType: vehicleSellerTypeFromFirestore(data['sellerType']),
      displayName: data['displayName'] as String? ?? '',
      phone: data['phone'] as String? ?? '',
      cityId: data['cityId'] as String? ?? '',
      zoneId: data['zoneId'] as String?,
      profilePhotoUrl: data['profilePhotoUrl'] as String?,
      shopName: data['shopName'] as String?,
      businessType: data.containsKey('businessType')
          ? vehicleBusinessTypeFromFirestore(data['businessType'])
          : null,
      professionalPhone: data['professionalPhone'] as String?,
      address: data['address'] as String?,
      locationVisibility: data.containsKey('locationVisibility')
          ? locationVisibilityFromFirestore(data['locationVisibility'])
          : null,
      logoUrl: data['logoUrl'] as String?,
      logoStoragePath: data['logoStoragePath'] as String?,
      description: data['description'] as String?,
      openingHours: data['openingHours'] as String?,
      verificationStatus:
          verificationStatusFromFirestore(data['verificationStatus']),
      suspended: data['suspended'] as bool? ?? false,
      suspensionReason: data['suspensionReason'] as String?,
      suspendedAt: _dateTimeFromFirestore(data['suspendedAt']),
      createdAt: _dateTimeFromFirestore(data['createdAt']),
      updatedAt: _dateTimeFromFirestore(data['updatedAt']),
    );
  }

  factory VehicleSellerProfile.fromDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
  ) =>
      VehicleSellerProfile.fromMap(document.data() ?? const {});

  Map<String, dynamic> toMap() => {
        'ownerId': ownerId.trim(),
        'sellerType': sellerType.toFirestore(),
        'displayName': displayName.trim(),
        'phone': phone.trim(),
        'cityId': cityId.trim(),
        if (_hasText(zoneId)) 'zoneId': zoneId!.trim(),
        if (_hasText(profilePhotoUrl))
          'profilePhotoUrl': profilePhotoUrl!.trim(),
        if (_hasText(shopName)) 'shopName': shopName!.trim(),
        if (businessType != null) 'businessType': businessType!.toFirestore(),
        if (_hasText(professionalPhone))
          'professionalPhone': professionalPhone!.trim(),
        if (_hasText(address)) 'address': address!.trim(),
        if (locationVisibility != null)
          'locationVisibility': locationVisibility!.toFirestore(),
        if (_hasText(logoUrl)) 'logoUrl': logoUrl!.trim(),
        if (_hasText(logoStoragePath))
          'logoStoragePath': logoStoragePath!.trim(),
        if (_hasText(description)) 'description': description!.trim(),
        if (_hasText(openingHours)) 'openingHours': openingHours!.trim(),
        'verificationStatus': verificationStatus.toFirestore(),
        if (suspended) 'suspended': true,
        if (_hasText(suspensionReason))
          'suspensionReason': suspensionReason!.trim(),
        if (suspendedAt != null)
          'suspendedAt': Timestamp.fromDate(suspendedAt!),
        if (createdAt != null) 'createdAt': Timestamp.fromDate(createdAt!),
        if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      };

  VehicleSellerProfile copyWith({
    String? displayName,
    String? phone,
    String? cityId,
    String? zoneId,
    String? shopName,
    VehicleBusinessType? businessType,
    String? professionalPhone,
    String? address,
    VehicleLocationVisibility? locationVisibility,
    String? logoUrl,
    String? logoStoragePath,
  }) =>
      VehicleSellerProfile(
        ownerId: ownerId,
        sellerType: sellerType,
        displayName: displayName ?? this.displayName,
        phone: phone ?? this.phone,
        cityId: cityId ?? this.cityId,
        zoneId: zoneId,
        profilePhotoUrl: profilePhotoUrl,
        shopName: shopName,
        businessType: businessType,
        professionalPhone: professionalPhone,
        address: address,
        locationVisibility: locationVisibility,
        logoUrl: logoUrl,
        logoStoragePath: logoStoragePath,
        description: description,
        openingHours: openingHours,
        verificationStatus: verificationStatus,
        suspended: suspended,
        suspensionReason: suspensionReason,
        suspendedAt: suspendedAt,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

bool _hasText(String? value) => value != null && value.trim().isNotEmpty;

DateTime? _dateTimeFromFirestore(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}
