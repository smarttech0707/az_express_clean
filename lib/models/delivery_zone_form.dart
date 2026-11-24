import 'delivery_zone.dart';
import 'local_place.dart';

class DeliveryZoneFormData {
  final String name;
  final String type;
  final String cityId;
  final String? parentZoneId;
  final List<String> aliases;
  final double? lat;
  final double? lng;
  final double? radiusKm;
  final bool isServiceable;
  final bool isActive;
  final int order;

  const DeliveryZoneFormData({
    required this.name,
    required this.type,
    required this.cityId,
    required this.parentZoneId,
    required this.aliases,
    required this.lat,
    required this.lng,
    required this.radiusKm,
    required this.isServiceable,
    required this.isActive,
    required this.order,
  });

  static String cityIdFromName(String name) => LocalPlace.normalize(name);

  String? validate({
    required Iterable<String> existingCityIds,
  }) {
    if (name.trim().isEmpty) return 'Le nom est obligatoire.';
    if (!const {'ville', 'quartier', 'village', 'secteur'}.contains(type)) {
      return 'Le type de zone est invalide.';
    }
    if (cityId.trim().isEmpty) return 'Le cityId est obligatoire.';
    final normalizedCityId = LocalPlace.normalize(cityId);
    if (normalizedCityId != cityId.trim()) {
      return 'Le cityId doit être normalisé.';
    }
    final cityIdTaken = existingCityIds.any((value) => value == cityId);
    if (type == 'ville' && cityIdTaken) {
      return 'Ce cityId est déjà utilisé par une autre ville.';
    }
    if (type != 'ville' &&
        (parentZoneId == null || parentZoneId!.trim().isEmpty)) {
      return 'Une zone enfant exige une ville parente.';
    }
    if ((lat == null) != (lng == null)) {
      return 'Latitude et longitude doivent être renseignées ensemble.';
    }
    if (lat != null && (lat! < -90 || lat! > 90)) {
      return 'La latitude doit être comprise entre -90 et 90.';
    }
    if (lng != null && (lng! < -180 || lng! > 180)) {
      return 'La longitude doit être comprise entre -180 et 180.';
    }
    if (radiusKm != null && radiusKm! <= 0) {
      return 'Le rayon doit être supérieur à 0 km.';
    }
    if (isServiceable && (lat == null || lng == null || radiusKm == null)) {
      return 'Une zone desservie exige un point propre et un rayon supérieur à 0.';
    }
    return null;
  }

  ZoneCoordinateSource get coordinateSource => lat != null && lng != null
      ? ZoneCoordinateSource.own
      : ZoneCoordinateSource.unknown;

  Map<String, dynamic> toMap() => {
        'name': name.trim(),
        'type': type,
        'cityId': cityId.trim(),
        if (type != 'ville') 'parentZoneId': parentZoneId,
        'normalizedName': LocalPlace.normalize(name),
        'aliases': aliases,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (radiusKm != null) 'radiusKm': radiusKm,
        'coordinateSource': coordinateSource.name,
        'isServiceable': isServiceable,
        'isActive': isActive,
        'order': order,
      };
}
