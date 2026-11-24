import '../models/real_estate_display_location.dart';
import 'map_navigation_service.dart';

/// Construction PURE du texte de partage (Mission 9) — séparée de l'appel
/// réel à `Share.share()` pour rester testable sans dépendre du plugin
/// `share_plus` (qui déclenche une vraie feuille de partage native, non
/// simulable en test unitaire).
///
/// Aucune fuite de coordonnée au-delà de ce que [RealEstateDisplayLocation]
/// autorise déjà explicitement — ce builder ne fait AUCUNE vérification de
/// droits lui-même, il fait entièrement confiance au [source] déjà résolu.
class RealEstateShareBuilder {
  const RealEstateShareBuilder._();

  /// [listingUrl] est optionnel — ce projet n'a aujourd'hui aucun lien web
  /// public par annonce (aucune route `go_router`/deep link dédiée,
  /// confirmé par audit) ; jamais fabriqué artificiellement ici.
  static String buildShareText({
    required String title,
    required RealEstateDisplayLocation location,
    String? listingUrl,
  }) {
    final lines = <String>[title];

    switch (location.source) {
      case RealEstateLocationSource.publicExact:
      case RealEstateLocationSource.privateAuthorized:
        // Position exacte autorisée (publique 'exact' ou privée accordée
        // après visite confirmée) — adresse + lien Maps.
        if (location.address != null && location.address!.isNotEmpty) {
          lines.add(location.address!);
        }
        if (location.hasCoordinates) {
          lines.add(MapNavigationService.buildGoogleMapsViewUri(
                  location.latitude!, location.longitude!)
              .toString());
        }
        break;

      case RealEstateLocationSource.publicApproximate:
        final place = _placeLine(location);
        if (place != null) lines.add(place);
        lines.add('Position approximative');
        if (location.hasCoordinates) {
          lines.add(MapNavigationService.buildGoogleMapsViewUri(
                  location.latitude!, location.longitude!)
              .toString());
        }
        break;

      case RealEstateLocationSource.unavailable:
        // Hidden sans accès (ou aucune localisation) : jamais de
        // coordonnée ni d'adresse exacte — seulement ville/quartier déjà
        // publics légitimement (Mission 9).
        final place = _placeLine(location);
        if (place != null) lines.add(place);
        break;
    }

    if (listingUrl != null && listingUrl.isNotEmpty) {
      lines.add(listingUrl);
    }

    return lines.join('\n');
  }

  static String? _placeLine(RealEstateDisplayLocation location) {
    final parts = [location.quartier, location.city]
        .where((s) => s != null && s.isNotEmpty)
        .toList();
    return parts.isEmpty ? null : parts.join(', ');
  }
}
