import 'package:az_express/auto_moto/models/vehicle_listing.dart';
import 'package:az_express/auto_moto/models/vehicle_seller_profile.dart';
import 'package:az_express/auto_moto/screens/vehicle_home_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_listing_detail_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_listings_screen.dart';
import 'package:az_express/auto_moto/vehicle_formatters.dart';
import 'package:az_express/auto_moto/vehicle_listing_repository.dart';
import 'package:az_express/auto_moto/widgets/vehicle_listing_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

VehicleListing listing({
  String id = 'v1',
  VehicleOfferType offerType = VehicleOfferType.sale,
  VehicleSellerType sellerType = VehicleSellerType.individual,
  String brand = 'Toyota',
  String model = 'Corolla',
}) =>
    VehicleListing(
      id: id,
      sellerId: 'seller-1',
      sellerType: sellerType,
      vehicleType: VehicleType.car,
      offerType: offerType,
      title: '$brand $model',
      description: 'Véhicule entretenu et disponible pour une visite.',
      brand: brand,
      model: model,
      year: 2020,
      condition: VehicleCondition.used,
      color: 'Blanc',
      mileageKm: 42000,
      transmission: VehicleTransmission.manual,
      fuelType: VehicleFuelType.petrol,
      seats: 5,
      salePrice: offerType == VehicleOfferType.sale ? 6500000 : null,
      rentalPricePerDay: offerType == VehicleOfferType.rental ? 6500000 : null,
      rentalWithoutDriver: offerType == VehicleOfferType.rental,
      price: 6500000,
      cityId: 'abengourou',
      cityName: 'Abengourou',
      status: VehicleListingStatus.active,
    );

Widget app(Widget home) => MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      home: home,
    );

void main() {
  test('formate le prix sans dépendance supplémentaire', () {
    expect(formatVehiclePrice(6500000), '6 500 000 FCFA');
  });

  testWidgets('accueil expose Acheter, Louer et les trois catégories',
      (tester) async {
    await tester.pumpWidget(app(const VehicleHomeScreen(cityId: 'abengourou')));

    expect(find.text('Acheter'), findsOneWidget);
    expect(find.text('Louer'), findsOneWidget);
    expect(find.text('Voitures'), findsOneWidget);
    expect(find.text('Motos'), findsOneWidget);
    expect(find.text('Tricycles'), findsOneWidget);
    expect(find.text('Publier une annonce'), findsOneWidget);
  });

  testWidgets('Louer puis Voitures transmet les filtres et la ville active',
      (tester) async {
    VehicleOfferType? receivedOffer;
    VehicleType? receivedVehicle;
    String? receivedCity;
    Future<VehicleListingsPage> loader({
      required String cityId,
      required VehicleOfferType offerType,
      required VehicleType vehicleType,
      required int pageSize,
      dynamic startAfter,
    }) async {
      receivedOffer = offerType;
      receivedVehicle = vehicleType;
      receivedCity = cityId;
      return const VehicleListingsPage(
        listings: [],
        nextCursor: null,
        hasMore: false,
      );
    }

    await tester.pumpWidget(app(VehicleHomeScreen(
      cityId: 'abengourou',
      pageLoader: loader,
    )));
    await tester.tap(find.text('Louer'));
    await tester.pump();
    await tester.tap(find.text('Voitures'));
    await tester.pumpAndSettle();

    expect(receivedOffer, VehicleOfferType.rental);
    expect(receivedVehicle, VehicleType.car);
    expect(receivedCity, 'abengourou');
    expect(
        find.text('Aucune annonce disponible pour le moment.'), findsOneWidget);
  });

  testWidgets('la liste affiche un état erreur et permet de réessayer',
      (tester) async {
    var attempts = 0;
    Future<VehicleListingsPage> loader({
      required String cityId,
      required VehicleOfferType offerType,
      required VehicleType vehicleType,
      required int pageSize,
      dynamic startAfter,
    }) async {
      attempts++;
      throw StateError('offline');
    }

    await tester.pumpWidget(app(VehicleListingsScreen(
      offerType: VehicleOfferType.sale,
      vehicleType: VehicleType.car,
      cityId: 'abengourou',
      pageLoader: loader,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Impossible de charger les annonces.'), findsOneWidget);

    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });

  testWidgets('la carte distingue particulier, professionnel et vérifié',
      (tester) async {
    await tester.pumpWidget(app(ListView(children: [
      VehicleListingCard(listing: listing(), onTap: () {}),
      VehicleListingCard(
        listing: listing(
          id: 'v2',
          sellerType: VehicleSellerType.professional,
        ),
        onTap: () {},
      ),
      VehicleListingCard(
        listing: listing(
          id: 'v3',
          sellerType: VehicleSellerType.professional,
        ),
        verificationStatus: VehicleSellerVerificationStatus.verified,
        onTap: () {},
      ),
    ])));

    expect(find.text('Particulier'), findsOneWidget);
    expect(find.text('Professionnel'), findsNWidgets(2));
    expect(find.text('Vérifié'), findsOneWidget);
  });

  testWidgets('une annonce de la liste ouvre son détail en lecture seule',
      (tester) async {
    Future<VehicleListingsPage> loader({
      required String cityId,
      required VehicleOfferType offerType,
      required VehicleType vehicleType,
      required int pageSize,
      dynamic startAfter,
    }) async =>
        VehicleListingsPage(
          listings: [listing()],
          nextCursor: null,
          hasMore: false,
        );

    await tester.pumpWidget(app(VehicleListingsScreen(
      offerType: VehicleOfferType.sale,
      vehicleType: VehicleType.car,
      cityId: 'abengourou',
      pageLoader: loader,
      detailProfileLoader: (_) async => null,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Toyota Corolla'));
    await tester.pumpAndSettle();

    expect(find.byType(VehicleListingDetailScreen), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);
    expect(find.text('Vendeur'), findsOneWidget);
    expect(find.textContaining('AZ Express met en relation'), findsOneWidget);
  });

  testWidgets('la carte supporte un petit écran et un texte long',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(Padding(
      padding: const EdgeInsets.all(8),
      child: VehicleListingCard(
        listing: listing(
          brand: 'Une marque automobile exceptionnellement longue',
          model: 'Un modèle dont le nom est également très long',
        ),
        onTap: () {},
      ),
    )));

    expect(tester.takeException(), isNull);
  });
}
