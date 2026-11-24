import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/web/pages/admin/admin_office_shell.dart';
import 'package:az_express/web/admin_auth_service.dart';

/// Phase 1 — Fondations du Bureau Web (sidebar, navigation, sections).
///
/// Tests purs sur la structure de navigation, sans Firebase ni montage de
/// widget : la sidebar elle-même (`officeSidebarSections`) et la restriction
/// d'accès (`isWebSuperAdmin`) sont des données/fonctions publiques
/// indépendantes de Firestore.
void main() {
  group('1. Les 9 sections demandées, dans l\'ordre exact', () {
    test('ids et ordre conformes à la mission Phase 1', () {
      expect(
        officeSidebarSections.map((s) => s.id).toList(),
        [
          'dashboard',
          'orders',
          'drivers',
          'partners',
          'requests',
          'finance',
          'services',
          'employees',
          'security',
        ],
      );
    });

    test('exactement 9 sections, aucune de plus', () {
      expect(officeSidebarSections.length, 9);
    });
  });

  group('2. Disponibilité honnête : seules les sections avec un vrai '
      'contenu sont marquées disponibles', () {
    test(
        'dashboard, orders, requests, services, security, employees = '
        'disponibles', () {
      for (final id in [
        'dashboard',
        'orders',
        'requests',
        'services',
        'security',
        'employees', // Phase 2 : gestion des employés/sous-admins.
      ]) {
        expect(officeSectionById(id).available, isTrue, reason: id);
      }
    });

    test('drivers, partners, finance = en préparation', () {
      for (final id in ['drivers', 'partners', 'finance']) {
        expect(officeSectionById(id).available, isFalse, reason: id);
      }
    });
  });

  group('3. officeSectionById', () {
    test('retrouve chaque section par son id', () {
      for (final s in officeSidebarSections) {
        expect(officeSectionById(s.id).id, s.id);
      }
    });

    test('un id inconnu ne lève jamais d\'exception (repli sur la première section)',
        () {
      expect(() => officeSectionById('inexistant'), returnsNormally);
      expect(officeSectionById('inexistant').id, officeSidebarSections.first.id);
    });
  });

  group('4. Non-régression : la restriction d\'accès Web existante est '
      'inchangée par la Phase 1', () {
    test('un compte super passe', () {
      expect(isWebSuperAdmin({'role': 'super'}), isTrue);
    });

    test('un sous-admin ne passe toujours pas (inchangé, hors périmètre '
        'Phase 1)', () {
      expect(isWebSuperAdmin({'role': 'sub'}), isFalse);
    });

    test('un enregistrement nul ne passe pas', () {
      expect(isWebSuperAdmin(null), isFalse);
    });
  });
}
