import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';

/// Page FAQ publique. Questions génériques sur le fonctionnement réel de
/// l'app (zone de service, paiement, livreurs, partenaires) — aucun chiffre
/// commercial inventé, uniquement des réponses vérifiables dans le produit.
class WebFaqPage extends StatelessWidget {
  const WebFaqPage({super.key});

  static const _faqs = [
    (
      'Dans quelles villes AZ Express est-il disponible ?',
      'AZ Express est lancé à Abengourou et se développe progressivement dans '
          'd\'autres villes de Côte d\'Ivoire. La disponibilité exacte d\'un '
          'service dépend de votre zone.',
    ),
    (
      'Comment payer une commande ?',
      'Vous pouvez payer en espèces à la livraison, ou via votre portefeuille '
          'AZ Express (Wallet), rechargeable par Mobile Money (Orange Money, '
          'MTN Money, Moov Money, Wave).',
    ),
    (
      'Comment suivre ma commande ?',
      'Depuis l\'application mobile, chaque commande affiche son statut en '
          'temps réel et, pour la livraison, la position du livreur sur une '
          'carte.',
    ),
    (
      'Puis-je annuler une commande ?',
      'Oui, tant que la commande n\'a pas encore été prise en charge par un '
          'livreur. Après cette étape, l\'annulation suit les règles '
          'affichées dans l\'application.',
    ),
    (
      'Comment devenir livreur AZ Express ?',
      'Rendez-vous sur la page "Devenir livreur" et soumettez votre '
          'candidature. Notre équipe examine chaque demande avant '
          'validation.',
    ),
    (
      'Comment inscrire mon commerce sur AZ Express ?',
      'Rendez-vous sur la page "Devenir partenaire" et remplissez le '
          'formulaire d\'inscription. Notre équipe vous contacte pour '
          'finaliser votre inscription.',
    ),
    (
      'Mes informations de paiement sont-elles sécurisées ?',
      'Les opérations financières sensibles (paiements, recharges, '
          'retraits) sont toujours traitées côté serveur, jamais directement '
          'depuis votre téléphone ou votre navigateur.',
    ),
    (
      'Comment contacter le support ?',
      'Depuis l\'application, via le centre d\'assistance intégré, ou depuis '
          'ce site via la page Contact.',
    ),
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
              _faqList(context),
              _ctaSection(context),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: WebNavBar(currentRoute: '/faq'),
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
          child: Text('QUESTIONS FRÉQUENTES',
              style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: kOrange,
                  letterSpacing: 1.2)),
        ).animate().fadeIn(duration: 600.ms),
        const SizedBox(height: 20),
        Text('Des questions ?\nOn a les réponses.',
            style: kDisplayStyle(ctx), textAlign: TextAlign.center),
      ]),
    );
  }

  Widget _faqList(BuildContext ctx) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 72),
      constraints: const BoxConstraints(maxWidth: 820),
      child: Column(
        children: [
          for (var i = 0; i < _faqs.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: _FaqTile(question: _faqs[i].$1, answer: _faqs[i].$2)
                  .animate(delay: (i * 60).ms)
                  .fadeIn(duration: 400.ms),
            ),
        ],
      ),
    );
  }

  Widget _ctaSection(BuildContext ctx) {
    return Container(
      color: kNavyMid,
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 64),
      child: Column(children: [
        Text('Vous ne trouvez pas votre réponse ?',
            style: kH1Style(ctx), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Text('Notre équipe est disponible pour vous aider.',
            style: GoogleFonts.inter(fontSize: 15, color: kTextMuted),
            textAlign: TextAlign.center),
        const SizedBox(height: 28),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => GoRouter.of(ctx).go('/contact'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
              decoration: orangeGlowDecoration,
              child: Text('Contacter le support',
                  style: GoogleFonts.inter(
                      fontSize: 15, fontWeight: FontWeight.w700, color: kWhite)),
            ),
          ),
        ),
      ]),
    );
  }
}

class _FaqTile extends StatefulWidget {
  final String question;
  final String answer;
  const _FaqTile({required this.question, required this.answer});

  @override
  State<_FaqTile> createState() => _FaqTileState();
}

class _FaqTileState extends State<_FaqTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: glassCard(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(widget.question,
                          style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: kText)),
                    ),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(Icons.keyboard_arrow_down_rounded,
                          color: kOrange),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Text(widget.answer,
                          style: kBodyStyle(color: kTextMuted, size: 14)),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
