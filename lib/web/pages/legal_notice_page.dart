import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';

class WebLegalNoticePage extends StatelessWidget {
  const WebLegalNoticePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kNavy,
      body: Stack(
        children: [
          SingleChildScrollView(
            child: Column(children: [
              const SizedBox(height: 72),
              _header(context),
              _body(context),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: WebNavBar(currentRoute: '/mentions-legales'),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext ctx) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 60),
      decoration: const BoxDecoration(gradient: kHeroGradient),
      child: Column(children: [
        Text('Informations juridiques sur le service',
            style: GoogleFonts.inter(
                fontSize: isDesktop(ctx) ? 40 : 26,
                fontWeight: FontWeight.w700,
                color: kWhite),
            textAlign: TextAlign.center),
      ]),
    );
  }

  Widget _body(BuildContext ctx) {
    final docWidth = isDesktop(ctx) ? 800.0 : double.infinity;
    return Center(
      child: Container(
        width: docWidth,
        padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 60),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('AZ EXPRESS — INFORMATIONS JURIDIQUES SUR LE SERVICE',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: kText)),
            SizedBox(height: 24),
            _Paragraph(
                'AZ Express est une plateforme numérique proposant des '
                'services de livraison, de courses, de mise en relation avec '
                'des commerçants, ainsi que des services numériques et de '
                'paiement selon les fonctionnalités disponibles.'),
            _Paragraph(
                'La plateforme AZ Express facilite la commande, la '
                'coordination et le suivi des prestations proposées aux '
                'utilisateurs.'),
            _Paragraph(
                'Les prestations de livraison peuvent être réalisées par des '
                'livreurs partenaires, des prestataires indépendants ou des '
                'livreurs opérant dans le cadre de l\'organisation d\'AZ '
                'Express, selon les modalités applicables à chaque service.'),
            _Paragraph(
                'Les informations, tarifs, estimations de délais et '
                'disponibilités affichés sur la plateforme sont communiqués à '
                'titre informatif et peuvent évoluer en fonction des '
                'conditions opérationnelles.'),
            _Paragraph(
                'Les commandes sont soumises aux conditions générales '
                'd\'utilisation d\'AZ Express. Les utilisateurs sont invités '
                'à consulter les conditions applicables à chaque service '
                'avant toute commande.'),
            _Paragraph(
                'AZ Express s\'engage à assurer la transparence de ses '
                'services, la protection des données de ses utilisateurs et '
                'le traitement des réclamations conformément aux '
                'dispositions légales et réglementaires applicables en Côte '
                'd\'Ivoire.'),
            SizedBox(height: 12),
            _Paragraph(
                'AZ Express — Votre solution de livraison, courses et '
                'services du quotidien.',
                emphasis: true),
          ],
        ),
      ),
    );
  }
}

class _Paragraph extends StatelessWidget {
  final String text;
  final bool emphasis;
  const _Paragraph(this.text, {this.emphasis = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Text(text,
          style: GoogleFonts.inter(
              fontSize: 15,
              color: emphasis ? kText : kTextMuted,
              fontWeight: emphasis ? FontWeight.w600 : FontWeight.w400,
              height: 1.8)),
    );
  }
}
