import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';
import '../../constants/app_constants.dart';

class WebContactPage extends StatelessWidget {
  const WebContactPage({super.key});

  static final _contacts = [
    (
      Icons.chat_bubble_rounded,
      'WhatsApp',
      '+225 07 98 05 13 97',
      AppConfig.whatsAppUrl,
      const Color(0xFF25D366)
    ),
    (
      Icons.email_rounded,
      'Email',
      AppConfig.supportEmail,
      'mailto:${AppConfig.supportEmail}',
      kOrange
    ),
    (
      Icons.phone_rounded,
      'Téléphone',
      '+225 07 98 05 13 97',
      'tel:${AppConfig.supportPhone}',
      kBlue
    ),
    (
      Icons.location_on_rounded,
      'Adresse',
      '${AppConfig.city}, ${AppConfig.country}',
      'https://maps.google.com/?q=${AppConfig.city},Cote+d+Ivoire',
      kSuccess
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
              _header(context),
              _ContactBody(contacts: _contacts),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: WebNavBar(currentRoute: '/contact'),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext ctx) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(ctx), vertical: 72),
      decoration: const BoxDecoration(gradient: kHeroGradient),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
              color: kOrange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20)),
          child: Text('CONTACT',
              style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: kOrange,
                  letterSpacing: 1.2)),
        ).animate().fadeIn(duration: 600.ms),
        const SizedBox(height: 20),
        Text(
          'Nous contacter',
          style: kDisplayStyle(ctx),
          textAlign: TextAlign.center,
        ).animate(delay: 200.ms).fadeIn(duration: 700.ms),
        const SizedBox(height: 16),
        Text(
          'Notre équipe est disponible 7j/7 pour répondre à toutes vos questions.',
          style:
              GoogleFonts.inter(fontSize: 16, color: kTextMuted, height: 1.6),
          textAlign: TextAlign.center,
        ).animate(delay: 350.ms).fadeIn(duration: 600.ms),
      ]),
    );
  }
}

class _ContactBody extends StatelessWidget {
  final List<(IconData, String, String, String, Color)> contacts;
  const _ContactBody({required this.contacts});

  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 72),
      child: desk
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _ContactInfo(contacts: contacts)),
                const SizedBox(width: 60),
                Expanded(child: _ContactForm()),
              ],
            )
          : Column(
              children: [
                _ContactInfo(contacts: contacts),
                const SizedBox(height: 40),
                _ContactForm(),
              ],
            ),
    );
  }
}

class _ContactInfo extends StatelessWidget {
  final List<(IconData, String, String, String, Color)> contacts;
  const _ContactInfo({required this.contacts});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Canaux de contact',
            style: GoogleFonts.inter(
                fontSize: 22, fontWeight: FontWeight.w700, color: kWhite)),
        const SizedBox(height: 8),
        Text('Choisissez le canal qui vous convient.',
            style: GoogleFonts.inter(fontSize: 14, color: kTextMuted)),
        const SizedBox(height: 32),
        ...contacts.asMap().entries.map((e) => _ContactCard(c: e.value)
            .animate(delay: (e.key * 100).ms)
            .fadeIn(duration: 600.ms)
            .slideX(begin: -0.1)),
        const SizedBox(height: 32),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: kOrange.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kOrange.withValues(alpha: 0.2)),
          ),
          child: Row(children: [
            const Icon(Icons.access_time_rounded, color: kOrange, size: 20),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Horaires du support',
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: kWhite)),
              const SizedBox(height: 4),
              Text('Lun – Sam : 07h00 – 22h00',
                  style: GoogleFonts.inter(fontSize: 13, color: kTextMuted)),
              Text('Dimanche : 08h00 – 20h00',
                  style: GoogleFonts.inter(fontSize: 13, color: kTextMuted)),
            ]),
          ]),
        ),
      ],
    );
  }
}

class _ContactCard extends StatefulWidget {
  final (IconData, String, String, String, Color) c;
  const _ContactCard({required this.c});

  @override
  State<_ContactCard> createState() => _ContactCardState();
}

class _ContactCardState extends State<_ContactCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => launchUrl(Uri.parse(c.$4)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: _hover ? kNavyCard.withValues(alpha: 0.9) : kNavyCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: _hover ? c.$5.withValues(alpha: 0.5) : kDivider),
          ),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.$5.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(c.$1, color: c.$5, size: 22),
            ),
            const SizedBox(width: 16),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.$2,
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      color: kTextMuted,
                      fontWeight: FontWeight.w500)),
              Text(c.$3,
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: kWhite)),
            ]),
            const Spacer(),
            const Icon(Icons.arrow_forward_ios_rounded,
                color: kTextMuted, size: 14),
          ]),
        ),
      ),
    );
  }
}

class _ContactForm extends StatefulWidget {
  @override
  State<_ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends State<_ContactForm> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _subjCtrl = TextEditingController();
  final _msgCtrl = TextEditingController();
  bool _loading = false;
  bool _success = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _subjCtrl.dispose();
    _msgCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await FirebaseFirestore.instance.collection('contact_messages').add({
        'name': _nameCtrl.text.trim(),
        'email': _emailCtrl.text.trim(),
        'subject': _subjCtrl.text.trim(),
        'message': _msgCtrl.text.trim(),
        'createdAt': Timestamp.now(),
        'status': 'unread',
      });
      setState(() {
        _loading = false;
        _success = true;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: glassCard(radius: 24),
      child: _success ? _successView() : _formView(),
    );
  }

  Widget _successView() {
    return Column(children: [
      const Icon(Icons.mark_email_read_rounded, color: kSuccess, size: 56)
          .animate()
          .scale(duration: 600.ms, curve: Curves.elasticOut),
      const SizedBox(height: 20),
      Text('Message envoyé !',
          style: GoogleFonts.inter(
              fontSize: 22, fontWeight: FontWeight.w700, color: kWhite),
          textAlign: TextAlign.center),
      const SizedBox(height: 10),
      Text('Nous vous répondrons dans les meilleurs délais.',
          style: GoogleFonts.inter(fontSize: 14, color: kTextMuted),
          textAlign: TextAlign.center),
    ]);
  }

  Widget _formView() {
    return Form(
      key: _formKey,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Envoyer un message',
            style: GoogleFonts.inter(
                fontSize: 20, fontWeight: FontWeight.w700, color: kWhite)),
        const SizedBox(height: 24),
        _field(_nameCtrl, 'Votre nom', Icons.person_rounded),
        const SizedBox(height: 16),
        _field(_emailCtrl, 'Email (optionnel)', Icons.email_rounded,
            required: false, keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 16),
        _field(_subjCtrl, 'Sujet', Icons.subject_rounded),
        const SizedBox(height: 16),
        TextFormField(
          controller: _msgCtrl,
          maxLines: 4,
          style: GoogleFonts.inter(color: kWhite, fontSize: 15),
          validator: (v) => (v?.isEmpty ?? true) ? 'Obligatoire' : null,
          decoration: const InputDecoration(
            labelText: 'Votre message',
            alignLabelWithHint: true,
            prefixIcon: Padding(
              padding: EdgeInsets.only(bottom: 60),
              child: Icon(Icons.message_rounded, color: kTextMuted, size: 20),
            ),
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: kOrange,
              foregroundColor: kWhite,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: kWhite, strokeWidth: 2))
                : Text('Envoyer le message',
                    style: GoogleFonts.inter(
                        fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {bool required = true, TextInputType? keyboardType}) {
    return TextFormField(
      controller: ctrl,
      keyboardType: keyboardType,
      style: GoogleFonts.inter(color: kWhite, fontSize: 15),
      validator:
          required ? (v) => (v?.isEmpty ?? true) ? 'Obligatoire' : null : null,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: kTextMuted, size: 20),
      ),
    );
  }
}
