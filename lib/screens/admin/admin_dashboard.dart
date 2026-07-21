import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../services/notification_service.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/glass_kit.dart';
import '../../widgets/logout_confirm_dialog.dart';
import '../home/home_screen.dart';
import 'admin_service_requests_page.dart';
import 'admin_zones_page.dart';
import 'admin_geo_stats_page.dart';
import 'admin_map.dart';
import 'driver_requests_page.dart';
import 'admin_earnings.dart';
import 'admin_orders.dart';
import 'admin_drivers_ranking.dart';
import 'drivers_page.dart';
import 'admin_restaurants_page.dart';
import 'admin_pharmacies_page.dart';
import 'admin_boutique_page.dart';
import 'admin_recharge_page.dart';
import 'admin_fleet_page.dart';
import 'admin_purge_page.dart';
import 'admin_locations_page.dart';
import 'admin_services_page.dart';
import 'admin_simple_services_page.dart';
import 'admin_residences_page.dart';
import 'admin_sos_page.dart';
import 'admin_restaurant_requests_page.dart';
import 'admin_seller_requests_page.dart';
import 'admin_boulangerie_requests_page.dart';
import 'admin_pharmacie_requests_page.dart';
import 'admin_cod_page.dart';
import 'admin_cash_settlement_page.dart';
import 'admin_support_page.dart';
import 'admin_boulangeries_page.dart';
import 'admin_ekbine_page.dart';
import 'admin_sub_admins_page.dart';
import 'admin_commissions_page.dart';
import 'admin_live_tracking_page.dart';
import 'admin_security_dashboard.dart';
import 'admin_ai_dashboard.dart';

class AdminDashboard extends StatefulWidget {
  final Map<String, dynamic> adminData;
  const AdminDashboard({super.key, required this.adminData});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  bool get _isSuper => (widget.adminData['role'] as String?) != 'sub';
  List<String> get _perms =>
      List<String>.from(widget.adminData['permissions'] ?? []);
  bool _has(String key) => _isSuper || _perms.contains(key);

  @override
  void initState() {
    super.initState();
    NotificationService.registerTapHandler((type, orderId, status) {
      if (!mounted) return;
      if (type == 'admin_new_driver') {
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const DriverRequestsPage()));
      } else if (type == 'admin_new_service_provider') {
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminServiceRequestsPage()));
      }
    });
  }

  @override
  void dispose() {
    NotificationService.unregisterTapHandler();
    super.dispose();
  }

  // Master Prompt 135 — bouton Déconnexion manquant sur ce tableau de bord
  // (seul rôle sans aucun point de sortie, contrairement à tous les autres).
  // Même pattern déjà établi ailleurs (confirmation → logAuthEvent → signOut
  // → signInAnonymously → retour HomeScreen) — ne touche à aucune logique
  // métier, ne modifie aucune vérification de rôle déjà faite avant l'accès
  // à cet écran (admin_login.dart).
  void _logout() => showLogoutConfirmDialog(context, onConfirm: _doLogout);

  Future<void> _doLogout() async {
    AuthService().logAuthEvent('logout', 'admin');
    await FirebaseAuth.instance.signOut();
    try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final adminName = (widget.adminData['name'] as String?) ?? '';
    final isSuper   = _isSuper;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CustomScrollView(
        slivers: [
          // ── APP BAR PREMIUM ─────────────────────────────
          SliverAppBar(
            expandedHeight: 170,
            floating:       false,
            pinned:         true,
            backgroundColor: AppColors.primary,
            elevation:       0,
            scrolledUnderElevation: 0,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFFE65100), AppColors.primary, Color(0xFFFF8C42)],
                    begin:  Alignment.topLeft,
                    end:    Alignment.bottomRight,
                    stops:  [0.0, 0.5, 1.0],
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            // Avatar icon
                            Container(
                              padding: const EdgeInsets.all(11),
                              decoration: BoxDecoration(
                                color:        Colors.white.withValues(alpha: 0.18),
                                borderRadius: AppRadius.lgR,
                                border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.3)),
                              ),
                              child: Icon(
                                isSuper
                                    ? Icons.admin_panel_settings_rounded
                                    : Icons.manage_accounts_rounded,
                                color: Colors.white,
                                size:  26,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isSuper
                                      ? 'Administration'
                                      : (adminName.isNotEmpty ? adminName : 'Sous-Admin'),
                                  style: const TextStyle(
                                    color:      Colors.white,
                                    fontSize:   20,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color:        Colors.white.withValues(alpha: 0.2),
                                    borderRadius: AppRadius.pillR,
                                  ),
                                  child: Text(
                                    isSuper
                                        ? 'AZ Express — Super Admin'
                                        : 'AZ Express — Accès limité',
                                    style: TextStyle(
                                      color:    Colors.white.withValues(alpha: 0.92),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: Text(
              isSuper ? 'Admin AZ Express' : 'Tableau de bord',
              style: const TextStyle(
                  color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
            ),
            centerTitle: true,
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                icon: const Icon(Icons.logout_rounded),
                tooltip: 'Déconnexion',
                onPressed: _logout,
              ),
            ],
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isSuper) ...[
                    _StatsRow(),
                    const SizedBox(height: 24),
                  ],

                  Row(
                    children: [
                      const Text(
                        'Gestion',
                        style: TextStyle(
                          fontSize:   20,
                          fontWeight: FontWeight.w700,
                          color:      AppColors.text,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: const BoxDecoration(
                          color:        AppColors.primary10,
                          borderRadius: AppRadius.pillR,
                        ),
                        child: const Text(
                          'AZ Express',
                          style: TextStyle(
                            color:      AppColors.primary,
                            fontSize:   11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  GridView.count(
                    crossAxisCount:    2,
                    shrinkWrap:        true,
                    physics:           const NeverScrollableScrollPhysics(),
                    mainAxisSpacing:   14,
                    crossAxisSpacing:  14,
                    childAspectRatio:  1.22,
                    children: _buildCards(context),
                  ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCards(BuildContext context) {
    Widget go(String title, String subtitle, IconData icon,
            List<Color> gradient, Widget page) =>
        _MenuCard(
          title:    title,
          subtitle: subtitle,
          icon:     icon,
          gradient: gradient,
          onTap:    () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => page)),
        );

    return [
      if (_has('livreurs'))
        go('Livreurs', 'Gérer les comptes', Icons.delivery_dining_rounded,
            const [Color(0xFF1565C0), Color(0xFF1E88E5)], const DriversPage()),
      if (_has('commandes'))
        go('Commandes', 'Historique complet', Icons.receipt_long_rounded,
            const [Color(0xFFE65100), AppColors.primary], const AdminOrders()),
      if (_has('gains'))
        go('Gains', 'Revenus & stats', Icons.bar_chart_rounded,
            const [Color(0xFF1B5E20), Color(0xFF388E3C)], const AdminEarnings()),
      if (_has('gains'))
        go('Commissions', 'Commissions livreurs', Icons.percent_rounded,
            const [Color(0xFF1565C0), Color(0xFF42A5F5)],
            const AdminCommissionsPage()),
      if (_has('classement'))
        go('Classement', 'Top livreurs', Icons.emoji_events_rounded,
            const [Color(0xFF4A148C), Color(0xFF7B1FA2)],
            const AdminDriversRanking()),
      if (_has('carte'))
        go('Carte live', 'Position temps réel', Icons.map_rounded,
            const [Color(0xFF00695C), Color(0xFF00897B)], const AdminMap()),
      if (_has('carte'))
        go('Tracking Live', 'Tous les livreurs', Icons.gps_fixed_rounded,
            const [Color(0xFF0277BD), Color(0xFF0288D1)],
            const AdminLiveTrackingPage()),
      if (_has('zones'))
        go('Zones Géo', 'Quartiers & villages', Icons.add_location_alt_rounded,
            const [Color(0xFF1565C0), Color(0xFF0D47A1)],
            const AdminZonesPage()),
      if (_has('zones'))
        go('Stats Géo', 'Zones & horaires', Icons.bar_chart_rounded,
            const [Color(0xFF1A237E), Color(0xFF3949AB)],
            const AdminGeoStatsPage()),
      if (_has('demandes'))
        go('Demandes', 'Nouveaux livreurs', Icons.person_add_rounded,
            const [Color(0xFFBF360C), Color(0xFFE64A19)],
            const DriverRequestsPage()),
      if (_has('restaurants'))
        go('Restaurants', 'Gérer les menus', Icons.restaurant_rounded,
            const [Color(0xFF1565C0), Color(0xFF1E88E5)],
            const AdminRestaurantsPage()),
      if (_has('demandes_resto'))
        go('Demandes Resto', 'Approuver les restos',
            Icons.store_mall_directory_rounded,
            const [Color(0xFF00695C), Color(0xFF00897B)],
            const AdminRestaurantRequestsPage()),
      if (_has('demandes_vendeurs'))
        go('Demandes Vendeurs', 'Approuver boutiques', Icons.storefront_rounded,
            const [Color(0xFF1565C0), Color(0xFF42A5F5)],
            const AdminSellerRequestsPage()),
      if (_has('demandes_boulangeries'))
        go('Dem. Boulangeries', 'Approuver boulangeries',
            Icons.bakery_dining_rounded,
            const [Color(0xFF4E342E), Color(0xFFA1887F)],
            const AdminBoulangerieRequestsPage()),
      if (_has('demandes_pharmacies'))
        go('Dem. Pharmacies', 'Approuver pharmacies',
            Icons.local_pharmacy_rounded,
            const [Color(0xFFC62828), Color(0xFFEF5350)],
            const AdminPharmacieRequestsPage()),
      if (_has('pharmacies'))
        go('Pharmacies', 'Gardes & horaires', Icons.local_pharmacy_rounded,
            const [Color(0xFFB71C1C), Color(0xFFE53935)],
            const AdminPharmaciesPage()),
      if (_has('boutique'))
        go('Boutique', 'Produits & commandes', Icons.storefront_rounded,
            const [Color(0xFFE65100), AppColors.primary],
            const AdminBoutiquePage()),
      if (_has('recharges'))
        go('Recharges', 'Créditer les wallets',
            Icons.account_balance_wallet_rounded,
            const [Color(0xFF1B5E20), Color(0xFF388E3C)],
            const AdminRechargePage()),
      if (_has('flottes'))
        go('Flottes', 'Approuver les patrons', Icons.motorcycle_rounded,
            const [Color(0xFF4A148C), Color(0xFF8E24AA)],
            const AdminFleetPage()),
      if (_has('locations'))
        go('Locations', 'Maisons à louer', Icons.home_rounded,
            const [Color(0xFF004D40), Color(0xFF00897B)],
            const AdminLocationsPage()),
      if (_has('residences'))
        go('Résidences', 'Meublées & studios', Icons.apartment_rounded,
            const [Color(0xFF4A148C), Color(0xFF7B1FA2)],
            const AdminResidencesPage()),
      if (_has('services'))
        go('Services', 'Artisans & Commerces', Icons.construction_rounded,
            const [Color(0xFF0D47A1), Color(0xFF1976D2)],
            const AdminServicesPage()),
      if (_has('tricycle'))
        go('Tricycle & Taxi', 'Location & Taxi nuit', Icons.local_taxi_rounded,
            const [Color(0xFF263238), Color(0xFF546E7A)],
            const AdminSimpleServicesPage()),
      if (_has('sos'))
        go('Alertes SOS', 'Urgences livreurs', Icons.sos_rounded,
            const [Color(0xFFB71C1C), Color(0xFFE53935)],
            const AdminSosPage()),
      if (_has('anti_fraude'))
        go('Anti-fraude', 'Clients bloqués COD', Icons.gpp_bad_rounded,
            const [Color(0xFFBF360C), AppColors.primary],
            const AdminCodPage()),
      if (_has('cash_marchand'))
        go('Cash à régler', 'Espèces dues aux marchands',
            Icons.payments_rounded,
            const [Color(0xFFC62828), Color(0xFFE53935)],
            const AdminCashSettlementPage()),
      if (_has('support'))
        go('Support & Signalements', 'Tickets clients & abus',
            Icons.support_agent_rounded,
            const [Color(0xFF004D40), Color(0xFF00695C)],
            const AdminSupportPage()),
      if (_has('ai_dashboard'))
        go('Tableau de bord IA', 'Conversations, coût, cache, outils',
            Icons.smart_toy_rounded,
            const [Color(0xFF4527A0), Color(0xFF7E57C2)],
            AdminAiDashboard(isSuper: _isSuper)),
      if (_has('boulangeries'))
        go('Boulangeries', 'Boulangeries & cafés', Icons.bakery_dining_rounded,
            const [Color(0xFF4E342E), Color(0xFF8D6E63)],
            const AdminBoulangeriesPage()),
      if (_has('ekbine'))
        go('Agents E-Kbine', 'Approuver candidatures',
            Icons.sim_card_rounded,
            const [Color(0xFF00695C), Color(0xFF00BFA5)],
            const AdminEkbinePage()),
      if (_has('purger'))
        go('Purger', 'Vider données de test', Icons.delete_sweep_rounded,
            const [Color(0xFF37474F), Color(0xFF546E7A)],
            const AdminPurgePage()),
      if (_isSuper)
        _MenuCard(
          title:    'Gestion Admins',
          subtitle: 'Sous-administrateurs',
          icon:     Icons.manage_accounts_rounded,
          gradient: const [Color(0xFF880E4F), Color(0xFFE91E63)],
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AdminSubAdminsPage()),
          ),
        ),
      if (_isSuper)
        _MenuCard(
          title:    'Sécurité',
          subtitle: 'Audit & monitoring',
          icon:     Icons.security_rounded,
          gradient: const [Color(0xFF1A1A2E), Color(0xFF16213E)],
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AdminSecurityDashboard()),
          ),
        ),
    ];
  }
}

// ── STATS ROW ────────────────────────────────────────────────────────────────

class _StatsRow extends StatefulWidget {
  @override
  State<_StatsRow> createState() => _StatsRowState();
}

class _StatsRowState extends State<_StatsRow> {
  int  _totalOrders  = 0;
  int  _delivered    = 0;
  int  _totalDrivers = 0;
  int  _online       = 0;
  bool _loading      = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final db      = FirebaseFirestore.instance;
      final results = await Future.wait([
        db.collection('orders').count().get(),
        db.collection('orders').where('status', isEqualTo: 'delivered').count().get(),
        db.collection('livreurs').count().get(),
        db.collection('livreurs').where('isOnline', isEqualTo: true).count().get(),
      ]);
      if (!mounted) return;
      setState(() {
        _totalOrders  = results[0].count ?? 0;
        _delivered    = results[1].count ?? 0;
        _totalDrivers = results[2].count ?? 0;
        _online       = results[3].count ?? 0;
        _loading      = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Row(
        children: [
          Expanded(child: AzShimmer(width: double.infinity, height: 80, radius: AppRadius.xl)),
          SizedBox(width: 10),
          Expanded(child: AzShimmer(width: double.infinity, height: 80, radius: AppRadius.xl)),
          SizedBox(width: 10),
          Expanded(child: AzShimmer(width: double.infinity, height: 80, radius: AppRadius.xl)),
        ],
      );
    }
    return Row(
      children: [
        _StatChip(
          value:  '$_totalOrders',
          label:  'Commandes',
          icon:   Icons.shopping_bag_rounded,
          color:  AppColors.primary,
          onTap:  _load,
        ),
        const SizedBox(width: 10),
        _StatChip(
          value:  '$_online/$_totalDrivers',
          label:  'En ligne',
          icon:   Icons.delivery_dining_rounded,
          color:  const Color(0xFF1565C0),
          onTap:  _load,
        ),
        const SizedBox(width: 10),
        _StatChip(
          value:  '$_delivered',
          label:  'Livrées',
          icon:   Icons.check_circle_rounded,
          color:  const Color(0xFF1B5E20),
          onTap:  _load,
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String      value;
  final String      label;
  final IconData    icon;
  final Color       color;
  final VoidCallback? onTap;

  const _StatChip({
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: ScaleTap(
        onTap: onTap,
        child: PremiumCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width:  40,
                height: 40,
                decoration: BoxDecoration(
                  color:        color.withValues(alpha: 0.10),
                  borderRadius: AppRadius.mdR,
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: 8),
              Text(
                value,
                style: TextStyle(
                  color:      color,
                  fontSize:   18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              Text(
                label,
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 11,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── MENU CARD ──────────────────────────────────────────────────────────────

class _MenuCard extends StatelessWidget {
  final String      title;
  final String      subtitle;
  final IconData    icon;
  final List<Color> gradient;
  final VoidCallback onTap;

  const _MenuCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradient,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ScaleTap(
      onTap:     onTap,
      scaleDown: 0.94,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: gradient,
            begin:  Alignment.topLeft,
            end:    Alignment.bottomRight,
          ),
          borderRadius: AppRadius.xlR,
          boxShadow: [
            BoxShadow(
              color:      gradient.first.withValues(alpha: 0.32),
              blurRadius: 16,
              offset:     const Offset(0, 6),
              spreadRadius: 0,
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:  CrossAxisAlignment.start,
          mainAxisAlignment:   MainAxisAlignment.spaceBetween,
          children: [
            // Icône dans un carré semi-transparent
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color:        Colors.white.withValues(alpha: 0.2),
                borderRadius: AppRadius.mdR,
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.25), width: 0.8),
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color:      Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize:   14,
                    letterSpacing: -0.1,
                  ),
                  maxLines:  1,
                  overflow:  TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color:    Colors.white.withValues(alpha: 0.72),
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
