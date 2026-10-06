import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'admin_auth_service.dart';
import 'web_client_auth.dart';
import 'pages/home_page.dart';
import 'pages/services_page.dart';
import 'pages/how_it_works_page.dart';
import 'pages/merchants_page.dart';
import 'pages/drivers_page.dart';
import 'pages/contact_page.dart';
import 'pages/about_page.dart';
import 'pages/privacy_page.dart';
import 'pages/terms_page.dart';
import 'pages/delete_account_page.dart';
import 'pages/admin/web_admin_login.dart';
import 'pages/admin/web_admin_dashboard.dart';
import 'pages/client/web_client_login.dart';
import 'pages/client/web_client_dashboard.dart';

/// Toutes les routes de l'espace client web.
///
/// Deux familles distinctes, volontairement regroupées ici pour qu'aucune
/// route ne puisse exister sans que le dashboard sache quoi en faire :
///   - les SECTIONS (`clientSectionTabs`), chacune adossée à une vraie page ;
///   - les routes de SERVICE, qui n'ont aujourd'hui aucune page web (voir
///     `WebClientDashboard` : elles affichent un état explicite au lieu de
///     ramener silencieusement l'utilisateur à l'accueil).
const clientAppRoutes = <String>[
  // Sections réelles
  '/app',
  '/app/commandes',
  '/app/wallet',
  '/app/profil',
  // Services sans page web dédiée
  '/app/commander',
  '/app/restaurants',
  '/app/boulangeries',
  '/app/pharmacies',
  '/app/ekbine',
  '/app/boutique',
  '/app/eau',
  '/app/blanchisserie',
  '/app/artisans',
  '/app/residences',
  '/app/locations',
  '/app/colis',
  '/app/recharge',
  '/app/retrait',
];

final webRouter = GoRouter(
  initialLocation: '/',
  refreshListenable: _MultiListenable([
    AdminAuthService.instance,
    WebClientAuth.instance,
  ]),
  redirect: (context, state) {
    final loc = state.matchedLocation;
    final isAdminRoute = loc.startsWith('/admin');
    final isLoginRoute = loc == '/admin/login';
    final isClientApp = loc.startsWith('/app');
    final isClientLogin = loc == '/connexion';
    final isAdmin = AdminAuthService.instance.isAdmin;
    final isClient = WebClientAuth.instance.isLoggedIn;

    // Admin routes
    if (isAdminRoute && !isLoginRoute && !isAdmin) return '/admin/login';
    if (isLoginRoute && isAdmin) return '/admin/dashboard';

    // Client app routes
    if (isClientApp && !isClient) return '/connexion';
    if (isClientLogin && isClient) return '/app';

    return null;
  },
  errorBuilder: (_, state) => const WebHomePage(),
  routes: [
    // ── Pages publiques ───────────────────────────────────────────────────────
    GoRoute(path: '/', builder: (_, __) => const WebHomePage()),
    GoRoute(path: '/services', builder: (_, __) => const WebServicesPage()),
    GoRoute(
        path: '/comment-ca-marche',
        builder: (_, __) => const WebHowItWorksPage()),
    GoRoute(path: '/commercants', builder: (_, __) => const WebMerchantsPage()),
    GoRoute(path: '/livreurs', builder: (_, __) => const WebDriversPage()),
    GoRoute(path: '/contact', builder: (_, __) => const WebContactPage()),
    GoRoute(path: '/a-propos', builder: (_, __) => const WebAboutPage()),
    GoRoute(
        path: '/confidentialite', builder: (_, __) => const WebPrivacyPage()),
    GoRoute(path: '/conditions', builder: (_, __) => const WebTermsPage()),
    GoRoute(
        path: '/delete-account',
        builder: (_, __) => const WebDeleteAccountPage()),

    // ── Auth client ───────────────────────────────────────────────────────────
    GoRoute(path: '/connexion', builder: (_, __) => const WebClientLoginPage()),

    // ── App client (protégée) ─────────────────────────────────────────────────
    //
    // BUG CORRIGÉ : ces routes construisaient toutes `const
    // WebClientDashboard()` SANS lui transmettre la route demandée. Un clic
    // sur une carte changeait donc l'URL, go_router reconstruisait… le même
    // widget, dont l'onglet interne (`_tab`) repartait à 0 — l'utilisateur
    // était ramené à l'accueil. Chaque route passe maintenant sa localisation
    // au dashboard, qui en dérive ce qu'il affiche.
    //
    // `clientAppRoutes` est la liste unique : elle alimente les GoRoute ET la
    // table de sections du dashboard, qui ne peuvent donc plus diverger.
    for (final path in clientAppRoutes)
      GoRoute(
        path: path,
        builder: (_, state) =>
            WebClientDashboard(location: state.matchedLocation),
      ),

    // ── Pages admin (protégées) ───────────────────────────────────────────────
    GoRoute(path: '/admin', redirect: (_, __) => '/admin/login'),
    GoRoute(
        path: '/admin/login', builder: (_, __) => const WebAdminLoginPage()),
    GoRoute(
        path: '/admin/dashboard',
        builder: (_, __) => const WebAdminDashboard()),
  ],
);

/// ChangeNotifier combiné pour que go_router réagisse à plusieurs sources.
class _MultiListenable extends ChangeNotifier {
  final List<ChangeNotifier> _notifiers;

  _MultiListenable(this._notifiers) {
    for (final n in _notifiers) {
      n.addListener(notifyListeners);
    }
  }

  @override
  void dispose() {
    for (final n in _notifiers) {
      n.removeListener(notifyListeners);
    }
    super.dispose();
  }
}
