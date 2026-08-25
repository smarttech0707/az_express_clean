import 'package:cloud_firestore/cloud_firestore.dart';

class RealEstateListing {
  final String id;
  final String agentId;
  final String? agentName;
  final String? agentPhone;
  final String title;
  final String description;
  final int price;
  final String priceType; // 'sale' | 'rent'
  final String propertyType;
  final bool furnished;
  final String city;

  /// Hérité (Master Prompt "correctif nullable"), plus jamais écrit par le
  /// formulaire agent depuis "GPS privé V2" — conservé nullable uniquement
  /// pour la rétrocompatibilité de lecture d'anciennes annonces. Jamais
  /// affiché publiquement : voir `publicLatitude`/`publicLongitude`.
  final double? lat;
  final double? lng;

  /// 'exact' | 'approximate' | 'hidden' — null pour une annonce héritée
  /// jamais passée par upsertRealEstateLocation (aucune localisation connue).
  final String? locationPrivacy;

  /// Coordonnée PUBLIQUE autorisée par [locationPrivacy] — jamais la
  /// coordonnée exacte quand locationPrivacy vaut 'approximate' ou 'hidden'.
  /// Absente (null) pour 'hidden'. Calculée côté serveur uniquement.
  final double? publicLatitude;
  final double? publicLongitude;
  final String? publicGeohash;
  final String? publicAddress;
  final String? quartier;
  final String? locationLabel;

  /// true seulement si locationPrivacy == 'exact' — jamais déduit côté
  /// client, toujours le reflet direct de ce que le serveur a écrit.
  final bool hasExactLocation;
  final DateTime? locationUpdatedAt;

  final List<String> images;

  /// Master Prompt "Immobilier V6" — Mission 6 : liens vidéo (YouTube, lien
  /// direct...), ouverts en externe via `url_launcher` — pas de lecteur
  /// vidéo intégré dans cette passe (aucune dépendance vidéo dans le
  /// projet, en ajouter une serait hors du périmètre demandé). Additif pur.
  final List<String> videos;

  final String status; // 'active' | 'hidden'
  final int views;
  final DateTime? createdAt;

  /// Master Prompt "Immobilier V6.2" — Mission 4 : horodatage de dernière
  /// modification par l'agent — absent sur toute annonce jamais éditée
  /// (créée avant cette passe, ou jamais retouchée depuis) : `null` reste un
  /// état légitime, jamais remplacé par une valeur inventée.
  final DateTime? updatedAt;

  // ── Master Prompt "Immobilier V6" — Mission 2 : caractéristiques détaillées,
  // toutes additives (null/valeur par défaut neutre pour une annonce déjà
  // existante, jamais un champ requis qui casserait une lecture ancienne).

  /// Surface bâtie en m² (maison/appartement/villa/bureau/magasin...).
  final double? surface;

  /// Surface du terrain en m² (terrain nu, ou terrain d'une villa/ferme).
  final double? surfaceTerrain;

  final int? rooms; // nombre de pièces
  final int? bedrooms; // nombre de chambres
  final int? bathrooms; // nombre de salles de bain
  final int? floor; // étage

  final bool hasGarage;
  final bool hasParking;
  final bool hasTerrace;
  final bool hasBalcony;
  final bool hasKitchen;
  final bool hasAirConditioning;
  final bool hasInternet;
  final bool hasGenerator; // groupe électrogène
  final bool hasPool; // piscine
  final bool hasBorehole; // forage
  final bool hasGuard; // gardien
  final bool hasElevator; // ascenseur
  final bool chargesIncluded; // charges incluses (location)

  /// Tarifs alternatifs (résidences meublées / locations courte durée) — en
  /// plus de [price]/[priceType], jamais à la place (rétrocompatibilité).
  final int? pricePerDay;
  final int? pricePerWeek;
  final int? pricePerMonth;

  final bool isAvailable;
  final DateTime? availabilityDate;

  const RealEstateListing({
    required this.id,
    required this.agentId,
    this.agentName,
    this.agentPhone,
    required this.title,
    required this.description,
    required this.price,
    this.priceType = 'sale',
    required this.propertyType,
    this.furnished = false,
    required this.city,
    this.lat,
    this.lng,
    this.locationPrivacy,
    this.publicLatitude,
    this.publicLongitude,
    this.publicGeohash,
    this.publicAddress,
    this.quartier,
    this.locationLabel,
    this.hasExactLocation = false,
    this.locationUpdatedAt,
    this.images = const [],
    this.videos = const [],
    this.status = 'active',
    this.views = 0,
    this.createdAt,
    this.updatedAt,
    this.surface,
    this.surfaceTerrain,
    this.rooms,
    this.bedrooms,
    this.bathrooms,
    this.floor,
    this.hasGarage = false,
    this.hasParking = false,
    this.hasTerrace = false,
    this.hasBalcony = false,
    this.hasKitchen = false,
    this.hasAirConditioning = false,
    this.hasInternet = false,
    this.hasGenerator = false,
    this.hasPool = false,
    this.hasBorehole = false,
    this.hasGuard = false,
    this.hasElevator = false,
    this.chargesIncluded = false,
    this.pricePerDay,
    this.pricePerWeek,
    this.pricePerMonth,
    this.isAvailable = true,
    this.availabilityDate,
  });

  /// A-t-on une position publique affichable (exacte ou approximative) ?
  /// Jamais vrai pour 'hidden', par construction serveur.
  bool get hasPublicLocation =>
      publicLatitude != null && publicLongitude != null;

  factory RealEstateListing.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return RealEstateListing(
      id: doc.id,
      agentId: d['agentId'] as String? ?? '',
      agentName: d['agentName'] as String?,
      agentPhone: d['agentPhone'] as String?,
      title: d['title'] as String? ?? '',
      description: d['description'] as String? ?? '',
      price: (d['price'] as num? ?? 0).toInt(),
      priceType: d['priceType'] as String? ?? 'sale',
      propertyType: d['propertyType'] as String? ?? '',
      furnished: d['furnished'] == true,
      city: d['city'] as String? ?? '',
      // Hérités — jamais utilisés pour l'affichage public, voir commentaire
      // du champ. Lus uniquement pour ne jamais planter sur une ancienne
      // annonce qui les possède encore.
      lat: (d['lat'] as num?)?.toDouble(),
      lng: (d['lng'] as num?)?.toDouble(),
      locationPrivacy: d['locationPrivacy'] as String?,
      publicLatitude: (d['publicLatitude'] as num?)?.toDouble(),
      publicLongitude: (d['publicLongitude'] as num?)?.toDouble(),
      publicGeohash: d['publicGeohash'] as String?,
      publicAddress: d['publicAddress'] as String?,
      quartier: d['quartier'] as String?,
      locationLabel: d['locationLabel'] as String?,
      hasExactLocation: d['hasExactLocation'] == true,
      locationUpdatedAt: (d['locationUpdatedAt'] as Timestamp?)?.toDate(),
      images:
          (d['images'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      videos:
          (d['videos'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      status: d['status'] as String? ?? 'active',
      views: (d['views'] as num? ?? 0).toInt(),
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
      surface: (d['surface'] as num?)?.toDouble(),
      surfaceTerrain: (d['surfaceTerrain'] as num?)?.toDouble(),
      rooms: (d['rooms'] as num?)?.toInt(),
      bedrooms: (d['bedrooms'] as num?)?.toInt(),
      bathrooms: (d['bathrooms'] as num?)?.toInt(),
      floor: (d['floor'] as num?)?.toInt(),
      hasGarage: d['hasGarage'] == true,
      hasParking: d['hasParking'] == true,
      hasTerrace: d['hasTerrace'] == true,
      hasBalcony: d['hasBalcony'] == true,
      hasKitchen: d['hasKitchen'] == true,
      hasAirConditioning: d['hasAirConditioning'] == true,
      hasInternet: d['hasInternet'] == true,
      hasGenerator: d['hasGenerator'] == true,
      hasPool: d['hasPool'] == true,
      hasBorehole: d['hasBorehole'] == true,
      hasGuard: d['hasGuard'] == true,
      hasElevator: d['hasElevator'] == true,
      chargesIncluded: d['chargesIncluded'] == true,
      pricePerDay: (d['pricePerDay'] as num?)?.toInt(),
      pricePerWeek: (d['pricePerWeek'] as num?)?.toInt(),
      pricePerMonth: (d['pricePerMonth'] as num?)?.toInt(),
      // `isAvailable` absent sur une annonce ancienne == disponible par
      // défaut (comportement inchangé pour tout ce qui existe déjà).
      isAvailable: d['isAvailable'] != false,
      availabilityDate: (d['availabilityDate'] as Timestamp?)?.toDate(),
    );
  }

  /// Ne contient volontairement plus jamais lat/lng ni aucun champ de
  /// localisation : la création d'annonce se fait sans coordonnées (Rules
  /// `noDirectLocationFieldsOnCreate()`), la localisation étant ajoutée
  /// ensuite exclusivement via `RealEstateService.upsertLocation()` ->
  /// Cloud Function `upsertRealEstateLocation`. Voir Mission 13.
  Map<String, dynamic> toMap() => {
        'agentId': agentId,
        if (agentName != null) 'agentName': agentName,
        if (agentPhone != null) 'agentPhone': agentPhone,
        'title': title,
        'description': description,
        'price': price,
        'priceType': priceType,
        'propertyType': propertyType,
        'furnished': furnished,
        'city': city,
        'images': images,
        if (videos.isNotEmpty) 'videos': videos,
        'status': status,
        'views': views,
        'createdAt': FieldValue.serverTimestamp(),
        if (surface != null) 'surface': surface,
        if (surfaceTerrain != null) 'surfaceTerrain': surfaceTerrain,
        if (rooms != null) 'rooms': rooms,
        if (bedrooms != null) 'bedrooms': bedrooms,
        if (bathrooms != null) 'bathrooms': bathrooms,
        if (floor != null) 'floor': floor,
        'hasGarage': hasGarage,
        'hasParking': hasParking,
        'hasTerrace': hasTerrace,
        'hasBalcony': hasBalcony,
        'hasKitchen': hasKitchen,
        'hasAirConditioning': hasAirConditioning,
        'hasInternet': hasInternet,
        'hasGenerator': hasGenerator,
        'hasPool': hasPool,
        'hasBorehole': hasBorehole,
        'hasGuard': hasGuard,
        'hasElevator': hasElevator,
        'chargesIncluded': chargesIncluded,
        if (pricePerDay != null) 'pricePerDay': pricePerDay,
        if (pricePerWeek != null) 'pricePerWeek': pricePerWeek,
        if (pricePerMonth != null) 'pricePerMonth': pricePerMonth,
        'isAvailable': isAvailable,
        if (availabilityDate != null)
          'availabilityDate': Timestamp.fromDate(availabilityDate!),
      };
}
