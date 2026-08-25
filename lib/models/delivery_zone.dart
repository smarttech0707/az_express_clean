import 'local_place.dart';

enum ZoneCoordinateSource { own, inherited, unknown }

/// Représentation tolérante d'un document `zones_livraison`.
///
/// Les champs legacy absents restent nuls, sauf les valeurs par défaut
/// explicitement définies par le contrat multi-ville.
class DeliveryZone {
  final String id;
  final String? name;
  final String? type;
  final String? cityId;
  final String? parentZoneId;
  final String? parentName;
  final String? normalizedName;
  final List<String> aliases;
  final double? lat;
  final double? lng;
  final double? radiusKm;
  final ZoneCoordinateSource coordinateSource;
  final bool isServiceable;
  final bool? isActive;
  final num? order;

  const DeliveryZone({
    required this.id,
    this.name,
    this.type,
    this.cityId,
    this.parentZoneId,
    this.parentName,
    this.normalizedName,
    this.aliases = const [],
    this.lat,
    this.lng,
    this.radiusKm,
    this.coordinateSource = ZoneCoordinateSource.unknown,
    this.isServiceable = false,
    this.isActive,
    this.order,
  });

  factory DeliveryZone.fromMap(String id, Map<String, dynamic> data) {
    return DeliveryZone(
      id: id,
      name: data['name'] as String?,
      type: data['type'] as String?,
      cityId: data['cityId'] as String?,
      parentZoneId: data['parentZoneId'] as String?,
      parentName: data['parentName'] as String?,
      normalizedName: data['normalizedName'] as String?,
      aliases: _stringList(data['aliases']),
      lat: _doubleOrNull(data['lat']),
      lng: _doubleOrNull(data['lng']),
      radiusKm: _doubleOrNull(data['radiusKm']),
      coordinateSource: _coordinateSource(data['coordinateSource']),
      isServiceable: data['isServiceable'] as bool? ?? false,
      isActive: data['isActive'] as bool?,
      order: data['order'] as num?,
    );
  }

  /// Nom normalisé calculé à la demande, sans aucune écriture Firestore.
  String? get effectiveNormalizedName {
    final stored = normalizedName;
    if (stored != null) return stored;
    final legacyName = name;
    return legacyName == null ? null : LocalPlace.normalize(legacyName);
  }

  bool get hasUsableGeometry {
    final latitude = lat;
    final longitude = lng;
    final radius = radiusKm;
    return coordinateSource == ZoneCoordinateSource.own &&
        isServiceable &&
        latitude != null &&
        latitude.isFinite &&
        latitude >= -90 &&
        latitude <= 90 &&
        longitude != null &&
        longitude.isFinite &&
        longitude >= -180 &&
        longitude <= 180 &&
        radius != null &&
        radius.isFinite &&
        radius > 0;
  }

  static double? _doubleOrNull(dynamic value) =>
      value is num ? value.toDouble() : null;

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<String>().toList(growable: false);
  }

  static ZoneCoordinateSource _coordinateSource(dynamic value) {
    switch (value) {
      case 'own':
        return ZoneCoordinateSource.own;
      case 'inherited':
        return ZoneCoordinateSource.inherited;
      default:
        return ZoneCoordinateSource.unknown;
    }
  }
}
