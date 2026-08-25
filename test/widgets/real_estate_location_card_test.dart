import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/models/real_estate_display_location.dart';
import 'package:az_express/models/real_estate_listing.dart';
import 'package:az_express/models/real_estate_private_location.dart';
import 'package:az_express/services/map_navigation_service.dart';
import 'package:az_express/widgets/immobilier/real_estate_location_card.dart';

// Mission 15 — tests widgets de la fiche Immobilier. Le vrai `GoogleMap`
// natif n'est pas instanciable en test unitaire (nécessite une vue de
// plateforme) : chaque scénario où `canShowMap==true` injecte un
// `mapBuilder` factice (Mission 15 : "extraire le contenu logique, injecter
// un mapBuilder"), jamais le vrai widget carte.
void main() {
  RealEstateListing listingFixture({
    required String? locationPrivacy,
    double? publicLatitude,
    double? publicLongitude,
    String propertyType = 'villa',
    String? quartier,
  }) =>
      RealEstateListing(
        id: 'l1',
        agentId: 'agent1',
        title: 'Belle villa',
        description: 'desc',
        price: 1000000,
        propertyType: propertyType,
        city: 'Abengourou',
        quartier: quartier,
        locationPrivacy: locationPrivacy,
        publicLatitude: publicLatitude,
        publicLongitude: publicLongitude,
      );

  Widget fakeMapBuilder(double lat, double lng, bool isApproximate) =>
      Container(key: const Key('fake_map'), height: 40);

  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  testWidgets('carte exacte — bouton Itinéraire visible, aucune fuite',
      (tester) async {
    final location = RealEstateDisplayLocation.resolve(
      listing: listingFixture(
          locationPrivacy: 'exact',
          publicLatitude: 6.72,
          publicLongitude: -3.49),
    );
    await tester.pumpWidget(wrap(RealEstateLocationCard(
      listingTitle: 'Belle villa',
      propertyType: 'villa',
      location: location,
      mapBuilder: fakeMapBuilder,
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('fake_map')), findsOneWidget);
    expect(find.text('Itinéraire'), findsOneWidget);
    expect(find.text('Ouvrir dans Maps'), findsOneWidget);
    expect(find.text('Partager'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'carte approximative — badge "Position approximative", jamais de marqueur précis présenté comme exact',
      (tester) async {
    final location = RealEstateDisplayLocation.resolve(
      listing: listingFixture(
          locationPrivacy: 'approximate',
          publicLatitude: 6.72,
          publicLongitude: -3.49),
    );
    await tester.pumpWidget(wrap(RealEstateLocationCard(
      listingTitle: 'Belle villa',
      propertyType: 'villa',
      location: location,
      mapBuilder: fakeMapBuilder,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Position approximative'), findsOneWidget);
    expect(find.textContaining('zone générale du bien'), findsOneWidget);
    expect(find.text('Itinéraire'), findsOneWidget);
  });

  testWidgets(
      'hidden sans accès — aucune carte, message explicatif, bouton visite si fourni',
      (tester) async {
    final location = RealEstateDisplayLocation.resolve(
      listing: listingFixture(locationPrivacy: 'hidden', quartier: 'Château'),
    );
    var visitTapped = false;
    await tester.pumpWidget(wrap(RealEstateLocationCard(
      listingTitle: 'Belle villa',
      propertyType: 'villa',
      location: location,
      mapBuilder: fakeMapBuilder,
      onRequestVisit: () => visitTapped = true,
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('fake_map')), findsNothing,
        reason: 'jamais de carte vide pour hidden sans accès');
    expect(find.textContaining('disponible après confirmation de visite'),
        findsOneWidget);
    expect(find.text('Itinéraire'), findsNothing,
        reason: 'aucun itinéraire sans localisation autorisée');
    expect(find.text('Demander une visite'), findsOneWidget);

    await tester.tap(find.text('Demander une visite'));
    await tester.pumpAndSettle();
    expect(visitTapped, true);
  });

  testWidgets(
      'hidden sans accès — demande déjà en cours affiche le statut, pas de doublon de bouton',
      (tester) async {
    final location = RealEstateDisplayLocation.resolve(
      listing: listingFixture(locationPrivacy: 'hidden'),
    );
    await tester.pumpWidget(wrap(RealEstateLocationCard(
      listingTitle: 'Belle villa',
      propertyType: 'villa',
      location: location,
      onRequestVisit: () {},
      hasPendingVisitRequest: true,
      visitRequestStatusLabel: 'en attente de réponse de l\'agent',
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('en attente de réponse'), findsOneWidget);
    expect(find.text('Demander une visite'), findsNothing);
  });

  testWidgets(
      'hidden avec accès — charge la carte exacte, bannière d\'accès accordé',
      (tester) async {
    final location = RealEstateDisplayLocation.resolve(
      listing: listingFixture(locationPrivacy: 'hidden'),
      privateLocation: const RealEstatePrivateLocation(
        listingId: 'l1',
        ownerId: 'agent1',
        agentId: 'agent1',
        exactLatitude: 6.731,
        exactLongitude: -3.491,
        exactGeohash: 'abcde',
      ),
    );
    await tester.pumpWidget(wrap(RealEstateLocationCard(
      listingTitle: 'Belle villa',
      propertyType: 'villa',
      location: location,
      mapBuilder: fakeMapBuilder,
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('fake_map')), findsOneWidget);
    expect(find.textContaining('Accès exact accordé'), findsOneWidget);
    expect(find.text('Itinéraire'), findsOneWidget);
  });

  testWidgets(
      'localisation absente — message dédié, aucune carte, aucun bouton itinéraire',
      (tester) async {
    final location = RealEstateDisplayLocation.resolve(
      listing: listingFixture(locationPrivacy: null),
    );
    await tester.pumpWidget(wrap(RealEstateLocationCard(
      listingTitle: 'Belle villa',
      propertyType: 'villa',
      location: location,
      mapBuilder: fakeMapBuilder,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Localisation non renseignée'), findsOneWidget);
    expect(find.byKey(const Key('fake_map')), findsNothing);
    expect(find.text('Itinéraire'), findsNothing);
  });

  group('Position client / distance (Mission 6/7)', () {
    final exactLocation = RealEstateDisplayLocation.resolve(
      listing: listingFixture(
          locationPrivacy: 'exact',
          publicLatitude: 6.7273,
          publicLongitude: -3.4961),
    );

    testWidgets('loader pendant la localisation', (tester) async {
      await tester.pumpWidget(wrap(RealEstateLocationCard(
        listingTitle: 'Belle villa',
        propertyType: 'villa',
        location: exactLocation,
        mapBuilder: fakeMapBuilder,
        isLocatingClient: true,
      )));
      await tester.pump();
      expect(find.textContaining('Localisation en cours'), findsOneWidget);
    });

    testWidgets('distance affichée quand la position client est connue',
        (tester) async {
      await tester.pumpWidget(wrap(RealEstateLocationCard(
        listingTitle: 'Belle villa',
        propertyType: 'villa',
        location: exactLocation,
        mapBuilder: fakeMapBuilder,
        clientLatitude: 6.74,
        clientLongitude: -3.49,
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('de votre position'), findsOneWidget);
    });

    testWidgets('GPS désactivé — message + bouton Activer la localisation',
        (tester) async {
      await tester.pumpWidget(wrap(RealEstateLocationCard(
        listingTitle: 'Belle villa',
        propertyType: 'villa',
        location: exactLocation,
        mapBuilder: fakeMapBuilder,
        clientGpsState: ClientGpsState.serviceOff,
        onRequestClientPosition: () {},
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('GPS est désactivé'), findsOneWidget);
      expect(find.text('Activer la localisation'), findsOneWidget);
    });

    testWidgets(
        'GPS désactivé — tap invoque onOpenLocationSettings, JAMAIS onRequestClientPosition '
        '(bug réel trouvé sur appareil réel : les deux boutons étaient câblés sur le mauvais callback)',
        (tester) async {
      var openLocationSettingsCalled = false;
      var requestPositionCalled = false;
      await tester.pumpWidget(wrap(RealEstateLocationCard(
        listingTitle: 'Belle villa',
        propertyType: 'villa',
        location: exactLocation,
        mapBuilder: fakeMapBuilder,
        clientGpsState: ClientGpsState.serviceOff,
        onRequestClientPosition: () => requestPositionCalled = true,
        onOpenLocationSettings: () => openLocationSettingsCalled = true,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activer la localisation'));
      await tester.pumpAndSettle();
      expect(openLocationSettingsCalled, true);
      expect(requestPositionCalled, false);
    });

    testWidgets('permission refusée — message + bouton Ouvrir les paramètres',
        (tester) async {
      await tester.pumpWidget(wrap(RealEstateLocationCard(
        listingTitle: 'Belle villa',
        propertyType: 'villa',
        location: exactLocation,
        mapBuilder: fakeMapBuilder,
        clientGpsState: ClientGpsState.deniedForever,
        onRequestClientPosition: () {},
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('refusée'), findsOneWidget);
      expect(find.text('Ouvrir les paramètres'), findsOneWidget);
    });

    testWidgets(
        'permission refusée — tap invoque onOpenAppSettings, JAMAIS onRequestClientPosition',
        (tester) async {
      var openAppSettingsCalled = false;
      var requestPositionCalled = false;
      await tester.pumpWidget(wrap(RealEstateLocationCard(
        listingTitle: 'Belle villa',
        propertyType: 'villa',
        location: exactLocation,
        mapBuilder: fakeMapBuilder,
        clientGpsState: ClientGpsState.deniedForever,
        onRequestClientPosition: () => requestPositionCalled = true,
        onOpenAppSettings: () => openAppSettingsCalled = true,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ouvrir les paramètres'));
      await tester.pumpAndSettle();
      expect(openAppSettingsCalled, true);
      expect(requestPositionCalled, false);
    });

    testWidgets('erreur/timeout — message + bouton Réessayer', (tester) async {
      await tester.pumpWidget(wrap(RealEstateLocationCard(
        listingTitle: 'Belle villa',
        propertyType: 'villa',
        location: exactLocation,
        mapBuilder: fakeMapBuilder,
        clientGpsState: ClientGpsState.timeout,
        onRequestClientPosition: () {},
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('indisponible'), findsOneWidget);
      expect(find.text('Réessayer'), findsOneWidget);
    });
  });

  group('Partage (Mission 9/15)', () {
    testWidgets(
        'tap Partager invoque le callback injecté avec un texte conforme',
        (tester) async {
      final location = RealEstateDisplayLocation.resolve(
        listing: listingFixture(locationPrivacy: 'hidden', quartier: 'Château'),
      );
      String? sharedText;
      await tester.pumpWidget(wrap(RealEstateLocationCard(
        listingTitle: 'Belle villa',
        propertyType: 'villa',
        location: location,
        onRequestVisit: () {},
        share: (text) async => sharedText = text,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Partager'));
      await tester.pumpAndSettle();

      expect(sharedText, isNotNull);
      expect(sharedText, contains('Belle villa'));
      expect(sharedText, contains('Château'));
      expect(sharedText, isNot(contains('6.7')),
          reason: 'aucune coordonnée pour hidden sans accès');
    });
  });

  testWidgets(
      'disclaimer terrain affiché quel que soit le niveau de confidentialité',
      (tester) async {
    final location = RealEstateDisplayLocation.resolve(
      listing:
          listingFixture(locationPrivacy: 'hidden', propertyType: 'Terrain'),
    );
    await tester.pumpWidget(wrap(RealEstateLocationCard(
      listingTitle: 'Beau terrain',
      propertyType: 'Terrain',
      location: location,
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('documents fonciers ou cadastraux'),
        findsOneWidget);
  });

  testWidgets(
      'disclaimer terrain affiché aussi pour le type canonique V6 "land" '
      '(bug réel trouvé sur device : le test par substring ne reconnaissait '
      'que l\'ancien libellé français, jamais le nouveau type canonique)',
      (tester) async {
    final location = RealEstateDisplayLocation.resolve(
      listing: listingFixture(locationPrivacy: 'hidden', propertyType: 'land'),
    );
    await tester.pumpWidget(wrap(RealEstateLocationCard(
      listingTitle: 'Beau terrain',
      propertyType: 'land',
      location: location,
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('documents fonciers ou cadastraux'),
        findsOneWidget);
  });

  testWidgets('écran Galaxy A11 (petit écran) — aucun overflow',
      (tester) async {
    tester.view.physicalSize = const Size(720, 1560);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final location = RealEstateDisplayLocation.resolve(
      listing: listingFixture(
          locationPrivacy: 'exact',
          publicLatitude: 6.72,
          publicLongitude: -3.49),
    );
    await tester.pumpWidget(wrap(RealEstateLocationCard(
      listingTitle:
          'Belle villa avec un titre assez long pour tester le débordement',
      propertyType: 'villa',
      location: location,
      mapBuilder: fakeMapBuilder,
      clientLatitude: 6.74,
      clientLongitude: -3.49,
    )));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
