import 'package:flutter/material.dart';

import '../artisan/artisan_login.dart';
import '../driver/driver_login.dart';
import '../fleet/fleet_login.dart';
import '../seller/seller_login.dart';
import '../restaurant/restaurant_owner_login.dart';
import '../pharmacie/pharmacie_login.dart';
import '../boulangerie/boulangerie_login.dart';
import '../../theme/app_theme.dart';
import '../../event/screens/event_provider_portal.dart';

/// Espace professionnel : huit accès partenaires, rangés en trois catégories.
/// Chaque carte ouvre la page de connexion de son rôle (routes inchangées ;
/// les inscriptions et permissions vivent dans ces pages, pas ici).
class ProPortal extends StatelessWidget {
  const ProPortal({super.key});

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.premiumBg(b),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Retour',
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text('Espace Professionnel'),
        centerTitle: true,
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            _PartnerNotice(brightness: b),
            for (final section in _sections) ...[
              const SizedBox(height: 24),
              Semantics(
                header: true,
                child: Text(
                  section.title,
                  style: text.titleSmall?.copyWith(
                    color: AppColors.premiumTextSecondary(b),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              for (final entry in section.entries) ...[
                _ProCard(entry: entry, brightness: b),
                const SizedBox(height: 10),
              ],
            ],
            const SizedBox(height: 12),
            Center(
              child: Text(
                'AZ Express — Abengourou',
                style: text.bodySmall
                    ?.copyWith(color: AppColors.premiumTextSecondary(b)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Données : catégories et accès ────────────────────────────────────────────

enum _Accent { orange, blue, green, violet }

class _ProEntry {
  final IconData icon;
  final String title;
  final String subtitle;
  final _Accent accent;
  final Widget Function() page;

  const _ProEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.page,
  });
}

class _ProSection {
  final String title;
  final List<_ProEntry> entries;
  const _ProSection(this.title, this.entries);
}

final List<_ProSection> _sections = [
  _ProSection('LIVRAISON ET TRANSPORT', [
    _ProEntry(
      icon: Icons.delivery_dining_rounded,
      title: 'Livreur',
      subtitle: 'Accédez à votre espace courses',
      accent: _Accent.blue,
      page: () => const DriverLogin(),
    ),
    _ProEntry(
      icon: Icons.motorcycle_rounded,
      title: 'Patron de Flotte',
      subtitle: 'Gérez vos livreurs et vos gains',
      accent: _Accent.violet,
      page: () => const FleetLogin(),
    ),
  ]),
  _ProSection('COMMERCE', [
    _ProEntry(
      icon: Icons.storefront_rounded,
      title: 'Boutique / Vendeur',
      subtitle: 'Gérez vos produits et commandes',
      accent: _Accent.orange,
      page: () => const SellerLogin(),
    ),
    _ProEntry(
      icon: Icons.restaurant_rounded,
      title: 'Restaurant',
      subtitle: 'Gérez votre menu et vos commandes',
      accent: _Accent.orange,
      page: () => const RestaurantOwnerLogin(),
    ),
    _ProEntry(
      icon: Icons.local_pharmacy_rounded,
      title: 'Pharmacie',
      subtitle: 'Gérez votre statut de garde et wallet',
      accent: _Accent.green,
      page: () => const PharmacieLogin(),
    ),
    _ProEntry(
      icon: Icons.bakery_dining_rounded,
      title: 'Boulangerie / Café',
      subtitle: 'Gérez votre menu et vos commandes',
      accent: _Accent.orange,
      page: () => const BoulangerieLogin(),
    ),
  ]),
  _ProSection('SERVICES', [
    _ProEntry(
      icon: Icons.handyman_rounded,
      title: 'Artisan / Mécanicien',
      subtitle: 'Gérez vos photos de réalisations',
      accent: _Accent.blue,
      page: () => const ArtisanLogin(),
    ),
    _ProEntry(
      icon: Icons.celebration_rounded,
      title: 'Prestataire événementiel',
      subtitle: 'Locations, décoration, traiteur & personnel',
      accent: _Accent.violet,
      page: () => const EventProviderPortal(),
    ),
  ]),
];

Color _accentColor(_Accent a, Brightness b) {
  final dark = b == Brightness.dark;
  switch (a) {
    case _Accent.orange:
      return AppColors.primaryText(b);
    case _Accent.blue:
      return dark ? AppColors.blue.withValues(alpha: 1) : AppColors.blueAction;
    case _Accent.green:
      return dark ? AppColors.success : AppColors.successStrong;
    case _Accent.violet:
      return dark ? AppColors.eventAccentDark : AppColors.eventAccent;
  }
}

// ── Composants ───────────────────────────────────────────────────────────────

class _PartnerNotice extends StatelessWidget {
  final Brightness brightness;
  const _PartnerNotice({required this.brightness});

  @override
  Widget build(BuildContext context) {
    final b = brightness;
    final text = Theme.of(context).textTheme;
    final accent = AppColors.primaryText(b);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: AppRadius.cardR,
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.verified_user_rounded, color: accent, size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Accès réservé aux partenaires',
                    style: text.titleSmall?.copyWith(
                        color: AppColors.premiumTextPrimary(b),
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                    'Comptes créés par l\'administrateur AZ Express uniquement.',
                    style: text.bodySmall?.copyWith(
                        color: AppColors.premiumTextSecondary(b))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProCard extends StatelessWidget {
  final _ProEntry entry;
  final Brightness brightness;
  const _ProCard({required this.entry, required this.brightness});

  @override
  Widget build(BuildContext context) {
    final b = brightness;
    final text = Theme.of(context).textTheme;
    final accent = _accentColor(entry.accent, b);
    return Semantics(
      button: true,
      label: '${entry.title}. ${entry.subtitle}',
      excludeSemantics: true,
      child: Material(
        color: AppColors.premiumSurface(b),
        borderRadius: AppRadius.cardR,
        child: InkWell(
          borderRadius: AppRadius.cardR,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => entry.page()),
          ),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: AppRadius.cardR,
              border: Border.all(color: AppColors.premiumBorder(b)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(entry.icon, color: accent, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.title,
                          style: text.titleMedium?.copyWith(
                              color: AppColors.premiumTextPrimary(b),
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(entry.subtitle,
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
