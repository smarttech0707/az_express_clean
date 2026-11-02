import 'package:flutter/material.dart';

import '../../event/screens/admin_event_screen.dart';
import '../../partner_qr/partner_qr_page.dart';
import '../../theme/app_theme.dart';
import 'account_deletion_support_page.dart';
import 'admin_ai_dashboard.dart';
import 'admin_billing_reviews_page.dart';
import 'admin_disputes_page.dart';
import 'admin_stuck_alerts_page.dart';
import 'admin_boulangerie_requests_page.dart';
import 'admin_boulangeries_page.dart';
import 'admin_boutique_page.dart';
import 'admin_cash_settlement_page.dart';
import 'admin_cod_page.dart';
import 'admin_commissions_page.dart';
import 'admin_drivers_ranking.dart';
import 'admin_earnings.dart';
import 'admin_ekbine_page.dart';
import 'admin_fleet_page.dart';
import 'admin_geo_stats_page.dart';
import 'admin_live_tracking_page.dart';
import 'admin_locations_page.dart';
import 'admin_map.dart';
import 'admin_orders.dart';
import 'admin_pharmacie_requests_page.dart';
import 'admin_pharmacies_page.dart';
import 'admin_purge_page.dart';
import 'admin_recharge_page.dart';
import 'admin_residences_page.dart';
import 'admin_restaurant_requests_page.dart';
import 'admin_restaurants_page.dart';
import 'admin_reviews_page.dart';
import 'admin_security_dashboard.dart';
import 'admin_seller_requests_page.dart';
import 'admin_service_requests_page.dart';
import 'admin_services_page.dart';
import 'admin_simple_services_page.dart';
import 'admin_sos_page.dart';
import 'admin_sub_admins_page.dart';
import 'admin_support_page.dart';
import 'admin_transfer_settlements_page.dart';
import 'admin_vehicle_moderation_page.dart';
import 'admin_zones_page.dart';
import 'drivers_page.dart';
import 'driver_requests_page.dart';

/// Rattachement des écrans « Litiges de livraison » et « Commandes bloquées ».
/// Reste à `false` tant que `adminOrderDisputeCF` et `adminConfirmDeliveryCF` ne sont pas déployées et
/// vérifiées (docs/ORDER_RELIABILITY_DEPLOYMENT_PLAN.md, lot C) : sans elles, les écrans n'afficheraient
/// qu'une erreur. Passer à `true` fait partie de la publication de la version admin, pas avant.
const bool kShowOrderDisputeScreens = false;

/// Une entrée du menu administrateur. Les pages et leurs clés de permission
/// sont celles de l'ancienne grille : seule l'organisation change.
class AdminMenuItem {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget Function() page;

  const AdminMenuItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.page,
  });
}

class AdminMenuCategory {
  final String id;
  final String title;
  final IconData icon;
  final List<AdminMenuItem> items;

  const AdminMenuCategory({
    required this.id,
    required this.title,
    required this.icon,
    required this.items,
  });
}

/// Catégories visibles pour ce profil. Les entrées sont filtrées exactement
/// comme avant (`super` = tout ; sinon la clé doit figurer dans `permissions`),
/// et une catégorie sans entrée visible disparaît.
///
/// Ce filtre n'est qu'un confort d'affichage : la vraie protection reste
/// côté serveur (règles Firestore et Cloud Functions).
@visibleForTesting
List<AdminMenuCategory> buildAdminMenu({
  required bool isSuper,
  required List<String> permissions,
  bool showOrderDisputes = kShowOrderDisputeScreens,
}) {
  bool has(String key) => isSuper || permissions.contains(key);

  // `perm` : clé de permission ; `superOnly` : réservé au super-admin.
  List<AdminMenuItem> pick(List<(AdminMenuItem, String?)> entries) => [
        for (final (item, perm) in entries)
          if (perm == null ? isSuper : has(perm)) item,
      ];

  final categories = [
    AdminMenuCategory(
      id: 'stats',
      title: 'Tableau de bord et statistiques',
      icon: Icons.insights_rounded,
      items: pick([
        (
          AdminMenuItem(
            id: 'geo_stats',
            title: 'Stats Géo',
            subtitle: 'Zones & horaires',
            icon: Icons.insights_rounded,
            page: () => const AdminGeoStatsPage(),
          ),
          'zones'
        ),
        (
          AdminMenuItem(
            id: 'ranking',
            title: 'Classement',
            subtitle: 'Top livreurs',
            icon: Icons.emoji_events_rounded,
            page: () => const AdminDriversRanking(),
          ),
          'classement'
        ),
        (
          AdminMenuItem(
            id: 'reviews',
            title: 'Avis partenaires',
            subtitle: 'Notes et commentaires clients',
            icon: Icons.reviews_rounded,
            page: () => const AdminReviewsPage(),
          ),
          'support'
        ),
        (
          AdminMenuItem(
            id: 'ai',
            title: 'Tableau de bord IA',
            subtitle: 'Conversations, coût, cache, outils',
            icon: Icons.smart_toy_rounded,
            page: () => AdminAiDashboard(isSuper: isSuper),
          ),
          'ai_dashboard'
        ),
      ]),
    ),
    AdminMenuCategory(
      id: 'orders',
      title: 'Commandes et livraisons',
      icon: Icons.receipt_long_rounded,
      items: pick([
        (
          AdminMenuItem(
            id: 'orders',
            title: 'Commandes',
            subtitle: 'Historique complet',
            icon: Icons.list_alt_rounded,
            page: () => const AdminOrders(),
          ),
          'commandes'
        ),
        (
          AdminMenuItem(
            id: 'live_map',
            title: 'Carte live',
            subtitle: 'Livreurs et commandes en cours sur la carte',
            icon: Icons.map_rounded,
            page: () => const AdminMap(),
          ),
          'carte'
        ),
        (
          AdminMenuItem(
            id: 'live_tracking',
            title: 'Tracking Live',
            subtitle: 'État GPS de tous les livreurs',
            icon: Icons.gps_fixed_rounded,
            page: () => const AdminLiveTrackingPage(),
          ),
          'carte'
        ),
        (
          AdminMenuItem(
            id: 'zones',
            title: 'Zones Géo',
            subtitle: 'Quartiers & villages',
            icon: Icons.add_location_alt_rounded,
            page: () => const AdminZonesPage(),
          ),
          'zones'
        ),
        (
          AdminMenuItem(
            id: 'sos',
            title: 'Alertes SOS',
            subtitle: 'Urgences livreurs',
            icon: Icons.sos_rounded,
            page: () => const AdminSosPage(),
          ),
          'sos'
        ),
        (
          AdminMenuItem(
            id: 'antifraud',
            title: 'Anti-fraude',
            subtitle: 'Clients bloqués COD',
            icon: Icons.gpp_bad_rounded,
            page: () => const AdminCodPage(),
          ),
          'anti_fraude'
        ),
      ]),
    ),
    AdminMenuCategory(
      id: 'drivers',
      title: 'Livreurs et flottes',
      icon: Icons.delivery_dining_rounded,
      items: pick([
        (
          AdminMenuItem(
            id: 'drivers',
            title: 'Livreurs',
            subtitle: 'Gérer les comptes',
            icon: Icons.delivery_dining_rounded,
            page: () => const DriversPage(),
          ),
          'livreurs'
        ),
        (
          AdminMenuItem(
            id: 'fleets',
            title: 'Flottes',
            subtitle: 'Approuver les patrons',
            icon: Icons.motorcycle_rounded,
            page: () => const AdminFleetPage(),
          ),
          'flottes'
        ),
        (
          AdminMenuItem(
            id: 'vehicles',
            title: 'Auto & Moto',
            subtitle: 'Annonces, vendeurs et signalements',
            icon: Icons.directions_car_rounded,
            page: () => const AdminVehicleModerationPage(),
          ),
          null
        ),
      ]),
    ),
    AdminMenuCategory(
      id: 'partners',
      title: 'Partenaires et commerces',
      icon: Icons.storefront_rounded,
      items: pick([
        (
          AdminMenuItem(
            id: 'restaurants',
            title: 'Restaurants',
            subtitle: 'Gérer les menus',
            icon: Icons.restaurant_rounded,
            page: () => const AdminRestaurantsPage(),
          ),
          'restaurants'
        ),
        (
          AdminMenuItem(
            id: 'pharmacies',
            title: 'Pharmacies',
            subtitle: 'Fiches, horaires et gardes',
            icon: Icons.local_pharmacy_rounded,
            page: () => const AdminPharmaciesPage(),
          ),
          'pharmacies'
        ),
        (
          AdminMenuItem(
            id: 'bakeries',
            title: 'Boulangeries',
            subtitle: 'Boulangeries & cafés',
            icon: Icons.bakery_dining_rounded,
            page: () => const AdminBoulangeriesPage(),
          ),
          'boulangeries'
        ),
        (
          AdminMenuItem(
            id: 'boutique',
            title: 'Boutique',
            subtitle: 'Produits & commandes',
            icon: Icons.shopping_bag_rounded,
            page: () => const AdminBoutiquePage(),
          ),
          'boutique'
        ),
        (
          AdminMenuItem(
            id: 'locations',
            title: 'Locations',
            subtitle: 'Maisons à louer',
            icon: Icons.home_rounded,
            page: () => const AdminLocationsPage(),
          ),
          'locations'
        ),
        (
          AdminMenuItem(
            id: 'residences',
            title: 'Résidences',
            subtitle: 'Meublées & studios',
            icon: Icons.apartment_rounded,
            page: () => const AdminResidencesPage(),
          ),
          'residences'
        ),
        (
          AdminMenuItem(
            id: 'ekbine',
            title: 'Agents E-Kbine',
            subtitle: 'Approuver candidatures',
            icon: Icons.sim_card_rounded,
            page: () => const AdminEkbinePage(),
          ),
          'ekbine'
        ),
        (
          AdminMenuItem(
            id: 'partner_qr',
            title: 'QR des établissements',
            subtitle: 'Identification publique',
            icon: Icons.qr_code_2_rounded,
            page: () => const AdminPartnerQrPage(),
          ),
          null
        ),
      ]),
    ),
    AdminMenuCategory(
      id: 'requests',
      title: 'Centre de demandes',
      icon: Icons.inbox_rounded,
      items: pick([
        (
          AdminMenuItem(
            id: 'req_drivers',
            title: 'Livreurs',
            subtitle: 'Nouvelles candidatures',
            icon: Icons.person_add_rounded,
            page: () => const DriverRequestsPage(),
          ),
          'demandes'
        ),
        (
          AdminMenuItem(
            id: 'req_restaurants',
            title: 'Restaurants',
            subtitle: 'Approuver les restos',
            icon: Icons.store_mall_directory_rounded,
            page: () => const AdminRestaurantRequestsPage(),
          ),
          'demandes_resto'
        ),
        (
          AdminMenuItem(
            id: 'req_sellers',
            title: 'Vendeurs',
            subtitle: 'Approuver boutiques',
            icon: Icons.storefront_rounded,
            page: () => const AdminSellerRequestsPage(),
          ),
          'demandes_vendeurs'
        ),
        (
          AdminMenuItem(
            id: 'req_bakeries',
            title: 'Boulangeries',
            subtitle: 'Approuver boulangeries',
            icon: Icons.bakery_dining_rounded,
            page: () => const AdminBoulangerieRequestsPage(),
          ),
          'demandes_boulangeries'
        ),
        (
          AdminMenuItem(
            id: 'req_pharmacies',
            title: 'Pharmacies',
            subtitle: 'Approuver pharmacies',
            icon: Icons.medical_services_rounded,
            page: () => const AdminPharmacieRequestsPage(),
          ),
          'demandes_pharmacies'
        ),
        (
          AdminMenuItem(
            id: 'req_providers',
            title: 'Prestataires de services',
            subtitle: 'Artisans & commerces',
            icon: Icons.handyman_rounded,
            page: () => const AdminServiceRequestsPage(),
          ),
          'services'
        ),
      ]),
    ),
    AdminMenuCategory(
      id: 'finance',
      title: 'Finances',
      icon: Icons.account_balance_wallet_rounded,
      items: pick([
        (
          AdminMenuItem(
            id: 'earnings',
            title: 'Gains',
            subtitle: 'Revenus & stats',
            icon: Icons.trending_up_rounded,
            page: () => const AdminEarnings(),
          ),
          'gains'
        ),
        (
          AdminMenuItem(
            id: 'commissions',
            title: 'Commissions',
            subtitle: 'Commissions livreurs',
            icon: Icons.percent_rounded,
            page: () => const AdminCommissionsPage(),
          ),
          'gains'
        ),
        (
          AdminMenuItem(
            id: 'recharges',
            title: 'Recharges',
            subtitle: 'Créditer les wallets',
            icon: Icons.add_card_rounded,
            page: () => const AdminRechargePage(),
          ),
          'recharges'
        ),
        (
          AdminMenuItem(
            id: 'cash',
            title: 'Cash à régler',
            subtitle: 'Espèces dues aux marchands',
            icon: Icons.payments_rounded,
            page: () => const AdminCashSettlementPage(),
          ),
          'cash_marchand'
        ),
        (
          AdminMenuItem(
            id: 'transfers',
            title: 'Gains transferts',
            subtitle: 'Partage des gains entre livreurs',
            icon: Icons.compare_arrows_rounded,
            page: () => const AdminTransferSettlementsPage(),
          ),
          null
        ),
        (
          AdminMenuItem(
            id: 'billing',
            title: 'Facturation Marketplace',
            subtitle: 'Frais retenus, livraisons bloquées',
            icon: Icons.request_quote_rounded,
            page: () => const AdminBillingReviewsPage(),
          ),
          null
        ),
        // Lecture par la permission `commandes` ; les décisions financières sont refusées par le serveur
        // à tout autre que le super-administrateur.
        if (showOrderDisputes) ...[
          (
            AdminMenuItem(
              id: 'disputes',
              title: 'Litiges de livraison',
              subtitle: 'Remboursements, confirmation de livraison',
              icon: Icons.gavel_rounded,
              page: () => const AdminDisputesPage(),
            ),
            'commandes'
          ),
          (
            AdminMenuItem(
              id: 'stuck_alerts',
              title: 'Commandes bloquées',
              subtitle: 'Alertes de courses sans suite',
              icon: Icons.report_problem_rounded,
              page: () => const AdminStuckAlertsPage(),
            ),
            'commandes'
          ),
        ],
      ]),
    ),
    AdminMenuCategory(
      id: 'services',
      title: 'Services',
      icon: Icons.construction_rounded,
      items: pick([
        (
          AdminMenuItem(
            id: 'services',
            title: 'Services',
            subtitle: 'Artisans & Commerces',
            icon: Icons.construction_rounded,
            page: () => const AdminServicesPage(),
          ),
          'services'
        ),
        (
          AdminMenuItem(
            id: 'events',
            title: 'Événementiel',
            subtitle: 'Prestataires & réservations',
            icon: Icons.celebration_rounded,
            page: () => const AdminEventScreen(),
          ),
          'eventiel'
        ),
        (
          AdminMenuItem(
            id: 'taxi',
            title: 'Tricycle & Taxi',
            subtitle: 'Location & Taxi nuit',
            icon: Icons.local_taxi_rounded,
            page: () => const AdminSimpleServicesPage(),
          ),
          'tricycle'
        ),
      ]),
    ),
    AdminMenuCategory(
      id: 'settings',
      title: 'Paramètres et sécurité',
      icon: Icons.security_rounded,
      items: pick([
        (
          AdminMenuItem(
            id: 'support',
            title: 'Support & Signalements',
            subtitle: 'Tickets clients & abus',
            icon: Icons.support_agent_rounded,
            page: () => const AdminSupportPage(),
          ),
          'support'
        ),
        (
          AdminMenuItem(
            id: 'sub_admins',
            title: 'Gestion Admins',
            subtitle: 'Sous-administrateurs',
            icon: Icons.manage_accounts_rounded,
            page: () => const AdminSubAdminsPage(),
          ),
          null
        ),
        (
          AdminMenuItem(
            id: 'security',
            title: 'Sécurité',
            subtitle: 'Audit & monitoring',
            icon: Icons.security_rounded,
            page: () => const AdminSecurityDashboard(),
          ),
          null
        ),
        (
          AdminMenuItem(
            id: 'deletions',
            title: 'Suppressions de comptes',
            subtitle: 'Suivi et régularisation',
            icon: Icons.person_remove_rounded,
            page: () => const AccountDeletionSupportPage(),
          ),
          null
        ),
        (
          AdminMenuItem(
            id: 'purge',
            title: 'Purger',
            subtitle: 'Vider données de test',
            icon: Icons.delete_sweep_rounded,
            page: () => const AdminPurgePage(),
          ),
          'purger'
        ),
      ]),
    ),
  ];
  return [
    for (final c in categories)
      if (c.items.isNotEmpty) c,
  ];
}

/// Menu administrateur : recherche + catégories dépliables. La recherche
/// parcourt toutes les entrées visibles (titre, description, catégorie).
class AdminMenu extends StatefulWidget {
  final bool isSuper;
  final List<String> permissions;

  const AdminMenu({
    super.key,
    required this.isSuper,
    required this.permissions,
  });

  @override
  State<AdminMenu> createState() => _AdminMenuState();
}

class _AdminMenuState extends State<AdminMenu> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(AdminMenuCategory c, AdminMenuItem i) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return '${i.title} ${i.subtitle} ${c.title}'.toLowerCase().contains(q);
  }

  void _open(AdminMenuItem item) => Navigator.push(
      context, MaterialPageRoute(builder: (_) => item.page()));

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final categories = buildAdminMenu(
        isSuper: widget.isSuper, permissions: widget.permissions);
    final searching = _query.trim().isNotEmpty;
    final visible = [
      for (final c in categories)
        if (c.items.any((i) => _matches(c, i))) c,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _search,
          onChanged: (v) => setState(() => _query = v),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Rechercher une fonction…',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: searching
                ? IconButton(
                    tooltip: 'Effacer',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  )
                : null,
          ),
        ),
        const SizedBox(height: 14),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text('Aucune fonction ne correspond.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.premiumTextSecondary(b))),
            ),
          ),
        for (final c in visible)
          _CategoryCard(
            // La clé change avec la recherche : les catégories filtrées
            // s'ouvrent d'elles-mêmes, sans état d'expansion à synchroniser.
            key: ValueKey('${c.id}|${searching ? 's' : 'n'}'),
            category: c,
            items: [for (final i in c.items) if (_matches(c, i)) i],
            expanded: searching,
            onOpen: _open,
          ),
      ],
    );
  }
}

class _CategoryCard extends StatelessWidget {
  final AdminMenuCategory category;
  final List<AdminMenuItem> items;
  final bool expanded;
  final ValueChanged<AdminMenuItem> onOpen;

  const _CategoryCard({
    super.key,
    required this.category,
    required this.items,
    required this.expanded,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final text = Theme.of(context).textTheme;
    final accent = AppColors.primaryText(b);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.premiumSurface(b),
          borderRadius: AppRadius.cardR,
          border: Border.all(color: AppColors.premiumBorder(b)),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: expanded,
            shape: const RoundedRectangleBorder(borderRadius: AppRadius.cardR),
            collapsedShape:
                const RoundedRectangleBorder(borderRadius: AppRadius.cardR),
            tilePadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(category.icon, color: accent, size: 24),
            ),
            title: Text(category.title,
                style: text.titleMedium?.copyWith(
                    color: AppColors.premiumTextPrimary(b),
                    fontWeight: FontWeight.w700)),
            subtitle: Text(
                '${items.length} fonction${items.length > 1 ? 's' : ''}',
                style: text.bodySmall
                    ?.copyWith(color: AppColors.premiumTextSecondary(b))),
            children: [
              for (final item in items) _ItemTile(item: item, onOpen: onOpen),
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  final AdminMenuItem item;
  final ValueChanged<AdminMenuItem> onOpen;
  const _ItemTile({required this.item, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: '${item.title}. ${item.subtitle}',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: AppRadius.premiumMdR,
        onTap: () => onOpen(item),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(item.icon,
                    size: 22, color: AppColors.premiumTextSecondary(b)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title,
                          style: text.bodyLarge?.copyWith(
                              color: AppColors.premiumTextPrimary(b),
                              fontWeight: FontWeight.w600)),
                      Text(item.subtitle,
                          style: text.bodySmall?.copyWith(
                              color: AppColors.premiumTextSecondary(b))),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    color: AppColors.premiumTextSecondary(b)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
