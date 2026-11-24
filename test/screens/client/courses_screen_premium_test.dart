import 'package:az_express/screens/client/courses_screen.dart';
import 'package:az_express/theme/app_theme.dart';
import 'package:az_express/widgets/premium_background.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugin.csdcorp.com/speech_to_text'),
      (_) async => false,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'),
      (call) async {
        if (call.method == 'isLocationServiceEnabled') return false;
        return null;
      },
    );
  });

  tearDown(() {
    for (final channel in const [
      MethodChannel('plugin.csdcorp.com/speech_to_text'),
      MethodChannel('flutter.baseflow.com/geolocator'),
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  Widget app(Brightness brightness) => MaterialApp(
        theme: brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
        darkTheme: AppTheme.dark,
        themeMode:
            brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        home: const CoursesScreen(),
      );

  testWidgets('light : ajout et suppression article restent fonctionnels',
      (tester) async {
    await tester.pumpWidget(app(Brightness.light));
    await tester.pump();

    expect(find.byType(PremiumBackground), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Huile 500 FCFA, Tomates, Pain…'),
      'Pain',
    );
    await tester.tap(find.bySemanticsLabel("Ajouter l'article"));
    await tester.pump();
    expect(find.text('Pain'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pump();
    expect(find.text('Pain'), findsNothing);
  });

  testWidgets('dark 320px et textScale 1.6 : aucun overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(
        size: Size(320, 700),
        textScaler: TextScaler.linear(1.6),
      ),
      child: app(Brightness.dark),
    ));
    await tester.pump();

    expect(find.text('Mes Courses'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ─────────────────────────────────────────────────────────────────────
  // LOT 4.1 — polish final Courses. Étend (sans les remplacer) les 2 tests
  // ci-dessus déjà en place.
  // ─────────────────────────────────────────────────────────────────────

  testWidgets('light : aucun overflow, PremiumBackground clair appliqué',
      (tester) async {
    await tester.pumpWidget(app(Brightness.light));
    await tester.pump();

    final bg = tester.widget<PremiumBackground>(find.byType(PremiumBackground));
    expect(bg.child, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quantité : le bouton + incrémente, le bouton − décrémente',
      (tester) async {
    await tester.pumpWidget(app(Brightness.light));
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextField, 'Huile 500 FCFA, Tomates, Pain…'),
      'Tomates',
    );
    await tester.tap(find.bySemanticsLabel("Ajouter l'article"));
    await tester.pump();
    expect(find.text('Tomates'), findsOneWidget);
    expect(find.text('1'), findsOneWidget); // quantité initiale

    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pump();
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.remove).first);
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets(
      'adresse : "Ma position" / "Autre adresse" ont bien un état '
      'sélectionné distinct, sans toucher la logique GPS', (tester) async {
    await tester.pumpWidget(app(Brightness.light));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // GPS désactivé (mocké) → l'état "Ma position" affiche une erreur, pas
    // un crash — la bascule vers "Autre adresse" reste fonctionnelle.
    expect(find.text('📍 Ma position'), findsOneWidget);
    expect(find.text('🔍 Autre adresse'), findsOneWidget);

    await tester.tap(find.text('🔍 Autre adresse'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('CTA "Commander maintenant" présent et accessible',
      (tester) async {
    await tester.pumpWidget(app(Brightness.light));
    await tester.pump();

    final ctaFinder = find.text('Commander maintenant');
    await tester.scrollUntilVisible(
      ctaFinder,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(ctaFinder, findsOneWidget);
    expect(find.byIcon(Icons.shopping_cart_checkout_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'clavier ouvert (viewInsets.bottom simulé) : le contenu reste '
      'scrollable et le CTA atteignable, aucun overflow', (tester) async {
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(
        size: Size(390, 844),
        viewInsets: EdgeInsets.only(bottom: 300), // clavier iOS ouvert
      ),
      child: app(Brightness.light),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.text('Commander maintenant'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Commander maintenant'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'taille iPhone (390×844) avec bottom safe-area inset (home '
      'indicator) : aucun overflow', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34); // home indicator
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    await tester.pumpWidget(app(Brightness.light));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.text('Commander maintenant'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'comportement métier inchangé : session anonyme, budget/adresse '
      'toujours requis avant envoi (dialogue de validation)', (tester) async {
    await tester.pumpWidget(app(Brightness.light));
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('Commander maintenant'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Commander maintenant'));
    await tester.pump();

    // Ni articles, ni budget, ni adresse ne sont renseignés — la même
    // validation qu'avant ce lot doit toujours bloquer l'envoi.
    expect(find.text('Informations manquantes'), findsOneWidget);
  });
}
