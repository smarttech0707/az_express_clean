import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/ekbine/models/ek_agent.dart';
import 'package:az_express/ekbine/models/ek_deposit_account.dart';
import 'package:az_express/ekbine/utils/ek_deposit_accounts_logic.dart';
import 'package:az_express/ekbine/widgets/ek_deposit_account_dialog.dart';

// Tests ciblés — Mission "FINALISATION ET VALIDATION DU MODULE MULTI-NUMÉROS
// E-KBINE", Mission 6. La logique de fusion/validation a été extraite dans
// EkDepositAccountsLogic (utilisée réellement par ek_agent_register.dart et
// ek_deposit_accounts_screen.dart) précisément pour rester testable sans
// Firebase — ces tests exercent donc le même code que l'application réelle,
// pas une réimplémentation parallèle.

EkDepositAccount account({
  required String id,
  required String operator,
  required String phoneNumber,
  String? label,
  bool isPrimary = false,
  bool isActive = true,
}) =>
    EkDepositAccount(
      id: id,
      operator: operator,
      phoneNumber: phoneNumber,
      label: label,
      isPrimary: isPrimary,
      isActive: isActive,
    );

void main() {
  group('1. Inscription avec un seul numéro', () {
    test('un compte orange principal suffit à couvrir orange', () {
      final accounts = EkDepositAccountsLogic.merge(
        [],
        account(
            id: 'a1',
            operator: 'orange',
            phoneNumber: '07000000',
            isPrimary: true),
      );
      expect(accounts.length, 1);
      expect(EkDepositAccountsLogic.coveredOperators(accounts), ['orange']);
      expect(EkDepositAccountsLogic.hasActiveAccount(accounts), true);
    });
  });

  group('2. Inscription avec plusieurs numéros Orange', () {
    test('deux numéros orange distincts coexistent, un seul opérateur couvert',
        () {
      var accounts = EkDepositAccountsLogic.merge(
        [],
        account(
            id: 'a1',
            operator: 'orange',
            phoneNumber: '07000001',
            isPrimary: true),
      );
      accounts = EkDepositAccountsLogic.merge(
        accounts,
        account(id: 'a2', operator: 'orange', phoneNumber: '07000002'),
      );
      expect(accounts.length, 2);
      expect(accounts.where((a) => a.operator == 'orange').length, 2);
      expect(EkDepositAccountsLogic.coveredOperators(accounts), ['orange']);
    });
  });

  group('3. Inscription avec plusieurs opérateurs', () {
    test('orange + mtn + wave couvrent 3 opérateurs distincts', () {
      var accounts = <EkDepositAccount>[];
      accounts = EkDepositAccountsLogic.merge(
          accounts,
          account(
              id: 'a1',
              operator: 'orange',
              phoneNumber: '07000001',
              isPrimary: true));
      accounts = EkDepositAccountsLogic.merge(
          accounts,
          account(
              id: 'a2',
              operator: 'mtn',
              phoneNumber: '05000001',
              isPrimary: true));
      accounts = EkDepositAccountsLogic.merge(
          accounts,
          account(
              id: 'a3',
              operator: 'wave',
              phoneNumber: '07777777',
              isPrimary: true));
      expect(accounts.length, 3);
      expect(
        EkDepositAccountsLogic.coveredOperators(accounts).toSet(),
        {'orange', 'mtn', 'wave'},
      );
    });
  });

  group('4. Changement de principal', () {
    test(
        'marquer une nouvelle ligne principale rétrograde l\'ancienne (même opérateur)',
        () {
      var accounts = EkDepositAccountsLogic.merge(
        [],
        account(
            id: 'old',
            operator: 'orange',
            phoneNumber: '07000001',
            isPrimary: true),
      );
      accounts = EkDepositAccountsLogic.merge(
        accounts,
        account(
            id: 'new',
            operator: 'orange',
            phoneNumber: '07000002',
            isPrimary: true),
      );
      final old = accounts.firstWhere((a) => a.id == 'old');
      final newAcc = accounts.firstWhere((a) => a.id == 'new');
      expect(old.isPrimary, false);
      expect(newAcc.isPrimary, true);
    });
  });

  group('5. Refus de deux principaux actifs', () {
    test(
        'après plusieurs changements de principal, jamais deux principaux simultanés pour un même opérateur',
        () {
      var accounts = <EkDepositAccount>[];
      accounts = EkDepositAccountsLogic.merge(
          accounts,
          account(
              id: 'a1',
              operator: 'orange',
              phoneNumber: '07000001',
              isPrimary: true));
      accounts = EkDepositAccountsLogic.merge(
          accounts,
          account(
              id: 'a2',
              operator: 'orange',
              phoneNumber: '07000002',
              isPrimary: true));
      accounts = EkDepositAccountsLogic.merge(
          accounts,
          account(
              id: 'a3',
              operator: 'orange',
              phoneNumber: '07000003',
              isPrimary: true));
      final primaries =
          accounts.where((a) => a.operator == 'orange' && a.isPrimary);
      expect(primaries.length, 1,
          reason: 'un seul principal actif par opérateur, jamais deux');
      expect(primaries.first.id, 'a3');
    });

    test(
        'deux opérateurs différents peuvent chacun avoir leur propre principal',
        () {
      var accounts = <EkDepositAccount>[];
      accounts = EkDepositAccountsLogic.merge(
          accounts,
          account(
              id: 'a1',
              operator: 'orange',
              phoneNumber: '07000001',
              isPrimary: true));
      accounts = EkDepositAccountsLogic.merge(
          accounts,
          account(
              id: 'a2',
              operator: 'mtn',
              phoneNumber: '05000001',
              isPrimary: true));
      expect(accounts.where((a) => a.isPrimary).length, 2);
    });
  });

  group('6. Refus d\'un doublon', () {
    test('même opérateur + même numéro (normalisé) → doublon détecté', () {
      final current = [
        account(
            id: 'a1',
            operator: 'orange',
            phoneNumber: '0700000001',
            isPrimary: true)
      ];
      final incoming =
          account(id: 'a2', operator: 'orange', phoneNumber: '0700000001');
      expect(EkDepositAccountsLogic.isDuplicate(current, incoming), true);
    });

    test('même numéro mais opérateur différent → pas un doublon', () {
      final current = [
        account(
            id: 'a1',
            operator: 'orange',
            phoneNumber: '0700000001',
            isPrimary: true)
      ];
      final incoming =
          account(id: 'a2', operator: 'mtn', phoneNumber: '0700000001');
      expect(EkDepositAccountsLogic.isDuplicate(current, incoming), false);
    });

    test(
        'modifier une ligne existante (même id) n\'est jamais un faux doublon avec elle-même',
        () {
      final current = [
        account(
            id: 'a1',
            operator: 'orange',
            phoneNumber: '0700000001',
            isPrimary: true)
      ];
      final incoming = account(
          id: 'a1',
          operator: 'orange',
          phoneNumber: '0700000001',
          label: 'Renommé');
      expect(EkDepositAccountsLogic.isDuplicate(current, incoming), false);
    });
  });

  group('7/8. Confirmation de suppression', () {
    testWidgets('7. suppression confirmée : "Supprimer" renvoie true',
        (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) {
            return ElevatedButton(
              onPressed: () async {
                result = await showEkDeleteAccountConfirmDialog(
                  context,
                  account(
                      id: 'a1', operator: 'orange', phoneNumber: '0700000001'),
                  operatorLabel: 'Orange',
                );
              },
              child: const Text('Supprimer'),
            );
          }),
        ),
      ));
      await tester.tap(find.text('Supprimer').first);
      await tester.pumpAndSettle();
      // Le dialogue est affiché : un bouton "Supprimer" additionnel apparaît dedans.
      expect(find.text('Supprimer ce numéro ?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Supprimer'));
      await tester.pumpAndSettle();
      expect(result, true);
      expect(find.text('Supprimer ce numéro ?'), findsNothing);
    });

    testWidgets(
        '8. suppression annulée : "Annuler" renvoie false, rien n\'est supprimé',
        (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) {
            return ElevatedButton(
              onPressed: () async {
                result = await showEkDeleteAccountConfirmDialog(
                  context,
                  account(
                      id: 'a1', operator: 'orange', phoneNumber: '0700000001'),
                  operatorLabel: 'Orange',
                );
              },
              child: const Text('Ouvrir'),
            );
          }),
        ),
      ));
      await tester.tap(find.text('Ouvrir'));
      await tester.pumpAndSettle();
      expect(find.text('Supprimer ce numéro ?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Annuler'));
      await tester.pumpAndSettle();
      expect(result, false);
      expect(find.text('Supprimer ce numéro ?'), findsNothing);
    });
  });

  group('9. Sauvegarde puis rechargement', () {
    test(
        'toMap() puis fromMap() (après résolution serveur des timestamps) restaure les mêmes données',
        () {
      final original = account(
        id: 'a1',
        operator: 'wave',
        phoneNumber: '0798765432',
        label: 'Boutique principale',
        isPrimary: true,
        isActive: true,
      ).copyWith(); // createdAt reste null dans ce test, comme à la création réelle
      final saved = original.toMap();
      // Simule la résolution côté serveur des FieldValue.serverTimestamp()
      // (jamais une vraie valeur avant que Firestore ne le fasse) — un
      // "rechargement" réaliste relit toujours de vrais Timestamp, jamais
      // le sentinel FieldValue brut.
      final reloaded = {
        ...saved,
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
      };
      final restored =
          EkDepositAccount.fromMap(Map<String, dynamic>.from(reloaded));
      expect(restored.operator, original.operator);
      expect(restored.phoneNumber, original.phoneNumber);
      expect(restored.label, original.label);
      expect(restored.isPrimary, original.isPrimary);
      expect(restored.isActive, original.isActive);
    });

    test('une liste complète survit à un cycle sauvegarde/rechargement', () {
      final accounts = [
        account(
            id: 'a1',
            operator: 'orange',
            phoneNumber: '0700000001',
            isPrimary: true),
        account(
            id: 'a2',
            operator: 'mtn',
            phoneNumber: '0500000002',
            isActive: false),
      ];
      final savedMaps = accounts
          .map((a) => {
                ...a.toMap(),
                'createdAt': Timestamp.now(),
                'updatedAt': Timestamp.now(),
              })
          .toList();
      final restored = savedMaps
          .map((m) => EkDepositAccount.fromMap(Map<String, dynamic>.from(m)))
          .toList();
      expect(restored.length, 2);
      expect(restored[0].operator, 'orange');
      expect(restored[1].isActive, false);
    });
  });

  group('10. Migration operatorNumbers vers depositAccounts', () {
    test(
        'un agent legacy (operatorNumbers seul, depositAccounts vide) obtient un compte de repli synthétisé',
        () {
      final agent = EkAgent(
        id: 'a1',
        name: 'Agent Legacy',
        phone: '0700000000',
        operatorNumbers: const {'orange': '0711111111'},
        depositAccounts: const [],
      );
      final accounts = agent.accountsFor('orange');
      expect(accounts.length, 1);
      expect(accounts.first.id, 'legacy_orange');
      expect(accounts.first.phoneNumber, '0711111111');
      expect(accounts.first.isPrimary, true);
    });

    test(
        'un agent déjà migré (depositAccounts non vide) ignore operatorNumbers pour cet opérateur',
        () {
      final agent = EkAgent(
        id: 'a1', name: 'Agent Migré', phone: '0700000000',
        operatorNumbers: const {
          'orange': '0799999999'
        }, // ancienne valeur, ne doit plus être utilisée
        depositAccounts: [
          account(
              id: 'acc1',
              operator: 'orange',
              phoneNumber: '0722222222',
              isPrimary: true,
              isActive: true),
        ],
      );
      final accounts = agent.accountsFor('orange');
      expect(accounts.length, 1);
      expect(accounts.first.phoneNumber, '0722222222');
    });

    test('un agent legacy sans numéro pour un opérateur donné ne renvoie rien',
        () {
      final agent = EkAgent(
        id: 'a1',
        name: 'Agent Legacy',
        phone: '0700000000',
        operatorNumbers: const {'orange': '0711111111'},
        depositAccounts: const [],
      );
      expect(agent.accountsFor('mtn'), isEmpty);
    });
  });
}
