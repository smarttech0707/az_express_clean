import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';
import '../widgets/az_logo.dart';

class WebAboutPage extends StatelessWidget {
  const WebAboutPage({super.key});

  static const _values = [
    (
      Icons.flash_on_rounded,
      kOrange,
      'Rapidité',
      'Chaque seconde compte. Nous optimisons chaque étape pour une livraison ultrarapide.'
    ),
    (
      Icons.verified_rounded,
      kBlue,
      'Fiabilité',
      'Nos livreurs sont vérifiés, formés et suivis. Votre commande arrive toujours.'
    ),
    (
      Icons.people_rounded,
      kSuccess,
      'Communauté',
      'Nous créons de la valeur pour les clients, livreurs et commerçants.'
    ),
    (
      Icons.security_rounded,
      Color(0xFF9C27B0),
      'Sécurité',
      'Paiements sécurisés, données protégées, transactions vérifiées.'
    ),
  ];

  static const _team = [
    (
      'Fondateurs',
      'Une équipe ivoirienne passionnée par la tech et la logistique.'
    ),
    (
      'Tech',
      'Ingénieurs Flutter, Firebase et Cloud experts en plateformes mobiles.'
    ),
    (
      'Opérations',
      'Coordinateurs terrain formés pour gérer la flotte et les partenaires.'
    ),
    (
      'Support',
      'Équipe client disponible 7j/7 pour garantir votre satisfaction.'
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
              _storySection(context),
              _valuesSection(context),
              _missionSection(context),
              _teamSection(context),
              _ctaSection(context),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: WebNavBar(currentRoute: '/a-propos'),
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
          child: Text('NOTRE HISTOIRE',
              style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: kOrange,
                  letterSpacing: 1.2)),
        ).animate().fadeIn(duration: 600.ms),
        const SizedBox(height: 20),
        Text(
          'Née à Abengourou,\npour l\'Afrique',
          style: kDisplayStyle(ctx),
          textAlign: TextAlign.center,
        ).animate(delay: 200.ms).fadeIn(duration: 700.ms),
        const SizedBox(height: 16),
        Text(
          'AZ Express est une startup technologique ivoirienne qui révolutionne\nla livraison et les services du quotidien en Côte d\'Ivoire.',
          style:
              GoogleFonts.inter(fontSize: 16, color: kTextMuted, height: 1.7),
          textAlign: TextAlign.center,
        ).animate(delay: 350.ms).fadeIn(duration: 600.ms),
      ]),
    );
  }

  Widget _storySection(BuildContext ctx) {
    final desk = isDesktop(ctx);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 72),
      child: desk
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: _storyText()),
                const SizedBox(width: 60),
                Expanded(child: _storyVisual()),
              ],
            )
          : Column(children: [
              _storyText(),
              const SizedBox(height: 32),
              _storyVisual()
            ]),
    );
  }

  Widget _storyText() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Notre histoire',
            style: GoogleFonts.inter(
                fontSize: 28, fontWeight: FontWeight.w700, color: kWhite)),
        const SizedBox(height: 16),
        Text(
          'AZ Express est née d\'un constat simple : à Abengourou, les déplacements pour récupérer des colis, faire ses courses ou trouver un artisan fiable sont une véritable perte de temps.\n\nNos fondateurs, jeunes entrepreneurs ivoiriens, ont décidé de créer une solution locale, adaptée aux réalités africaines : paiement Wave, MTN Money, Orange Money — livraison express, service client en français.\n\nAujourd\'hui, AZ Express est la plateforme de référence à Abengourou, avec une expansion rapide dans tout le pays.',
          style:
              GoogleFonts.inter(fontSize: 15, color: kTextMuted, height: 1.8),
        ),
      ],
    ).animate().fadeIn(duration: 700.ms).slideX(begin: -0.1);
  }

  Widget _storyVisual() {
    return Container(
      height: 320,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            kOrange.withValues(alpha: 0.15),
            kBlue.withValues(alpha: 0.1)
          ],
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: kDivider),
      ),
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const AzLogo(size: 80),
                const SizedBox(height: 20),
                Text('AZ Express',
                    style: GoogleFonts.inter(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: kWhite)),
                const SizedBox(height: 8),
                Text('🇨🇮  Made in Côte d\'Ivoire',
                    style: GoogleFonts.inter(fontSize: 15, color: kTextMuted)),
              ],
            ),
          ),
          Positioned(
            top: 24,
            right: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: kSuccess.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: kSuccess.withValues(alpha: 0.3)),
              ),
              child: Text('Fondée en 2024',
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      color: kSuccess,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    ).animate(delay: 200.ms).fadeIn(duration: 700.ms).slideX(begin: 0.1);
  }

  Widget _valuesSection(BuildContext ctx) {
    return Container(
      color: kNavyMid,
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 72),
      child: Column(
        children: [
          Text('Nos valeurs',
              style: kH1Style(ctx), textAlign: TextAlign.center),
          const SizedBox(height: 48),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: isDesktop(ctx) ? 4 : 2,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: isDesktop(ctx) ? 0.9 : 0.85,
            ),
            itemCount: _values.length,
            itemBuilder: (_, i) => Container(
              padding: const EdgeInsets.all(24),
              decoration: glassCard(),
              child: Column(children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _values[i].$2.withValues(alpha: 0.12),
                  ),
                  child: Icon(_values[i].$1, color: _values[i].$2, size: 26),
                ),
                const SizedBox(height: 14),
                Text(_values[i].$3,
                    style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: kWhite)),
                const SizedBox(height: 8),
                Text(_values[i].$4,
                    style: GoogleFonts.inter(
                        fontSize: 12, color: kTextMuted, height: 1.6),
                    textAlign: TextAlign.center),
              ]),
            ).animate(delay: (i * 100).ms).fadeIn(duration: 600.ms),
          ),
        ],
      ),
    );
  }

  Widget _missionSection(BuildContext ctx) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 72),
      child: Column(
        children: [
          Text('Notre Mission',
              style: kH1Style(ctx), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(36),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  kOrange.withValues(alpha: 0.08),
                  kBlue.withValues(alpha: 0.06)
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: kOrange.withValues(alpha: 0.2)),
            ),
            child: Text(
              '"Démocratiser l\'accès aux services du quotidien en Afrique, '
              'en connectant les consommateurs, les commerçants et les livreurs '
              'sur une plateforme technologique de classe mondiale."',
              style: GoogleFonts.inter(
                fontSize: isDesktop(ctx) ? 20 : 16,
                fontWeight: FontWeight.w600,
                color: kWhite,
                height: 1.6,
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          Text('— L\'équipe AZ Express',
              style: GoogleFonts.inter(
                  fontSize: 14, color: kOrange, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _teamSection(BuildContext ctx) {
    return Container(
      color: kNavyMid,
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 72),
      child: Column(
        children: [
          Text('Notre équipe',
              style: kH1Style(ctx), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Text(
              'Des professionnels passionnés au service de votre satisfaction.',
              style: GoogleFonts.inter(fontSize: 15, color: kTextMuted),
              textAlign: TextAlign.center),
          const SizedBox(height: 48),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: isDesktop(ctx) ? 4 : 2,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: 1.1,
            ),
            itemCount: _team.length,
            itemBuilder: (_, i) => Container(
              padding: const EdgeInsets.all(24),
              decoration: glassCard(),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: kOrangeGradient,
                    ),
                    child: Center(
                        child: Text(_team[i].$1[0],
                            style: GoogleFonts.inter(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: kWhite))),
                  ),
                  const SizedBox(height: 12),
                  Text(_team[i].$1,
                      style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: kWhite)),
                  const SizedBox(height: 8),
                  Text(_team[i].$2,
                      style: GoogleFonts.inter(
                          fontSize: 12, color: kTextMuted, height: 1.5),
                      textAlign: TextAlign.center),
                ],
              ),
            ).animate(delay: (i * 100).ms).fadeIn(duration: 600.ms),
          ),
        ],
      ),
    );
  }

  Widget _ctaSection(BuildContext ctx) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 72),
      child: Column(children: [
        Text('Rejoignez l\'aventure AZ Express',
            style: kH1Style(ctx), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Text('Client, livreur ou commerçant — votre place est avec nous.',
            style: GoogleFonts.inter(fontSize: 16, color: kTextMuted),
            textAlign: TextAlign.center),
        const SizedBox(height: 32),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: [
            _Btn('Devenir partenaire',
                () => GoRouter.of(ctx).go('/commercants'), true),
            _Btn('Rejoindre la flotte', () => GoRouter.of(ctx).go('/livreurs'),
                false),
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
  const _Btn(this.label, this.onTap, this.filled);

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
            scale: _h ? 1.03 : 1.0,
            duration: 150.ms,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
              decoration: widget.filled
                  ? orangeGlowDecoration
                  : BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: kOrange)),
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
