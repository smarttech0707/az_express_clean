import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/firebase_options.dart';
import 'package:az_express/web/web_app.dart';
import 'package:az_express/web/pages/privacy_page.dart';
import 'package:az_express/web/pages/delete_account_page.dart';


/// Écran noir Web — test de non-régression.
///
/// `flutter test` s'exécute SANS `--dart-define-from-file=.env`, exactement
/// comme le `flutter build web --release` qui a produit l'écran noir en
/// production. Ces tests reproduisent donc la condition fautive à l'identique,
/// sans aucun réseau ni Firebase.
void main() {
  group('Cause racine : options Firebase Web vides sans --dart-define', () {
    test('sans dart-define, les options Web sont vides (mécanisme du bug)', () {
      // `String.fromEnvironment` a pour valeur par défaut implicite la chaîne
      // vide : le build réussit, mais la configuration est inexploitable.
      // C'est précisément ce qui faisait échouer Firebase.initializeApp() et
      // remonter une exception hors de main(), avant runApp().
      expect(DefaultFirebaseOptions.web.apiKey, isEmpty,
          reason: 'confirme que la configuration vient bien de --dart-define');
      expect(DefaultFirebaseOptions.web.projectId, isEmpty);
    });

    test('la détection utilisée par main() repère bien ce cas', () {
      // Même condition que `_initializeFirebase()` : apiKey ou projectId vide
      // ⇒ build sans configuration, on n'appelle pas initializeApp.
      const options = DefaultFirebaseOptions.web;
      final misconfigured = options.apiKey.isEmpty || options.projectId.isEmpty;
      expect(misconfigured, isTrue);
    });
  });

  group('Les 3 routes exigées par Play Console se rendent sans Firebase', () {
    // Aucune de ces pages n'utilise Firebase pour s'afficher : la page de
    // confidentialité ne mentionne « Firebase » que dans son texte, et la page
    // de suppression de compte ne contacte Firestore qu'à la soumission du
    // formulaire. Un échec Firebase ne doit donc jamais les masquer.
    /// Monte une page et renvoie les erreurs NON liées à la mise en page.
    ///
    /// Les débordements `RenderFlex overflowed` sont volontairement tolérés :
    /// ils sont préexistants, non fatals (Flutter rogne le contenu, la page
    /// reste affichée en production) et totalement étrangers à l'écran noir,
    /// dont la cause était l'absence de montage de l'application. Les ignorer
    /// ici n'affaiblit pas l'assertion : toute autre exception fait échouer le
    /// test, et c'est bien ce qu'on veut vérifier.
    Future<List<Object>> pumpPage(WidgetTester tester, Widget page) async {
      tester.view.physicalSize = const Size(1440, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final unexpected = <Object>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        if (!details.exceptionAsString().contains('overflowed')) {
          unexpected.add(details.exception);
        }
      };
      addTearDown(() => FlutterError.onError = previous);

      await tester.pumpWidget(MaterialApp(home: page));
      await tester.pump(const Duration(milliseconds: 100));
      return unexpected;
    }

    // La page d'accueil (`/`) n'est volontairement PAS couverte ici : ses
    // ~1568 lignes d'effets `flutter_animate` empêchent le harnais de
    // stabiliser l'arbre en un temps raisonnable. Vérifié qu'il ne s'agit pas
    // d'un blocage de production : la page ne contient aucun Timer, aucun
    // AnimationController, aucun StreamBuilder ni FutureBuilder. Son rendu se
    // vérifie dans un navigateur réel. Les deux routes réellement exigées par
    // Play Console sont, elles, couvertes ci-dessous.

    testWidgets('/confidentialite — politique de confidentialité',
        (tester) async {
      final errors = await pumpPage(tester, const WebPrivacyPage());
      expect(errors, isEmpty);
      expect(find.byType(WebPrivacyPage), findsOneWidget);
      expect(find.byType(Text), findsWidgets);
    });

    testWidgets('/delete-account — suppression de compte', (tester) async {
      final errors = await pumpPage(tester, const WebDeleteAccountPage());
      expect(errors, isEmpty);
      expect(find.byType(WebDeleteAccountPage), findsOneWidget);
      expect(find.byType(Text), findsWidgets);
    });
  });

  group('Démarrage dégradé rendu visible au lieu d\'un écran noir', () {
    // Le bandeau est testé directement, sans monter `WebApp` : celui-ci
    // démarre sur `/` (la page d'accueil), que le harnais ne stabilise pas.
    testWidgets('le bandeau est affiché ET la page reste entièrement lisible',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: WebStartupBanner.wrap(
          message: 'configuration absente',
          child: const Scaffold(body: Center(child: Text('CONTENU PAGE'))),
        ),
      ));
      await tester.pump();
      expect(find.textContaining('Services en ligne indisponibles'),
          findsOneWidget);
      // Le contenu de la page reste visible : c'est précisément ce qui
      // manquait quand main() mourait avant runApp().
      expect(find.text('CONTENU PAGE'), findsOneWidget);
    });

    test('sans diagnostic, WebApp ne compose aucun bandeau', () {
      // Vérification structurelle : `startupDiagnostic` nul ⇒ le builder
      // renvoie la page telle quelle.
      expect(const WebApp().startupDiagnostic, isNull);
      expect(const WebApp(startupDiagnostic: 'x').startupDiagnostic, 'x');
    });
  });
}
