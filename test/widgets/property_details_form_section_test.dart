import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/models/real_estate_property_type.dart';
import 'package:az_express/widgets/immobilier/property_details_form_section.dart';

// Master Prompt "Immobilier V6" — Mission 9 : verrouille le formulaire
// dynamique (Mission 3) — un terrain n'affiche jamais "Pièces"/"Chambres",
// un local commercial affiche parking/vitrine, une résidence meublée met
// en avant ses équipements en premier, et [toListingFields] ne fabrique
// jamais un champ numérique à partir d'un champ vide.
void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

  group('PropertyDetailsFormController.toListingFieldsForCreate', () {
    test('un contrôleur vide ne produit que les booléens (tous false)', () {
      final c = PropertyDetailsFormController();
      final fields = c.toListingFieldsForCreate(RealEstatePropertyType.villa);
      expect(fields.containsKey('surface'), isFalse);
      expect(fields.containsKey('rooms'), isFalse);
      expect(fields.containsKey('pricePerDay'), isFalse);
      expect(fields['hasGarage'], isFalse);
      expect(fields['hasPool'], isFalse);
      c.dispose();
    });

    test('les champs texte renseignés sont convertis et inclus', () {
      final c = PropertyDetailsFormController();
      c.surfaceCtrl.text = '120.5';
      c.roomsCtrl.text = '4';
      c.hasPool = true;
      final fields = c.toListingFieldsForCreate(RealEstatePropertyType.villa);
      expect(fields['surface'], 120.5);
      expect(fields['rooms'], 4);
      expect(fields['hasPool'], isTrue);
      c.dispose();
    });

    test('un champ incompatible avec le type (terrain) est absent, pas false',
        () {
      final c = PropertyDetailsFormController();
      c.hasPool = true; // jamais pertinent pour un terrain
      c.surfaceTerrainCtrl.text = '500';
      final fields = c.toListingFieldsForCreate(RealEstatePropertyType.land);
      expect(fields.containsKey('hasPool'), isFalse);
      expect(fields['surfaceTerrain'], 500.0);
      c.dispose();
    });
  });

  group('PropertyDetailsFormController.toListingFieldsForUpdate', () {
    test(
        'Mission 6 (V6.2) — un champ incompatible avec le NOUVEAU type est '
        'explicitement supprimé (FieldValue.delete), jamais laissé ou mis à false',
        () {
      final c = PropertyDetailsFormController();
      c.hasPool = true;
      c.roomsCtrl.text = '5';
      final fields = c.toListingFieldsForUpdate(RealEstatePropertyType.land);
      // hasPool/rooms n'ont aucun sens pour un terrain : supprimés.
      expect(fields['hasPool'], isA<FieldValue>());
      expect(fields['rooms'], isA<FieldValue>());
      c.dispose();
    });

    test('un champ compatible et renseigné est écrit normalement', () {
      final c = PropertyDetailsFormController();
      c.surfaceTerrainCtrl.text = '1200';
      final fields = c.toListingFieldsForUpdate(RealEstatePropertyType.land);
      expect(fields['surfaceTerrain'], 1200.0);
      c.dispose();
    });

    test('un champ compatible mais vide est supprimé (jamais 0 fabriqué)', () {
      final c = PropertyDetailsFormController();
      // surfaceCtrl jamais rempli, mais 'surface' est autorisé pour une villa.
      final fields = c.toListingFieldsForUpdate(RealEstatePropertyType.villa);
      expect(fields['surface'], isA<FieldValue>());
      c.dispose();
    });

    test('hasSurfaceTerrain reflète uniquement le champ surfaceTerrain', () {
      final c = PropertyDetailsFormController();
      expect(c.hasSurfaceTerrain, isFalse);
      c.surfaceTerrainCtrl.text = '500';
      expect(c.hasSurfaceTerrain, isTrue);
      c.dispose();
    });
  });

  group('PropertyDetailsFormSection — affichage dynamique', () {
    testWidgets('terrain : superficie terrain visible, jamais Pièces/Chambres',
        (tester) async {
      final c = PropertyDetailsFormController();
      await tester.pumpWidget(wrap(PropertyDetailsFormSection(
        propertyType: RealEstatePropertyType.land,
        controller: c,
      )));

      expect(find.text('Superficie du terrain *'), findsOneWidget);
      expect(find.text('Pièces'), findsNothing);
      expect(find.text('Chambres'), findsNothing);
      c.dispose();
    });

    testWidgets(
        'bien habitable : pièces/chambres/équipements généraux visibles',
        (tester) async {
      final c = PropertyDetailsFormController();
      await tester.pumpWidget(wrap(PropertyDetailsFormSection(
        propertyType: RealEstatePropertyType.villa,
        controller: c,
      )));

      expect(find.text('Pièces'), findsOneWidget);
      expect(find.text('Chambres'), findsOneWidget);
      expect(find.text('Garage'), findsOneWidget);
      expect(find.text('Piscine'), findsOneWidget);
      c.dispose();
    });

    testWidgets(
        'local commercial : parking + vitrine, jamais garage/piscine/pièces/chambres '
        '(bug réel trouvé sur device V6.1 : Pièces/Chambres/Salles de bain/Étage '
        's\'affichaient à tort pour un bien commercial, corrigé)',
        (tester) async {
      final c = PropertyDetailsFormController();
      await tester.pumpWidget(wrap(PropertyDetailsFormSection(
        propertyType: RealEstatePropertyType.shop,
        controller: c,
      )));

      expect(find.text('Parking disponible'), findsOneWidget);
      expect(find.text('Vitrine / façade commerciale'), findsOneWidget);
      expect(find.text('Garage'), findsNothing);
      expect(find.text('Piscine'), findsNothing);
      expect(find.text('Pièces'), findsNothing);
      expect(find.text('Chambres'), findsNothing);
      expect(find.text('Salles de bain'), findsNothing);
      expect(find.text('Étage'), findsNothing);
      c.dispose();
    });

    testWidgets('résidence meublée : section équipements dédiée affichée',
        (tester) async {
      final c = PropertyDetailsFormController();
      await tester.pumpWidget(wrap(PropertyDetailsFormSection(
        propertyType: RealEstatePropertyType.furnishedResidence,
        controller: c,
      )));

      expect(find.text('Équipements (résidence meublée)'), findsOneWidget);
      c.dispose();
    });
  });
}
