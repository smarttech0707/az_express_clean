import 'package:cloud_firestore/cloud_firestore.dart';

/// Modèle de `real_estate_private_locations/{listingId}` — coordonnées
/// EXACTES d'une annonce. Ne doit être chargé QUE pour un utilisateur déjà
/// autorisé par les Firestore Rules (propriétaire/agent, admin, ou client
/// avec un accès accordé après confirmation réelle de visite) — jamais
/// affiché à un utilisateur non vérifié, ces Rules étant la seule barrière
/// réelle (ce modèle ne fait aucune vérification lui-même).
class RealEstatePrivateLocation {
  final String listingId;
  final String ownerId;
  final String agentId;
  final double exactLatitude;
  final double exactLongitude;
  final String exactGeohash;
  final String? exactAddress;
  final String? exactCity;
  final String? exactQuartier;
  final bool locationVerified;
  final DateTime? locationUpdatedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const RealEstatePrivateLocation({
    required this.listingId,
    required this.ownerId,
    required this.agentId,
    required this.exactLatitude,
    required this.exactLongitude,
    required this.exactGeohash,
    this.exactAddress,
    this.exactCity,
    this.exactQuartier,
    this.locationVerified = false,
    this.locationUpdatedAt,
    this.createdAt,
    this.updatedAt,
  });

  factory RealEstatePrivateLocation.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return RealEstatePrivateLocation(
      listingId: d['listingId'] as String? ?? doc.id,
      ownerId: d['ownerId'] as String? ?? '',
      agentId: d['agentId'] as String? ?? '',
      exactLatitude: (d['exactLatitude'] as num?)?.toDouble() ?? 0,
      exactLongitude: (d['exactLongitude'] as num?)?.toDouble() ?? 0,
      exactGeohash: d['exactGeohash'] as String? ?? '',
      exactAddress: d['exactAddress'] as String?,
      exactCity: d['exactCity'] as String?,
      exactQuartier: d['exactQuartier'] as String?,
      locationVerified: d['locationVerified'] == true,
      locationUpdatedAt: (d['locationUpdatedAt'] as Timestamp?)?.toDate(),
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
