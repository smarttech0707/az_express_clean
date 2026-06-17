import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../web_theme.dart';
import 'az_logo.dart';
import '../../constants/app_constants.dart';

class WebFooter extends StatelessWidget {
  const WebFooter({super.key});

  static const _services = [
    'Livraison Express',
    'Courses & Shopping',
    'Restaurants',
    'Boulangerie & Café',
    'Pharmacie de garde',
    'Artisans & Réparations',
    'Immobilier',
    'Transport',
  ];

  static const _pages = [
    ('Comment ça marche', '/comment-ca-marche'),
    ('Commerçants',       '/commercants'),
    ('Livreurs',          '/livreurs'),
    ('À propos',          '/a-propos'),
    ('Contact',           '/contact'),
  ];

  static const _legal = [
    ('Politique de confidentialité', '/confidentialite'),
    ('Conditions d\'utilisation',    '/conditions'),
  ];

  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    return Container(
      color: const Color(0xFF1A1A2E),
      child: Column(
        children: [
          // Divider top
          Container(height: 1, color: kDivider),
          // Content
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: hPad(context),
              vertical: 60,
            ),
            child: desk ? _desktopLayout(context) : _mobileLayout(context),
          ),
          // Bottom bar
          Container(
            height: 1, color: kDivider,
          ),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: hPad(context),
              vertical: 20,
            ),
            child: desk
                ? Row(
                    children: [
                      Text(
                        '© ${DateTime.now().year} AZ Express. Tous droits réservés.',
                        style: kBodyStyle(color: kTextMuted, size: 13),
                      ),
                      const Spacer(),
                      _socialIcons(),
                    ],
                  )
                : Column(
                    children: [
                      _socialIcons(),
                      const SizedBox(height: 12),
                      Text(
                        '© ${DateTime.now().year} AZ Express. Tous droits réservés.',
                        style: kBodyStyle(color: kTextMuted, size: 12),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _desktopLayout(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 3, child: _brand(context)),
        const SizedBox(width: 60),
        Expanded(flex: 2, child: _col('Services', _services.map((s) => (s, '')).toList(), context, isLink: false)),
        const SizedBox(width: 40),
        Expanded(flex: 2, child: _col('Plateforme', _pages.toList(), context)),
        const SizedBox(width: 40),
        Expanded(flex: 2, child: _col('Légal', _legal.toList(), context)),
      ],
    );
  }

  Widget _mobileLayout(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _brand(context),
        const SizedBox(height: 40),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _col('Plateforme', _pages.toList(), context)),
            const SizedBox(width: 24),
            Expanded(child: _col('Légal', _legal.toList(), context)),
          ],
        ),
      ],
    );
  }

  Widget _brand(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AzLogo(size: 40),
            const SizedBox(width: 10),
            Text(
              'AZ Express',
              style: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w800, color: kWhite),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'La plateforme N°1 de livraison express\net de services en Côte d\'Ivoire.',
          style: kBodyStyle(color: kTextMuted, size: 14),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: kNavyCard,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kDivider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on_rounded, color: kOrange, size: 16),
              const SizedBox(width: 6),
              Text('Abengourou, Côte d\'Ivoire', style: kBodyStyle(color: kTextMuted, size: 13)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _col(String title, List<(String, String)> items, BuildContext context, {bool isLink = true}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w700, color: kWhite)),
        const SizedBox(height: 16),
        ...items.map((item) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: isLink && item.$2.isNotEmpty
              ? MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => context.go(item.$2),
                    child: Text(item.$1, style: kBodyStyle(color: kTextMuted, size: 13)),
                  ),
                )
              : Text(item.$1, style: kBodyStyle(color: kTextMuted, size: 13)),
        )),
      ],
    );
  }

  Widget _socialIcons() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _social(Icons.facebook_rounded, 'https://facebook.com'),
        _social(Icons.camera_alt_rounded, 'https://instagram.com'),
        _social(Icons.chat_rounded, AppConfig.whatsAppUrl),
      ],
    );
  }

  Widget _social(IconData icon, String url) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => launchUrl(Uri.parse(url)),
        child: Container(
          margin: const EdgeInsets.only(left: 8),
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: kNavyCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kDivider),
          ),
          child: Icon(icon, color: kTextMuted, size: 18),
        ),
      ),
    );
  }
}

