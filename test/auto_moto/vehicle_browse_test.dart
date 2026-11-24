import 'package:az_express/auto_moto/models/vehicle_listing.dart';
import 'package:az_express/auto_moto/screens/vehicle_home_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_listings_screen.dart';
import 'package:az_express/auto_moto/vehicle_listing_repository.dart';
import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/providers/active_city_provider.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget app(Widget home) => MaterialApp(home: home);

DeliveryZone city(String id, String name) => DeliveryZone(
      id: 'zone-$id',
      cityId: id,
      name: name,
      type: 'ville',
      lat: 6.7,
      lng: -3.4,
      radiusKm: 10,
      coordinateSource: ZoneCoordinateSource.own,
      isActive: true,
      isServiceable: true,
    );

void main() {
  testWidgets('national browsing works without an ActiveCity', (tester) async {
    String? receivedCity;
    await tester.pumpWidget(app(VehicleHomeScreen(
      currentUserId: () => null,
      marketCitiesLoader: () async => const [],
      pageLoader: ({
        required cityId,
        required offerType,
        required vehicleType,
        required pageSize,
        startAfter,
      }) async {
        receivedCity = cityId;
        return const VehicleListingsPage(
          listings: [],
          nextCursor: null,
          hasMore: false,
        );
      },
    )));

    expect(find.text('Auto & Moto'), findsOneWidget);
    expect(find.text('Toute la Côte d’Ivoire'), findsOneWidget);
    await tester.tap(find.text('Voitures'));
    await tester.pumpAndSettle();
    expect(receivedCity, isNull);
    expect(find.byKey(const Key('vehicle_scope_label')), findsOneWidget);
  });

  testWidgets('market city filter does not change ActiveCity', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = ActiveCityProvider(
      service: ActiveCityService(
        cityLoader: () async => [
          city('abengourou', 'Abengourou'),
          city('abidjan', 'Abidjan'),
        ],
      ),
    );
    await provider.selectManualCity('abengourou');
    String? receivedCity;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: provider,
      child: MaterialApp(home: VehicleHomeScreen(
        currentUserId: () => null,
        marketCitiesLoader: () async => [city('abidjan', 'Abidjan')],
        pageLoader: ({
          required cityId,
          required offerType,
          required vehicleType,
          required pageSize,
          startAfter,
        }) async {
          receivedCity = cityId;
          return const VehicleListingsPage(
            listings: [],
            nextCursor: null,
            hasMore: false,
          );
        },
      )),
    ));

    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Changer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Abidjan').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Voitures'));
    await tester.pump();
    await tester.pump();

    expect(receivedCity, 'abidjan');
    expect(provider.activeCityId, 'abengourou');
  });

  testWidgets('listing screen resets pagination when city filter changes',
      (tester) async {
    final requestedCities = <String?>[];
    Future<VehicleListingsPage> loader({
      required String? cityId,
      required VehicleOfferType offerType,
      required VehicleType vehicleType,
      required int pageSize,
      dynamic startAfter,
    }) async {
      requestedCities.add(cityId);
      return const VehicleListingsPage(
        listings: [],
        nextCursor: null,
        hasMore: false,
      );
    }

    await tester.pumpWidget(app(VehicleListingsScreen(
      key: const ValueKey('vehicle-listings'),
      offerType: VehicleOfferType.sale,
      vehicleType: VehicleType.car,
      cityId: null,
      pageLoader: loader,
    )));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(VehicleListingsScreen(
      key: const ValueKey('vehicle-listings'),
      offerType: VehicleOfferType.sale,
      vehicleType: VehicleType.car,
      cityId: 'abengourou',
      pageLoader: loader,
    )));
    await tester.pumpAndSettle();
    expect(requestedCities, [null, 'abengourou']);
  });

  testWidgets('listing error offers a retry', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(app(VehicleListingsScreen(
      offerType: VehicleOfferType.sale,
      vehicleType: VehicleType.car,
      cityId: null,
      pageLoader: ({
        required cityId,
        required offerType,
        required vehicleType,
        required pageSize,
        startAfter,
      }) async {
        attempts++;
        throw StateError('offline');
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('Impossible de charger les annonces.'), findsOneWidget);
    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });

  testWidgets('accueil reste utilisable à 320 px en thème sombre',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: ThemeMode.dark,
      home: VehicleHomeScreen(
        currentUserId: () => null,
        marketCitiesLoader: () async => const [],
      ),
    ));
    await tester.pump();

    expect(find.byKey(const Key('market_city_scope')), findsOneWidget);
    await tester.tap(find.text('Louer'));
    await tester.pump();
    expect(
      tester.widget<SegmentedButton<VehicleOfferType>>(
        find.byType(SegmentedButton<VehicleOfferType>),
      ).selected,
      {VehicleOfferType.rental},
    );
    expect(find.text('Acheter'), findsOneWidget);
    expect(find.text('Louer'), findsOneWidget);

    final homeList = find.byType(ListView);
    expect(homeList, findsOneWidget);
    final scrollable = find.descendant(
      of: homeList,
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    for (final shortcut in const [
      Key('vehicle_personal_listings'),
      Key('vehicle_personal_profile'),
      Key('vehicle_personal_messages'),
      Key('vehicle_personal_favorites'),
    ]) {
      final finder = find.byKey(shortcut);
      await tester.scrollUntilVisible(finder, 240, scrollable: scrollable);
      expect(finder, findsOneWidget);
    }

    final publish = find.byKey(const Key('vehicle_publish_cta'));
    await tester.scrollUntilVisible(
      publish,
      240,
      scrollable: scrollable,
    );
    expect(publish, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
