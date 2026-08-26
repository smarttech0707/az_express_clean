import 'package:az_express/models/delivery_zone.dart';
import 'package:az_express/providers/active_city_provider.dart';
import 'package:az_express/screens/client/livraison_screen.dart';
import 'package:az_express/services/active_city_service.dart';
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
}
