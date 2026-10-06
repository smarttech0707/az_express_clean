import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/web/web_router.dart';
import 'package:az_express/web/pages/client/web_client_dashboard.dart';

/// Navigation de l'espace client Web.
///
/// Tests purs sur la table de routes et la table de sections : aucun réseau,
/// aucun Firebase, aucun montage de widget (le dashboard lit Firestore et le
/// routeur construit les singletons d'authentification).
///
/// La règle de redirection est reproduite à l'identique pour être vérifiée
/// sans instancier `GoRouter` — toute divergence future entre cette copie et
/// `web_router.dart` serait un vrai écart à corriger dans les deux.
String? redirectFor(String loc, {required bool isClient, bool isAdmin = false}) {
  final isAdminRoute = loc.startsWith('/admin');
  final isLoginRoute = loc == '/admin/login';
  final isClientApp = loc.startsWith('/app');
  final isClientLogin = loc == '/connexion';
  if (isAdminRoute && !isLoginRoute && !isAdmin) return '/admin/login';
  if (isLoginRoute && isAdmin) return '/admin/dashboard';
  if (isClientApp && !isClient) return '/connexion';
  if (isClientLogin && isClient) return '/app';
  return null;
}

void main() {
  group('1. Client NON connecté : toute route privée renvoie à /connexion', () {
    test('chacune des routes /app* est protégée', () {
      for (final path in clientAppRoutes) {
        expect(redirectFor(path, isClient: false), '/connexion',
            reason: '$path doit être protégée');
      }
    });

    test('les pages publiques restent accessibles sans connexion', () {
      for (final path in ['/', '/confidentialite', '/delete-account',
        '/conditions', '/contact', '/connexion']) {
        expect(redirectFor(path, isClient: false), isNull,
            reason: '$path doit rester public');
      }
    });
  });

  group('2-3. Client connecté : AUCUNE route privée ne retombe sur /app', () {
    test('aucune redirection sur les routes /app*', () {
      for (final path in clientAppRoutes) {
        expect(redirectFor(path, isClient: true), isNull,
            reason: '$path ne doit pas être redirigée');
      }
    });

    test('/connexion renvoie bien au dashboard quand déjà connecté', () {
      expect(redirectFor('/connexion', isClient: true), '/app');
    });

    test('la protection admin reste intacte pour un client', () {
      expect(redirectFor('/admin/dashboard', isClient: true), '/admin/login');
    });
  });

  group('4. Chaque route déclarée mène à une destination définie', () {
    test('les 4 sections réelles sont toutes déclarées comme routes', () {
      for (final section in clientSectionTabs.keys) {
        expect(clientAppRoutes, contains(section),
            reason: '$section doit exister comme GoRoute');
      }
    });

    test('les 4 onglets sont distincts et couvrent 0..3', () {
      expect(clientSectionTabs.values.toSet(), {0, 1, 2, 3});
    });

    test('clientPathForTab est l\'inverse exact de clientSectionTabs', () {
      for (final entry in clientSectionTabs.entries) {
        expect(clientPathForTab(entry.value), entry.key);
      }
    });

    test('un onglet inconnu retombe sur l\'accueil, jamais sur une URL vide',
        () {
      expect(clientPathForTab(99), '/app');
      expect(clientPathForTab(-1), '/app');
    });
  });

  group('5. Toutes les cibles des boutons du dashboard sont déclarées', () {
    test('les 12 cartes de service pointent vers une route existante', () {
      // C'était le cœur du bug : les cartes naviguaient vers des routes qui
      // reconstruisaient le même dashboard sans savoir quoi afficher.
      for (final service in clientServiceRoutes) {
        expect(clientAppRoutes, contains(service),
            reason: '$service est la cible d\'une carte du dashboard');
      }
      expect(clientServiceRoutes.length, 12);
    });

    test('les 2 actions du wallet pointent vers une route existante', () {
      for (final path in ['/app/recharge', '/app/retrait']) {
        expect(clientAppRoutes, contains(path));
      }
    });
  });

  group('6. Aucune boucle de redirection possible', () {
    test('la cible d\'une redirection n\'est jamais elle-même redirigée', () {
      final cases = <(String, bool, bool)>[
        ('/app', false, false),
        ('/app/wallet', false, false),
        ('/connexion', true, false),
        ('/admin/dashboard', false, false),
        ('/admin/login', false, true),
      ];
      for (final (loc, isClient, isAdmin) in cases) {
        final first = redirectFor(loc, isClient: isClient, isAdmin: isAdmin);
        expect(first, isNotNull, reason: '$loc devait être redirigée');
        // Un second passage sur la destination ne doit plus rien redirger.
        final second =
            redirectFor(first!, isClient: isClient, isAdmin: isAdmin);
        expect(second, isNull,
            reason: '$loc -> $first -> $second : boucle de redirection');
      }
    });

    test('un état stable ne produit aucune redirection', () {
      expect(redirectFor('/app', isClient: true), isNull);
      expect(redirectFor('/connexion', isClient: false), isNull);
      expect(redirectFor('/admin/login', isClient: false), isNull);
      expect(redirectFor('/admin/dashboard', isAdmin: true, isClient: false),
          isNull);
    });
  });

  group('Séparation sections / services sans page', () {
    test('toute route /app* est soit une section, soit un service annoncé', () {
      const walletActions = {'/app/recharge', '/app/retrait'};
      for (final path in clientAppRoutes) {
        final isSection = clientSectionTabs.containsKey(path);
        final isService = clientServiceRoutes.contains(path) ||
            walletActions.contains(path);
        expect(isSection || isService, isTrue,
            reason: '$path n\'est ni une section ni un service connu — le '
                'dashboard ne saurait pas quoi afficher');
        expect(isSection && isService, isFalse,
            reason: '$path ne peut pas être les deux à la fois');
      }
    });
  });
}
