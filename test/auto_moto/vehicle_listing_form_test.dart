import 'package:az_express/auto_moto/models/vehicle_listing.dart';
import 'package:az_express/auto_moto/models/vehicle_seller_profile.dart';
import 'package:az_express/auto_moto/screens/vehicle_home_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_listing_form_screen.dart';
import 'package:az_express/auto_moto/screens/my_vehicle_listings_screen.dart';
import 'package:az_express/auto_moto/vehicle_listing_form_data.dart';
import 'package:az_express/auto_moto/vehicle_listing_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const profile = VehicleSellerProfile(
  ownerId: 'seller-1',
  sellerType: VehicleSellerType.individual,
  displayName: 'Aya Koné',
  phone: '0700000000',
  cityId: 'abengourou',
);

VehicleListing validListing() => VehicleListingFormData(
      offerType: VehicleOfferType.sale,
      vehicleType: VehicleType.car,
      condition: VehicleCondition.used,
      brand: 'Toyota',
      model: 'Corolla',
      year: '2022',
      color: 'Gris',
      mileageKm: '25000',
      transmission: VehicleTransmission.automatic,
      fuelType: VehicleFuelType.petrol,
      seats: '5',
      salePrice: '6500000',
      title: 'Toyota Corolla 2022',
      description: 'Véhicule propre, entretenu et disponible immédiatement.',
    ).toListing(
      sellerId: 'seller-1',
      profile: profile,
      cityId: 'abengourou',
      cityName: 'Abengourou',
    );

Widget app(Widget home, {ThemeMode mode = ThemeMode.light}) => MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: mode,
      home: home,
    );

void main() {
  group('validation du formulaire', () {
    test('vente exige un prix positif', () {
      final data = VehicleListingFormData(offerType: VehicleOfferType.sale);
      expect(data.validateStep(5),
          contains('Le prix de vente doit être supérieur à zéro.'));
    });

    test('location exige prix journalier et une option', () {
      final data = VehicleListingFormData(offerType: VehicleOfferType.rental);
      expect(data.validateStep(5),
          contains('Le prix journalier doit être supérieur à zéro.'));
      expect(data.validateStep(5),
          contains('Choisissez au moins une option de location.'));
    });

    test('occasion exige un kilométrage', () {
      final data = VehicleListingFormData(
        condition: VehicleCondition.used,
        vehicleType: VehicleType.motorcycle,
        engineCapacityCc: '125',
      );
      expect(data.validateStep(4),
          contains('Le kilométrage est obligatoire pour une occasion.'));
    });

    test('année impossible et prix négatif sont refusés', () {
      final data = VehicleListingFormData(
        brand: 'Toyota',
        model: 'Corolla',
        color: 'Noir',
        year: '2200',
        salePrice: '-1',
      );
      expect(data.validateStep(3, now: DateTime.utc(2026)),
          contains('L’année du véhicule est invalide.'));
      expect(data.validateStep(5),
          contains('Le prix de vente doit être supérieur à zéro.'));
    });

    test('sellerId vient de la session et un profil différent est refusé', () {
      expect(validListing().sellerId, 'seller-1');
      final data = VehicleListingFormData.fromListing(validListing());
      expect(
        () => data.toListing(
          sellerId: 'intrus',
          profile: profile,
          cityId: 'abengourou',
          cityName: 'Abengourou',
        ),
        throwsStateError,
      );
    });

    test('édition préremplit et conserve sellerId, createdAt et statut', () {
      final original = validListing().copyWith(
        id: 'listing-1',
        createdAt: DateTime.utc(2026, 9, 1),
        status: VehicleListingStatus.sold,
      );
      final data = VehicleListingFormData.fromListing(original)
        ..title = 'Titre modifié';
      final edited = data.toListing(
        sellerId: 'seller-1',
        profile: profile,
        cityId: 'abengourou',
        cityName: 'Abengourou',
        original: original,
      );
      expect(data.brand, 'Toyota');
      expect(edited.sellerId, original.sellerId);
      expect(edited.createdAt, original.createdAt);
      expect(edited.status, original.status);
    });

    test(
        'voiture, moto et tricycle conservent uniquement leurs champs pertinents',
        () {
      final sale = VehicleListingFormData.fromListing(validListing());
      for (final type
          in VehicleType.values.where((type) => type != VehicleType.unknown)) {
        sale.vehicleType = type;
        sale.engineCapacityCc = '125';
        final result = sale.toListing(
          sellerId: 'seller-1',
          profile: profile,
          cityId: 'abengourou',
          cityName: 'Abengourou',
        );
        expect(result.vehicleType, type);
        expect(
            result.transmission, type == VehicleType.car ? isNotNull : isNull);
        expect(result.engineCapacityCc, type == VehicleType.car ? isNull : 125);
      }
    });
  });

  testWidgets('les étapes conservent les valeurs au retour', (tester) async {
    await tester.pumpWidget(app(VehicleListingFormScreen(
      profile: profile,
      cityId: 'abengourou',
      cityName: 'Abengourou',
      saveListing: (_) async {},
    )));
    await tester.tap(find.text('Suivant'));
    await tester.pump();
    await tester.tap(find.text('Suivant'));
    await tester.pump();
    await tester.tap(find.text('Suivant'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Marque'), 'Toyota');
    await tester.tap(find.text('Retour'));
    await tester.pump();
    await tester.tap(find.text('Suivant'));
    await tester.pump();
    expect(find.text('Toyota'), findsOneWidget);
  });

  testWidgets(
      'profil absent puis création reprend automatiquement la publication',
      (tester) async {
    await tester.pumpWidget(app(VehicleHomeScreen(
      cityId: 'abengourou',
      currentUserId: () => 'seller-1',
      profileLoader: (_) async => null,
      saveProfile: (_, __) async {},
    )));
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    await tester.tap(find.text('Publier une annonce'));
    await tester.pumpAndSettle();
    expect(find.text('Créer mon profil vendeur'), findsOneWidget);
    expect(find.text('Vous vendez en tant que :'), findsOneWidget);
    await tester.tap(find.byKey(const Key('choose_individual')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('seller_display_name')),
      'Aya Koné',
    );
    await tester.enterText(
      find.byKey(const Key('seller_phone')),
      '0700000000',
    );
    await tester.ensureVisible(find.byKey(const Key('save_seller_profile')));
    await tester.tap(find.byKey(const Key('save_seller_profile')));
    await tester.pumpAndSettle();
    expect(find.byType(VehicleListingFormScreen), findsOneWidget);
  });

  testWidgets(
      'une édition préremplie atteint la prévisualisation et enregistre',
      (tester) async {
    VehicleListing? saved;
    final original = validListing().copyWith(id: 'listing-1');
    await tester.pumpWidget(app(VehicleListingFormScreen(
      profile: profile,
      cityId: 'abengourou',
      cityName: 'Abengourou',
      original: original,
      saveListing: (listing) async => saved = listing,
    )));
    for (var index = 0; index < 8; index++) {
      await tester.tap(find.text('Suivant'));
      await tester.pump();
    }
    expect(find.text('Prévisualisation'), findsOneWidget);
    expect(find.textContaining('AZ Express facilite'), findsOneWidget);
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(saved?.id, 'listing-1');
    expect(saved?.sellerId, 'seller-1');
  });

  testWidgets('Mes annonces charge uniquement le sellerId du profil',
      (tester) async {
    String? requestedSeller;
    await tester.pumpWidget(app(MyVehicleListingsScreen(
      profile: profile,
      cityName: 'Abengourou',
      pageLoader: ({required sellerId, required pageSize, startAfter}) async {
        requestedSeller = sellerId;
        return VehicleListingsPage(
          listings: [validListing()],
          nextCursor: null,
          hasMore: false,
        );
      },
    )));
    await tester.pumpAndSettle();
    expect(requestedSeller, 'seller-1');
    expect(find.text('Toyota Corolla 2022'), findsOneWidget);
    expect(find.textContaining('Active'), findsOneWidget);
  });

  testWidgets('le formulaire ne déborde pas sur 320 px en mode sombre',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(
      VehicleListingFormScreen(
        profile: profile,
        cityId: 'abengourou',
        cityName: 'Abengourou',
        saveListing: (_) async {},
      ),
      mode: ThemeMode.dark,
    ));
    expect(tester.takeException(), isNull);
  });
}
