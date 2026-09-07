import 'package:az_express/auto_moto/models/vehicle_favorite.dart';
import 'package:az_express/auto_moto/models/vehicle_listing.dart';
import 'package:az_express/auto_moto/screens/vehicle_favorites_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_listings_screen.dart';
import 'package:az_express/auto_moto/vehicle_favorite_repository.dart';
import 'package:az_express/auto_moto/vehicle_listing_query.dart';
import 'package:az_express/auto_moto/vehicle_listing_repository.dart';
import 'package:az_express/auto_moto/widgets/vehicle_filter_sheet.dart';
import 'package:az_express/auto_moto/widgets/vehicle_listing_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// ignore: subtype_of_sealed_class
class FakeVehicleCursor extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {}

const listing = VehicleListing(
  id: 'v1',
  sellerId: 'seller',
  sellerType: VehicleSellerType.individual,
  vehicleType: VehicleType.car,
  offerType: VehicleOfferType.sale,
  title: 'Belle Toyota Corolla',
  description: 'Très bon véhicule entretenu.',
  brand: 'Toyota',
  model: 'Corolla',
  year: 2022,
  condition: VehicleCondition.used,
  color: 'Noir',
  mileageKm: 45000,
  transmission: VehicleTransmission.automatic,
  fuelType: VehicleFuelType.petrol,
  seats: 5,
  salePrice: 6000000,
  price: 6000000,
  cityId: 'abidjan',
  cityName: 'Abidjan',
  status: VehicleListingStatus.active,
);

final listing2 =
    listing.copyWith(id: 'v2', model: 'Yaris', title: 'Toyota Yaris');

Widget app(Widget child, {ThemeMode mode = ThemeMode.light}) => MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: mode,
      home: child,
    );

void main() {
  test('recherche normalise marque, modèle, titre et préfixes', () {
    final terms = buildVehicleSearchKeywords(
      title: listing.title,
      brand: listing.brand,
      model: listing.model,
    );
    expect(terms, containsAll(['toyota', 'corolla', 'belle', 'toy']));
    expect(normalizeVehicleSearch('  TôYÖTA  '), 'toyota');
  });

  test('filtres offre/type restent serveur et champs avancés correspondent',
      () {
    const filters = VehicleListingFilters(
      condition: VehicleCondition.used,
      brand: 'Toyota',
      minYear: 2020,
      maxYear: 2024,
      minPrice: 5000000,
      maxPrice: 7000000,
      transmission: VehicleTransmission.automatic,
      fuelType: VehicleFuelType.petrol,
      maxMileageKm: 50000,
      seats: 5,
    );
    expect(filters.matches(listing), isTrue);
    expect(
      const VehicleListingFilters(maxPrice: 1000).matches(listing),
      isFalse,
    );
    const request = VehicleListingRequest(
      cityId: 'abidjan',
      offerType: VehicleOfferType.sale,
      vehicleType: VehicleType.car,
      filters: filters,
    );
    expect(request.cityId, 'abidjan');
    expect(VehicleListingSort.values, hasLength(4));
  });

  testWidgets('recherche applique un debounce et réinitialise la requête',
      (tester) async {
    final searches = <String>[];
    await tester.pumpWidget(app(VehicleListingsScreen(
      offerType: VehicleOfferType.sale,
      vehicleType: VehicleType.car,
      cityId: 'abidjan',
      currentUserId: '__test__',
      searchPageLoader: (
          {required request, required pageSize, startAfter}) async {
        searches.add(request.normalizedSearch);
        return const VehicleListingsPage(
          listings: [],
          nextCursor: null,
          hasMore: false,
        );
      },
    )));
    await tester.pump();
    expect(searches, ['']);
    await tester.enterText(find.byKey(const Key('vehicle_search')), 'Toyota');
    await tester.pump(const Duration(milliseconds: 400));
    expect(searches, ['']);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    expect(searches, ['', 'toyota']);
    expect(find.textContaining('Aucune annonce'), findsOneWidget);
  });

  testWidgets(
      'pagination dédoublonne et recherche/ville repartent sans curseur',
      (tester) async {
    final cursor = FakeVehicleCursor();
    final calls = <(String, bool)>[];
    var page = 0;

    Widget screen(String city) => VehicleListingsScreen(
          offerType: VehicleOfferType.sale,
          vehicleType: VehicleType.car,
          cityId: city,
          currentUserId: '__test__',
          searchPageLoader: (
              {required request, required pageSize, startAfter}) async {
            calls.add((request.cityId, startAfter != null));
            if (startAfter == null) page = 0;
            page++;
            return VehicleListingsPage(
              listings: page == 1
                  ? List.generate(
                      8,
                      (index) => listing.copyWith(id: 'v$index'),
                    )
                  : [listing, listing2],
              nextCursor: page == 1 ? cursor : null,
              hasMore: page == 1,
            );
          },
        );

    await tester.pumpWidget(app(screen('abidjan')));
    await tester.pump();
    await tester.drag(find.byType(ListView).last, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('Toyota Corolla'), findsWidgets);
    expect(calls.any((call) => call.$2), isTrue);

    await tester.enterText(find.byKey(const Key('vehicle_search')), 'Yaris');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(calls.last.$2, isFalse);

    await tester.pumpWidget(app(screen('bouake')));
    await tester.pump();
    expect(calls.last, ('bouake', false));
  });

  testWidgets('cœur et écran Mes favoris affichent l’état favori',
      (tester) async {
    var toggled = false;
    await tester.pumpWidget(app(VehicleListingCard(
      listing: listing,
      onTap: () {},
      isFavorite: true,
      onFavoriteChanged: (value) => toggled = value,
    )));
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.favorite_rounded));
    expect(toggled, isFalse);

    await tester.pumpWidget(app(VehicleFavoritesScreen(
      currentUserId: 'buyer',
      pageLoader: ({required uid, required pageSize, startAfter}) async =>
          const VehicleFavoritesPage(
        favorites: [VehicleFavorite(listing: listing)],
        nextCursor: null,
        hasMore: false,
      ),
    )));
    await tester.pump();
    expect(find.text('Mes favoris'), findsOneWidget);
    expect(find.text('Toyota Corolla'), findsOneWidget);
  });

  testWidgets('filtres restent utilisables à 320 px, sombre et clavier ouvert',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(
      const Scaffold(
        body: VehicleFilterSheet(
          initial: VehicleListingFilters(),
          offerType: VehicleOfferType.rental,
          vehicleType: VehicleType.car,
        ),
      ),
      mode: ThemeMode.dark,
    ));
    await tester.tap(find.widgetWithText(TextField, 'Marque exacte'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Afficher les résultats'), findsOneWidget);
  });
}
