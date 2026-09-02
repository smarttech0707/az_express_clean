import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/providers/active_city_provider.dart';
import 'package:az_express/screens/client/livraison_screen.dart';
import 'package:az_express/services/active_city_service.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late ActiveCityProvider cityProvider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cityProvider = ActiveCityProvider(
      service: ActiveCityService(
        cityLoader: () async => const <DeliveryZone>[],
        preferencesLoader: SharedPreferences.getInstance,
      ),
    );
  });

  Widget app() => ChangeNotifierProvider<ActiveCityProvider>.value(
        value: cityProvider,
        child: const MaterialApp(
          home: LivraisonScreen(startStartupServices: false),
        ),
      );

  Widget darkIosApp() => ChangeNotifierProvider<ActiveCityProvider>.value(
        value: cityProvider,
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(platform: TargetPlatform.iOS),
          home: const LivraisonScreen(startStartupServices: false),
        ),
      );

  Widget navigationApp() => ChangeNotifierProvider<ActiveCityProvider>.value(
        value: cityProvider,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const LivraisonScreen(startStartupServices: false),
                    ),
                  ),
                  child: const Text('Ouvrir livraison'),
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('un démontage immédiat ne crée aucun ticker pendant dispose',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpWidget(const SizedBox.shrink());

    expect(tester.takeException(), isNull);
  });

  testWidgets('les contrôleurs initialisés sont libérés sans ticker résiduel',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'la première étape laisse le Navigator dépiler la route Livraison',
      (tester) async {
    await tester.pumpWidget(navigationApp());
    await tester.tap(find.text('Ouvrir livraison'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(LivraisonScreen), findsOneWidget);
    final deliveryContext = tester.element(find.byType(LivraisonScreen));
    expect(
      ModalRoute.of(deliveryContext)!.popDisposition,
      RoutePopDisposition.pop,
    );
    final popHandled = await Navigator.of(deliveryContext).maybePop();
    expect(popHandled, isTrue);
    await tester.pumpAndSettle();

    expect(find.text('Ouvrir livraison'), findsOneWidget);
    expect(find.byType(LivraisonScreen), findsNothing);
  });

  test('le fond premium iOS sombre ne peut pas hériter du thème sombre', () {
    expect(
      shouldUseLightLivraisonPremiumFieldFill(
        platform: TargetPlatform.iOS,
        brightness: Brightness.dark,
      ),
      isTrue,
    );
    expect(
      shouldUseLightLivraisonPremiumFieldFill(
        platform: TargetPlatform.iOS,
        brightness: Brightness.light,
      ),
      isFalse,
    );
    expect(
      shouldUseLightLivraisonPremiumFieldFill(
        platform: TargetPlatform.android,
        brightness: Brightness.dark,
      ),
      isFalse,
    );
  });

  testWidgets('le champ de recherche réel garde un fond clair sur iOS sombre',
      (tester) async {
    await tester.pumpWidget(darkIosApp());

    final searchField = tester.widget<TextField>(find.byType(TextField));
    expect(searchField.style?.color, AppColors.text);
    expect(searchField.decoration?.filled, isTrue);
    expect(searchField.decoration?.fillColor, Colors.white);
    expect(searchField.decoration?.hintStyle?.color, AppColors.textLight);
  });

  test('le titre des lieux populaires reste opaque sur iOS sombre', () {
    expect(
      livraisonPopularPlaceTitleColor(
        platform: TargetPlatform.iOS,
        brightness: Brightness.dark,
      ),
      AppColors.text,
    );
    expect(
      livraisonPopularPlaceTitleColor(
        platform: TargetPlatform.iOS,
        brightness: Brightness.light,
      ),
      isNull,
    );
    expect(
      livraisonPopularPlaceTitleColor(
        platform: TargetPlatform.android,
        brightness: Brightness.dark,
      ),
      isNull,
    );
  });
}
