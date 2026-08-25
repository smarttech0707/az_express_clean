import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/models/real_estate_display_location.dart';
import 'package:az_express/models/real_estate_listing.dart';
import 'package:az_express/models/real_estate_private_location.dart';

// Mission 2/14 — "Activation UI carte/itinéraire Immobilier" : verrouille la
// logique de résolution UNIQUE (jamais un fallback sur lat/lng/latitude/
// longitude hérités pour une annonce approximate/hidden).
void main() {
  RealEstateListing listing({
    String? locationPrivacy,
    double? publicLatitude,
    double? publicLongitude,
    double? lat,
    double? lng,
    String city = 'Abengourou',
    String? quartier,
    String propertyType = 'villa',
  }) =>
      RealEstateListing(
        id: 'l1',
        agentId: 'agent1',
        title: 'Belle villa',
        description: 'desc',
        price: 1000000,
        propertyType: propertyType,
        city: city,
        quartier: quartier,
        locationPrivacy: locationPrivacy,
        publicLatitude: publicLatitude,
        publicLongitude: publicLongitude,
        lat: lat,
        lng: lng,
      );

  RealEstatePrivateLocation privateLoc({
    double exactLatitude = 6.73,
    double exactLongitude = -3.49,
  }) =>
      RealEstatePrivateLocation(
        listingId: 'l1',
        ownerId: 'agent1',
        agentId: 'agent1',
        exactLatitude: exactLatitude,
        exactLongitude: exactLongitude,
        exactGeohash: 'abcde',
      );

  group('RealEstateDisplayLocation.resolve — exact public', () {
    test('locationPrivacy exact + coordonnées publiques valides → publicExact',
        () {
      final r = RealEstateDisplayLocation.resolve(
        listing: listing(
            locationPrivacy: 'exact',
            publicLatitude: 6.72,
            publicLongitude: -3.49),
      );
      expect(r.source, RealEstateLocationSource.publicExact);
      expect(r.isExact, true);
      expect(r.isApproximate, false);
      expect(r.isHidden, false);
      expect(r.hasPrivateAccess, false);
      expect(r.canShowMap, true);
      expect(r.canNavigate, true);
      expect(r.canShareCoordinates, true);
      expect(r.latitude, 6.72);
      expect(r.longitude, -3.49);
    });
  });

  group('RealEstateDisplayLocation.resolve — approximate public', () {
    test('approximate + coordonnées publiques, sans accès → publicApproximate',
        () {
      final r = RealEstateDisplayLocation.resolve(
        listing: listing(
            locationPrivacy: 'approximate',
            publicLatitude: 6.72,
            publicLongitude: -3.49),
      );
      expect(r.source, RealEstateLocationSource.publicApproximate);
      expect(r.isExact, false);
      expect(r.isApproximate, true);
      expect(r.hasPrivateAccess, false);
      expect(r.address, null,
          reason: 'jamais une adresse exacte pour une position approximative');
      expect(r.canShowMap, true);
      expect(r.canNavigate, true);
      expect(r.canShareCoordinates, true);
    });
  });

  group('RealEstateDisplayLocation.resolve — hidden sans accès', () {
    test('hidden, aucun accès → unavailable, jamais de coordonnée', () {
      final r = RealEstateDisplayLocation.resolve(
        listing: listing(
            locationPrivacy: 'hidden', city: 'Abengourou', quartier: 'Cafétou'),
      );
      expect(r.source, RealEstateLocationSource.unavailable);
      expect(r.isHidden, true);
      expect(r.hasCoordinates, false);
      expect(r.canShowMap, false);
      expect(r.canNavigate, false);
      expect(r.canShareCoordinates, false);
      // Ville/quartier restent des champs publics légitimes.
      expect(r.city, 'Abengourou');
      expect(r.quartier, 'Cafétou');
    });
  });

  group('RealEstateDisplayLocation.resolve — hidden avec accès', () {
    test(
        'hidden + accès privé accordé → privateAuthorized, coordonnées exactes',
        () {
      final r = RealEstateDisplayLocation.resolve(
        listing: listing(locationPrivacy: 'hidden'),
        privateLocation:
            privateLoc(exactLatitude: 6.731, exactLongitude: -3.491),
      );
      expect(r.source, RealEstateLocationSource.privateAuthorized);
      expect(r.hasPrivateAccess, true);
      expect(r.isHidden, true);
      expect(r.latitude, 6.731);
      expect(r.longitude, -3.491);
      expect(r.canShowMap, true);
      expect(r.canNavigate, true);
      expect(r.canShareCoordinates, true);
    });
  });

  group('RealEstateDisplayLocation.resolve — approximate avec accès', () {
    test(
        'approximate + accès privé accordé → privateAuthorized (prime sur la position publique)',
        () {
      final r = RealEstateDisplayLocation.resolve(
        listing: listing(
            locationPrivacy: 'approximate',
            publicLatitude: 6.72,
            publicLongitude: -3.49),
        privateLocation:
            privateLoc(exactLatitude: 6.7301, exactLongitude: -3.4902),
      );
      expect(r.source, RealEstateLocationSource.privateAuthorized);
      expect(r.hasPrivateAccess, true);
      expect(r.isApproximate, true);
      expect(r.latitude, 6.7301,
          reason:
              'la position privée exacte prime sur la publique approximative');
    });
  });

  group('RealEstateDisplayLocation.resolve — accès inactif/expiré', () {
    test(
        'privateLocation absente (accès inactif ou expiré déjà filtré en amont) → repli sur approximate publique',
        () {
      final r = RealEstateDisplayLocation.resolve(
        listing: listing(
            locationPrivacy: 'approximate',
            publicLatitude: 6.72,
            publicLongitude: -3.49),
        privateLocation: null,
      );
      expect(r.source, RealEstateLocationSource.publicApproximate);
      expect(r.hasPrivateAccess, false);
    });

    test('hidden + accès inactif/expiré (privateLocation null) → unavailable',
        () {
      final r = RealEstateDisplayLocation.resolve(
        listing: listing(locationPrivacy: 'hidden'),
        privateLocation: null,
      );
      expect(r.source, RealEstateLocationSource.unavailable);
    });
  });

  group('RealEstateDisplayLocation.resolve — localisation absente / invalide',
      () {
    test('locationPrivacy null, aucune coordonnée → unavailable', () {
      final r = RealEstateDisplayLocation.resolve(listing: listing());
      expect(r.source, RealEstateLocationSource.unavailable);
      expect(r.canShowMap, false);
    });

    test(
        'exact mais coordonnées publiques absentes → unavailable (jamais de faux exact)',
        () {
      final r = RealEstateDisplayLocation.resolve(
        listing: listing(locationPrivacy: 'exact'),
      );
      expect(r.source, RealEstateLocationSource.unavailable);
    });

    test(
        'anciens champs lat/lng hérités IGNORÉS pour une annonce hidden — jamais de repli',
        () {
      final r = RealEstateDisplayLocation.resolve(
        listing: listing(locationPrivacy: 'hidden', lat: 6.72, lng: -3.49),
      );
      expect(r.source, RealEstateLocationSource.unavailable);
      expect(r.hasCoordinates, false,
          reason:
              'lat/lng hérités ne doivent JAMAIS servir de repli public pour hidden/approximate');
    });

    test(
        'anciens champs lat/lng hérités IGNORÉS pour une annonce approximate — jamais de repli',
        () {
      final r = RealEstateDisplayLocation.resolve(
        listing: listing(locationPrivacy: 'approximate', lat: 6.72, lng: -3.49),
      );
      expect(r.source, RealEstateLocationSource.unavailable);
      expect(r.hasCoordinates, false);
    });
  });
}
