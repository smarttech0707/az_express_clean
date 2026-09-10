import 'package:az_express/auto_moto/models/vehicle_listing.dart';
import 'package:az_express/auto_moto/models/vehicle_seller_profile.dart';
import 'package:az_express/auto_moto/screens/vehicle_public_seller_profile_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_seller_profile_screen.dart';
import 'package:az_express/models/delivery_zone.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const city = DeliveryZone(
  id: 'abengourou',
  cityId: 'abengourou',
  name: 'Abengourou',
);

Widget app(Widget home, {ThemeMode mode = ThemeMode.light}) => MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: mode,
      home: home,
    );

VehicleSellerProfile professional({
  VehicleSellerVerificationStatus status =
      VehicleSellerVerificationStatus.unverified,
  VehicleLocationVisibility visibility = VehicleLocationVisibility.hidden,
}) =>
    VehicleSellerProfile(
      ownerId: 'seller-1',
      sellerType: VehicleSellerType.professional,
      displayName: 'Aya Koné',
      phone: '+2250700000000',
      cityId: 'abengourou',
      zoneId: 'centre-ville',
      shopName: 'AZ Motors',
      businessType: VehicleBusinessType.dealership,
      professionalPhone: '+2250100000000',
      address: 'Près du marché central',
      locationVisibility: visibility,
      verificationStatus: status,
    );

void main() {
  testWidgets('le premier écran explique Particulier et Professionnel',
      (tester) async {
    await tester.pumpWidget(app(VehicleSellerProfileScreen(
      ownerId: 'seller-1',
      initialCityId: 'abengourou',
      cities: const [city],
      saveProfile: (_, __) async {},
    )));
    expect(find.text('Vous vendez en tant que :'), findsOneWidget);
    expect(find.text('Particulier'), findsOneWidget);
    expect(find.text('Professionnel'), findsOneWidget);
  });

  testWidgets('création particulier normalise et sauvegarde les champs',
      (tester) async {
    VehicleSellerProfile? saved;
    await tester.pumpWidget(app(VehicleSellerProfileScreen(
      ownerId: 'seller-1',
      initialCityId: 'abengourou',
      cities: const [city],
      saveProfile: (profile, creating) async {
        expect(creating, isTrue);
        saved = profile;
      },
    )));
    await tester.tap(find.byKey(const Key('choose_individual')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const Key('seller_display_name')), ' Aya Koné ');
    await tester.enterText(
        find.byKey(const Key('seller_phone')), '07 00 00 00 00');
    await tester.enterText(
        find.byKey(const Key('seller_zone')), 'Centre Ville');
    await tester.tap(find.byKey(const Key('save_seller_profile')));
    await tester.pumpAndSettle();
    expect(saved?.sellerType, VehicleSellerType.individual);
    expect(saved?.phone, '+2250700000000');
    expect(saved?.zoneId, 'centre-ville');
  });

  testWidgets('validation affiche nom et téléphone invalides', (tester) async {
    await tester.pumpWidget(app(VehicleSellerProfileScreen(
      ownerId: 'seller-1',
      initialCityId: 'abengourou',
      cities: const [city],
      saveProfile: (_, __) async {},
    )));
    await tester.tap(find.byKey(const Key('choose_individual')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save_seller_profile')));
    await tester.pump();
    expect(find.text('Nom requis'), findsOneWidget);
    expect(find.text('Téléphone invalide'), findsOneWidget);
  });

  testWidgets('professionnel exige magasin et activité', (tester) async {
    await tester.pumpWidget(app(VehicleSellerProfileScreen(
      ownerId: 'seller-1',
      initialCityId: 'abengourou',
      cities: const [city],
      saveProfile: (_, __) async {},
    )));
    await tester.tap(find.byKey(const Key('choose_professional')));
    await tester.pump();
    final save = find.byKey(const Key('save_seller_profile'));
    await tester.scrollUntilVisible(
      save,
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(save, findsOneWidget);
    await tester.ensureVisible(save);
    await tester.pump();
    await tester.tap(save);
    await tester.pump();
    final shop = find.byKey(const Key('seller_shop_name'));
    await tester.scrollUntilVisible(
      shop,
      -400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(shop, findsOneWidget);
    expect(find.text('Magasin requis'), findsOneWidget);
    expect(find.text('Activité requise'), findsOneWidget);
  });

  testWidgets('édition conserve le type vendeur et sauvegarde', (tester) async {
    VehicleSellerProfile? saved;
    await tester.pumpWidget(app(VehicleSellerProfileScreen(
      ownerId: 'seller-1',
      initialProfile: professional(),
      cities: const [city],
      saveProfile: (profile, creating) async {
        expect(creating, isFalse);
        saved = profile;
      },
    )));
    expect(find.text('Changer'), findsNothing);
    await tester.enterText(
        find.byKey(const Key('seller_shop_name')), 'Nouveau Garage');
    await tester.scrollUntilVisible(
      find.byKey(const Key('save_seller_profile')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('save_seller_profile')));
    await tester.pumpAndSettle();
    expect(saved?.sellerType, VehicleSellerType.professional);
    expect(saved?.shopName, 'Nouveau Garage');
  });

  testWidgets('badge Vérifié dépend uniquement du statut', (tester) async {
    await tester.pumpWidget(app(VehiclePublicSellerProfileScreen(
      profile: professional(),
      cityName: 'Abengourou',
    )));
    expect(find.text('Professionnel'), findsOneWidget);
    expect(find.text('Vérifié par AZ Express'), findsNothing);

    await tester.pumpWidget(app(VehiclePublicSellerProfileScreen(
      profile: professional(status: VehicleSellerVerificationStatus.verified),
      cityName: 'Abengourou',
    )));
    expect(find.text('Vérifié par AZ Express'), findsOneWidget);
  });

  test('visibilité publique masque ou expose les détails prévus', () {
    expect(
      publicVehicleSellerLocation(professional(), 'Abengourou'),
      'Abengourou',
    );
    expect(
      publicVehicleSellerLocation(
        professional(visibility: VehicleLocationVisibility.approximate),
        'Abengourou',
      ),
      'Abengourou • centre-ville',
    );
    expect(
      publicVehicleSellerLocation(
        professional(visibility: VehicleLocationVisibility.exact),
        'Abengourou',
      ),
      'Abengourou • centre-ville • Près du marché central',
    );
  });

  testWidgets('formulaire professionnel ne déborde pas sur petit écran sombre',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(
      VehicleSellerProfileScreen(
        ownerId: 'seller-1',
        initialProfile: professional(),
        cities: const [city],
        saveProfile: (_, __) async {},
      ),
      mode: ThemeMode.dark,
    ));
    expect(tester.takeException(), isNull);
  });
}
