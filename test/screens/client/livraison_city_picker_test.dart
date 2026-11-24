import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/models/local_place.dart';
import 'package:az_express/providers/active_city_provider.dart';
import 'package:az_express/screens/client/livraison_screen.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:az_express/services/places_search_service.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

DeliveryZone _city(String cityId, String name, double lat, double lng) =>
    DeliveryZone(
      id: cityId,
      name: name,
      type: 'ville',
      cityId: cityId,
      lat: lat,
      lng: lng,
      radiusKm: 30,
      coordinateSource: ZoneCoordinateSource.own,
      isServiceable: true,
      isActive: true,
    );

LocalPlace _place(String id, String name) => LocalPlace(
      id: id,
      name: name,
      category: 'other',
      district: 'centre',
      address: name,
      latitude: 6.73,
      longitude: -3.49,
      cityId: 'abengourou',
      verified: true,
    );

const _geolocatorChannel = MethodChannel('flutter.baseflow.com/geolocator');

/// Simule la localisation du téléphone (permission accordée, position fixe).
void mockGeolocator({required double latitude, required double longitude}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_geolocatorChannel, (call) async {
    switch (call.method) {
      case 'requestPermission':
      case 'checkPermission':
        return 2; // LocationPermission.whileInUse
      case 'isLocationServiceEnabled':
        return true;
      case 'getCurrentPosition':
        return <String, dynamic>{
          'latitude': latitude,
          'longitude': longitude,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'accuracy': 5.0,
          'altitude': 0.0,
          'altitude_accuracy': 0.0,
          'heading': 0.0,
          'heading_accuracy': 0.0,
          'speed': 0.0,
          'speed_accuracy': 0.0,
          'is_mocked': false,
        };
    }
    return null;
  });
}

void main() {
  late ActiveCityProvider cityProvider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // La carte Google (vue native) n'existe pas en test : on neutralise sa création.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter/platform_views'), (_) async => 0);
    mockGeolocator(latitude: 6.7297, longitude: -3.4964);
    PlacesSearchService.debugResetSearchState();
    PlacesSearchService.debugSetCityPlacesLoader(
        (cityId) async => cityId == 'abengourou'
            ? [
                _place('1', 'École Château'),
                _place('2', 'Maternité Cafétou'),
                _place('3', 'Grand Marché Abengourou'),
              ]
            : const []);
    PlacesSearchService.debugSetHttpClient(
        MockClient((_) async => http.Response('[]', 200)));
    // GPS jamais résolu : permission refusée, délai dépassé ou hors zone.
    cityProvider = ActiveCityProvider(
      service: ActiveCityService(
        cityLoader: () async => [
          _city('abengourou', 'Abengourou', 6.7297, -3.4964),
          _city('agnibilekrou', 'Agnibilékrou', 7.1289, -3.2044),
        ],
        preferencesLoader: SharedPreferences.getInstance,
      ),
    );
  });

  tearDown(() {
    PlacesSearchService.debugResetSearchState();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_geolocatorChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter/platform_views'), null);
  });

  Widget app() => ChangeNotifierProvider<ActiveCityProvider>.value(
        value: cityProvider,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const LivraisonScreen(startStartupServices: false),
        ),
      );

  Finder fieldWithHint(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint);

  /// Touche un bouton qui déclenche la localisation : la géolocalisation inverse
  /// (HTTP) passe par un client simulé, donc aucune attente réelle n'est utile.
  Future<void> tapAndLocate(WidgetTester tester, Finder target) async {
    await http.runWithClient(
      () async {
        await tester.tap(target);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
      },
      () => MockClient((_) async => http.Response('{}', 200)),
    );
  }

  Finder fieldWithValue(String value) => find
      .byWidgetPredicate((w) => w is TextField && w.controller?.text == value);

  Future<void> openPickupSearch(WidgetTester tester) async {
    await tester.runAsync(cityProvider.initialize);
    await tester.pumpWidget(app());
    await tester.tap(find.widgetWithText(TextField, '').first);
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
      'ville inconnue : message clair, deux villes proposées, '
      'pas de « Aucun lieu trouvé » trompeur', (tester) async {
    await openPickupSearch(tester);

    expect(find.byKey(const Key('city-context-panel')), findsOneWidget);
    expect(find.text(livraisonLocationIssueMessage(null)), findsOneWidget);
    expect(find.byKey(const Key('search-city-abengourou')), findsOneWidget);
    expect(find.byKey(const Key('search-city-agnibilekrou')), findsOneWidget);
    expect(find.byKey(const Key('retry-location-button')), findsOneWidget);
    expect(find.text('Aucun lieu trouvé'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'château');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Aucun lieu trouvé'), findsNothing);
    expect(find.text('École Château'), findsNothing);
  });

  testWidgets('choisir Abengourou rétablit la recherche sur tous les mots',
      (tester) async {
    await openPickupSearch(tester);
    await tester.enterText(find.byType(TextField).first, 'château');
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const Key('search-city-abengourou')));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('École Château'), findsOneWidget);
    // Le choix cadre la recherche ; il ne devient jamais la ville active.
    expect(cityProvider.activeCityId, isNull);
    expect(cityProvider.service.hasUsableActiveCity, isFalse);

    await tester.enterText(find.byType(TextField).first, 'cafétou');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Maternité Cafétou'), findsOneWidget);
  });

  testWidgets(
      'étape « Où livrons-nous ? » : même sélecteur, mêmes résultats par mots',
      (tester) async {
    await openPickupSearch(tester);
    // Étape 1 : « Où récupérer ? » — ville choisie puis lieu de départ.
    await tester.tap(find.byKey(const Key('search-city-abengourou')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).first, 'grand marché');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Grand Marché Abengourou'), findsOneWidget);
    await tester.tap(find.text('Grand Marché Abengourou'));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('Confirmer le point de récupération'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(fieldWithHint('Nom complet de la personne'), 'Jean');
    await tester.enterText(fieldWithHint('07 XX XX XX XX'), '0700000000');
    await tester.tap(find.text('Choisir le point de livraison'));
    await tester.pump(const Duration(milliseconds: 500));

    // Étape 2 : « Où livrons-nous ? » — même panneau, même recherche.
    await tester.tap(find.byType(TextField).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('city-context-panel')), findsOneWidget);
    expect(find.byKey(const Key('search-city-agnibilekrou')), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'cafétou');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Maternité Cafétou'), findsOneWidget);
    expect(cityProvider.activeCityId, isNull);
  });

  testWidgets(
      'Réessayer la localisation ne remplace pas une adresse déjà choisie '
      'mais résout la ville', (tester) async {
    await openPickupSearch(tester);
    await tester.tap(find.byKey(const Key('search-city-abengourou')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).first, 'château');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('École Château'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(fieldWithValue('École Château'), findsOneWidget);

    // Retour dans la recherche (ville toujours non résolue) puis nouvel essai.
    await tester.tap(fieldWithValue('École Château'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(cityProvider.activeCityId, isNull);
    await tapAndLocate(tester, find.byKey(const Key('retry-location-button')));

    expect(cityProvider.activeCityId, 'abengourou');
    expect(find.byKey(const Key('city-context-panel')), findsNothing);
    // L'adresse choisie à la main est conservée (le champ apparaît aussi dans
    // l'en-tête de la recherche active).
    expect(fieldWithValue('École Château'), findsWidgets);
    expect(find.text('Ma position actuelle'), findsNothing);
  });

  testWidgets(
      '« Ma position » continue de remplacer le champ par la position actuelle',
      (tester) async {
    await openPickupSearch(tester);
    await tester.tap(find.byKey(const Key('search-city-abengourou')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).first, 'château');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('École Château'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(fieldWithValue('École Château'), findsOneWidget);

    await tapAndLocate(tester, find.text('Ma position'));

    // Comportement historique du bouton, volontairement inchangé : le champ
    // reçoit la position (le texte exact dépend de la géolocalisation inverse).
    expect(cityProvider.activeCityId, 'abengourou');
    expect(fieldWithValue('École Château'), findsNothing);
  });

  testWidgets('GPS résolu : aucun sélecteur de ville', (tester) async {
    await tester.runAsync(
        () => cityProvider.resolveGps(latitude: 6.7297, longitude: -3.4964));
    await tester.pumpWidget(app());
    await tester.tap(find.byType(TextField).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(cityProvider.activeCityId, 'abengourou');
    expect(find.byKey(const Key('city-context-panel')), findsNothing);
  });

  group('messages de localisation', () {
    test('un message distinct par cause', () {
      final messages = {
        for (final issue in LivraisonLocationIssue.values)
          livraisonLocationIssueMessage(issue),
        livraisonLocationIssueMessage(null),
      };
      expect(messages, hasLength(LivraisonLocationIssue.values.length + 1));
    });

    test('le sélecteur ne propose que les villes actives localisables', () {
      final cities = livraisonSelectableCities([
        _city('abengourou', 'Abengourou', 6.7297, -3.4964),
        const DeliveryZone(
          id: 'x',
          name: 'Sans géométrie',
          type: 'ville',
          cityId: 'x',
          coordinateSource: ZoneCoordinateSource.own,
          isServiceable: true,
          isActive: true,
        ),
      ]);
      expect(cities.map((c) => c.cityId), ['abengourou']);
    });

    test('le sélecteur n\'apparaît que sans ville résolue', () {
      expect(shouldShowLivraisonCityPicker(activeCityId: null), isTrue);
      expect(
          shouldShowLivraisonCityPicker(activeCityId: 'abengourou'), isFalse);
    });
  });
}
