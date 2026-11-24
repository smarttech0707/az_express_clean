import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';
import '../../constants/app_constants.dart';

/// Page "Télécharger l'application".
///
/// État honnête et vérifié (voir `AZ_EXPRESS_MARKETING_KIT.md` : le lien
/// Play Store est explicitement "à ajouter dès publication réelle", l'app
/// n'est pas encore publiée sur les stores officiels). Pas de badge Play
/// Store / App Store menant vers une fiche qui n'existe pas : on oriente
/// vers un contact direct (WhatsApp) pour obtenir l'app, sans jamais
/// affirmer une disponibilité store qui n'est pas réelle.
class WebDownloadPage extends StatelessWidget {
  const WebDownloadPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kNavy,
      body: Stack(
        children: [
          SingleChildScrollView(
            child: Column(children: [
              const SizedBox(height: 72),
              _hero(context),
              _platformsSection(context),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: WebNavBar(currentRoute: '/telecharger'),
          ),
        ],
      ),
    );
  }

  Widget _hero(BuildContext ctx) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 80),
      decoration: const BoxDecoration(gradient: kHeroGradient),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
              color: kOrange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20)),
          child: Text('APPLICATION MOBILE',
              style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: kOrange,
                  letterSpacing: 1.2)),
        ).animate().fadeIn(duration: 600.ms),
        const SizedBox(height: 20),
        Text('Téléchargez\nAZ Express',
            style: kDisplayStyle(ctx), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Text(
          'Toutes vos commandes, votre wallet et vos services AZ Express,\n'
          'directement sur votre téléphone.',
          style: GoogleFonts.inter(fontSize: 16, color: kTextMuted),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }

  Widget _platformsSection(BuildContext ctx) {
    final desk = isDesktop(ctx);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 72),
      child: Column(
        children: [
          desk
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _PlatformCard(
                        icon: Icons.android_rounded,
                        color: const Color(0xFF34A853),
                        title: 'Android',
                        status: 'Sur demande',
                        description:
                            'En attendant la publication sur Google Play, '
                            'contactez notre équipe sur WhatsApp pour obtenir '
                            'l\'application.',
                        ctaLabel: 'Contacter l\'équipe',
                        onTap: () => launchUrl(Uri.parse(AppConfig.whatsAppUrl)),
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      child: _PlatformCard(
                        icon: Icons.apple_rounded,
                        color: const Color(0xFF555555),
                        title: 'iOS',
                        status: 'Bientôt disponible',
                        description:
                            'La version iOS d\'AZ Express est en préparation. '
                            'Contactez-nous pour être informé dès sa sortie.',
                        ctaLabel: 'Être informé',
                        onTap: () => launchUrl(Uri.parse(AppConfig.whatsAppUrl)),
                      ),
                    ),
                  ],
                )
              : Column(children: [
                  _PlatformCard(
                    icon: Icons.android_rounded,
                    color: const Color(0xFF34A853),
                    title: 'Android',
                    status: 'Sur demande',
                    description:
                        'En attendant la publication sur Google Play, '
                        'contactez notre équipe sur WhatsApp pour obtenir '
                        'l\'application.',
                    ctaLabel: 'Contacter l\'équipe',
                    onTap: () => launchUrl(Uri.parse(AppConfig.whatsAppUrl)),
                  ),
                  const SizedBox(height: 20),
                  _PlatformCard(
                    icon: Icons.apple_rounded,
                    color: const Color(0xFF555555),
                    title: 'iOS',
                    status: 'Bientôt disponible',
                    description:
                        'La version iOS d\'AZ Express est en préparation. '
                        'Contactez-nous pour être informé dès sa sortie.',
                    ctaLabel: 'Être informé',
                    onTap: () => launchUrl(Uri.parse(AppConfig.whatsAppUrl)),
                  ),
                ]),
        ],
      ),
    );
  }
}

class _PlatformCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String status;
  final String description;
  final String ctaLabel;
  final VoidCallback onTap;

  const _PlatformCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.status,
    required this.description,
    required this.ctaLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: glassCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.12),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 18),
          Text(title,
              style: GoogleFonts.inter(
                  fontSize: 20, fontWeight: FontWeight.w700, color: kText)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(status,
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ),
          const SizedBox(height: 14),
          Text(description, style: kBodyStyle(color: kTextMuted, size: 14)),
          const SizedBox(height: 20),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                width: double.infinity,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: orangeGlowDecoration,
                child: Text(ctaLabel,
                    style: GoogleFonts.inter(
                        fontSize: 14, fontWeight: FontWeight.w700, color: kWhite)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
