import 'real_estate_listing.dart';
import 'real_estate_private_location.dart';

/// D'où vient la position réellement affichée au client — jamais devinée,
/// toujours dérivée de `locationPrivacy` + de l'accès réellement accordé
/// (voir [RealEstateDisplayLocation.resolve]).
enum RealEstateLocationSource {
  publicExact,
  publicApproximate,
  privateAuthorized,
  unavailable,
}

/// Représente UNIQUEMENT la localisation que le client courant est
/// réellement autorisé à utiliser — jamais une donnée brute d'annonce.
/// Construit exclusivement via [RealEstateDisplayLocation.resolve], qui est
/// le SEUL endroit de tout le module client où la logique de confidentialité
/// est décidée. Les widgets consommateurs ne doivent plus jamais lire
/// `listing.publicLatitude`/`listing.lat`/etc. directement — voir Mission 2
/// et Mission 5 ("le widget ne décide jamais des droits, il affiche des
/// données déjà autorisées").
class RealEstateDisplayLocation {
  final double? latitude;
  final double? longitude;

  /// 'exact' | 'approximate' | 'none' — jamais déduit du champ brut
  /// `locationPrivacy` seul, reflète la précision RÉELLEMENT affichée.
  final String precision;

  final String? address;
  final String? city;
  final String? quartier;
  final String? locationLabel;

  final RealEstateLocationSource source;

  /// Ces trois booléens décrivent le NIVEAU DE CONFIDENTIALITÉ CHOISI par
  /// l'agent pour l'annonce (indépendant de l'accès du client courant) —
  /// combinés à [hasPrivateAccess], ils permettent à l'UI de choisir parmi
  /// les 6 branches d'affichage de la Mission 4 (exact public / approximate
  /// sans accès / approximate avec accès / hidden sans accès / hidden avec
  /// accès / absente).
  final bool isExact;
  final bool isApproximate;
  final bool isHidden;

  /// true seulement si `real_estate_location_access` a réellement accordé
  /// l'accès ET que le document privé a pu être chargé — jamais déduit côté
  /// client, toujours le reflet d'une vraie lecture Firestore déjà filtrée
  /// par les Rules (voir Mission 3).
  final bool hasPrivateAccess;

  final bool canShowMap;
  final bool canNavigate;
  final bool canShareCoordinates;

  const RealEstateDisplayLocation._({
    this.latitude,
    this.longitude,
    required this.precision,
    this.address,
    this.city,
    this.quartier,
    this.locationLabel,
    required this.source,
    required this.isExact,
    required this.isApproximate,
    required this.isHidden,
    required this.hasPrivateAccess,
    required this.canShowMap,
    required this.canNavigate,
    required this.canShareCoordinates,
  });

  bool get hasCoordinates => latitude != null && longitude != null;

  /// Résolution UNIQUE de la localisation à afficher (Mission 2) :
  ///
  /// 1. `locationPrivacy == 'exact'` + coordonnées publiques valides →
  ///    position publique exacte.
  /// 2. `locationPrivacy` en (`hidden`, `approximate`) + accès réel accordé
  ///    (document privé chargé) → position privée exacte.
  /// 3. `locationPrivacy == 'approximate'` + coordonnées publiques valides
  ///    (et pas d'accès réel) → position publique approximative SEULE.
  /// 4. Sinon → `unavailable` (ville/quartier restent affichables s'ils sont
  ///    déjà des champs publics légitimes — jamais une coordonnée).
  ///
  /// `lat`/`lng`/`latitude`/`longitude` (anciens champs hérités) ne sont
  /// JAMAIS utilisés ici, même en repli — un repli sur ces champs pour une
  /// annonce `hidden`/`approximate` romprait exactement la garantie de
  /// confidentialité que ce chantier construit.
  factory RealEstateDisplayLocation.resolve({
    required RealEstateListing listing,
    RealEstatePrivateLocation? privateLocation,
  }) {
    final privacy = listing.locationPrivacy;
    final isExact = privacy == 'exact';
    final isApproximate = privacy == 'approximate';
    final isHidden = privacy == 'hidden';
    final hasPrivateAccess = privateLocation != null;

    // 1. Exact public — jamais concurrencé par un accès privé (déjà la
    // position la plus précise possible).
    if (isExact && listing.hasPublicLocation) {
      return RealEstateDisplayLocation._(
        latitude: listing.publicLatitude,
        longitude: listing.publicLongitude,
        precision: 'exact',
        address: listing.publicAddress,
        city: listing.city.isNotEmpty ? listing.city : null,
        quartier: listing.quartier,
        locationLabel: listing.locationLabel,
        source: RealEstateLocationSource.publicExact,
        isExact: true,
        isApproximate: false,
        isHidden: false,
        hasPrivateAccess: hasPrivateAccess,
        canShowMap: true,
        canNavigate: true,
        canShareCoordinates: true,
      );
    }

    // 2. Accès privé réel accordé (hidden OU approximate) — la position
    // privée exacte prime sur la position publique approximative.
    if ((isHidden || isApproximate) && hasPrivateAccess) {
      return RealEstateDisplayLocation._(
        latitude: privateLocation.exactLatitude,
        longitude: privateLocation.exactLongitude,
        precision: 'exact',
        address: privateLocation.exactAddress ?? listing.publicAddress,
        city: (privateLocation.exactCity?.isNotEmpty ?? false)
            ? privateLocation.exactCity
            : (listing.city.isNotEmpty ? listing.city : null),
        quartier: privateLocation.exactQuartier ?? listing.quartier,
        locationLabel: listing.locationLabel,
        source: RealEstateLocationSource.privateAuthorized,
        isExact: false,
        isApproximate: isApproximate,
        isHidden: isHidden,
        hasPrivateAccess: true,
        canShowMap: true,
        canNavigate: true,
        canShareCoordinates: true,
      );
    }

    // 3. Approximate publique, sans accès réel — jamais présentée comme
    // l'entrée exacte du bien (voir Mission 4).
    if (isApproximate && listing.hasPublicLocation) {
      return RealEstateDisplayLocation._(
        latitude: listing.publicLatitude,
        longitude: listing.publicLongitude,
        precision: 'approximate',
        address:
            null, // jamais d'adresse exacte pour une position approximative
        city: listing.city.isNotEmpty ? listing.city : null,
        quartier: listing.quartier,
        locationLabel: listing.locationLabel,
        source: RealEstateLocationSource.publicApproximate,
        isExact: false,
        isApproximate: true,
        isHidden: false,
        hasPrivateAccess: false,
        canShowMap: true,
        canNavigate: true,
        canShareCoordinates: true,
      );
    }

    // 4. Hidden sans accès, ou aucune localisation connue — ville/quartier
    // restent affichables (ce sont des champs publics légitimes), jamais
    // de coordonnée ni de carte.
    return RealEstateDisplayLocation._(
      latitude: null,
      longitude: null,
      precision: 'none',
      address: null,
      city: listing.city.isNotEmpty ? listing.city : null,
      quartier: listing.quartier,
      locationLabel: listing.locationLabel,
      source: RealEstateLocationSource.unavailable,
      isExact: false,
      isApproximate: false,
      isHidden: isHidden,
      hasPrivateAccess: false,
      canShowMap: false,
      canNavigate: false,
      canShareCoordinates: false,
    );
  }
}
