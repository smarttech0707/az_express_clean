import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';

class WebMerchantsPage extends StatelessWidget {
  const WebMerchantsPage({super.key});

  static const _types = [
    (Icons.restaurant_rounded,      'Restaurant / Fast-Food'),
    (Icons.bakery_dining_rounded,   'Boulangerie & Café'),
    (Icons.local_pharmacy_rounded,  'Pharmacie'),
    (Icons.store_rounded,           'Boutique / Commerce'),
    (Icons.local_laundry_service_rounded, 'Blanchisserie'),
    (Icons.build_rounded,           'Artisan / Réparateur'),
    (Icons.home_rounded,            'Agence Immobilière'),
    (Icons.more_horiz_rounded,      'Autre activité'),
  ];

  static const _stats = [
    ('200+', 'Partenaires actifs'),
    ('50K+', 'Clients potentiels'),
    ('0 FCFA', 'Frais d\'inscription'),
    ('24h',  'Mise en ligne'),
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
              const _Hero(stats: _stats),
              _HowToJoin(),
              const _FormSection(types: _types),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0, left: 0, right: 0,
            child: WebNavBar(currentRoute: '/commercants'),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  final List<(String, String)> stats;
  const _Hero({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 80),
      decoration: const BoxDecoration(gradient: kHeroGradient),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: kOrange.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
            child: Text('ESPACE PARTENAIRES',
              style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700,
                color: kOrange, letterSpacing: 1.2)),
          ).animate().fadeIn(duration: 600.ms),
          const SizedBox(height: 20),
          Text('Développez votre\nBusiness avec AZ Express',
            style: kDisplayStyle(context), textAlign: TextAlign.center,
          ).animate(delay: 200.ms).fadeIn(duration: 700.ms),
          const SizedBox(height: 16),
          Text('Rejoignez la plateforme N°1 de livraison en Côte d\'Ivoire et\ntouchez des milliers de nouveaux clients chaque jour.',
            style: GoogleFonts.inter(fontSize: 16, color: kTextMuted, height: 1.6),
            textAlign: TextAlign.center,
          ).animate(delay: 350.ms).fadeIn(duration: 600.ms),
          const SizedBox(height: 40),
          Wrap(
            spacing: 16, runSpacing: 12,
            alignment: WrapAlignment.center,
            children: stats.map((s) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: kNavyCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kDivider),
              ),
              child: Column(children: [
                Text(s.$1, style: GoogleFonts.inter(
                  fontSize: 24, fontWeight: FontWeight.w800, color: kOrange)),
                Text(s.$2, style: GoogleFonts.inter(fontSize: 12, color: kTextMuted)),
              ]),
            )).toList(),
          ).animate(delay: 500.ms).fadeIn(duration: 600.ms),
        ],
      ),
    );
  }
}

class _HowToJoin extends StatelessWidget {
  static const _steps = [
    ('1', Icons.app_registration_rounded, 'Inscrivez-vous', 'Remplissez le formulaire en 3 minutes.'),
    ('2', Icons.verified_rounded,         'Validation',     'Notre équipe valide votre dossier sous 24h.'),
    ('3', Icons.rocket_launch_rounded,    'Mise en ligne',  'Votre boutique est visible par tous nos clients.'),
    ('4', Icons.trending_up_rounded,      'Croissance',     'Recevez commandes, paiements et statistiques.'),
  ];

  @override
  Widget build(BuildContext context) {
    final desk = isDesktop(context);
    return Container(
      color: kNavyMid,
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 72),
      child: Column(
        children: [
          Text('Comment rejoindre AZ Express ?',
            style: kH1Style(context), textAlign: TextAlign.center),
          const SizedBox(height: 48),
          desk
              ? Row(
                  children: _steps.asMap().entries.map((e) =>
                    Expanded(child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: _StepCard(s: e.value),
                    )),
                  ).toList(),
                )
              : Column(
                  children: _steps.map((s) => Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: _StepCard(s: s),
                  )).toList(),
                ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final (String, IconData, String, String) s;
  const _StepCard({required this.s});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: glassCard(),
      child: Column(children: [
        Container(
          width: 52, height: 52,
          decoration: const BoxDecoration(shape: BoxShape.circle, gradient: kOrangeGradient),
          child: Center(child: Text(s.$1,
            style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w800, color: kWhite))),
        ),
        const SizedBox(height: 14),
        Icon(s.$2, color: kOrange, size: 28),
        const SizedBox(height: 12),
        Text(s.$3, style: GoogleFonts.inter(
          fontSize: 15, fontWeight: FontWeight.w700, color: kWhite),
          textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(s.$4, style: GoogleFonts.inter(fontSize: 13, color: kTextMuted, height: 1.6),
          textAlign: TextAlign.center),
      ]),
    );
  }
}

class _FormSection extends StatefulWidget {
  final List<(IconData, String)> types;
  const _FormSection({required this.types});

  @override
  State<_FormSection> createState() => _FormSectionState();
}

class _FormSectionState extends State<_FormSection> {
  final _formKey  = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _bizCtrl  = TextEditingController();
  final _phoneCtrl= TextEditingController();
  final _cityCtrl = TextEditingController();
  String _type    = 'Restaurant / Fast-Food';
  bool  _loading  = false;
  bool  _success  = false;

  @override
  void dispose() {
    _nameCtrl.dispose(); _bizCtrl.dispose();
    _phoneCtrl.dispose(); _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await FirebaseFirestore.instance.collection('partner_applications').add({
        'contactName': _nameCtrl.text.trim(),
        'businessName': _bizCtrl.text.trim(),
        'phone':       _phoneCtrl.text.trim(),
        'city':        _cityCtrl.text.trim(),
        'type':        _type,
        'source':      'website',
        'status':      'pending',
        'createdAt':   Timestamp.now(),
      });
      setState(() { _loading = false; _success = true; });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 80),
      child: Column(
        children: [
          Text('Formulaire d\'inscription partenaire',
            style: kH1Style(context), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text('Inscription 100% gratuite. Notre équipe vous appelle.',
            style: GoogleFonts.inter(fontSize: 15, color: kTextMuted),
            textAlign: TextAlign.center),
          const SizedBox(height: 40),
          Center(
            child: Container(
              width: w > 700 ? 560 : double.infinity,
              padding: const EdgeInsets.all(32),
              decoration: glassCard(radius: 24),
              child: _success ? _successView() : _formView(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _successView() {
    return Column(children: [
      Container(width: 80, height: 80,
        decoration: BoxDecoration(shape: BoxShape.circle, color: kSuccess.withValues(alpha: 0.1)),
        child: const Icon(Icons.check_circle_rounded, color: kSuccess, size: 44),
      ).animate().scale(duration: 600.ms, curve: Curves.elasticOut),
      const SizedBox(height: 20),
      Text('Demande reçue !', style: GoogleFonts.inter(
        fontSize: 22, fontWeight: FontWeight.w700, color: kWhite), textAlign: TextAlign.center),
      const SizedBox(height: 10),
      Text('Notre équipe commerciale vous contactera dans les 24 heures pour finaliser votre inscription.',
        style: GoogleFonts.inter(fontSize: 14, color: kTextMuted, height: 1.6),
        textAlign: TextAlign.center),
    ]);
  }

  Widget _formView() {
    return Form(
      key: _formKey,
      child: Column(children: [
        _field(_nameCtrl, 'Votre nom complet', Icons.person_rounded),
        const SizedBox(height: 16),
        _field(_bizCtrl, 'Nom de votre commerce', Icons.store_rounded),
        const SizedBox(height: 16),
        _field(_phoneCtrl, 'Téléphone (WhatsApp de préférence)', Icons.phone_rounded,
          keyboardType: TextInputType.phone),
        const SizedBox(height: 16),
        _field(_cityCtrl, 'Ville / Quartier', Icons.location_city_rounded),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _type,
          onChanged: (v) => setState(() => _type = v!),
          dropdownColor: kNavyCard,
          style: GoogleFonts.inter(color: kWhite, fontSize: 15),
          decoration: const InputDecoration(
            labelText: 'Type d\'activité',
            prefixIcon: Icon(Icons.category_rounded, color: kTextMuted),
          ),
          items: widget.types.map((t) => DropdownMenuItem(
            value: t.$2,
            child: Row(children: [
              Icon(t.$1, size: 16, color: kOrange),
              const SizedBox(width: 8),
              Text(t.$2),
            ]),
          )).toList(),
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: kOrange, foregroundColor: kWhite,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: _loading
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(color: kWhite, strokeWidth: 2))
                : Text('Devenir partenaire gratuitement',
                    style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType? keyboardType}) {
    return TextFormField(
      controller: ctrl,
      keyboardType: keyboardType,
      style: GoogleFonts.inter(color: kWhite, fontSize: 15),
      validator: (v) => (v?.isEmpty ?? true) ? 'Obligatoire' : null,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: kTextMuted, size: 20),
      ),
    );
  }
}
