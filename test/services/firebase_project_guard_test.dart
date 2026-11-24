import 'dart:io';

import 'package:az_express/services/firebase_project_guard.dart';
import 'package:az_express/widgets/wrong_firebase_project_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const preprod = 'az-express-preprod';

void main() {
  group('évaluation du projet effectif', () {
    test('inactive sans define : aucun blocage, quel que soit le projet (builds existants)',
        () {
      for (final p in [null, '', preprod, 'az-express-b0469', 'autre']) {
        expect(FirebaseProjectGuard.evaluate(required: '', effectiveProject: p),
            isNull);
      }
      expect(FirebaseProjectGuard.active, isFalse);
      expect(FirebaseProjectGuard.requiredProject, isEmpty);
      expect(FirebaseProjectGuard.check(), isNull); // même sans Firebase initialisé
    });

    test('projet effectif = préproduction : le démarrage continue', () {
      expect(
          FirebaseProjectGuard.evaluate(
              required: preprod, effectiveProject: preprod),
          isNull);
    });

    test('projet effectif de production : WRONG_FIREBASE_PROJECT', () {
      for (final prod in ['az-express-b0469', 'az-express-clean']) {
        expect(
            FirebaseProjectGuard.evaluate(
                required: preprod, effectiveProject: prod),
            FirebaseProjectGuard.blockedCode);
      }
      expect(FirebaseProjectGuard.blockedCode, 'WRONG_FIREBASE_PROJECT');
    });

    test('projet effectif absent, vide ou autre : bloqué (fail-closed)', () {
      for (final p in [null, '', 'demo-test', 'az-express-preprod-2', 'AZ-EXPRESS-PREPROD']) {
        expect(
            FirebaseProjectGuard.evaluate(required: preprod, effectiveProject: p),
            FirebaseProjectGuard.blockedCode,
            reason: 'effectif=$p');
      }
    });

    test('define autre que la préproduction : toujours bloqué, même si le projet effectif coïncide',
        () {
      for (final other in ['az-express-b0469', 'az-express-clean', 'demo-test']) {
        expect(
            FirebaseProjectGuard.evaluate(required: other, effectiveProject: other),
            FirebaseProjectGuard.blockedCode);
      }
      expect(FirebaseProjectGuard.allowedProject, preprod);
    });

    test('le fichier de la garde ne contient aucun identifiant de production', () {
      final src = File('lib/services/firebase_project_guard.dart').readAsStringSync();
      expect(src.contains('b0469'), isFalse);
      expect(src.contains('az-express-clean'), isFalse);
    });

    test('lecture du projet effectif impossible : bloqué', () {
      expect(
          FirebaseProjectGuard.check(
              required: preprod, readEffectiveProject: () => throw StateError('pas de Firebase')),
          FirebaseProjectGuard.blockedCode);
    });

    test('lecture réussie via check()', () {
      expect(
          FirebaseProjectGuard.check(
              required: preprod, readEffectiveProject: () => preprod),
          isNull);
      expect(
          FirebaseProjectGuard.check(
              required: preprod, readEffectiveProject: () => 'az-express-b0469'),
          FirebaseProjectGuard.blockedCode);
    });
  });

  group('écran bloquant', () {
    testWidgets('affiche WRONG_FIREBASE_PROJECT sans action possible ni identifiant de projet',
        (t) async {
      await t.pumpWidget(const WrongFirebaseProjectScreen());
      expect(find.byKey(const Key('wrong-firebase-project-code')), findsOneWidget);
      expect(find.text('WRONG_FIREBASE_PROJECT'), findsOneWidget);
      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('b0469'), findsNothing);
      expect(find.textContaining('preprod'), findsNothing);
    });

    test('le widget n\'importe ni Firebase ni services métier', () {
      final src = File('lib/widgets/wrong_firebase_project_screen.dart').readAsStringSync();
      for (final banned in ['cloud_firestore', 'firebase_auth', 'cloud_functions', 'firebase_storage', 'firebase_messaging', 'provider', 'services/firestore', 'services/notification']) {
        expect(src.contains(banned), isFalse, reason: banned);
      }
    });
  });

  group('position de la garde dans main()', () {
    final main = File('lib/main.dart').readAsStringSync();

    int at(String s) {
      final i = main.indexOf(s);
      expect(i, greaterThanOrEqualTo(0), reason: 'introuvable : $s');
      return i;
    }

    test('la garde s\'exécute et arrête main() AVANT tout service susceptible d\'opérations métier',
        () {
      final guard = at('startupDiagnostic == FirebaseProjectGuard.blockedCode');
      final stop = main.indexOf('return;', guard);
      final firstRunApp = at('runApp(');
      expect(at('await _initializeFirebase()'), lessThan(guard));
      expect(stop, greaterThan(guard));
      for (final risky in [
        '_activateAppCheck()',
        'FirebaseCrashlytics.instance.recordFlutterFatalError',
        'FirebaseFirestore.instance.settings',
        'MultiProvider(',
        'NotificationService().init()',
        '_ensureAnonymousAuth()',
        'loadCommissionConfig()',
        '_initializeDeferred(appCheckReady)',
      ]) {
        final i = main.indexOf(risky);
        if (i < 0) continue;
        // la première occurrence d'un service à risque doit venir APRÈS le retour de la garde
        expect(i, greaterThan(stop), reason: '$risky précède l\'arrêt de la garde');
      }
      expect(firstRunApp, lessThan(stop)); // l'écran bloquant est bien lancé avant le return
    });

    test('le bloc de garde ne lance que l\'écran bloquant', () {
      final guard = at('startupDiagnostic == FirebaseProjectGuard.blockedCode');
      final stop = main.indexOf('return;', guard);
      final block = main.substring(guard, stop);
      expect(block.contains('runApp(const WrongFirebaseProjectScreen())'), isTrue);
      expect(block.contains('Provider'), isFalse);
      expect(block.contains('Firebase'), isTrue); // seulement la constante de code
      expect(block.contains('FirebaseFirestore'), isFalse);
      expect(block.contains('FirebaseAuth'), isFalse);
    });

    test('la vérification porte sur le projet effectif, après initialisation', () {
      expect(main.contains('FirebaseProjectGuard.check()'), isTrue);
      final src = File('lib/services/firebase_project_guard.dart').readAsStringSync();
      expect(src.contains('Firebase.app().options.projectId'), isTrue);
    });
  });
}
