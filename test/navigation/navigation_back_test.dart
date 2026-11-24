import 'dart:io';

import 'package:az_express/theme/app_theme.dart';
import 'package:az_express/widgets/pro_back_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Navigation « retour » sur Android et iOS : flèche visible sur les états sans
/// AppBar, geste de retour iOS préservé, retours bloqués seulement quand une
/// opération sensible est en cours, pile nettoyée à la déconnexion.
void main() {
  const homeKey = Key('home');
  const secondKey = Key('second');

  Widget app(Route<void> Function(Widget page) route, Widget second,
      {bool withTheme = true}) {
    return MaterialApp(
      theme: withTheme ? AppTheme.light : null,
      home: Builder(
        builder: (context) => Scaffold(
          key: homeKey,
          body: TextButton(
            onPressed: () => Navigator.push(context, route(second)),
            child: const Text('Ouvrir'),
          ),
        ),
      ),
    );
  }

  Route<void> standard(Widget page) =>
      MaterialPageRoute<void>(builder: (_) => page);
  Route<void> fadeSlide(Widget page) => AppTransitions.fadeSlide<void>(page);
  Route<void> slideRight(Widget page) => AppTransitions.slideRight<void>(page);

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();
  }

  /// Glissement depuis le bord gauche, comme le geste de retour iPhone.
  Future<void> edgeSwipe(WidgetTester tester) async {
    await tester.dragFrom(const Offset(2, 300), const Offset(600, 0));
    await tester.pumpAndSettle();
  }

  const secondScreen = Scaffold(key: secondKey, body: Text('Page secondaire'));

  group('iOS : geste de retour par glissement', () {
    final routes = <String, Route<void> Function(Widget)>{
      'MaterialPageRoute': standard,
      'AppTransitions.fadeSlide': fadeSlide,
      'AppTransitions.slideRight': slideRight,
    };
    for (final entry in routes.entries) {
      testWidgets('${entry.key} se ferme par glissement', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await tester.pumpWidget(app(entry.value, secondScreen));
          await open(tester);
          expect(find.byKey(secondKey), findsOneWidget);
          await edgeSwipe(tester);
          expect(find.byKey(secondKey), findsNothing);
          expect(find.byKey(homeKey), findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('le glissement respecte PopScope(canPop: false)',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await tester.pumpWidget(app(
          fadeSlide,
          const PopScope(
            canPop: false,
            child: Scaffold(key: secondKey, body: Text('Paiement en cours')),
          ),
        ));
        await open(tester);
        await edgeSwipe(tester);
        // Opération sensible : le retour reste refusé, aucun contournement.
        expect(find.byKey(secondKey), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('Android : bouton Retour système', () {
    for (final entry in {
      'MaterialPageRoute': standard,
      'AppTransitions.fadeSlide': fadeSlide,
      'AppTransitions.slideRight': slideRight,
    }.entries) {
      testWidgets('${entry.key} revient à la page précédente', (tester) async {
        await tester.pumpWidget(app(entry.value, secondScreen));
        await open(tester);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(secondKey), findsNothing);
        expect(find.byKey(homeKey), findsOneWidget);
      });
    }

    testWidgets('PopScope(canPop: false) refuse aussi le retour système',
        (tester) async {
      await tester.pumpWidget(app(
        fadeSlide,
        const PopScope(
          canPop: false,
          child: Scaffold(key: secondKey, body: Text('Commande en cours')),
        ),
      ));
      await open(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(secondKey), findsOneWidget);
    });
  });

  group('BackOverlay (états chargement / erreur / connexion requise)', () {
    const state = Scaffold(
      key: secondKey,
      body: BackOverlay(child: Center(child: Text('Annonce introuvable'))),
    );

    testWidgets('affiche une flèche qui ramène à la page précédente',
        (tester) async {
      await tester.pumpWidget(app(standard, state));
      await open(tester);
      expect(find.byTooltip('Retour'), findsOneWidget);
      await tester.tap(find.byTooltip('Retour'));
      await tester.pumpAndSettle();
      expect(find.byKey(secondKey), findsNothing);
      expect(find.byKey(homeKey), findsOneWidget);
    });

    testWidgets('n\'affiche aucune flèche sur un écran racine', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light, home: state));
      expect(find.byTooltip('Retour'), findsNothing);
      expect(find.text('Annonce introuvable'), findsOneWidget);
    });

    testWidgets('reste utilisable en mode sombre', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(context, standard(state)),
            child: const Text('Ouvrir'),
          ),
        ),
      ));
      await open(tester);
      final icon = tester.widget<IconButton>(find.byType(IconButton));
      expect(icon.color, AppTheme.dark.colorScheme.onSurface);
    });
  });

  group('Garde-fous de structure (code source)', () {
    String source(String path) => File(path).readAsStringSync();

    test('les écrans de reprise de session des espaces pro ont une flèche', () {
      for (final path in [
        'lib/screens/boulangerie/boulangerie_login.dart',
        'lib/screens/driver/driver_login.dart',
        'lib/screens/fleet/fleet_login.dart',
        'lib/screens/pharmacie/pharmacie_login.dart',
        'lib/screens/restaurant/restaurant_owner_login.dart',
        'lib/screens/admin/admin_login.dart',
        'lib/screens/seller/seller_login.dart',
        'lib/screens/artisan/artisan_login.dart',
      ]) {
        final text = source(path);
        final spinner = text.indexOf('if (_autoResuming)');
        expect(spinner, greaterThan(-1), reason: path);
        expect(text.substring(spinner, spinner + 700),
            anyOf(contains('BackOverlay('), contains('ProBackButton(')),
            reason: '$path : spinner de reprise sans flèche de retour');
      }
    });

    test('la déconnexion vide la pile ou revient au portail', () {
      // Aucune page protégée ne doit rester accessible par « Retour » après
      // signOut : chaque tableau de bord nettoie la pile juste après.
      final clearing = RegExp(
          r'pushAndRemoveUntil|popUntil\(\(r\) => r\.isFirst\)|Navigator\.pop\(context\)');
      for (final path in [
        'lib/screens/seller/seller_dashboard.dart',
        'lib/screens/artisan/artisan_dashboard.dart',
        'lib/screens/fleet/fleet_dashboard.dart',
        'lib/screens/boulangerie/boulangerie_dashboard.dart',
        'lib/screens/pharmacie/pharmacie_dashboard.dart',
        'lib/screens/restaurant/restaurant_owner_dashboard.dart',
        'lib/screens/immobilier/agent_dashboard_screen.dart',
        'lib/ekbine/screens/ek_agent_dashboard.dart',
        'lib/screens/admin/admin_dashboard.dart',
      ]) {
        final text = source(path);
        final start = text.indexOf('Future<void> _doLogout');
        expect(start, greaterThan(-1), reason: path);
        final body = text.substring(start, start + 900);
        final signOut = body.indexOf('signOut()');
        expect(signOut, greaterThan(-1), reason: '$path : signOut absent');
        expect(clearing.hasMatch(body.substring(signOut)), isTrue,
            reason: '$path : pile non nettoyée après la déconnexion');
      }
    });

    test('les connexions remplacent leur écran par le tableau de bord', () {
      // pushReplacement : « Retour » depuis le tableau de bord ne revient pas
      // au formulaire de connexion.
      for (final path in [
        'lib/screens/seller/seller_login.dart',
        'lib/screens/artisan/artisan_login.dart',
      ]) {
        expect(source(path), contains('Navigator.pushReplacement('),
            reason: path);
      }
    });

    test('les écrans de changement de mot de passe forcé restent bloquants', () {
      // Sécurité : pas de retour pour contourner l'activation du compte.
      expect(source('lib/screens/auth/partner_first_password_page.dart'),
          contains('PopScope('));
      expect(source('lib/screens/pharmacie/pharmacie_change_password.dart'),
          contains('automaticallyImplyLeading: false'));
    });
  });
}
