import 'package:az_express/auto_moto/models/vehicle_listing.dart';
import 'package:az_express/auto_moto/vehicle_listing_validator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

VehicleListing validListing({
  String sellerId = 'seller-1',
  int? year = 2024,
  int price = 2500000,
}) =>
    VehicleListing(
      id: 'listing-1',
      sellerId: sellerId,
      sellerType: VehicleSellerType.individual,
      vehicleType: VehicleType.car,
      offerType: VehicleOfferType.sale,
      title: 'Toyota Corolla 2024',
      description: 'Véhicule propre et régulièrement entretenu.',
      brand: 'Toyota',
      model: 'Corolla',
      year: year,
      condition: VehicleCondition.used,
      color: 'Gris',
      mileageKm: 35000,
      transmission: VehicleTransmission.automatic,
      fuelType: VehicleFuelType.petrol,
      seats: 5,
      salePrice: price,
      price: price,
      cityId: 'agnibilekrou',
      cityName: 'Agnibilékrou',
      status: VehicleListingStatus.active,
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 2),
    );

void main() {
  test('sérialise le contrat Firestore sans id', () {
    final map = validListing().toMap();

    expect(map['sellerType'], 'individual');
    expect(map['vehicleType'], 'car');
    expect(map['offerType'], 'sale');
    expect(map['status'], 'active');
    expect(map['currency'], 'XOF');
    expect(map['createdAt'], isA<Timestamp>());
    expect(map.containsKey('id'), isFalse);
  });

  test('désérialise les champs et timestamps', () {
    final source = validListing();
    final decoded = VehicleListing.fromMap('listing-2', source.toMap());

    expect(decoded.id, 'listing-2');
    expect(decoded.vehicleType, VehicleType.car);
    expect(decoded.year, 2024);
    expect(
      decoded.createdAt?.millisecondsSinceEpoch,
      source.createdAt?.millisecondsSinceEpoch,
    );
  });

  test('les valeurs enum inconnues ne font pas planter la lecture', () {
    final map = validListing().toMap()
      ..['vehicleType'] = 'boat'
      ..['offerType'] = 'exchange'
      ..['sellerType'] = 'verified'
      ..['status'] = 'moderated';
    final decoded = VehicleListing.fromMap('legacy', map);

    expect(decoded.vehicleType, VehicleType.unknown);
    expect(decoded.offerType, VehicleOfferType.unknown);
    expect(decoded.sellerType, VehicleSellerType.unknown);
    expect(decoded.status, VehicleListingStatus.unknown);
    expect(VehicleListingValidator.validate(decoded), isNotEmpty);
  });

  test('refuse prix négatif, sellerId vide et année invalide', () {
    final errors = VehicleListingValidator.validate(
      validListing(sellerId: ' ', price: -1, year: 2200),
      now: DateTime.utc(2026),
    );

    expect(errors, contains('sellerId est obligatoire.'));
    expect(errors, contains('Le prix doit être supérieur à zéro.'));
    expect(errors, contains('L’année du véhicule est invalide.'));
  });

  test('copyWith conserve le socle et applique les changements', () {
    final changed = validListing().copyWith(
      price: 2400000,
      status: VehicleListingStatus.sold,
    );

    expect(changed.price, 2400000);
    expect(changed.status, VehicleListingStatus.sold);
    expect(changed.sellerId, 'seller-1');
    expect(changed.title, 'Toyota Corolla 2024');
  });

  test('accepte une annonce valide et refuse un cityId non normalisé', () {
    expect(VehicleListingValidator.validate(validListing()), isEmpty);
    expect(
      VehicleListingValidator.validate(
        validListing().copyWith(cityId: 'Agnibilékrou'),
      ),
      contains('cityId doit être non vide et normalisé.'),
    );
  });
}
