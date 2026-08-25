import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';

class WebHowItWorksPage extends StatelessWidget {
  const WebHowItWorksPage({super.key});

  static const _clientSteps = [
    (
      Icons.download_rounded,
      kOrange,
      'Téléchargez l\'App',
      'Disponible gratuitement sur Google Play et App Store. Installation en 2 minutes.'
    ),
    (
      Icons.account_circle_rounded,
      kBlue,
      'Créez votre compte',
      'Inscription rapide avec votre numéro de téléphone. Pas de carte bancaire requise.'
    ),
    (
      Icons.search_rounded,
      Color(0xFF9C27B0),
      'Choisissez votre service',
      'Livraison, restaurant, courses, pharmacie… Sélectionnez ce dont vous avez besoin.'
    ),
    (
      Icons.add_shopping_cart_rounded,
      kSuccess,
      'Passez commande',
      'Ajoutez vos articles, entrez votre adresse et confirmez en un clic.'
    ),
    (
      Icons.payments_rounded,
      Color(0xFFE91E63),
      'Payez facilement',
      'Wave, MTN Money, Orange Money, Moov Money ou espèces à la livraison.'
    ),
    (
      Icons.location_on_rounded,
      Color(0xFFFF5722),
      'Suivez en direct',
      'Votre livreur est visible sur la carte en temps réel. ETA précis.'
    ),
    (
      Icons.celebration_rounded,
      kOrange,
      'Recevez & Notez',
      'Livraison à domicile garantie. Notez votre expérience pour aider la communauté.'
    ),
  ];

  static const _driverSteps = [
    (
      Icons.app_registration_rounded,
      kOrange,
      'Inscrivez-vous',
      'Formulaire en ligne ou contactez notre équipe. Dossier simple.'
    ),
    (
      Icons.verified_user_rounded,
      kBlue,
      'Validation dossier',
      'Vérification identité et engin en 24 à 48 heures.'
    ),
    (
      Icons.phone_android_rounded,
      kSuccess,
      'Activez votre compte',
      'Téléchargez l\'app livreur et connectez-vous.'
    ),
    (
      Icons.notifications_active_rounded,
      Color(0xFF9C27B0),
      'Recevez des missions',
      'Les commandes arrivent automatiquement selon votre zone.'
    ),
    (
      Icons.account_balance_wallet_rounded,
      Color(0xFFE91E63),
      'Gagnez & Encaissez',
      'Paiement hebdomadaire sur votre mobile money.'
    ),
  ];

  static const _fleetSteps = [
    (
      Icons.app_registration_rounded,
      Color(0xFF6A1B9A),
      'Créez votre compte Patron',
      'Inscrivez-vous en tant que Patron de flotte et configurez votre profil.'
    ),
    (
      Icons.people_alt_rounded,
      kBlue,
      'Ajoutez vos livreurs',
      'Recrutez et enregistrez vos livreurs directement dans l\'application.'
    ),
    (
      Icons.dashboard_rounded,
      kOrange,
      'Gérez votre flotte',
      'Suivez les performances, disponibilités et missions de chaque livreur.'
    ),
    (
      Icons.bar_chart_rounded,
      kSuccess,
      'Consultez les revenus',
      'Tableau de bord complet : commandes traitées, gains par livreur, statistiques.'
    ),
    (
      Icons.account_balance_wallet_rounded,
      Color(0xFFE91E63),
      'Encaissez vos bénéfices',
      'Reversement automatique sur votre wallet ou mobile money.'
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
              _pageHeader(context),
              _ClientSection(),
              _DriverSection(),
              _FleetOwnerSection(),
              _FaqSection(),
              _CtaSection(),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: WebNavBar(currentRoute: '/comment-ca-marche'),
          ),
        ],
      ),
    );
  }

  Widget _pageHeader(BuildContext ctx) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 80),
      decoration: const BoxDecoration(gradient: kHeroGradient),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
              color: kOrange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20)),
          child: Text('GUIDE',
              style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: kOrange,
                  letterSpacing: 1.2)),
        ).animate().fadeIn(duration: 600.ms),
        const SizedBox(height: 20),
        Text(
          'Comment ça marche ?',
          style: kDisplayStyle(ctx),
          textAlign: TextAlign.center,
        ).animate(delay: 200.ms).fadeIn(duration: 700.ms),
        const SizedBox(height: 16),
        Text(
          'Tout ce que vous devez savoir pour utiliser AZ Express.',
          style:
              GoogleFonts.inter(fontSize: 16, color: kTextMuted, height: 1.6),
          textAlign: TextAlign.center,
        ).animate(delay: 350.ms).fadeIn(duration: 600.ms),
      ]),
    );
  }
}

class _ClientSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const steps = WebHowItWorksPage._clientSteps;
    final desk = isDesktop(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 72),
      child: Column(children: [
        const _TabHeader(
          icon: Icons.person_rounded,
          color: kOrange,
          title: 'Pour les Clients',
          subtitle: 'Commander en 7 étapes simples',
        ),
        const SizedBox(height: 48),
        ...steps.asMap().entries.map((e) => _TimelineItem(
              step: e.value,
              index: e.key,
              isLast: e.key == steps.length - 1,
              reversed: desk && e.key.isEven,
            )),
      ]),
    );
  }
}

class _DriverSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const steps = WebHowItWorksPage._driverSteps;
    return Container(
      color: kNavyMid,
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 72),
      child: Column(children: [
        const _TabHeader(
          icon: Icons.delivery_dining_rounded,
          color: kBlue,
          title: 'Pour les Livreurs',
          subtitle: '5 étapes pour commencer à gagner',
        ),
        const SizedBox(height: 48),
        ...steps.asMap().entries.map((e) => _TimelineItem(
              step: e.value,
              index: e.key,
              isLast: e.key == steps.length - 1,
              reversed: false,
            )),
      ]),
    );
  }
}

class _FleetOwnerSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const steps = WebHowItWorksPage._fleetSteps;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 72),
      child: Column(children: [
        const _TabHeader(
          icon: Icons.directions_car_rounded,
          color: Color(0xFF6A1B9A),
          title: 'Pour les Patrons de flotte',
          subtitle: 'Gérez plusieurs livreurs depuis un seul compte',
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF6A1B9A).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: const Color(0xFF6A1B9A).withValues(alpha: 0.2)),
          ),
          child: Text(
            'Le Patron de flotte possède une flotte de livreurs. Il les gère, suit leurs revenus et encaisse une part des commissions.',
            style:
                GoogleFonts.inter(fontSize: 14, color: kTextMuted, height: 1.6),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 48),
        ...steps.asMap().entries.map((e) => _TimelineItem(
              step: e.value,
              index: e.key,
              isLast: e.key == steps.length - 1,
              reversed: false,
            )),
      ]),
    );
  }
}

class _TabHeader extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  const _TabHeader(
      {required this.icon,
      required this.color,
      required this.title,
      required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.12),
        ),
        child: Icon(icon, color: color, size: 28),
      ),
      const SizedBox(width: 16),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: GoogleFonts.inter(
                fontSize: 24, fontWeight: FontWeight.w700, color: kWhite)),
        Text(subtitle,
            style: GoogleFonts.inter(fontSize: 14, color: kTextMuted)),
      ]),
    ]);
  }
}

class _TimelineItem extends StatelessWidget {
  final (IconData, Color, String, String) step;
  final int index;
  final bool isLast;
  final bool reversed;
  const _TimelineItem(
      {required this.step,
      required this.index,
      required this.isLast,
      required this.reversed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timeline line & number
          Column(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [step.$2, step.$2.withValues(alpha: 0.7)],
                  ),
                ),
                child: Center(
                    child: Text('${index + 1}',
                        style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: kWhite))),
              ),
              if (!isLast)
                Container(
                  width: 2,
                  height: 60,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        step.$2.withValues(alpha: 0.5),
                        Colors.transparent
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(step.$1, color: step.$2, size: 20),
                    const SizedBox(width: 8),
                    Text(step.$3,
                        style: GoogleFonts.inter(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: kWhite)),
                  ]),
                  const SizedBox(height: 6),
                  Text(step.$4,
                      style: GoogleFonts.inter(
                          fontSize: 14, color: kTextMuted, height: 1.6)),
                ],
              ),
            ),
          ),
        ],
      ),
    )
        .animate(delay: (index * 100).ms)
        .fadeIn(duration: 600.ms)
        .slideX(begin: -0.1);
  }
}

class _FaqSection extends StatelessWidget {
  static const _faqs = [
    (
      'Combien coûte la livraison ?',
      'Le prix de la livraison varie selon la distance et le service. Vous verrez toujours le prix avant de confirmer votre commande.'
    ),
    (
      'Dans quelles villes livrez-vous ?',
      'Nous couvrons principalement Abengourou et ses environs. Nous nous expandons progressivement dans d\'autres villes de Côte d\'Ivoire.'
    ),
    (
      'Comment payer ?',
      'Vous pouvez payer par Wave, MTN Mobile Money, Orange Money, Moov Money ou en espèces à la livraison.'
    ),
    (
      'Que faire si ma commande a un problème ?',
      'Contactez notre support via l\'application ou WhatsApp. Nous traitons toutes les réclamations dans les 2 heures.'
    ),
    (
      'Puis-je planifier une livraison à l\'avance ?',
      'Oui ! Vous pouvez planifier vos commandes jusqu\'à 48h à l\'avance pour certains services (boulangerie, traiteur, etc.).'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 72),
      child: Column(children: [
        Text('Questions fréquentes',
            style: kH1Style(context), textAlign: TextAlign.center),
        const SizedBox(height: 48),
        ..._faqs.map((f) => _FaqItem(q: f.$1, a: f.$2)),
      ]),
    );
  }
}

class _FaqItem extends StatefulWidget {
  final String q;
  final String a;
  const _FaqItem({required this.q, required this.a});

  @override
  State<_FaqItem> createState() => _FaqItemState();
}

class _FaqItemState extends State<_FaqItem> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _open = !_open),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: kNavyCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: _open ? kOrange.withValues(alpha: 0.4) : kDivider),
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              Expanded(
                  child: Text(widget.q,
                      style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: kWhite))),
              AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.expand_more_rounded, color: kOrange),
              ),
            ]),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Text(widget.a,
                  style: GoogleFonts.inter(
                      fontSize: 14, color: kTextMuted, height: 1.7)),
            ),
        ]),
      ),
    );
  }
}

class _CtaSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: kNavyMid,
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 72),
      child: Column(children: [
        Text('Prêt à commencer ?',
            style: kH1Style(context), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Text('Téléchargez l\'app et passez votre première commande maintenant.',
            style: GoogleFonts.inter(fontSize: 16, color: kTextMuted),
            textAlign: TextAlign.center),
        const SizedBox(height: 32),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: [
            _Btn(
                label: '📱 Télécharger l\'App',
                onTap: () => launchUrl(Uri.parse('https://play.google.com')),
                filled: true),
            _Btn(
                label: '🛵 Devenir Livreur',
                onTap: () => context.go('/livreurs'),
                filled: false),
          ],
        ),
      ]),
    );
  }
}

class _Btn extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool filled;
  const _Btn({required this.label, required this.onTap, required this.filled});

  @override
  State<_Btn> createState() => _BtnState();
}

class _BtnState extends State<_Btn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _h ? 1.04 : 1.0,
            duration: 150.ms,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
              decoration: widget.filled
                  ? orangeGlowDecoration
                  : BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: kOrange),
                    ),
              child: Text(widget.label,
                  style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: kWhite)),
            ),
          ),
        ),
      );
}
