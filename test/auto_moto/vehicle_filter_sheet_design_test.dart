import 'package:az_express/auto_moto/models/vehicle_listing.dart';
import 'package:az_express/auto_moto/vehicle_listing_query.dart';
import 'package:az_express/auto_moto/widgets/vehicle_filter_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app({required ThemeData theme}) => MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => const VehicleFilterSheet(
                  initial: VehicleListingFilters(),
                  offerType: VehicleOfferType.sale,
                  vehicleType: VehicleType.car,
                  cityLabel: 'Toute la Côte d’Ivoire',
                ),
              ),
              child: const Text('Ouvrir les filtres'),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('filter sheet remains usable at 320 px', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(theme: ThemeData.light(useMaterial3: true)));
    await tester.tap(find.text('Ouvrir les filtres'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Filtres'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('vehicle_filter_city')),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.byKey(const Key('vehicle_filter_city')), findsOneWidget);
    expect(find.byKey(const Key('vehicle_filter_apply')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected choice chip has an explicit selected state in dark mode',
      (tester) async {
    await tester.pumpWidget(_app(theme: ThemeData.dark(useMaterial3: true)));
    await tester.tap(find.text('Ouvrir les filtres'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Neuf'));
    await tester.pump();

    final chip = tester.widget<ChoiceChip>(find.byType(ChoiceChip).first);
    expect(chip.selected, isTrue);
    expect(tester.takeException(), isNull);
  });
}
