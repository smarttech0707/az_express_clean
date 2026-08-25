import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/widgets/immobilier/listing_gallery_viewer.dart';

// Master Prompt "Immobilier V6" — Mission 9 : verrouille l'état vide (aucune
// photo/vidéo) et la présence des indicateurs de page pour un multi-photo —
// le vrai chargement réseau (CachedNetworkImage) n'est volontairement pas
// exercé ici (nécessiterait un mock HTTP, hors périmètre de cette passe),
// seule la structure du widget est vérifiée.
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('aucune image ni vidéo : affiche l\'icône de repli',
      (tester) async {
    await tester.pumpWidget(wrap(const ListingGalleryHeader(images: [])));
    expect(find.byIcon(Icons.home_outlined), findsOneWidget);
  });

  testWidgets('une seule image : aucun indicateur de page affiché',
      (tester) async {
    await tester.pumpWidget(wrap(const ListingGalleryHeader(
      images: ['https://example.com/1.jpg'],
    )));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(PageView), findsOneWidget);
    // Un seul point de pagination ne serait pas informatif — le widget ne
    // les affiche qu'à partir de 2 images.
    expect(find.byType(AnimatedContainer), findsNothing);
  });

  testWidgets('plusieurs images : affiche autant d\'indicateurs de page',
      (tester) async {
    await tester.pumpWidget(wrap(const ListingGalleryHeader(
      images: [
        'https://example.com/1.jpg',
        'https://example.com/2.jpg',
        'https://example.com/3.jpg',
      ],
    )));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AnimatedContainer), findsNWidgets(3));
  });

  testWidgets('vidéos présentes : affiche un bouton lecture par vidéo',
      (tester) async {
    await tester.pumpWidget(wrap(const ListingGalleryHeader(
      images: ['https://example.com/1.jpg'],
      videos: [
        'https://youtube.com/watch?v=a',
        'https://youtube.com/watch?v=b'
      ],
    )));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byIcon(Icons.play_arrow_rounded), findsNWidgets(2));
  });
}
