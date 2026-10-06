import 'package:az_express/widgets/admin_restaurant_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const names = [
  'foutou sauce gouagouassou viande de brousse',
  'spaghetti viande',
  'riz sauce graine poisson fumé',
  'attiéké poisson thon braisé',
];
const description =
    'Plat préparé avec des légumes frais, une sauce maison et un accompagnement au choix.';

Future<void> showCard(
  WidgetTester tester,
  Widget child,
  double width,
  double scale,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(platform: TargetPlatform.android),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [child],
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [320.0, 360.0, 412.0, 800.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final name in names) {
        testWidgets('dish $name at $width px, text x$scale', (tester) async {
          var edits = 0;
          var deletes = 0;
          await showCard(
            tester,
            AdminRestaurantDishCard(
              name: name,
              description: description,
              price: '12500 FCFA',
              imageUrl: '',
              onEdit: () => edits++,
              onDelete: () => deletes++,
            ),
            width,
            scale,
          );
          expect(tester.takeException(), isNull);
          // A regression to a narrow ListTile title fails this geometry check.
          for (final value in [name, description]) {
            final paragraph =
                tester.renderObject<RenderParagraph>(find.text(value));
            expect(paragraph.size.width, greaterThanOrEqualTo(256));
            final lines = paragraph.getBoxesForSelection(
                TextSelection(baseOffset: 0, extentOffset: value.length));
            expect(lines.map((box) => box.top).toSet().length,
                lessThanOrEqualTo(2));
          }
          final price =
              tester.renderObject<RenderParagraph>(find.text('12500 FCFA'));
          expect(price.didExceedMaxLines, isFalse);
          expect(tester.getRect(find.text('12500 FCFA')).right,
              lessThanOrEqualTo(width - 16));
          expect(tester.getTopLeft(find.byTooltip('Modifier')).dy,
              greaterThan(tester.getBottomLeft(find.text(description)).dy));
          await tester.tap(find.byTooltip('Modifier'));
          await tester.tap(find.byTooltip('Supprimer'));
          expect(edits, 1);
          expect(deletes, 1);
          expect(tester.takeException(), isNull);
        });
      }
      testWidgets('restaurant actions at $width px, text x$scale',
          (tester) async {
        final taps = <String>[];
        await showCard(
          tester,
          AdminRestaurantActions(
            onMenu: () => taps.add('Menu'),
            onSubscription: () => taps.add('Abo'),
            onDelete: () => taps.add('Supprimer'),
          ),
          width,
          scale,
        );
        for (final label in ['Menu', 'Abo', 'Supprimer']) {
          final paragraph =
              tester.renderObject<RenderParagraph>(find.text(label));
          final boxes = paragraph.getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: label.length));
          expect(boxes.map((box) => box.top).toSet(), hasLength(1),
              reason: '$label must remain on a single line');
          expect(tester.getRect(find.text(label)).right,
              lessThanOrEqualTo(width - 16));
          await tester.tap(find.text(label));
        }
        expect(taps, ['Menu', 'Abo', 'Supprimer']);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
