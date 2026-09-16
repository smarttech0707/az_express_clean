import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/providers/active_city_provider.dart';
import 'package:az_express/screens/client/blanchisserie_page.dart';
import 'package:az_express/screens/client/pharmacie_garde.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:az_express/widgets/premium_empty_state.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  testWidgets('RadioListTile sélectionné possède un ancêtre Material',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: const BlanchisseriePage(),
    ));
    await tester.pump();

    final selectedTile = find.byWidgetPredicate(
      (widget) => widget is RadioListTile<String> && widget.selected,
    );
    expect(selectedTile, findsOneWidget);
    expect(
      find.ancestor(of: selectedTile, matching: find.byType(Material)),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('état vide premium reste lisible en light à 320px',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: const Scaffold(
        body: PremiumEmptyState(
          icon: Icons.storefront_outlined,
          title: 'Aucun produit disponible',
          message: 'Les nouveaux produits apparaîtront ici.',
        ),
      ),
    ));

    expect(find.text('Aucun produit disponible'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pharmacies vide reste lisible en dark avec textScale 1.6',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final provider = ActiveCityProvider(
      service: ActiveCityService(
        cityLoader: () async => const [
          DeliveryZone(
            id: 'city-abengourou',
            cityId: 'abengourou',
            name: 'Abengourou',
            type: 'ville',
            lat: 6.7,
            lng: -3.4,
            radiusKm: 10,
            coordinateSource: ZoneCoordinateSource.own,
            isActive: true,
            isServiceable: true,
          ),
        ],
      ),
    );
    await provider.initialize();
    await provider.selectManualCity('abengourou');

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: provider,
      child: MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: PharmacieGardePage(
          loadPosition: false,
          guardsLoader: (_) => Stream.value(const []),
          partnersLoader: (_, __) => Stream.value(const []),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(PremiumEmptyState), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
