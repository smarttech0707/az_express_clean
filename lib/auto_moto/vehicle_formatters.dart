import 'models/vehicle_listing.dart';

String formatVehiclePrice(int price, {String currency = 'XOF'}) {
  final digits = price.toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(' ');
    buffer.write(digits[index]);
  }
  return '${buffer.toString()} ${currency == 'XOF' ? 'FCFA' : currency}';
}

String vehicleTypeLabel(VehicleType type) => switch (type) {
      VehicleType.car => 'Voiture',
      VehicleType.motorcycle => 'Moto',
      VehicleType.tricycle => 'Tricycle',
      VehicleType.unknown => 'Véhicule',
    };

String vehicleOfferLabel(VehicleOfferType type) => switch (type) {
      VehicleOfferType.sale => 'Vente',
      VehicleOfferType.rental => 'Location',
      VehicleOfferType.unknown => 'Offre',
    };

String vehicleListingStatusLabel(VehicleListingStatus status) =>
    switch (status) {
      VehicleListingStatus.draft => 'Brouillon',
      VehicleListingStatus.active => 'Active',
      VehicleListingStatus.sold => 'Vendue',
      VehicleListingStatus.rented => 'Louée',
      VehicleListingStatus.archived => 'Archivée',
      VehicleListingStatus.suspended => 'Suspendue par AZ Express',
      VehicleListingStatus.unknown => 'Statut inconnu',
    };
