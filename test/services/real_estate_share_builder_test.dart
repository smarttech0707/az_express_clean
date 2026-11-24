import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/models/real_estate_display_location.dart';
import 'package:az_express/models/real_estate_listing.dart';
import 'package:az_express/models/real_estate_private_location.dart';
import 'package:az_express/services/real_estate_share_builder.dart';

// Mission 9/14 — le texte de partage ne doit jamais fuiter une coordonnée
// ou une adresse au-delà de ce que la précision autorisée permet déjà.
// Fixtures construites via `RealEstateDisplayLocation.resolve(...)` (la
// seule façon légitime d'obtenir une instance) plutôt qu'un constructeur de
// test — cohérent avec `real_estate_display_location_test.dart`.
void main() {
  RealEstateListing listing({
    String? locationPrivacy,
    double? publicLatitude,
    double? publicLongitude,
    String? publicAddress,
    String city = 'Abengourou',
    String? quartier,
  }) =>
      RealEstateListing(
        id: 'l1',
        agentId: 'agent1',
        title: 'Belle villa',
        description: 'desc',
        price: 1000000,
        propertyType: 'villa',
        city: city,
        quartier: quartier,
        locationPrivacy: locationPrivacy,
        publicLatitude: publicLatitude,
        publicLongitude: publicLongitude,
        publicAddress: publicAddress,
      );

  final exact = RealEstateDisplayLocation.resolve(
    listing: listing(
      locationPrivacy: 'exact',
      publicLatitude: 6.72,
      publicLongitude: -3.49,
      publicAddress: '12 rue du Commerce',
      quartier: 'Commerce',
    ),
  );

  final approximate = RealEstateDisplayLocation.resolve(
    listing: listing(
      locationPrivacy: 'approximate',
      publicLatitude: 6.72,
      publicLongitude: -3.49,
      quartier: 'Cafétou',
    ),
  );

  final hiddenNoAccess = RealEstateDisplayLocation.resolve(
    listing: listing(locationPrivacy: 'hidden', quartier: 'Château'),
  );

  final privateAuthorized = RealEstateDisplayLocation.resolve(
    listing: listing(locationPrivacy: 'hidden', quartier: 'Commerce'),
    privateLocation: const RealEstatePrivateLocation(
      listingId: 'l1',
      ownerId: 'agent1',
      agentId: 'agent1',
      exactLatitude: 6.731,
      exactLongitude: -3.491,
      exactGeohash: 'abcde',
      exactAddress: '12 rue du Commerce',
    ),
  );

  group('RealEstateShareBuilder.buildShareText', () {
    test('exact — titre + adresse + lien Maps', () {
      final text = RealEstateShareBuilder.buildShareText(
          title: 'Belle villa', location: exact);
      expect(text, contains('Belle villa'));
      expect(text, contains('12 rue du Commerce'));
      expect(text, contains('google.com/maps'));
      expect(text, contains('6.72'));
    });

    test('accès privé autorisé — coordonnées exactes partagées', () {
      final text = RealEstateShareBuilder.buildShareText(
          title: 'Belle villa', location: privateAuthorized);
      expect(text, contains('6.731'));
      expect(text, contains('-3.491'));
    });

    test(
        'approximate — ville/quartier + mention approximative, jamais d\'adresse exacte',
        () {
      final text = RealEstateShareBuilder.buildShareText(
          title: 'Belle villa', location: approximate);
      expect(text, contains('Cafétou'));
      expect(text, contains('Position approximative'));
      expect(text, isNot(contains('12 rue du Commerce')));
    });

    test('hidden sans accès — aucune coordonnée, aucune adresse exacte', () {
      final text = RealEstateShareBuilder.buildShareText(
          title: 'Belle villa', location: hiddenNoAccess);
      expect(text, contains('Château'));
      expect(text, isNot(contains('12 rue du Commerce')));
      expect(text, isNot(contains('6.7')));
      expect(text, isNot(contains('-3.4')));
    });

    test('lien annonce optionnel — inclus seulement si fourni', () {
      final withUrl = RealEstateShareBuilder.buildShareText(
          title: 'Belle villa',
          location: hiddenNoAccess,
          listingUrl: 'https://example.com/l/1');
      expect(withUrl, contains('https://example.com/l/1'));

      final withoutUrl = RealEstateShareBuilder.buildShareText(
          title: 'Belle villa', location: hiddenNoAccess);
      expect(withoutUrl, isNot(contains('https://')));
    });
  });
}
