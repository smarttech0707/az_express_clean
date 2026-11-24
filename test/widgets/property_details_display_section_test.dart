import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/models/real_estate_listing.dart';
import 'package:az_express/widgets/immobilier/property_details_display_section.dart';

// Master Prompt "Immobilier V6" — Mission 9 : verrouille l'affichage adapté
// par type (Mission 5) — un terrain n'affiche jamais de champ "pièces", une
// villa n'affiche jamais un "terrain (m²)", et une annonce ancienne
// (aucun champ V6 renseigné) n'affiche aucune section supplémentaire.
void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

  testWidgets('terrain : affiche la surface du terrain, jamais les pièces',
      (tester) async {
    const listing = RealEstateListing(
      id: 'l1',
      agentId: 'a1',
      title: 'Grand terrain',
      description: 'd',
      price: 2000000,
      propertyType: 'land',
      city: 'Abengourou',
      surfaceTerrain: 1200,
      rooms: 5, // ignoré par construction pour un terrain
    );

    await tester.pumpWidget(
        wrap(const PropertyDetailsDisplaySection(listing: listing)));

    expect(find.textContaining('1200'), findsOneWidget);
    expect(find.textContaining('terrain'), findsOneWidget);
    expect(find.textContaining('pièces'), findsNothing);
  });

  testWidgets(
      'villa : affiche pièces/chambres/équipements, pas de surface terrain',
      (tester) async {
    const listing = RealEstateListing(
      id: 'l1',
      agentId: 'a1',
      title: 'Villa moderne',
      description: 'd',
      price: 500000,
      propertyType: 'villa',
      city: 'Abengourou',
      surface: 180,
      rooms: 5,
      bedrooms: 3,
      hasPool: true,
      hasGarage: true,
    );

    await tester.pumpWidget(
        wrap(const PropertyDetailsDisplaySection(listing: listing)));

    expect(find.textContaining('180'), findsOneWidget);
    expect(find.text('5 pièces'), findsOneWidget);
    expect(find.text('3 chambres'), findsOneWidget);
    expect(find.text('Piscine'), findsOneWidget);
    expect(find.text('Garage'), findsOneWidget);
    expect(find.textContaining('(terrain)'), findsNothing);
  });

  testWidgets('annonce ancienne sans aucun champ V6 : aucune section affichée',
      (tester) async {
    const listing = RealEstateListing(
      id: 'l1',
      agentId: 'a1',
      title: 'Ancienne annonce',
      description: 'd',
      price: 100000,
      propertyType: 'Villa',
      city: 'Abengourou',
    );

    await tester.pumpWidget(
        wrap(const PropertyDetailsDisplaySection(listing: listing)));

    expect(find.text('Équipements'), findsNothing);
    expect(find.text('Tarifs'), findsNothing);
  });

  testWidgets('bien indisponible : bannière affichée avec la date si connue',
      (tester) async {
    final listing = RealEstateListing(
      id: 'l1',
      agentId: 'a1',
      title: 'Villa',
      description: 'd',
      price: 500000,
      propertyType: 'villa',
      city: 'Abengourou',
      isAvailable: false,
      availabilityDate: DateTime(2026, 9, 1),
    );

    await tester
        .pumpWidget(wrap(PropertyDetailsDisplaySection(listing: listing)));

    expect(find.textContaining('1/9/2026'), findsOneWidget);
  });

  testWidgets(
      'Mission 4 (V6.1) — un ancien type villa reconverti en terrain ignore '
      'silencieusement les champs résidentiels laissés en base (aucune UI '
      'd\'édition n\'existe dans l\'app pour tester ce scénario en conditions '
      'réelles — vérifié ici au niveau modèle/affichage : la stratégie '
      '"champs conservés mais ignorés" est déjà sûre par construction, '
      'puisque l\'affichage ne branche que sur propertyType)',
      (tester) async {
    const listing = RealEstateListing(
      id: 'l1',
      agentId: 'a1',
      title: 'Ancienne villa devenue terrain',
      description: 'd',
      price: 4000000,
      // Type mis à jour vers 'land', mais les anciens champs résidentiels
      // (rooms/bedrooms/hasPool) restent en base — un `update()` Firestore
      // ne touche jamais les clés qu'on ne lui envoie pas explicitement.
      propertyType: 'land',
      city: 'Abengourou',
      surfaceTerrain: 800,
      rooms: 5,
      bedrooms: 3,
      hasPool: true,
      hasGarage: true,
    );

    await tester.pumpWidget(wrap(const PropertyDetailsDisplaySection(listing: listing)));

    // Le terrain est affiché...
    expect(find.textContaining('800'), findsOneWidget);
    // ...mais aucun champ résidentiel hérité n'apparaît, malgré leur
    // présence réelle dans le modèle passé au widget.
    expect(find.textContaining('pièces'), findsNothing);
    expect(find.textContaining('chambres'), findsNothing);
    expect(find.text('Piscine'), findsNothing);
    expect(find.text('Garage'), findsNothing);
  });

  testWidgets('tarifs alternatifs affichés quand renseignés', (tester) async {
    const listing = RealEstateListing(
      id: 'l1',
      agentId: 'a1',
      title: 'Résidence meublée',
      description: 'd',
      price: 500000,
      propertyType: 'furnishedResidence',
      city: 'Abengourou',
      pricePerDay: 15000,
      pricePerMonth: 300000,
    );

    await tester.pumpWidget(
        wrap(const PropertyDetailsDisplaySection(listing: listing)));

    expect(find.text('Tarifs'), findsOneWidget);
    expect(find.text('Par jour'), findsOneWidget);
    expect(find.text('15000 FCFA'), findsOneWidget);
    expect(find.text('Par mois'), findsOneWidget);
    expect(find.text('300000 FCFA'), findsOneWidget);
    expect(find.text('Par semaine'), findsNothing);
  });
}
