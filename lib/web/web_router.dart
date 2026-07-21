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

final webRouter = GoRouter(
  initialLocation: '/',
  refreshListenable: _MultiListenable([
    AdminAuthService.instance,
    WebClientAuth.instance,
  ]),
  redirect: (context, state) {
    final loc          = state.matchedLocation;
    final isAdminRoute = loc.startsWith('/admin');
    final isLoginRoute = loc == '/admin/login';
    final isClientApp  = loc.startsWith('/app');
    final isClientLogin = loc == '/connexion';
    final isAdmin      = AdminAuthService.instance.isAdmin;
    final isClient     = WebClientAuth.instance.isLoggedIn;

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
    GoRoute(path: '/',                   builder: (_, __) => const WebHomePage()),
    GoRoute(path: '/services',           builder: (_, __) => const WebServicesPage()),
    GoRoute(path: '/comment-ca-marche',  builder: (_, __) => const WebHowItWorksPage()),
    GoRoute(path: '/commercants',        builder: (_, __) => const WebMerchantsPage()),
    GoRoute(path: '/livreurs',           builder: (_, __) => const WebDriversPage()),
    GoRoute(path: '/contact',            builder: (_, __) => const WebContactPage()),
    GoRoute(path: '/a-propos',           builder: (_, __) => const WebAboutPage()),
    GoRoute(path: '/confidentialite',    builder: (_, __) => const WebPrivacyPage()),
    GoRoute(path: '/conditions',         builder: (_, __) => const WebTermsPage()),
    GoRoute(path: '/delete-account',     builder: (_, __) => const WebDeleteAccountPage()),

    // ── Auth client ───────────────────────────────────────────────────────────
    GoRoute(path: '/connexion',          builder: (_, __) => const WebClientLoginPage()),

    // ── App client (protégée) ─────────────────────────────────────────────────
    GoRoute(path: '/app',                builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/commander',      builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/restaurants',    builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/boulangeries',   builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/pharmacies',     builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/ekbine',         builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/boutique',       builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/eau',            builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/blanchisserie',  builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/artisans',       builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/residences',     builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/locations',      builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/colis',          builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/recharge',       builder: (_, __) => const WebClientDashboard()),
    GoRoute(path: '/app/retrait',        builder: (_, __) => const WebClientDashboard()),

    // ── Pages admin (protégées) ───────────────────────────────────────────────
    GoRoute(path: '/admin',              redirect: (_, __) => '/admin/login'),
    GoRoute(path: '/admin/login',        builder: (_, __) => const WebAdminLoginPage()),
    GoRoute(path: '/admin/dashboard',    builder: (_, __) => const WebAdminDashboard()),
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
