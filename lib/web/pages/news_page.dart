import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';
import '../../constants/app_constants.dart';
import 'package:url_launcher/url_launcher.dart';

/// Page "Actualités et promotions".
///
/// Volontairement sans contenu daté inventé : tant qu'aucune source de
/// contenu (annonce admin, collection Firestore dédiée) n'existe, la page
/// présente l'état honnête ("aucune actualité publiée pour le moment") au
/// lieu de données fictives. À remplacer par un vrai flux dès qu'une source
/// de contenu sera validée côté Espace C (voir plan Phase 1, section 2).
class WebNewsPage extends StatelessWidget {
  const WebNewsPage({super.key});

  static const _categories = [
    (Icons.campaign_rounded, 'Annonces', 'Nouveautés et évolutions du service.'),
    (Icons.local_offer_rounded, 'Promotions', 'Offres ponctuelles sur certains services.'),
    (Icons.store_rounded, 'Partenaires', 'Nouveaux commerçants et zones desservies.'),
  ];

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
              _categoriesSection(context),
              _emptyState(context),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: WebNavBar(currentRoute: '/actualites'),
          ),
        ],
      ),
    );
  }

  Widget _hero(BuildContext ctx) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 72),
      decoration: const BoxDecoration(gradient: kHeroGradient),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
              color: kOrange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20)),
          child: Text('ACTUALITÉS & PROMOTIONS',
              style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: kOrange,
                  letterSpacing: 1.2)),
        ).animate().fadeIn(duration: 600.ms),
        const SizedBox(height: 20),
        Text('L\'actualité\nAZ Express',
            style: kDisplayStyle(ctx), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Text(
          'Nouveautés, promotions et annonces de l\'équipe AZ Express.',
          style: GoogleFonts.inter(fontSize: 16, color: kTextMuted),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }

  Widget _categoriesSection(BuildContext ctx) {
    final desk = isDesktop(ctx);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 56),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: desk ? 3 : 1,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: desk ? 1.3 : 1.8,
        ),
        itemCount: _categories.length,
        itemBuilder: (_, i) => Container(
          padding: const EdgeInsets.all(24),
          decoration: glassCard(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kOrange.withValues(alpha: 0.12),
                ),
                child: Icon(_categories[i].$1, color: kOrange, size: 24),
              ),
              const SizedBox(height: 14),
              Text(_categories[i].$2,
                  style: GoogleFonts.inter(
                      fontSize: 16, fontWeight: FontWeight.w700, color: kText)),
              const SizedBox(height: 6),
              Text(_categories[i].$3,
                  style: kBodyStyle(color: kTextMuted, size: 13)),
            ],
          ),
        ).animate(delay: (i * 100).ms).fadeIn(duration: 500.ms),
      ),
    );
  }

  Widget _emptyState(BuildContext ctx) {
    return Container(
      color: kNavyMid,
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 72),
      child: Column(
        children: [
          Icon(Icons.inventory_2_outlined,
              size: 48, color: kTextMuted.withValues(alpha: 0.6)),
          const SizedBox(height: 20),
          Text('Aucune actualité publiée pour le moment',
              style: kH2Style(ctx), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(
            'Revenez bientôt, ou suivez-nous sur WhatsApp pour ne rien manquer.',
            style: GoogleFonts.inter(fontSize: 14, color: kTextMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => launchUrl(Uri.parse(AppConfig.whatsAppUrl)),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kOrange),
                ),
                child: Text('Nous suivre sur WhatsApp',
                    style: GoogleFonts.inter(
                        fontSize: 14, fontWeight: FontWeight.w700, color: kOrange)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
