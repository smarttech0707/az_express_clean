import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';
import '../widgets/az_logo.dart';

class WebHomePage extends StatelessWidget {
  const WebHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kNavy,
      body: Stack(
        children: [
          SingleChildScrollView(
            child: Column(children: [
              const SizedBox(height: 72), // navbar space
              _HeroSection(),
              _StatsBar(),
              _ServicesSection(),
              _WalletSection(),
              _HowItWorksSection(),
              _AppDownloadSection(),
              _MerchantsSection(),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0, left: 0, right: 0,
            child: WebNavBar(currentRoute: '/'),
          ),
        ],
      ),
    );
  }
}

// ── Hero ──────────────────────────────────────────────────────────────────────
class _HeroSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    final tab  = isTablet(context);
    return Container(
      constraints: BoxConstraints(minHeight: MediaQuery.of(context).size.height - 72),
      decoration: const BoxDecoration(gradient: kHeroGradient),
      child: Stack(
        children: [
          // Background decorative circles
          Positioned(top: -80, right: -80,
            child: _GlowCircle(size: 400, color: kOrange.withValues(alpha: 0.06))),
          Positioned(bottom: 0, left: -120,
            child: _GlowCircle(size: 500, color: kBlue.withValues(alpha: 0.07))),
          Positioned(top: 200, left: '20%'.isEmpty ? 100 : MediaQuery.of(context).size.width * 0.4,
            child: _GlowCircle(size: 200, color: kOrange.withValues(alpha: 0.04))),

          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: hPad(context),
              vertical: desk ? 100 : 60,
            ),
            child: desk
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: _HeroText()),
                      const SizedBox(width: 60),
                      _PhoneMockup(),
                    ],
                  )
                : Column(
                    children: [
                      _HeroText(),
                      if (tab) ...[const SizedBox(height: 48), _PhoneMockup()],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _GlowCircle extends StatelessWidget {
  final double size;
  final Color color;
  const _GlowCircle({required this.size, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    width: size, height: size,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}

class _HeroText extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tag
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: kWhite.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: kWhite.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.flash_on_rounded, color: kWhite, size: 14),
              const SizedBox(width: 6),
              Text(
                'N°1 à Abengourou',
                style: GoogleFonts.inter(
                  fontSize: 13, fontWeight: FontWeight.w600, color: kWhite,
                ),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 600.ms).slideX(begin: -0.2),
        const SizedBox(height: 24),

        // Main headline
        RichText(
          text: TextSpan(
            style: kDisplayStyle(context),
            children: [
              const TextSpan(text: 'Livraison '),
              TextSpan(
                text: 'Express',
                style: kDisplayStyle(context).copyWith(
                  foreground: Paint()
                    ..shader = kOrangeGradient.createShader(
                      const Rect.fromLTWH(0, 0, 200, 60),
                    ),
                ),
              ),
              const TextSpan(text: ',\nServices\n'),
              TextSpan(
                text: 'Instantanés',
                style: kDisplayStyle(context).copyWith(color: kWhite.withValues(alpha: 0.6)),
              ),
            ],
          ),
        ).animate(delay: 200.ms).fadeIn(duration: 700.ms).slideX(begin: -0.15),

        const SizedBox(height: 20),
        Text(
          'Repas, courses, médicaments, transport…\nLivrés en minutes à Abengourou et en Côte d\'Ivoire.',
          style: kBodyStyle(color: kTextMuted, size: desk ? 17 : 15),
        ).animate(delay: 350.ms).fadeIn(duration: 600.ms),
        const SizedBox(height: 36),

        // CTA buttons
        Wrap(
          spacing: 14, runSpacing: 12,
          children: [
            _HeroButton(
              label: '🚀 Commander maintenant',
              isPrimary: true,
              onTap: () => context.go('/connexion'),
            ),
            _HeroButton(
              label: '📱 Télécharger l\'App',
              isPrimary: false,
              onTap: () => launchUrl(Uri.parse('https://play.google.com')),
            ),
            _HeroButton(
              label: '🛵 Devenir Livreur',
              isPrimary: false,
              onTap: () => context.go('/livreurs'),
            ),
          ],
        ).animate(delay: 500.ms).fadeIn(duration: 600.ms).slideY(begin: 0.2),

        const SizedBox(height: 40),

        // App store badges
        Wrap(
          spacing: 12, runSpacing: 8,
          children: [
            _StoreBadge(
              icon: Icons.android_rounded,
              title: 'Google Play',
              subtitle: 'Télécharger sur',
              color: const Color(0xFF34A853),
              onTap: () => launchUrl(Uri.parse('https://play.google.com')),
            ),
            _StoreBadge(
              icon: Icons.apple_rounded,
              title: 'App Store',
              subtitle: 'Disponible sur',
              color: const Color(0xFF555555),
              onTap: () => launchUrl(Uri.parse('https://apps.apple.com')),
            ),
          ],
        ).animate(delay: 650.ms).fadeIn(duration: 600.ms),
      ],
    );
  }
}

class _HeroButton extends StatefulWidget {
  final String label;
  final bool isPrimary;
  final VoidCallback onTap;
  const _HeroButton({required this.label, required this.isPrimary, required this.onTap});

  @override
  State<_HeroButton> createState() => _HeroButtonState();
}

class _HeroButtonState extends State<_HeroButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.04 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
            decoration: widget.isPrimary
                ? orangeGlowDecoration
                : BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kOrange, width: 1.5),
                  ),
            child: Text(
              widget.label,
              style: GoogleFonts.inter(
                fontSize: 15, fontWeight: FontWeight.w700,
                color: widget.isPrimary ? kWhite : kOrange,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StoreBadge extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  const _StoreBadge({
    required this.icon, required this.title,
    required this.subtitle, required this.color, required this.onTap,
  });

  @override
  State<_StoreBadge> createState() => _StoreBadgeState();
}

class _StoreBadgeState extends State<_StoreBadge> {
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _hover ? kNavyCard.withValues(alpha: 0.9) : kNavyCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _hover ? kOrange.withValues(alpha: 0.4) : kDivider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, color: widget.color, size: 26),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.subtitle, style: GoogleFonts.inter(fontSize: 10, color: kTextMuted)),
                  Text(widget.title, style: GoogleFonts.inter(
                    fontSize: 14, fontWeight: FontWeight.w700, color: kWhite,
                  )),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhoneMockup extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      height: 560,
      decoration: BoxDecoration(
        color: const Color(0xFFFF6D00),
        borderRadius: BorderRadius.circular(40),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 2),
        boxShadow: [
          BoxShadow(color: kOrange.withValues(alpha: 0.30), blurRadius: 60, offset: const Offset(-10, 20)),
          BoxShadow(color: kOrange.withValues(alpha: 0.15), blurRadius: 40, offset: const Offset(10, 20)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(38),
        child: Stack(
          children: [
            // Status bar
            Positioned(top: 16, left: 20, right: 20,
              child: Row(
                children: [
                  Text('9:41', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: kWhite)),
                  const Spacer(),
                  const Icon(Icons.signal_cellular_4_bar, size: 14, color: kWhite),
                  const SizedBox(width: 4),
                  const Icon(Icons.wifi_rounded, size: 14, color: kWhite),
                  const SizedBox(width: 4),
                  const Icon(Icons.battery_full_rounded, size: 14, color: kWhite),
                ],
              ),
            ),
            // Notch
            Positioned(top: 0, left: 0, right: 0,
              child: Center(
                child: Container(
                  width: 120, height: 28,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFF6D00),
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(20),
                      bottomRight: Radius.circular(20),
                    ),
                  ),
                ),
              ),
            ),
            // App content preview
            Positioned(top: 52, left: 0, right: 0, bottom: 0,
              child: _AppScreenPreview(),
            ),
          ],
        ),
      ),
    ).animate(delay: 400.ms).fadeIn(duration: 800.ms).slideX(begin: 0.2);
  }
}

class _AppScreenPreview extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Orange gradient top (comme l'app réelle) ──
        Expanded(
          flex: 5,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFFF6D00), Color(0xFFFF8F00), Color(0xFFFFB300)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Top bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(children: [
                    Text('AZ EXPRESS', style: GoogleFonts.inter(
                      fontSize: 13, fontWeight: FontWeight.w900,
                      color: Colors.white, letterSpacing: 1.5)),
                    const Spacer(),
                    Container(
                      width: 26, height: 26,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.language, color: Colors.white, size: 14),
                    ),
                  ]),
                ),
                // Logo centré
                Column(
                  children: [
                    Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(color: Colors.white.withValues(alpha: 0.5),
                            blurRadius: 20, spreadRadius: 6),
                        ],
                      ),
                      child: const Center(child: AzLogo(size: 52)),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text('Abengourou & environs',
                        style: GoogleFonts.inter(fontSize: 9, color: Colors.white)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        // ── Bas blanc arrondi (comme l'app réelle) ──
        Expanded(
          flex: 4,
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFFF5F5F5),
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
            ),
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
            child: Column(
              children: [
                Container(width: 28, height: 3, margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2))),
                _appCard('Commander', 'Livraison express',
                  Icons.shopping_bag_rounded,
                  const [Color(0xFFFF6D00), Color(0xFFFF8F00)]),
                const SizedBox(height: 8),
                _appCard('Boulangerie & Café', 'Viennoiseries livrées',
                  Icons.bakery_dining_rounded,
                  const [Color(0xFF4E342E), Color(0xFF8D6E63)]),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _appCard(String title, String sub, IconData icon, List<Color> colors) {
    return Container(
      height: 52,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors,
          begin: Alignment.centerLeft, end: Alignment.centerRight),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(
          color: colors.first.withValues(alpha: 0.35),
          blurRadius: 8, offset: const Offset(0, 4))],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: GoogleFonts.inter(
              fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
            Text(sub, style: GoogleFonts.inter(
              fontSize: 9, color: Colors.white.withValues(alpha: 0.8))),
          ],
        )),
        const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 10),
      ]),
    );
  }
}

// ── Wallet section ────────────────────────────────────────────────────────────
class _WalletSection extends StatelessWidget {
  static const _features = [
    (Icons.add_card_rounded,             kOrange,              'Recharger',       'Wave, MTN Money, Orange Money, Moov Money.'),
    (Icons.send_rounded,                 kBlue,                'Transférer',      'Envoyez de l\'argent à un autre utilisateur AZ Express.'),
    (Icons.receipt_long_rounded,         kSuccess,             'Historique',      'Consultez toutes vos transactions en temps réel.'),
    (Icons.shopping_bag_rounded,         Color(0xFF9C27B0),    'Payer commande',  'Utilisez votre solde pour régler vos commandes.'),
  ];

  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    return Container(
      color: kNavyMid,
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 80),
      child: Column(
        children: [
          const _SectionHeader(
            tag: 'WALLET',
            title: 'Votre portefeuille\nnumérique intégré',
            subtitle: 'Rechargez, transférez et payez directement depuis l\'app.',
          ),
          const SizedBox(height: 48),
          desk
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: _walletVisual()),
                    const SizedBox(width: 60),
                    Expanded(flex: 3, child: _walletFeatures(context)),
                  ],
                )
              : Column(children: [
                  _walletFeatures(context),
                  const SizedBox(height: 32),
                  _walletVisual(),
                ]),
        ],
      ),
    );
  }

  Widget _walletVisual() {
    return Container(
      height: 280,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFF6D00), Color(0xFFFF8F00)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(
          color: kOrange.withValues(alpha: 0.3),
          blurRadius: 30, offset: const Offset(0, 10),
        )],
      ),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.account_balance_wallet_rounded, color: Colors.white, size: 22),
            const SizedBox(width: 8),
            Text('AZ Wallet', style: GoogleFonts.inter(
              fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('Actif', style: GoogleFonts.inter(
                fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ]),
          const Spacer(),
          Text('Solde disponible', style: GoogleFonts.inter(
            fontSize: 12, color: Colors.white.withValues(alpha: 0.7))),
          const SizedBox(height: 6),
          Text('12 500 FCFA', style: GoogleFonts.inter(
            fontSize: 32, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 16),
          Row(children: [
            _walletBadge(Icons.add_rounded, 'Recharger'),
            const SizedBox(width: 10),
            _walletBadge(Icons.send_rounded, 'Envoyer'),
          ]),
        ],
      ),
    ).animate().fadeIn(duration: 700.ms).slideX(begin: -0.1);
  }

  Widget _walletBadge(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: Colors.white, size: 14),
        const SizedBox(width: 6),
        Text(label, style: GoogleFonts.inter(
          fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _walletFeatures(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: isDesktop(context) ? 2 : 2,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: isDesktop(context) ? 1.3 : 1.1,
      ),
      itemCount: _features.length,
      itemBuilder: (_, i) => Container(
        padding: const EdgeInsets.all(20),
        decoration: glassCard(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: _features[i].$2.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_features[i].$1, color: _features[i].$2, size: 22),
            ),
            const SizedBox(height: 12),
            Text(_features[i].$3, style: GoogleFonts.inter(
              fontSize: 14, fontWeight: FontWeight.w700, color: kText)),
            const SizedBox(height: 6),
            Expanded(child: Text(_features[i].$4, style: GoogleFonts.inter(
              fontSize: 12, color: kTextMuted, height: 1.5))),
          ],
        ),
      ).animate(delay: (i * 80).ms).fadeIn(duration: 600.ms).slideY(begin: 0.1),
    );
  }
}

// ── Stats bar ─────────────────────────────────────────────────────────────────
class _StatsBar extends StatelessWidget {
  static const _stats = [
    ('50K+', 'Commandes'),
    ('500+', 'Livreurs actifs'),
    ('10+',  'Villes couvertes'),
    ('4.8★', 'Note moyenne'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kOrangeBg,
      padding: EdgeInsets.symmetric(
        horizontal: hPad(context),
        vertical: 28,
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceAround,
        spacing: 16,
        runSpacing: 20,
        children: _stats.map((s) => _StatItem(value: s.$1, label: s.$2)).toList(),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String value;
  final String label;
  const _StatItem({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: GoogleFonts.inter(
          fontSize: 32, fontWeight: FontWeight.w800, color: kOrange,
        )),
        const SizedBox(height: 4),
        Text(label, style: GoogleFonts.inter(fontSize: 14, color: kText)),
      ],
    );
  }
}

// ── Services section ──────────────────────────────────────────────────────────
class _ServicesSection extends StatelessWidget {
  static const _services = [
    (Icons.delivery_dining_rounded,       'Livraison Express',    'Colis livrés en 30 min chrono.', kOrange),
    (Icons.bakery_dining_rounded,         'Boulangerie & Café',   'Viennoiseries fraîches & gâteaux personnalisés.', Color(0xFF795548)),
    (Icons.restaurant_menu_rounded,       'Restaurants',          'Vos plats préférés livrés chauds.', Color(0xFFE91E63)),
    (Icons.local_pharmacy_rounded,        'Pharmacie de garde',   'Médicaments 24h/24, 7j/7.', kSuccess),
    (Icons.storefront_rounded,            'Boutique',             'Achetez chez les commerçants locaux.', Color(0xFF9C27B0)),
    (Icons.shopping_bag_rounded,          'Courses Libres',       'Un livreur fait vos courses à votre place.', Color(0xFF3F51B5)),
    (Icons.home_rounded,                  'Immobilier',           'Maisons & résidences meublées à Abengourou.', Color(0xFF00BCD4)),
    (Icons.local_taxi_rounded,            'Taxi & Tricycle',      'Taxi de nuit & location de tricycle.', Color(0xFFFF5722)),
  ];

  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    final tab  = isTablet(context);
    final cols = desk ? 4 : (tab ? 3 : 2);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 80),
      child: Column(
        children: [
          const _SectionHeader(
            tag: 'NOS SERVICES',
            title: 'Tout ce dont vous avez\nbesoin, livré',
            subtitle: 'Une seule app pour tous vos besoins quotidiens.',
          ),
          const SizedBox(height: 48),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: desk ? 1.1 : 0.95,
            ),
            itemCount: _services.length,
            itemBuilder: (_, i) => _ServiceCard(
              icon: _services[i].$1,
              title: _services[i].$2,
              desc: _services[i].$3,
              color: _services[i].$4,
              delay: (i * 80).ms,
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String desc;
  final Color color;
  final Duration delay;
  const _ServiceCard({required this.icon, required this.title,
    required this.desc, required this.color, required this.delay});

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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _hover ? kNavyCard.withValues(alpha: 0.9) : kNavyCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _hover ? widget.color.withValues(alpha: 0.5) : kDivider,
            width: 1.5,
          ),
          boxShadow: _hover ? [
            BoxShadow(color: widget.color.withValues(alpha: 0.15), blurRadius: 24, offset: const Offset(0, 8)),
          ] : [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 50, height: 50,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(widget.icon, color: widget.color, size: 26),
            ),
            const SizedBox(height: 16),
            Text(widget.title, style: GoogleFonts.inter(
              fontSize: 15, fontWeight: FontWeight.w700, color: kText,
            )),
            const SizedBox(height: 8),
            Expanded(
              child: Text(widget.desc, style: GoogleFonts.inter(
                fontSize: 13, color: kTextGrey, height: 1.5,
              )),
            ),
          ],
        ),
      ),
    ).animate(delay: widget.delay).fadeIn(duration: 600.ms).slideY(begin: 0.15);
  }
}

// ── How it works ──────────────────────────────────────────────────────────────
class _HowItWorksSection extends StatelessWidget {
  static const _steps = [
    ('1', Icons.touch_app_rounded,       'Commandez',        'Choisissez votre service et passez commande en quelques secondes.', kOrange),
    ('2', Icons.check_circle_rounded,    'Acceptation',      'Un livreur proche accepte et prend en charge votre commande.', kBlue),
    ('3', Icons.location_on_rounded,     'Suivi en direct',  'Suivez votre livreur en temps réel sur la carte.', kSuccess),
    ('4', Icons.celebration_rounded,     'Livraison',        'Recevez votre commande et notez votre expérience.', Color(0xFF9C27B0)),
  ];

  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    return Container(
      color: kNavyMid,
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 80),
      child: Column(
        children: [
          const _SectionHeader(
            tag: 'COMMENT ÇA MARCHE',
            title: 'Simple. Rapide. Fiable.',
            subtitle: '4 étapes pour recevoir ce que vous voulez, où vous êtes.',
          ),
          const SizedBox(height: 56),
          desk
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _steps.asMap().entries.map((e) =>
                    Expanded(child: _StepCard(
                      number: e.value.$1,
                      icon: e.value.$2,
                      title: e.value.$3,
                      desc: e.value.$4,
                      color: e.value.$5,
                      isLast: e.key == _steps.length - 1,
                    )),
                  ).toList(),
                )
              : Column(
                  children: _steps.map((s) => _StepCardMobile(
                    number: s.$1, icon: s.$2, title: s.$3, desc: s.$4, color: s.$5,
                  )).toList(),
                ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final String number;
  final IconData icon;
  final String title;
  final String desc;
  final Color color;
  final bool isLast;
  const _StepCard({required this.number, required this.icon, required this.title,
    required this.desc, required this.color, required this.isLast});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.12),
                border: Border.all(color: color.withValues(alpha: 0.4), width: 2),
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            Positioned(
              top: -8, right: -8,
              child: Container(
                width: 24, height: 24,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                child: Center(
                  child: Text(number, style: GoogleFonts.inter(
                    fontSize: 11, fontWeight: FontWeight.w800, color: kWhite,
                  )),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              Text(title, style: GoogleFonts.inter(
                fontSize: 16, fontWeight: FontWeight.w700, color: kText,
              ), textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(desc, style: GoogleFonts.inter(
                fontSize: 13, color: kTextGrey, height: 1.6,
              ), textAlign: TextAlign.center),
            ],
          ),
        ),
      ],
    );
  }
}

class _StepCardMobile extends StatelessWidget {
  final String number;
  final IconData icon;
  final String title;
  final String desc;
  final Color color;
  const _StepCardMobile({required this.number, required this.icon, required this.title,
    required this.desc, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.12),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Center(
              child: Text(number, style: GoogleFonts.inter(
                fontSize: 18, fontWeight: FontWeight.w800, color: color,
              )),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: GoogleFonts.inter(
                  fontSize: 16, fontWeight: FontWeight.w700, color: kText,
                )),
                const SizedBox(height: 6),
                Text(desc, style: GoogleFonts.inter(fontSize: 13, color: kTextMuted, height: 1.6)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Download section ──────────────────────────────────────────────────────────
class _AppDownloadSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    return Container(
      margin: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 80),
      padding: EdgeInsets.symmetric(horizontal: desk ? 60 : 28, vertical: 56),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1A2E), Color(0xFF16213E), Color(0xFF0F3460)],
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: kDivider),
      ),
      child: desk
          ? Row(
              children: [
                Expanded(child: _downloadText(context)),
                const SizedBox(width: 48),
                _downloadBadges(context),
              ],
            )
          : Column(
              children: [
                _downloadText(context),
                const SizedBox(height: 28),
                _downloadBadges(context),
              ],
            ),
    );
  }

  Widget _downloadText(BuildContext ctx) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: kOrange.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text('DISPONIBLE MAINTENANT',
            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w700,
              color: kOrange, letterSpacing: 1.2)),
        ),
        const SizedBox(height: 16),
        Text('Téléchargez\nAZ Express',
          style: GoogleFonts.inter(
            fontSize: isDesktop(ctx) ? 36 : 28,
            fontWeight: FontWeight.w800,
            color: kWhite, height: 1.2,
          )),
        const SizedBox(height: 14),
        Text('Ton wallet, tes commandes, ta boutique.\nGratuit sur Android et iOS.',
          style: GoogleFonts.inter(fontSize: 15, color: kTextMuted, height: 1.6)),
      ],
    );
  }

  Widget _downloadBadges(BuildContext ctx) {
    return const Column(
      children: [
        _BigBadge(
          color: Color(0xFF34A853),
          icon: Icons.android_rounded,
          store: 'Google Play',
          url: 'https://play.google.com',
        ),
        SizedBox(height: 12),
        _BigBadge(
          color: Color(0xFF555555),
          icon: Icons.apple_rounded,
          store: 'App Store',
          url: 'https://apps.apple.com',
        ),
      ],
    );
  }
}

class _BigBadge extends StatefulWidget {
  final Color color;
  final IconData icon;
  final String store;
  final String url;
  const _BigBadge({required this.color, required this.icon,
    required this.store, required this.url});

  @override
  State<_BigBadge> createState() => _BigBadgeState();
}

class _BigBadgeState extends State<_BigBadge> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => launchUrl(Uri.parse(widget.url)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 200,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: _hover ? kNavyCard : kNavyDark,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _hover ? kOrange.withValues(alpha: 0.5) : kDivider),
          ),
          child: Row(
            children: [
              Icon(widget.icon, color: widget.color, size: 30),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Disponible sur', style: GoogleFonts.inter(fontSize: 10, color: kTextMuted)),
                  Text(widget.store, style: GoogleFonts.inter(
                    fontSize: 15, fontWeight: FontWeight.w700, color: kWhite,
                  )),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Merchants preview ─────────────────────────────────────────────────────────
class _MerchantsSection extends StatelessWidget {
  static const _perks = [
    (Icons.trending_up_rounded,   'Augmentez vos ventes',    'Touchez des milliers de clients supplémentaires.'),
    (Icons.dashboard_rounded,     'Dashboard complet',       'Gérez vos commandes, stocks et revenus en temps réel.'),
    (Icons.payments_rounded,      'Paiements sécurisés',     'Wave, MTN Money, Orange Money et Moov Money via FeexPay.'),
    (Icons.support_agent_rounded, 'Support 7j/7',            'Une équipe dédiée à votre réussite.'),
  ];

  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    return Container(
      color: kNavyMid,
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 80),
      child: Column(
        children: [
          const _SectionHeader(
            tag: 'PARTENAIRES',
            title: 'Développez votre\nbusiness avec nous',
            subtitle: 'Rejoignez plus de 200 commerçants qui font confiance à AZ Express.',
          ),
          const SizedBox(height: 48),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: desk ? 4 : 2,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: desk ? 1.0 : 0.9,
            ),
            itemCount: _perks.length,
            itemBuilder: (_, i) => Container(
              padding: const EdgeInsets.all(24),
              decoration: glassCard(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 46, height: 46,
                    decoration: BoxDecoration(
                      color: kOrange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(_perks[i].$1, color: kOrange, size: 22),
                  ),
                  const SizedBox(height: 14),
                  Text(_perks[i].$2, style: GoogleFonts.inter(
                    fontSize: 14, fontWeight: FontWeight.w700, color: kText,
                  )),
                  const SizedBox(height: 8),
                  Text(_perks[i].$3, style: GoogleFonts.inter(
                    fontSize: 12, color: kTextMuted, height: 1.6,
                  )),
                ],
              ),
            ).animate(delay: (i * 100).ms).fadeIn(duration: 600.ms).slideY(begin: 0.1),
          ),
          const SizedBox(height: 40),
          _ActionButton(
            label: 'Devenir partenaire →',
            onTap: () => context.go('/commercants'),
          ),
        ],
      ),
    );
  }
}

// ── Shared components ─────────────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final String tag;
  final String title;
  final String subtitle;
  const _SectionHeader({required this.tag, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: kOrange.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(tag, style: GoogleFonts.inter(
            fontSize: 12, fontWeight: FontWeight.w700,
            color: kOrange, letterSpacing: 1.2,
          )),
        ),
        const SizedBox(height: 16),
        Text(title,
          style: GoogleFonts.inter(
            fontSize: isDesktop(context) ? 36 : 24,
            fontWeight: FontWeight.w700, color: kText, height: 1.2),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(subtitle,
          style: GoogleFonts.inter(fontSize: 16, color: kTextGrey, height: 1.7),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _ActionButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _ActionButton({required this.label, required this.onTap});

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.03 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            decoration: orangeGlowDecoration,
            child: Text(widget.label, style: GoogleFonts.inter(
              fontSize: 15, fontWeight: FontWeight.w700, color: kWhite,
            )),
          ),
        ),
      ),
    );
  }
}
