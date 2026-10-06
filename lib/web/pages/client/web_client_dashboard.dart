import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../web_theme.dart';
import '../../web_client_auth.dart';
import 'web_delivery_page.dart';

/// Route de la page Livraison Express, désormais réellement implémentée
/// (`web_delivery_page.dart`) — elle n'affiche plus `_ServiceUnavailable`.
const clientDeliveryRoute = '/app/commander';

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
    // Livraison Express a maintenant une vraie page web.
    if (loc == clientDeliveryRoute) return null;
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
    'Mon profil'
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
class _OrdersTab extends StatelessWidget {
  final WebClientAuth auth;
  const _OrdersTab({required this.auth});

  @override
  Widget build(BuildContext context) {
    final uid = auth.user?.uid ?? '';
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('orders')
          .where('clientId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(50)
          .snapshots(),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: kOrange));
        }
        final docs = snap.data?.docs ?? [];
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

class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final String id;
  const _OrderCard({required this.data, required this.id});

  Color _statusColor(String s) {
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

  String _statusLabel(String s) {
    switch (s) {
      case 'pending':
        return 'En attente';
      case 'assigned':
        return 'Livreur assigné';
      case 'accepted':
        return 'En route';
      case 'picked_up':
        return 'Récupéré';
      case 'delivered':
        return 'Livré';
      case 'cancelled':
        return 'Annulé';
      default:
        return s;
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = data['status'] as String? ?? 'pending';
    final budget = (data['budget'] as num? ?? 0).toInt();
    final desc = data['description'] as String? ?? '';
    final color = _statusColor(status);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Row(children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.delivery_dining_rounded, color: color, size: 24),
        ),
        const SizedBox(width: 16),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(desc.isNotEmpty ? desc.split('\n').first : 'Livraison',
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
          child: Text(_statusLabel(status),
              style: GoogleFonts.inter(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ]),
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
class _ProfileTab extends StatelessWidget {
  final WebClientAuth auth;
  const _ProfileTab({required this.auth});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: EdgeInsets.all(hPad(context)),
          child: Column(children: [
            CircleAvatar(
              radius: 48,
              backgroundColor: kOrange.withValues(alpha: 0.2),
              child: Text(
                  auth.clientName.isNotEmpty
                      ? auth.clientName[0].toUpperCase()
                      : 'C',
                  style: const TextStyle(
                      color: kOrange,
                      fontSize: 40,
                      fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 16),
            Text(auth.clientName,
                style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(auth.user?.email?.replaceAll('@azexpress.ci', '') ?? '',
                style: GoogleFonts.inter(color: kTextMuted, fontSize: 14)),
            const SizedBox(height: 32),
            _infoTile(Icons.account_balance_wallet, 'Solde wallet',
                '${auth.wallet} FCFA'),
            const SizedBox(height: 32),
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
                      side:
                          BorderSide(color: Colors.red.withValues(alpha: 0.3))),
                  elevation: 0,
                ),
              ),
            ),
          ]),
        ),
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
