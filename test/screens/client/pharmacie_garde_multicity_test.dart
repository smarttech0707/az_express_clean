import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/models/pharmacy_guard.dart';
import 'package:az_express/providers/active_city_provider.dart';
import 'package:az_express/screens/client/pharmacie_garde.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

DeliveryZone city(String id, String name) => DeliveryZone(
      id: 'city-$id',
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

PharmacyGuard guard({
  required String id,
  required String name,
  required String cityName,
  bool partner = false,
}) {
  final now = DateTime.now().toUtc();
  return PharmacyGuard(
    id: id,
    name: name,
    city: cityName,
    guardStartAt: now.subtract(const Duration(hours: 1)),
    guardEndAt: now.add(const Duration(days: 2)),
    sourceType: partner ? 'partner' : 'manual',
    isVerified: true,
    isActive: true,
    linkedPartner: partner,
    partnerPharmacyId: partner ? 'partner-$id' : null,
  );
}

Future<ActiveCityProvider> activeCity(String id) async {
  SharedPreferences.setMockInitialValues({});
  final provider = ActiveCityProvider(
    service: ActiveCityService(
      cityLoader: () async => [
        city('abengourou', 'Abengourou'),
        city('agnibilekrou', 'Agnibilékrou'),
      ],
    ),
  );
  await provider.initialize();
  await provider.selectManualCity(id);
  return provider;
}

Widget app({
  required ActiveCityProvider provider,
  required PharmacyGuardStreamLoader guardsLoader,
  required PharmacyPartnerStreamLoader partnersLoader,
  ThemeMode mode = ThemeMode.light,
}) => ChangeNotifierProvider.value(
      value: provider,
      child: MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        darkTheme: ThemeData.dark(useMaterial3: true),
        themeMode: mode,
        home: PharmacieGardePage(
          guardsLoader: guardsLoader,
          partnersLoader: partnersLoader,
          loadPosition: false,
        ),
      ),
    );

void main() {
  testWidgets('ville active filtre les gardes et se met à jour',
      (tester) async {
    final provider = await activeCity('abengourou');
    final requestedCities = <String>[];
    final guards = {
      'Abengourou': [
        guard(id: 'a', name: 'Pharmacie Abengourou', cityName: 'Abengourou'),
      ],
      'Agnibilékrou': [
        guard(id: 'g', name: 'Pharmacie Agnibilékrou', cityName: 'Agnibilékrou'),
      ],
    };
    await tester.pumpWidget(app(
      provider: provider,
      guardsLoader: (cityName) {
        requestedCities.add(cityName);
        return Stream.value(guards[cityName] ?? const []);
      },
      partnersLoader: (_, __) => Stream.value(const []),
    ));
    await tester.pump();
    expect(find.text('Pharmacie Abengourou'), findsOneWidget);
    expect(find.text('Pharmacie Agnibilékrou'), findsNothing);

    await provider.selectManualCity('agnibilekrou');
    await tester.pump();
    await tester.pump();
    expect(find.text('Pharmacie Abengourou'), findsNothing);
    expect(find.text('Pharmacie Agnibilékrou'), findsOneWidget);
    expect(requestedCities, containsAll(['Abengourou', 'Agnibilékrou']));
  });

  testWidgets('partenaire et externe sont distingués, sans pharmacieId inventé',
      (tester) async {
    final provider = await activeCity('abengourou');
    final partner = guard(
      id: 'partner',
      name: 'Partenaire',
      cityName: 'Abengourou',
      partner: true,
    );
    final external = guard(
      id: 'external',
      name: 'Externe',
      cityName: 'Abengourou',
    );
    await tester.pumpWidget(app(
      provider: provider,
      guardsLoader: (_) => Stream.value([partner, external]),
      partnersLoader: (cityId, _) {
        expect(cityId, 'abengourou');
        return Stream.value([partner]);
      },
    ));
    await tester.pump();
    expect(find.text('PARTENAIRE AZ'), findsOneWidget);
    expect(find.text('NON PARTENAIRE'), findsOneWidget);
    expect(buildPharmacyOrderPrefill(partner)['pharmacieId'], 'partner-partner');
    expect(buildPharmacyOrderPrefill(external).containsKey('pharmacieId'), isFalse);
  });

  testWidgets('état sans ville et rendu sombre à 320 px', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = ActiveCityProvider(
      service: ActiveCityService(cityLoader: () async => [city('abengourou', 'Abengourou')]),
    );
    await provider.initialize();
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(
      provider: provider,
      guardsLoader: (_) => Stream.value(const []),
      partnersLoader: (_, __) => Stream.value(const []),
      mode: ThemeMode.dark,
    ));
    expect(find.textContaining('Sélectionnez une ville'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
