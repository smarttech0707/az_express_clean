import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../web_theme.dart';
import '../../web_client_auth.dart';
import '../../../services/auth_service.dart';
import '../../../services/firestore_service.dart';
import '../../../services/permission_primer.dart';
import '../../../widgets/rating_dialog.dart';
import '../../../widgets/stream_error_state.dart';
import '../../../ekbine/ek_constants.dart';
import 'web_delivery_page.dart';
import 'web_client_support.dart';
import 'web_artisans_page.dart';

/// Route de la page Livraison Express, désormais réellement implémentée
/// (`web_delivery_page.dart`) — elle n'affiche plus `_ServiceUnavailable`.
const clientDeliveryRoute = '/app/commander';

/// Route Artisans (Phase 3A), désormais réellement implémentée
/// (`web_artisans_page.dart`) — n'affiche plus `_ServiceUnavailable`.
const clientArtisansRoute = '/app/artisans';

/// Sections RÉELLES du dashboard : chacune correspond à une page réellement
/// implémentée (`_HomeTab`, `_OrdersTab`, `_WalletTab`, `_ProfileTab`).
///
/// Elles n'avaient AUCUNE URL avant ce correctif : l'onglet vivait uniquement
/// dans un `int _tab` local, donc un rafraîchissement ou un retour navigateur
/// ramenait toujours à l'accueil. L'URL est désormais la source de vérité.
const clientSectionTabs = <String, int>{
  '/app': 0,
  '/app/commandes': 1,
  '/app/wallet': 2,
  '/app/profil': 3,
  '/app/support': 4,
};

/// Chemin canonique d'un onglet, pour la navigation sortante.
String clientPathForTab(int tab) => clientSectionTabs.entries
    .firstWhere((e) => e.value == tab, orElse: () => clientSectionTabs.entries.first)
    .key;

class WebClientDashboard extends StatefulWidget {
  /// Route actuellement affichée. Transmise par go_router — sans elle, le
  /// dashboard ne pouvait pas savoir quoi montrer et repartait toujours à
  /// l'accueil, quelle que soit l'URL demandée.
  final String location;

  const WebClientDashboard({super.key, this.location = '/app'});

  @override
  State<WebClientDashboard> createState() => _WebClientDashboardState();
}

class _WebClientDashboardState extends State<WebClientDashboard> {
  /// Onglet dérivé de l'URL : plus aucun état local à resynchroniser.
  int get _tab => clientSectionTabs[widget.location] ?? 0;

  /// Service demandé par l'URL mais SANS page web implémentée, ou `null`.
  ///
  /// Aucune page n'existe dans `lib/web/pages/client/` pour ces routes : le
  /// répertoire ne contient que le dashboard et la connexion. Plutôt que de
  /// fabriquer une fausse navigation, on l'affiche explicitement.
  ({IconData icon, String title, Color color})? get _unavailableService {
    final loc = widget.location;
    if (clientSectionTabs.containsKey(loc)) return null;
    // Livraison Express et Artisans ont maintenant une vraie page web.
    if (loc == clientDeliveryRoute) return null;
    if (loc == clientArtisansRoute) return null;
    if (!loc.startsWith('/app/')) return null;

    // Le libellé et l'icône proviennent de la définition des cartes
    // elles-mêmes : aucune duplication, aucun intitulé inventé.
    for (final s in clientServiceCards) {
      if (s.$5 == loc) return (icon: s.$1, title: s.$2, color: s.$4);
    }
    // Les deux actions du wallet, qui ne sont pas des cartes de service.
    if (loc == '/app/recharge') {
      return (icon: Icons.add_rounded, title: 'Recharger le wallet', color: kSuccess);
    }
    if (loc == '/app/retrait') {
      return (
        icon: Icons.arrow_upward_rounded,
        title: 'Retirer de l\'argent',
        color: kBlue
      );
    }
    return null;
  }

  /// Navigation entre sections : passe par l'URL, pour que le rafraîchissement
  /// et les boutons Précédent/Suivant du navigateur restent cohérents.
  void _goToTab(int tab) => context.go(clientPathForTab(tab));

  @override
  Widget build(BuildContext context) {
    final auth = WebClientAuth.instance;
    final mob = isMobile(context);

    return Scaffold(
      backgroundColor: const Color(0xFF0F1923),
      body: Row(
        children: [
          if (!mob) _Sidebar(tab: _tab, onTab: _goToTab, auth: auth),
          Expanded(
            child: Column(
              children: [
                _TopBar(auth: auth, tab: _tab, onTab: _goToTab),
                Expanded(child: _body(auth)),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar:
          mob ? _MobileNav(tab: _tab, onTab: _goToTab) : null,
    );
  }

  Widget _body(WebClientAuth auth) {
    // Livraison Express : vraie page, rendue dans le cadre du dashboard pour
    // conserver la barre latérale et la navigation.
    if (widget.location == clientDeliveryRoute) return const WebDeliveryPage();
    if (widget.location == clientArtisansRoute) return const WebArtisansPage();
    // Une route de service prime : elle doit être annoncée honnêtement, pas
    // remplacée silencieusement par l'accueil.
    final service = _unavailableService;
    if (service != null) {
      return _ServiceUnavailable(
        icon: service.icon,
        title: service.title,
        color: service.color,
      );
    }
    switch (_tab) {
      case 0:
        return _HomeTab(auth: auth, onTab: _goToTab);
      case 1:
        return _OrdersTab(auth: auth);
      case 2:
        return _WalletTab(auth: auth);
      case 3:
        return _ProfileTab(auth: auth);
      case 4:
        return const WebClientSupportTab();
      default:
        return _HomeTab(auth: auth, onTab: _goToTab);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SIDEBAR DESKTOP
// ─────────────────────────────────────────────────────────────────────────────
class _Sidebar extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTab;
  final WebClientAuth auth;
  const _Sidebar({required this.tab, required this.onTab, required this.auth});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      color: const Color(0xFF161B22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('AZ Express',
                  style: GoogleFonts.inter(
                      color: kOrange,
                      fontSize: 20,
                      fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text('Abengourou',
                  style: GoogleFonts.inter(color: kTextMuted, fontSize: 12)),
            ]),
          ),
          const Divider(color: Color(0xFF30363D), height: 1),
          const SizedBox(height: 12),
          _navItem(0, Icons.home_rounded, 'Accueil'),
          _navItem(1, Icons.receipt_long_rounded, 'Mes commandes'),
          _navItem(2, Icons.account_balance_wallet, 'Mon wallet'),
          _navItem(3, Icons.person_rounded, 'Mon profil'),
          _navItem(4, Icons.support_agent_rounded, 'Support'),
          const Spacer(),
          const Divider(color: Color(0xFF30363D), height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: kOrange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kOrange.withValues(alpha: 0.2)),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(auth.clientName,
                        style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text('${auth.wallet} FCFA',
                        style: GoogleFonts.inter(
                            color: kOrange,
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () async {
                        await auth.logout();
                      },
                      child: Text('Déconnexion',
                          style: GoogleFonts.inter(
                              color: kTextMuted, fontSize: 12)),
                    ),
                  ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label) {
    final sel = tab == index;
    return GestureDetector(
      onTap: () => onTab(index),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: sel ? kOrange.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(icon, color: sel ? kOrange : kTextMuted, size: 20),
          const SizedBox(width: 12),
          Text(label,
              style: GoogleFonts.inter(
                  color: sel ? kOrange : kTextMuted,
                  fontSize: 14,
                  fontWeight: sel ? FontWeight.w700 : FontWeight.w400)),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TOP BAR
// ─────────────────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final WebClientAuth auth;
  final int tab;
  final ValueChanged<int> onTab;
  const _TopBar({required this.auth, required this.tab, required this.onTab});

  static const _titles = [
    'Accueil',
    'Mes commandes',
    'Mon wallet',
    'Mon profil',
    'Support',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
      ),
      child: Row(
        children: [
          Text(_titles[tab],
              style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: kOrange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kOrange.withValues(alpha: 0.3)),
            ),
            child: Row(children: [
              const Icon(Icons.account_balance_wallet,
                  color: kOrange, size: 16),
              const SizedBox(width: 8),
              Text('${auth.wallet} FCFA',
                  style: GoogleFonts.inter(
                      color: kOrange,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ]),
          ),
          const SizedBox(width: 12),
          CircleAvatar(
            radius: 18,
            backgroundColor: kOrange.withValues(alpha: 0.2),
            child: Text(
                auth.clientName.isNotEmpty
                    ? auth.clientName[0].toUpperCase()
                    : 'C',
                style: const TextStyle(
                    color: kOrange, fontWeight: FontWeight.w800, fontSize: 16)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ONGLET ACCUEIL — grille de services
// ─────────────────────────────────────────────────────────────────────────────
/// Cartes de service du dashboard client web — DÉFINITION UNIQUE.
///
/// Exposée au niveau du fichier pour que la liste des chemins ciblés soit
/// vérifiable par un test : c'est exactement ce couplage (carte -> route)
/// qui était cassé, chaque route reconstruisant le même dashboard.
const clientServiceCards = <(IconData, String, String, Color, String)>[
    (
      Icons.delivery_dining_rounded,
      'Livraison Express',
      'Envoyer un colis',
      kOrange,
      '/app/commander'
    ),
    (
      Icons.restaurant_rounded,
      'Restaurants',
      'Commander un repas',
      kBlue,
      '/app/restaurants'
    ),
    (
      Icons.bakery_dining_rounded,
      'Boulangeries & Café',
      'Petit-déjeuner livré',
      Color(0xFF8D6E63),
      '/app/boulangeries'
    ),
    (
      Icons.local_pharmacy_rounded,
      'Pharmacies',
      'Médicaments de garde',
      Colors.red,
      '/app/pharmacies'
    ),
    (
      Icons.sim_card_rounded,
      'E-Kbine Services',
      'Crédit, Internet, Mobile Money',
      Color(0xFF00695C),
      '/app/ekbine'
    ),
    (
      Icons.storefront_rounded,
      'Boutique',
      'Shopping en ligne',
      kBlue,
      '/app/boutique'
    ),
    (
      Icons.water_drop_rounded,
      'Eau & Boissons',
      'Livraison de bouteilles',
      Color(0xFF0288D1),
      '/app/eau'
    ),
    (
      Icons.dry_cleaning_rounded,
      'Blanchisserie',
      'Dépôt et retrait',
      Color(0xFF7B1FA2),
      '/app/blanchisserie'
    ),
    (
      Icons.handyman_rounded,
      'Artisans',
      'Réparations & Services',
      Color(0xFF1565C0),
      '/app/artisans'
    ),
    (
      Icons.home_rounded,
      'Résidences',
      'Logements meublés',
      kSuccess,
      '/app/residences'
    ),
    (
      Icons.local_taxi_rounded,
      'Locations',
      'Tricycles & Taxi',
      Color(0xFFE65100),
      '/app/locations'
    ),
    (
      Icons.inventory_2_rounded,
      'Colis & Cadeaux',
      'Envoi entre particuliers',
      kOrangeD,
      '/app/colis'
    ),
];

/// Chemins ciblés par les cartes de service ci-dessus.
List<String> get clientServiceRoutes =>
    clientServiceCards.map((c) => c.$5).toList(growable: false);

class _HomeTab extends StatelessWidget {
  final WebClientAuth auth;
  final ValueChanged<int> onTab;
  const _HomeTab({required this.auth, required this.onTab});

  /// Définition unique des cartes de service — également lue par
  /// `_WebClientDashboardState` pour nommer un service sans page web, afin
  /// qu'aucun libellé ne soit dupliqué ni inventé.

  @override
  Widget build(BuildContext context) {
    final cols = isDesktop(context) ? 4 : (isTablet(context) ? 3 : 2);
    return SingleChildScrollView(
      padding: EdgeInsets.all(hPad(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Accueil
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: kHeroGradient,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(children: [
              Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Bonjour, ${auth.clientName.split(' ').first} 👋',
                      style: GoogleFonts.inter(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text('Que souhaitez-vous commander aujourd\'hui ?',
                      style: GoogleFonts.inter(
                          color: Colors.white70, fontSize: 14)),
                  const SizedBox(height: 16),
                  Row(children: [
                    _StatChip(
                        icon: Icons.account_balance_wallet,
                        label: '${auth.wallet} FCFA',
                        sub: 'Votre wallet'),
                  ]),
                ],
              )),
              const SizedBox(width: 20),
              const Icon(Icons.delivery_dining_rounded,
                  color: Colors.white38, size: 80),
            ]),
          ).animate().fadeIn(duration: 500.ms),

          const SizedBox(height: 32),
          Text('Nos services',
              style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),

          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.3,
            ),
            itemCount: clientServiceCards.length,
            itemBuilder: (ctx, i) {
              final s = clientServiceCards[i];
              return _ServiceCard(
                icon: s.$1,
                title: s.$2,
                subtitle: s.$3,
                color: s.$4,
                route: s.$5,
              )
                  .animate(delay: (i * 50).ms)
                  .fadeIn(duration: 400.ms)
                  .slideY(begin: 0.1);
            },
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  const _StatChip({required this.icon, required this.label, required this.sub});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w800)),
          Text(sub,
              style: GoogleFonts.inter(color: Colors.white60, fontSize: 11)),
        ]),
      ]),
    );
  }
}

class _ServiceCard extends StatefulWidget {
  final IconData icon;
  final String title, subtitle, route;
  final Color color;
  const _ServiceCard(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.color,
      required this.route});
  @override
  State<_ServiceCard> createState() => _ServiceCardState();
}

class _ServiceCardState extends State<_ServiceCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => context.go(widget.route),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _hover
                ? widget.color.withValues(alpha: 0.18)
                : const Color(0xFF161B22),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: _hover
                  ? widget.color.withValues(alpha: 0.5)
                  : const Color(0xFF30363D),
              width: _hover ? 1.5 : 1,
            ),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.2),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    )
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(widget.icon, color: widget.color, size: 24),
              ),
              const Spacer(),
              Text(widget.title,
                  style: GoogleFonts.inter(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(widget.subtitle,
                  style: GoogleFonts.inter(color: kTextMuted, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ONGLET COMMANDES
// ─────────────────────────────────────────────────────────────────────────────
/// Statuts réels de `orders` (voir CLAUDE.md : « pending → broadcast/assigned
/// → accepted → picked_up → delivered, ou cancelled »). Aucun statut inventé
/// ici : cette liste n'est qu'un filtre d'affichage sur des valeurs déjà
/// écrites par les Cloud Functions existantes.
const orderStatusLabels = {
  'pending': 'En attente',
  'broadcast': 'Recherche d\'un livreur',
  'assigned': 'Livreur assigné',
  'accepted': 'En route',
  'picked_up': 'Récupéré',
  'delivered': 'Livré',
  'cancelled': 'Annulé',
};

Color orderStatusColor(String s) {
  switch (s) {
    case 'delivered':
      return kSuccess;
    case 'cancelled':
      return Colors.red;
    case 'accepted':
    case 'picked_up':
      return kBlue;
    default:
      return kOrange;
  }
}

IconData orderTypeIcon(Map<String, dynamic> data) {
  final type = data['type'] as String?;
  final sellerType = data['sellerType'] as String?;
  switch (sellerType ?? type) {
    case 'restaurant':
      return Icons.restaurant_rounded;
    case 'pharmacie':
      return Icons.local_pharmacy_rounded;
    case 'boulangerie':
      return Icons.bakery_dining_rounded;
    case 'seller':
      return Icons.storefront_rounded;
    case 'shopping':
      return Icons.shopping_basket_rounded;
    default:
      return Icons.delivery_dining_rounded;
  }
}

class _OrdersTab extends StatefulWidget {
  final WebClientAuth auth;
  const _OrdersTab({required this.auth});

  @override
  State<_OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends State<_OrdersTab> {
  bool _showEkbine = false;
  String _statusFilter = 'tous';

  @override
  Widget build(BuildContext context) {
    final uid = widget.auth.user?.uid ?? '';
    return Column(children: [
      Padding(
        padding: EdgeInsets.fromLTRB(hPad(context), hPad(context), hPad(context), 0),
        child: Row(children: [
          Expanded(
            child: _SourceToggle(
              showEkbine: _showEkbine,
              onChanged: (v) => setState(() => _showEkbine = v),
            ),
          ),
          if (!_showEkbine) ...[
            const SizedBox(width: 12),
            _StatusFilterDropdown(
              value: _statusFilter,
              onChanged: (v) => setState(() => _statusFilter = v),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: _showEkbine
            ? _EkbineHistoryList(uid: uid)
            : _OrdersList(uid: uid, statusFilter: _statusFilter),
      ),
    ]);
  }
}

class _SourceToggle extends StatelessWidget {
  final bool showEkbine;
  final ValueChanged<bool> onChanged;
  const _SourceToggle({required this.showEkbine, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _seg('Commandes', !showEkbine, () => onChanged(false)),
        _seg('E-Kbine', showEkbine, () => onChanged(true)),
      ]),
    );
  }

  Widget _seg(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? kOrange.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: GoogleFonts.inter(
                color: selected ? kOrange : kTextMuted,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
      ),
    );
  }
}

class _StatusFilterDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _StatusFilterDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final options = <String, String>{
      'tous': 'Tous les statuts',
      ...orderStatusLabels,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: DropdownButton<String>(
        value: value,
        underline: const SizedBox.shrink(),
        dropdownColor: const Color(0xFF161B22),
        style: GoogleFonts.inter(color: Colors.white, fontSize: 13),
        onChanged: (v) => onChanged(v ?? 'tous'),
        items: options.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
      ),
    );
  }
}

class _OrdersList extends StatelessWidget {
  final String uid;
  final String statusFilter;
  const _OrdersList({required this.uid, required this.statusFilter});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('orders')
          .where('clientId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(50)
          .snapshots(),
      builder: (ctx, snap) {
        if (snap.hasError) {
          return StreamErrorState(
            message: 'Impossible de charger vos commandes pour le moment.',
            onRetry: () {},
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: kOrange));
        }
        var docs = snap.data?.docs ?? [];
        if (statusFilter != 'tous') {
          docs = docs.where((d) {
            final data = d.data() as Map<String, dynamic>;
            return (data['status'] as String? ?? 'pending') == statusFilter;
          }).toList();
        }
        if (docs.isEmpty) {
          return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.receipt_long_rounded, color: kTextMuted, size: 64),
            const SizedBox(height: 16),
            Text('Aucune commande',
                style: GoogleFonts.inter(
                    color: kTextMuted,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('Vos commandes apparaîtront ici',
                style: GoogleFonts.inter(color: kTextMuted, fontSize: 14)),
          ]));
        }
        return ListView.separated(
          padding: EdgeInsets.all(hPad(context)),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (_, i) {
            final d = docs[i].data() as Map<String, dynamic>;
            return _OrderCard(data: d, id: docs[i].id);
          },
        );
      },
    );
  }
}

class _OrderCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final String id;
  const _OrderCard({required this.data, required this.id});

  @override
  State<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends State<_OrderCard> {
  bool _cancelling = false;

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Annuler la commande ?'),
        content: const Text(
            'Cette action est irréversible. Confirmez-vous l\'annulation ?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Non')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child:
                  const Text('Oui, annuler', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _cancelling = true);
    try {
      await FirestoreService().cancelOrder(widget.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Annulation impossible : $e'),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  // SEC-01 / S6.9 : le numéro n'est plus lu directement sur `livreurs` —
  // `getDriverPhoneForOrderCF` (S6.8) vérifie elle-même, côté serveur, que
  // l'appelant est bien le client de cette commande avant de le renvoyer.
  // Aucun repli vers la lecture directe en cas d'échec : mieux ne pas
  // afficher/appeler que d'afficher un numéro obsolète ou non autorisé.
  Future<void> _callDriver(String orderId) async {
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('getDriverPhoneForOrderCF')
          .call({'orderId': orderId});
      final phone = ((result.data as Map?)?['data'] as Map?)?['phone'] as String?;
      if (phone == null || phone.isEmpty) return;
      await launchUrl(Uri(scheme: 'tel', path: phone));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.code == 'resource-exhausted'
              ? 'Trop de tentatives, réessayez plus tard.'
              : "Numéro du livreur indisponible pour l'instant."),
          backgroundColor: Colors.red));
    } catch (_) {}
  }

  void _rateDriver(String driverId) async {
    String driverName = 'le livreur';
    try {
      // SEC-01 / S6.1 : seul le nom est nécessaire pour le dialogue de
      // notation → projection publique `driver_public`.
      final doc = await FirebaseFirestore.instance
          .collection('driver_public')
          .doc(driverId)
          .get();
      if (doc.exists) driverName = doc.data()?['name'] as String? ?? driverName;
    } catch (_) {}
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => RatingDialog(orderId: widget.id, driverName: driverName),
    );
  }

  void _rateSeller(String sellerId, String? sellerName, String? sellerType) {
    showDialog(
      context: context,
      builder: (_) => _SellerRatingDialog(
        orderId: widget.id,
        sellerName: sellerName ?? 'le vendeur',
        sellerType: sellerType,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final status = data['status'] as String? ?? 'pending';
    final budget = (data['budget'] as num? ?? 0).toInt();
    final desc = data['description'] as String? ?? '';
    final color = orderStatusColor(status);
    final driverId = data['driverId'] as String?;
    final sellerId = data['sellerId'] as String?;
    final rating = data['rating'] as num?;
    final sellerRating = data['sellerRating'] as num?;
    final isDelivered = status == 'delivered';
    final isActive = !isDelivered && status != 'cancelled';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(orderTypeIcon(data), color: color, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(desc.isNotEmpty ? desc.split('\n').first : 'Commande',
                    style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text('$budget FCFA',
                    style: GoogleFonts.inter(color: kTextMuted, fontSize: 13)),
              ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(orderStatusLabels[status] ?? status,
                style: GoogleFonts.inter(
                    color: color, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ]),

        // Le suivi carte temps réel et la messagerie avec le livreur restent
        // disponibles uniquement sur l'application mobile pour le moment
        // (carte Maps Web non intégrée, chat mobile dépendant de `dart:io` —
        // voir plan de développement, phases dédiées). On l'annonce
        // honnêtement plutôt que de masquer le bouton.
        if (isActive && driverId != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, size: 14, color: kTextMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    'Suivi carte et chat disponibles depuis l\'application mobile',
                    style: GoogleFonts.inter(color: kTextMuted, fontSize: 11)),
              ),
            ]),
          ),

        if (isDelivered && rating == null && driverId != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _rateDriver(driverId),
                icon: const Icon(Icons.star_rounded, color: Colors.amber),
                label: const Text('Noter le livreur'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.amber,
                    side: const BorderSide(color: Colors.amber)),
              ),
            ),
          ),
        if (isDelivered && sellerId != null && sellerRating == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _rateSeller(sellerId,
                    data['sellerName'] as String?, data['sellerType'] as String?),
                icon: const Icon(Icons.star_rate_rounded, color: kBlue),
                label: const Text('Noter le vendeur'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: kBlue, side: const BorderSide(color: kBlue)),
              ),
            ),
          ),

        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(children: [
            if (driverId != null)
              TextButton.icon(
                onPressed: () => _callDriver(widget.id),
                icon: const Icon(Icons.call_rounded, size: 18, color: kSuccess),
                label: const Text('Appeler', style: TextStyle(color: kSuccess)),
              ),
            const Spacer(),
            if (status == 'pending')
              TextButton.icon(
                onPressed: _cancelling ? null : _cancel,
                icon: const Icon(Icons.cancel_rounded, size: 18, color: Colors.red),
                label: Text(_cancelling ? 'Annulation…' : 'Annuler',
                    style: const TextStyle(color: Colors.red)),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Avis vendeur/restaurant/boulangerie — équivalent minimal de
/// `SellerReviewDialog` (lib/screens/client/suivi_commande.dart), qui ne peut
/// pas être importé tel quel sur le web (ce fichier dépend de
/// `chat_page.dart`, qui utilise `dart:io`/`record`/`path_provider`). La
/// seule logique ici est l'écriture du champ `sellerRating`, identique à
/// l'original — aucune nouvelle règle métier.
class _SellerRatingDialog extends StatefulWidget {
  final String orderId;
  final String sellerName;
  final String? sellerType;
  const _SellerRatingDialog(
      {required this.orderId, required this.sellerName, this.sellerType});

  @override
  State<_SellerRatingDialog> createState() => _SellerRatingDialogState();
}

class _SellerRatingDialogState extends State<_SellerRatingDialog> {
  int _rating = 0;
  bool _sending = false;

  String get _label => switch (widget.sellerType) {
        'restaurant' => 'le restaurant',
        'boulangerie' => 'la boulangerie',
        _ => widget.sellerName,
      };

  Future<void> _submit() async {
    if (_rating == 0) return;
    setState(() => _sending = true);
    try {
      await FirebaseFirestore.instance
          .collection('orders')
          .doc(widget.orderId)
          .update({'sellerRating': _rating});
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Erreur : $e'), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Noter $_label'),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(
            5,
            (i) => IconButton(
                  onPressed: () => setState(() => _rating = i + 1),
                  icon: Icon(
                      i < _rating ? Icons.star_rounded : Icons.star_border_rounded,
                      color: kBlue),
                )),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        ElevatedButton(
          onPressed: _sending ? null : _submit,
          child: const Text('Envoyer'),
        ),
      ],
    );
  }
}

class _EkbineHistoryList extends StatelessWidget {
  final String uid;
  const _EkbineHistoryList({required this.uid});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('ekbine_orders')
          .where('clientId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(50)
          .snapshots(),
      builder: (ctx, snap) {
        if (snap.hasError) {
          return StreamErrorState(
            message: 'Impossible de charger vos opérations E-Kbine.',
            onRetry: () {},
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: kOrange));
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.sim_card_rounded, color: kTextMuted, size: 64),
            const SizedBox(height: 16),
            Text('Aucune opération E-Kbine',
                style: GoogleFonts.inter(
                    color: kTextMuted,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
          ]));
        }
        return ListView.separated(
          padding: EdgeInsets.all(hPad(context)),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (_, i) {
            final data = docs[i].data() as Map<String, dynamic>;
            final status = data['status'] as String? ?? 'pending';
            final color = ekStatusColor(status);
            final amount = (data['amount'] as num? ?? 0).toInt();
            return Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.sim_card_rounded, color: color, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          (data['serviceLabel'] as String?) ??
                              (data['serviceId'] as String?) ??
                              'Opération E-Kbine',
                          style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text('$amount FCFA',
                          style: GoogleFonts.inter(color: kTextMuted, fontSize: 13)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(ekStatusLabels[status] ?? status,
                      style: GoogleFonts.inter(
                          color: color, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ]),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ONGLET WALLET
// ─────────────────────────────────────────────────────────────────────────────
class _WalletTab extends StatelessWidget {
  final WebClientAuth auth;
  const _WalletTab({required this.auth});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(hPad(context)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Balance card
        Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            gradient: kHeroGradient,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Solde disponible',
                      style: GoogleFonts.inter(
                          color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 8),
                  Text('${auth.wallet} FCFA',
                      style: GoogleFonts.inter(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w900)),
                ])),
            const Icon(Icons.account_balance_wallet,
                color: Colors.white24, size: 64),
          ]),
        ),

        const SizedBox(height: 20),

        // Actions
        Row(children: [
          Expanded(
              child: _WalletAction(
            icon: Icons.add_rounded,
            label: 'Recharger',
            color: kSuccess,
            onTap: () => context.go('/app/recharge'),
          )),
          const SizedBox(width: 12),
          Expanded(
              child: _WalletAction(
            icon: Icons.arrow_upward_rounded,
            label: 'Retirer',
            color: kBlue,
            onTap: () => context.go('/app/retrait'),
          )),
        ]),

        const SizedBox(height: 28),
        Text('Historique des transactions',
            style: GoogleFonts.inter(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),

        StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('clients')
              .doc(auth.user?.uid ?? '')
              .collection('wallet_transactions')
              .orderBy('createdAt', descending: true)
              .limit(30)
              .snapshots(),
          builder: (ctx, snap) {
            final docs = snap.data?.docs ?? [];
            if (docs.isEmpty) {
              return Center(
                  child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Text('Aucune transaction',
                    style: GoogleFonts.inter(color: kTextMuted)),
              ));
            }
            return Column(
              children: docs.map((d) {
                final data = d.data() as Map<String, dynamic>;
                final type = data['type'] as String? ?? '';
                final amount = (data['amount'] as num? ?? 0).toInt();
                final desc = data['description'] as String? ?? '';
                final isCredit =
                    ['recharge', 'earning', 'refund'].contains(type);
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF30363D)),
                  ),
                  child: Row(children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: (isCredit ? kSuccess : Colors.red)
                            .withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                          isCredit
                              ? Icons.arrow_downward_rounded
                              : Icons.arrow_upward_rounded,
                          color: isCredit ? kSuccess : Colors.red,
                          size: 20),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                        child: Text(desc,
                            style: GoogleFonts.inter(
                                color: Colors.white, fontSize: 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    Text('${isCredit ? '+' : '-'}$amount FCFA',
                        style: GoogleFonts.inter(
                            color: isCredit ? kSuccess : Colors.red,
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                  ]),
                );
              }).toList(),
            );
          },
        ),
      ]),
    );
  }
}

class _WalletAction extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _WalletAction(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});
  @override
  State<_WalletAction> createState() => _WalletActionState();
}

class _WalletActionState extends State<_WalletAction> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _hover
                ? widget.color.withValues(alpha: 0.18)
                : const Color(0xFF161B22),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: _hover ? widget.color : const Color(0xFF30363D)),
          ),
          child: Column(children: [
            Icon(widget.icon, color: widget.color, size: 28),
            const SizedBox(height: 8),
            Text(widget.label,
                style: GoogleFonts.inter(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14)),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ONGLET PROFIL
// ─────────────────────────────────────────────────────────────────────────────
class _ProfileTab extends StatefulWidget {
  final WebClientAuth auth;
  const _ProfileTab({required this.auth});

  @override
  State<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<_ProfileTab> {
  String? _photoUrl;
  String? _createdAt;
  String _phone = '';
  String _email = '';
  bool _loadingProfile = true;
  Object? _profileError;

  int? _totalOrders;
  int? _deliveredOrders;
  int? _pendingOrders;
  bool _uploadingPhoto = false;

  String get _uid => widget.auth.user?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadOrderStats();
  }

  Future<void> _loadProfile() async {
    if (_uid.isEmpty) return;
    setState(() {
      _loadingProfile = true;
      _profileError = null;
    });
    try {
      final doc = await FirebaseFirestore.instance
          .collection('clients')
          .doc(_uid)
          .get();
      final ts = doc.data()?['createdAt'];
      String? created;
      if (ts is Timestamp) {
        final d = ts.toDate();
        created = '${d.day.toString().padLeft(2, '0')}/'
            '${d.month.toString().padLeft(2, '0')}/${d.year}';
      }
      if (!mounted) return;
      setState(() {
        _photoUrl = doc.data()?['photoUrl'] as String?;
        _phone = doc.data()?['phone'] as String? ?? '';
        _email = doc.data()?['email'] as String? ?? '';
        _createdAt = created;
        _loadingProfile = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _profileError = e;
        _loadingProfile = false;
      });
    }
  }

  Future<void> _loadOrderStats() async {
    if (_uid.isEmpty) return;
    final col = FirebaseFirestore.instance
        .collection('orders')
        .where('clientId', isEqualTo: _uid);
    try {
      final results = await Future.wait([
        col.count().get(),
        col.where('status', isEqualTo: 'delivered').count().get(),
        col.where('status', isEqualTo: 'pending').count().get(),
      ]);
      if (!mounted) return;
      setState(() {
        _totalOrders = results[0].count ?? 0;
        _deliveredOrders = results[1].count ?? 0;
        _pendingOrders = results[2].count ?? 0;
      });
    } catch (_) {
      // Statistiques secondaires : une erreur ici ne doit pas bloquer le
      // reste du profil, déjà géré par `_profileError` pour les données
      // essentielles.
    }
  }

  Future<void> _changePhoto() async {
    if (_uid.isEmpty) return;
    try {
      if (!await PermissionPrimer.prepareImage(ImageSource.gallery, context: context)) return;
      final picked = await ImagePicker()
          .pickImage(source: ImageSource.gallery, imageQuality: 80, maxWidth: 800);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      setState(() => _uploadingPhoto = true);
      final ref =
          FirebaseStorage.instance.ref('client_photos/$_uid/profile.jpg');
      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();
      await FirebaseFirestore.instance
          .collection('clients')
          .doc(_uid)
          .update({'photoUrl': url});
      if (!mounted) return;
      setState(() {
        _photoUrl = url;
        _uploadingPhoto = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadingPhoto = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Impossible de mettre à jour la photo : $e'),
          backgroundColor: Colors.red));
    }
  }

  void _showEditName() {
    final ctrl = TextEditingController(text: widget.auth.clientName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Modifier le nom'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Nom complet'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              try {
                await FirebaseFirestore.instance
                    .collection('clients')
                    .doc(_uid)
                    .update({'name': name});
                await widget.auth.reload();
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                      content: Text('Erreur : $e'),
                      backgroundColor: Colors.red));
                }
              }
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  void _showChangePassword() {
    final curCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        bool loading = false;
        return StatefulBuilder(builder: (ctx, setS) {
          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Changer le mot de passe'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              _SecurityField(ctrl: curCtrl, label: 'Mot de passe actuel'),
              const SizedBox(height: 10),
              _SecurityField(ctrl: newCtrl, label: 'Nouveau mot de passe'),
              const SizedBox(height: 10),
              _SecurityField(ctrl: confCtrl, label: 'Confirmer'),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Annuler')),
              ElevatedButton(
                onPressed: loading
                    ? null
                    : () async {
                        final err = AuthService.validatePassword(newCtrl.text);
                        if (err != null) {
                          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                              content: Text(err),
                              backgroundColor: Colors.orange));
                          return;
                        }
                        if (newCtrl.text != confCtrl.text) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                              content:
                                  Text('Les mots de passe ne correspondent pas'),
                              backgroundColor: Colors.red));
                          return;
                        }
                        setS(() => loading = true);
                        try {
                          await AuthService().updatePassword(
                              currentPassword: curCtrl.text,
                              newPassword: newCtrl.text);
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Mot de passe mis à jour'),
                                    backgroundColor: Colors.green));
                          }
                        } catch (e) {
                          setS(() => loading = false);
                          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                              content: Text('Erreur : $e'),
                              backgroundColor: Colors.red));
                        }
                      },
                child: const Text('Enregistrer'),
              ),
            ],
          );
        });
      },
    );
  }

  void _showChangeEmail() {
    final passCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        bool loading = false;
        return StatefulBuilder(builder: (ctx, setS) {
          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Modifier l\'email'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                  'Un lien de confirmation sera envoyé au nouvel email. Votre '
                  'identifiant de connexion ne change qu\'après confirmation.',
                  style: GoogleFonts.inter(fontSize: 12, color: kTextMuted)),
              const SizedBox(height: 10),
              _SecurityField(ctrl: passCtrl, label: 'Mot de passe actuel'),
              const SizedBox(height: 10),
              _SecurityField(ctrl: emailCtrl, label: 'Nouvel email'),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Annuler')),
              ElevatedButton(
                onPressed: loading
                    ? null
                    : () async {
                        if (!AuthService.isValidEmail(emailCtrl.text)) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                              content: Text('Email invalide'),
                              backgroundColor: Colors.orange));
                          return;
                        }
                        setS(() => loading = true);
                        try {
                          await AuthService().updateEmail(
                              currentPassword: passCtrl.text,
                              newEmail: emailCtrl.text,
                              collection: 'clients');
                          if (mounted) {
                            setState(() => _email = emailCtrl.text.trim());
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Un lien de vérification a été envoyé à votre nouvel email'),
                                    backgroundColor: Colors.green,
                                    duration: Duration(seconds: 4)));
                          }
                        } catch (e) {
                          setS(() => loading = false);
                          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                              content: Text('Erreur : $e'),
                              backgroundColor: Colors.red));
                        }
                      },
                child: const Text('Envoyer la vérification'),
              ),
            ],
          );
        });
      },
    );
  }

  void _showChangePhone() {
    final passCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        bool loading = false;
        return StatefulBuilder(builder: (ctx, setS) {
          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Modifier le téléphone'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              _SecurityField(ctrl: passCtrl, label: 'Mot de passe actuel'),
              const SizedBox(height: 10),
              _SecurityField(ctrl: phoneCtrl, label: 'Nouveau numéro'),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Annuler')),
              ElevatedButton(
                onPressed: loading
                    ? null
                    : () async {
                        if (!AuthService.isValidPhone(phoneCtrl.text)) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                              content: Text('Numéro invalide'),
                              backgroundColor: Colors.orange));
                          return;
                        }
                        setS(() => loading = true);
                        try {
                          await AuthService().updatePhone(
                              currentPassword: passCtrl.text,
                              newPhone: phoneCtrl.text,
                              collection: 'clients');
                          await widget.auth.reload();
                          if (mounted) {
                            setState(() => _phone = phoneCtrl.text.trim());
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Numéro mis à jour'),
                                    backgroundColor: Colors.green));
                          }
                        } catch (e) {
                          setS(() => loading = false);
                          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                              content: Text('Erreur : $e'),
                              backgroundColor: Colors.red));
                        }
                      },
                child: const Text('Enregistrer'),
              ),
            ],
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_profileError != null) {
      return StreamErrorState(
        message: 'Impossible de charger votre profil pour le moment.',
        onRetry: _loadProfile,
      );
    }
    final auth = widget.auth;
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: EdgeInsets.all(hPad(context)),
            child: Column(children: [
              Stack(children: [
                CircleAvatar(
                  radius: 48,
                  backgroundColor: kOrange.withValues(alpha: 0.2),
                  backgroundImage:
                      _photoUrl != null ? NetworkImage(_photoUrl!) : null,
                  child: _photoUrl == null
                      ? Text(
                          auth.clientName.isNotEmpty
                              ? auth.clientName[0].toUpperCase()
                              : 'C',
                          style: const TextStyle(
                              color: kOrange,
                              fontSize: 40,
                              fontWeight: FontWeight.w800))
                      : null,
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onTap: _uploadingPhoto ? null : _changePhoto,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: kOrange,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: const Color(0xFF0F1923), width: 2),
                      ),
                      child: _uploadingPhoto
                          ? const Padding(
                              padding: EdgeInsets.all(7),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.camera_alt_rounded,
                              color: Colors.white, size: 16),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: _showEditName,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(auth.clientName.isEmpty ? 'Ajouter un nom' : auth.clientName,
                      style: GoogleFonts.inter(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(width: 8),
                  const Icon(Icons.edit_rounded, color: kTextMuted, size: 16),
                ]),
              ),
              if (_createdAt != null) ...[
                const SizedBox(height: 4),
                Text('Client depuis le $_createdAt',
                    style: GoogleFonts.inter(color: kTextMuted, fontSize: 13)),
              ],
              const SizedBox(height: 28),

              // Statistiques
              _loadingProfile
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: CircularProgressIndicator(color: kOrange),
                    )
                  : Row(children: [
                      Expanded(
                          child: _StatBox(
                              value: _totalOrders, label: 'Commandes')),
                      const SizedBox(width: 10),
                      Expanded(
                          child: _StatBox(
                              value: _deliveredOrders, label: 'Livrées')),
                      const SizedBox(width: 10),
                      Expanded(
                          child: _StatBox(
                              value: _pendingOrders, label: 'En attente')),
                    ]),

              const SizedBox(height: 28),
              _sectionLabel('Informations personnelles'),
              const SizedBox(height: 10),
              _actionTile(Icons.phone_rounded, 'Téléphone',
                  _phone.isEmpty ? 'Non renseigné' : _phone,
                  onTap: _showChangePhone),
              const SizedBox(height: 10),
              _actionTile(Icons.email_rounded, 'Email',
                  _email.isEmpty ? 'Non renseigné' : _email,
                  onTap: _showChangeEmail),
              const SizedBox(height: 10),
              _actionTile(Icons.lock_rounded, 'Mot de passe', '••••••••',
                  onTap: _showChangePassword),

              const SizedBox(height: 28),
              _sectionLabel('Mon compte'),
              const SizedBox(height: 10),
              _infoTile(Icons.account_balance_wallet, 'Solde wallet',
                  '${auth.wallet} FCFA'),
              const SizedBox(height: 10),
              _navTile(Icons.receipt_long_rounded, 'Historique des commandes',
                  () => context.go('/app/commandes')),
              const SizedBox(height: 10),
              _navTile(Icons.support_agent_rounded, 'Support',
                  () => context.go('/app/support')),

              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    await auth.logout();
                  },
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Se déconnecter'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.withValues(alpha: 0.15),
                    foregroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                            color: Colors.red.withValues(alpha: 0.3))),
                    elevation: 0,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => context.go('/delete-account'),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Supprimer mon compte'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kTextMuted,
                    side: BorderSide(color: kTextMuted.withValues(alpha: 0.3)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String label) => Align(
        alignment: Alignment.centerLeft,
        child: Text(label.toUpperCase(),
            style: GoogleFonts.inter(
                color: kTextMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8)),
      );

  Widget _actionTile(IconData icon, String label, String value,
      {required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: Row(children: [
          Icon(icon, color: kOrange, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: GoogleFonts.inter(color: kTextMuted, fontSize: 11)),
                Text(value,
                    style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Text('Modifier',
              style: GoogleFonts.inter(
                  color: kOrange, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _navTile(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: Row(children: [
          Icon(icon, color: kTextMuted, size: 20),
          const SizedBox(width: 14),
          Expanded(
              child: Text(label,
                  style: GoogleFonts.inter(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600))),
          const Icon(Icons.chevron_right_rounded, color: kTextMuted),
        ]),
      ),
    );
  }

  Widget _infoTile(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Row(children: [
        Icon(icon, color: kOrange, size: 22),
        const SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: GoogleFonts.inter(color: kTextMuted, fontSize: 12)),
          Text(value,
              style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
        ]),
      ]),
    );
  }
}

class _StatBox extends StatelessWidget {
  final int? value;
  final String label;
  const _StatBox({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(children: [
        Text(value?.toString() ?? '—',
            style: GoogleFonts.inter(
                color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(label, style: GoogleFonts.inter(color: kTextMuted, fontSize: 12)),
      ]),
    );
  }
}

class _SecurityField extends StatefulWidget {
  final TextEditingController ctrl;
  final String label;
  const _SecurityField({required this.ctrl, required this.label});

  @override
  State<_SecurityField> createState() => _SecurityFieldState();
}

class _SecurityFieldState extends State<_SecurityField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final isPassword = widget.label.toLowerCase().contains('mot de passe');
    return TextField(
      controller: widget.ctrl,
      obscureText: isPassword && _obscure,
      decoration: InputDecoration(
        labelText: widget.label,
        suffixIcon: isPassword
            ? IconButton(
                icon: Icon(_obscure
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded),
                onPressed: () => setState(() => _obscure = !_obscure),
              )
            : null,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// NAV MOBILE BAS
// ─────────────────────────────────────────────────────────────────────────────
class _MobileNav extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTab;
  const _MobileNav({required this.tab, required this.onTab});

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: tab,
      onTap: onTab,
      backgroundColor: const Color(0xFF161B22),
      selectedItemColor: kOrange,
      unselectedItemColor: kTextMuted,
      type: BottomNavigationBarType.fixed,
      items: const [
        BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded), label: 'Accueil'),
        BottomNavigationBarItem(
            icon: Icon(Icons.receipt_long_rounded), label: 'Commandes'),
        BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet), label: 'Wallet'),
        BottomNavigationBarItem(
            icon: Icon(Icons.person_rounded), label: 'Profil'),
        BottomNavigationBarItem(
            icon: Icon(Icons.support_agent_rounded), label: 'Support'),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SERVICE SANS PAGE WEB
// ─────────────────────────────────────────────────────────────────────────────
/// Affiché lorsqu'une route `/app/<service>` est atteinte alors qu'AUCUNE page
/// web ne l'implémente.
///
/// Vérifié : `lib/web/pages/client/` ne contient que le dashboard et la page
/// de connexion. Les 12 cartes de service et les 2 actions du wallet ne
/// pointent donc vers aucune page réelle. Avant ce correctif, le clic
/// ramenait silencieusement à l'accueil (l'onglet interne repartait à 0) ;
/// l'utilisateur croyait à un bouton cassé. On annonce désormais la limite
/// plutôt que de simuler une navigation.
class _ServiceUnavailable extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;

  const _ServiceUnavailable({
    required this.icon,
    required this.title,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(hPad(context)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: color.withValues(alpha: 0.3)),
                ),
                child: Icon(icon, color: color, size: 40),
              ),
              const SizedBox(height: 24),
              Text(
                title,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Ce service n\'est pas encore disponible depuis le site web. '
                'Il est accessible dans l\'application mobile AZ Express.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(color: kTextMuted, fontSize: 14),
              ),
              const SizedBox(height: 28),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => context.go('/app'),
                    icon: const Icon(Icons.arrow_back_rounded, size: 18),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kOrange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    label: Text('Retour à l\'accueil',
                        style: GoogleFonts.inter(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => context.go('/app/commandes'),
                    icon: const Icon(Icons.receipt_long_rounded, size: 18),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0x33FFFFFF)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    label: Text('Mes commandes',
                        style: GoogleFonts.inter(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
