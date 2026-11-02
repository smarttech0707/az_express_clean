import 'package:az_express/screens/artisan/artisan_login.dart';
import 'package:az_express/screens/seller/seller_login.dart';
import 'package:az_express/widgets/pro_back_button.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// « Espace Professionnel » → écran de connexion : la flèche (et le bouton
/// Retour Android) doit ramener au portail. Les écrans sans AppBar
/// (Vendeur, Artisan) n'avaient aucune flèche visible.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  const portalKey = Key('portal');

  Future<void> openFromPortal(WidgetTester tester, Widget login) async {
    // Taille de téléphone : la surface de test par défaut (800x600) est plus
    // basse que les écrans de connexion et provoquerait un débordement sans lien.
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          key: portalKey,
          body: TextButton(
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => login)),
            child: const Text('Ouvrir'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();
  }

  group('ProBackButton', () {
    testWidgets('est masqué sur un écran racine', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Stack(children: [ProBackButton()])),
      ));
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    });

    testWidgets('ramène à l\'écran précédent', (tester) async {
      await openFromPortal(
        tester,
        const Scaffold(body: Stack(children: [ProBackButton()])),
      );
      expect(find.byTooltip('Retour'), findsOneWidget);
      await tester.tap(find.byTooltip('Retour'));
      await tester.pumpAndSettle();
      expect(find.byKey(portalKey), findsOneWidget);
      expect(find.byTooltip('Retour'), findsNothing);
    });
  });

  final logins = <String, Widget Function()>{
    'Espace Vendeur': () => const SellerLogin(),
    'Espace Artisan': () => const ArtisanLogin(),
  };

  for (final entry in logins.entries) {
    group(entry.key, () {
      testWidgets('affiche une flèche de retour vers le portail',
          (tester) async {
        await openFromPortal(tester, entry.value());
        expect(find.text(entry.key), findsOneWidget);
        expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

        await tester.tap(find.byTooltip('Retour'));
        await tester.pumpAndSettle();
        expect(find.text(entry.key), findsNothing);
        expect(find.byKey(portalKey), findsOneWidget);
      });

      testWidgets('le bouton Retour Android ramène aussi au portail',
          (tester) async {
        await openFromPortal(tester, entry.value());
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text(entry.key), findsNothing);
        expect(find.byKey(portalKey), findsOneWidget);
      });
    });
  }
}
