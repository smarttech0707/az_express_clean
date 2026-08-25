/// Master Prompt "Immobilier V6" — Mission 4 : regroupe tous les filtres de
/// recherche étendus en un seul objet immuable, passé tel quel à
/// `RealEstateService.search()`. Ne contient jamais la position GPS du
/// client en dur (fournie séparément, jamais persistée — cohérent avec
/// Mission 6 du chantier GPS : "jamais demandée automatiquement").
class RealEstateSearchFilters {
  final String? query;
  final String? city;
  final String? quartier;
  final String? priceType;
  final int? minPrice;
  final int? maxPrice;
  final double? minSurface;
  final double? maxSurface;
  final int? minBedrooms;
  final bool? furnished;
  final bool? hasPool;
  final bool? hasGarage;
  final bool? hasParking;
  final bool? hasInternet;
  final bool? availableOnly;
  final bool landOnly;
  final bool commercialOnly;
  final bool furnishedResidenceOnly;
  final double? maxDistanceKm;
  final double? fromLatitude;
  final double? fromLongitude;

  const RealEstateSearchFilters({
    this.query,
    this.city,
    this.quartier,
    this.priceType,
    this.minPrice,
    this.maxPrice,
    this.minSurface,
    this.maxSurface,
    this.minBedrooms,
    this.furnished,
    this.hasPool,
    this.hasGarage,
    this.hasParking,
    this.hasInternet,
    this.availableOnly,
    this.landOnly = false,
    this.commercialOnly = false,
    this.furnishedResidenceOnly = false,
    this.maxDistanceKm,
    this.fromLatitude,
    this.fromLongitude,
  });

  /// Aucun filtre actif (état initial de l'écran de recherche).
  bool get isEmpty =>
      query == null &&
      city == null &&
      quartier == null &&
      priceType == null &&
      minPrice == null &&
      maxPrice == null &&
      minSurface == null &&
      maxSurface == null &&
      minBedrooms == null &&
      furnished == null &&
      hasPool == null &&
      hasGarage == null &&
      hasParking == null &&
      hasInternet == null &&
      availableOnly == null &&
      !landOnly &&
      !commercialOnly &&
      !furnishedResidenceOnly &&
      maxDistanceKm == null;

  RealEstateSearchFilters copyWith({
    String? query,
    String? city,
    String? quartier,
    String? priceType,
    int? minPrice,
    int? maxPrice,
    double? minSurface,
    double? maxSurface,
    int? minBedrooms,
    bool? furnished,
    bool? hasPool,
    bool? hasGarage,
    bool? hasParking,
    bool? hasInternet,
    bool? availableOnly,
    bool? landOnly,
    bool? commercialOnly,
    bool? furnishedResidenceOnly,
    double? maxDistanceKm,
    double? fromLatitude,
    double? fromLongitude,
  }) =>
      RealEstateSearchFilters(
        query: query ?? this.query,
        city: city ?? this.city,
        quartier: quartier ?? this.quartier,
        priceType: priceType ?? this.priceType,
        minPrice: minPrice ?? this.minPrice,
        maxPrice: maxPrice ?? this.maxPrice,
        minSurface: minSurface ?? this.minSurface,
        maxSurface: maxSurface ?? this.maxSurface,
        minBedrooms: minBedrooms ?? this.minBedrooms,
        furnished: furnished ?? this.furnished,
        hasPool: hasPool ?? this.hasPool,
        hasGarage: hasGarage ?? this.hasGarage,
        hasParking: hasParking ?? this.hasParking,
        hasInternet: hasInternet ?? this.hasInternet,
        availableOnly: availableOnly ?? this.availableOnly,
        landOnly: landOnly ?? this.landOnly,
        commercialOnly: commercialOnly ?? this.commercialOnly,
        furnishedResidenceOnly:
            furnishedResidenceOnly ?? this.furnishedResidenceOnly,
        maxDistanceKm: maxDistanceKm ?? this.maxDistanceKm,
        fromLatitude: fromLatitude ?? this.fromLatitude,
        fromLongitude: fromLongitude ?? this.fromLongitude,
      );
}
