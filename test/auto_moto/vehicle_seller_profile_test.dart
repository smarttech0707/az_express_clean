import 'package:az_express/auto_moto/models/vehicle_listing.dart';
import 'package:az_express/auto_moto/models/vehicle_seller_private_location.dart';
import 'package:az_express/auto_moto/models/vehicle_seller_profile.dart';
import 'package:az_express/auto_moto/vehicle_seller_profile_validator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

VehicleSellerProfile individualProfile() => VehicleSellerProfile(
      ownerId: 'seller-1',
      sellerType: VehicleSellerType.individual,
      displayName: 'Aya Koné',
      phone: '0700000000',
      cityId: 'abengourou',
      zoneId: 'centre-ville',
      createdAt: DateTime.utc(2026, 9, 5),
      updatedAt: DateTime.utc(2026, 9, 5),
    );

VehicleSellerProfile professionalProfile({
  String? shopName = 'AZ Motors',
  String? professionalPhone = '0100000000',
  VehicleBusinessType? businessType = VehicleBusinessType.dealership,
}) =>
    VehicleSellerProfile(
      ownerId: 'seller-2',
      sellerType: VehicleSellerType.professional,
      displayName: 'Moussa Traoré',
      phone: '0500000000',
      cityId: 'agnibilekrou',
      shopName: shopName,
      businessType: businessType,
      professionalPhone: professionalPhone,
      address: 'Quartier Commerce',
      locationVisibility: VehicleLocationVisibility.approximate,
      verificationStatus: VehicleSellerVerificationStatus.pending,
    );

void main() {
  test('sérialise et désérialise un profil particulier', () {
    final source = individualProfile();
    final map = source.toMap();
    final decoded = VehicleSellerProfile.fromMap(map);

    expect(map['sellerType'], 'individual');
    expect(map.containsKey('shopName'), isFalse);
    expect(map['createdAt'], isA<Timestamp>());
    expect(decoded.ownerId, source.ownerId);
    expect(decoded.sellerType, VehicleSellerType.individual);
    expect(VehicleSellerProfileValidator.validate(decoded), isEmpty);
  });

  test('sérialise un professionnel et ses enums techniques', () {
    final map = professionalProfile().toMap();

    expect(map['sellerType'], 'professional');
    expect(map['businessType'], 'dealership');
    expect(map['locationVisibility'], 'approximate');
    expect(map['verificationStatus'], 'pending');
    expect(
        VehicleSellerProfileValidator.validate(professionalProfile()), isEmpty);
  });

  test('accepte uniquement un chemin logo déterministe appartenant au vendeur',
      () {
    final valid = professionalProfile().copyWith(
      logoUrl: 'https://storage.example/logo.jpg',
      logoStoragePath: 'vehicle_seller_profiles/seller-2/logo/media-id.jpg',
      zoneId: null,
      shopName: 'AZ Motors',
      businessType: VehicleBusinessType.dealership,
      professionalPhone: '0100000000',
      address: 'Quartier Commerce',
      locationVisibility: VehicleLocationVisibility.approximate,
    );
    expect(VehicleSellerProfileValidator.validate(valid), isEmpty);
    final invalid = valid.copyWith(
      logoStoragePath: 'vehicle_seller_profiles/other/logo/media-id.jpg',
      shopName: valid.shopName,
      businessType: valid.businessType,
      professionalPhone: valid.professionalPhone,
      address: valid.address,
      locationVisibility: valid.locationVisibility,
      logoUrl: valid.logoUrl,
    );
    expect(VehicleSellerProfileValidator.validate(invalid), isNotEmpty);
  });

  test('les valeurs inconnues sont lues sans crash puis refusées', () {
    final map = professionalProfile().toMap()
      ..['sellerType'] = 'merchant'
      ..['businessType'] = 'importer'
      ..['verificationStatus'] = 'approved';
    final decoded = VehicleSellerProfile.fromMap(map);

    expect(decoded.sellerType, VehicleSellerType.unknown);
    expect(decoded.businessType, VehicleBusinessType.unknown);
    expect(
      decoded.verificationStatus,
      VehicleSellerVerificationStatus.unknown,
    );
    expect(VehicleSellerProfileValidator.validate(decoded), isNotEmpty);
  });

  test('particulier sans shopName accepté', () {
    expect(
        VehicleSellerProfileValidator.validate(individualProfile()), isEmpty);
  });

  test('professionnel sans magasin, téléphone ou activité refusé', () {
    final errors = VehicleSellerProfileValidator.validate(
      professionalProfile(
        shopName: null,
        professionalPhone: null,
        businessType: null,
      ),
    );

    expect(errors, contains('Le nom du magasin est obligatoire.'));
    expect(errors, contains('Le téléphone professionnel est obligatoire.'));
    expect(
      errors,
      contains('L’activité professionnelle est obligatoire et valide.'),
    );
  });

  test('sérialise et valide une localisation privée', () {
    final location = VehicleSellerPrivateLocation(
      ownerId: 'seller-2',
      latitude: 6.7297,
      longitude: -3.4964,
      cityId: 'abengourou',
      zoneId: 'centre-ville',
      addressLabel: 'Près du marché',
      updatedAt: DateTime.utc(2026, 9, 5),
    );
    final decoded = VehicleSellerPrivateLocation.fromMap(location.toMap());

    expect(decoded.latitude, 6.7297);
    expect(decoded.longitude, -3.4964);
    expect(decoded.cityId, 'abengourou');
    expect(
      VehicleSellerProfileValidator.validatePrivateLocation(decoded),
      isEmpty,
    );
  });

  test('refuse les coordonnées hors limites et ownerId vide', () {
    final errors = VehicleSellerProfileValidator.validatePrivateLocation(
      const VehicleSellerPrivateLocation(
        ownerId: '',
        latitude: 91,
        longitude: -181,
        cityId: 'abengourou',
      ),
    );

    expect(errors, contains('ownerId est obligatoire.'));
    expect(errors, contains('La latitude est invalide.'));
    expect(errors, contains('La longitude est invalide.'));
  });
}
