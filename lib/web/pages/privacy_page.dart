import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../legal/legal_renderer.dart';
import '../../legal/privacy_content.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';

class WebPrivacyPage extends StatelessWidget {
  const WebPrivacyPage({super.key});

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
            child: WebNavBar(currentRoute: '/confidentialite'),
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
        Text('Politique de Confidentialité',
            style: kH1Style(ctx), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text('Dernière mise à jour : ${PrivacyContent.lastUpdated}',
            style: GoogleFonts.inter(fontSize: 14, color: kTextMuted)),
      ]),
    );
  }

  Widget _body(BuildContext ctx) {
    final pad = hPad(ctx);
    final docWidth = isDesktop(ctx) ? 800.0 : double.infinity;
    return Center(
      child: Container(
        width: docWidth,
        padding: EdgeInsets.symmetric(horizontal: pad, vertical: 60),
        child: Column(children: [
          for (final section in PrivacyContent.sections)
            _Section(section.title, LegalRenderer.plainBlocks(section.blocks)),
        ]),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String content;
  const _Section(this.title, this.content);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: GoogleFonts.inter(
                  fontSize: 18, fontWeight: FontWeight.w700, color: kWhite)),
          const SizedBox(height: 12),
          Text(content,
              style: GoogleFonts.inter(
                  fontSize: 15, color: kTextMuted, height: 1.8)),
          const Divider(color: kDivider, height: 48),
        ],
      ),
    );
  }
}
