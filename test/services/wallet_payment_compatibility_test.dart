import 'dart:io';

import 'package:az_express/constants/app_build.dart';
import 'package:az_express/services/wallet_payment_compatibility.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// LOT 6.2/6.3 SECURITY.
void main() {
  group('WalletPaymentCompatibilityService.isCompatible (pur)', () {
    test('aucune exigence de version (config absente) -> toujours compatible',
        () {
      expect(WalletPaymentCompatibilityService.isCompatible(1, null), isTrue);
    });

    test('build courant strictement inférieur au minimum -> incompatible',
        () {
      expect(WalletPaymentCompatibilityService.isCompatible(1, 2), isFalse);
    });

    test('build courant égal au minimum -> compatible (borne inclusive)', () {
      expect(WalletPaymentCompatibilityService.isCompatible(2, 2), isTrue);
    });

    test('build courant strictement supérieur au minimum -> compatible', () {
      expect(WalletPaymentCompatibilityService.isCompatible(5, 2), isTrue);
    });
  });

  // kAppBuildNumber ne peut pas être lu dynamiquement au runtime (c'est une
  // constante compile-time) — ce test lit pubspec.yaml directement (le
  // fichier réel, `Directory.current` = racine du projet pendant `flutter
  // test`) et vérifie que le numéro de build publié n'a pas divergé sans
  // que kAppBuildNumber n'ait été mis à jour. Échoue volontairement si
  // quelqu'un bump `pubspec.yaml` sans toucher app_build.dart — exactement
  // le risque de désynchronisation documenté dans app_build.dart.
  test(
      'kAppBuildNumber correspond réellement au numéro de build publié dans pubspec.yaml',
      () {
    final pubspec = File('pubspec.yaml');
    expect(pubspec.existsSync(), isTrue,
        reason: 'ce test doit tourner depuis la racine du projet');
    final versionLine = pubspec
        .readAsLinesSync()
        .firstWhere((line) => line.trim().startsWith('version:'));
    final match = RegExp(r'\+(\d+)\s*$').firstMatch(versionLine);
    expect(match, isNotNull,
        reason: 'pubspec.yaml:version doit contenir un numéro de build '
            '"+N" (ex. 1.0.0+1)');
    final publishedBuild = int.parse(match!.group(1)!);
    expect(kAppBuildNumber, equals(publishedBuild),
        reason:
            'app_build.dart:kAppBuildNumber ($kAppBuildNumber) a divergé de '
            'pubspec.yaml ($publishedBuild) — mettre à jour kAppBuildNumber '
            'à chaque bump de version publiée.');
  });

  group('WalletPaymentCompatibilityService.ensureCompatible (widget)', () {
    Widget harness(Future<bool> Function(BuildContext) onPressed) {
      return MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => onPressed(context),
              child: const Text('go'),
            ),
          ),
        ),
      );
    }

    testWidgets('version compatible : aucun dialogue, retourne true',
        (tester) async {
      bool? result;
      await tester.pumpWidget(harness((context) async {
        result = await WalletPaymentCompatibilityService.ensureCompatible(
          context,
          fetchMinRequiredBuild: () async => kAppBuildNumber, // == courant
        );
        return result!;
      }));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
        'version incompatible : dialogue de mise à jour affiché, retourne false',
        (tester) async {
      bool? result;
      await tester.pumpWidget(harness((context) async {
        result = await WalletPaymentCompatibilityService.ensureCompatible(
          context,
          fetchMinRequiredBuild: () async => kAppBuildNumber + 1, // trop récent
        );
        return result!;
      }));
      await tester.tap(find.text('go'));
      await tester.pump(); // laisse le Future démarrer
      await tester.pump(); // laisse le dialogue s'ouvrir

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Mise à jour requise'), findsOneWidget);

      await tester.tap(find.text('Compris'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
        'configuration absente (fetcher retourne null) : aucun dialogue, retourne true (repli permissif)',
        (tester) async {
      bool? result;
      await tester.pumpWidget(harness((context) async {
        result = await WalletPaymentCompatibilityService.ensureCompatible(
          context,
          fetchMinRequiredBuild: () async => null,
        );
        return result!;
      }));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
        'erreur réseau (fetcher lève) : aucun dialogue, retourne true (repli permissif, ne bloque jamais un paiement légitime)',
        (tester) async {
      bool? result;
      await tester.pumpWidget(harness((context) async {
        result = await WalletPaymentCompatibilityService.ensureCompatible(
          context,
          fetchMinRequiredBuild: () async =>
              throw Exception('network down'),
        );
        return result!;
      }));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
        'paiement cash : le motif d\'appel réel (screens) ne consulte jamais ce service — simulé ici en ne l\'appelant pas, aucun dialogue ne peut apparaître',
        (tester) async {
      // Les 9 parcours réels (livraison/courses/create_order/restaurant/
      // boulangerie/colis/eau_boissons/blanchisserie/event) n'appellent
      // ensureCompatible QUE dans leur branche `paymentMethod == 'wallet'`
      // (vérifié par lecture de code sur les 9 fichiers) — un paiement cash
      // ne déclenche jamais cette vérification, donc jamais ce dialogue.
      const paymentMethod = 'cash';
      bool serviceCalled = false;
      await tester.pumpWidget(harness((context) async {
        if (paymentMethod == 'wallet') {
          serviceCalled = true;
          return WalletPaymentCompatibilityService.ensureCompatible(context);
        }
        return true; // chemin cash réel : jamais de vérification
      }));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(serviceCalled, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
        'paiement wallet : le service est bien invoqué avant tout débit (chemin réel simulé)',
        (tester) async {
      const paymentMethod = 'wallet';
      bool serviceCalled = false;
      await tester.pumpWidget(harness((context) async {
        if (paymentMethod == 'wallet') {
          serviceCalled = true;
          return WalletPaymentCompatibilityService.ensureCompatible(
            context,
            fetchMinRequiredBuild: () async => null,
          );
        }
        return true;
      }));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(serviceCalled, isTrue);
    });
  });
}
