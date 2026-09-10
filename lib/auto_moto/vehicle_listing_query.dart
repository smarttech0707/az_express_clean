import 'models/vehicle_listing.dart';

enum VehicleListingSort { newest, priceAscending, priceDescending, yearNewest }

class VehicleListingRequest {
  const VehicleListingRequest({
    this.cityId,
    required this.offerType,
    required this.vehicleType,
    this.searchText = '',
    this.filters = const VehicleListingFilters(),
    this.sort = VehicleListingSort.newest,
  });

  /// Null means all cities in Côte d’Ivoire; a listing itself always has one.
  final String? cityId;
  final VehicleOfferType offerType;
  final VehicleType vehicleType;
  final String searchText;
  final VehicleListingFilters filters;
  final VehicleListingSort sort;

  String get normalizedSearch => normalizeVehicleSearch(searchText);
}

class VehicleListingFilters {
  const VehicleListingFilters({
    this.condition,
    this.brand,
    this.minYear,
    this.maxYear,
    this.minPrice,
    this.maxPrice,
    this.transmission,
    this.fuelType,
    this.maxMileageKm,
    this.minEngineCapacityCc,
    this.seats,
    this.withDriver,
    this.withoutDriver,
  });

  final VehicleCondition? condition;
  final String? brand;
  final int? minYear;
  final int? maxYear;
  final int? minPrice;
  final int? maxPrice;
  final VehicleTransmission? transmission;
  final VehicleFuelType? fuelType;
  final int? maxMileageKm;
  final int? minEngineCapacityCc;
  final int? seats;
  final bool? withDriver;
  final bool? withoutDriver;

  bool get isEmpty => activeCount == 0;
  int get activeCount => [
        condition,
        brand?.trim().isEmpty == false ? brand : null,
        minYear,
        maxYear,
        minPrice,
        maxPrice,
        transmission,
        fuelType,
        maxMileageKm,
        minEngineCapacityCc,
        seats,
        withDriver == true ? true : null,
        withoutDriver == true ? true : null,
      ].where((value) => value != null).length;

  bool matches(VehicleListing listing) {
    final normalizedBrand = normalizeVehicleSearch(brand ?? '');
    return (condition == null || listing.condition == condition) &&
        (normalizedBrand.isEmpty ||
            normalizeVehicleSearch(listing.brand) == normalizedBrand) &&
        (minYear == null || (listing.year ?? -1) >= minYear!) &&
        (maxYear == null || (listing.year ?? 99999) <= maxYear!) &&
        (minPrice == null || listing.price >= minPrice!) &&
        (maxPrice == null || listing.price <= maxPrice!) &&
        (transmission == null || listing.transmission == transmission) &&
        (fuelType == null || listing.fuelType == fuelType) &&
        (maxMileageKm == null ||
            (listing.mileageKm ?? 1 << 30) <= maxMileageKm!) &&
        (minEngineCapacityCc == null ||
            (listing.engineCapacityCc ?? -1) >= minEngineCapacityCc!) &&
        (seats == null || listing.seats == seats) &&
        (withDriver != true || listing.rentalWithDriver) &&
        (withoutDriver != true || listing.rentalWithoutDriver);
  }
}

String normalizeVehicleSearch(String value) {
  const accents = 'àáâäãåçèéêëìíîïñòóôöõùúûüýÿ';
  const ascii = 'aaaaaaceeeeiiiinooooouuuuyy';
  var result = value.trim().toLowerCase();
  for (var index = 0; index < accents.length; index++) {
    result = result.replaceAll(accents[index], ascii[index]);
  }
  return result.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

List<String> buildVehicleSearchKeywords({
  required String title,
  required String brand,
  required String model,
}) {
  final keywords = <String>{};
  for (final source in [brand, model, title, '$brand $model']) {
    final normalized = normalizeVehicleSearch(source);
    if (normalized.isEmpty) continue;
    keywords.add(normalized);
    for (final word in normalized.split(' ')) {
      if (word.isEmpty) continue;
      for (var length = 1; length <= word.length; length++) {
        keywords.add(word.substring(0, length));
      }
    }
  }
  return keywords.take(100).toList(growable: false);
}
