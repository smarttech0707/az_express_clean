import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../web_theme.dart';
import '../widgets/web_navbar.dart';
import '../widgets/web_footer.dart';

class WebDriversPage extends StatelessWidget {
  const WebDriversPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kNavy,
      body: Stack(
        children: [
          SingleChildScrollView(
            child: Column(children: [
              const SizedBox(height: 72),
              _HeroSection(),
              _PerksSection(),
              _FormSection(),
              const WebFooter(),
            ]),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: WebNavBar(currentRoute: '/livreurs'),
          ),
        ],
      ),
    );
  }
}

class _HeroSection extends StatelessWidget {
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
              color: kOrange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('REJOIGNEZ NOTRE FLOTTE',
                style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: kOrange,
                    letterSpacing: 1.2)),
          ).animate().fadeIn(duration: 600.ms),
          const SizedBox(height: 20),
          Text(
            'Devenez Livreur\nAZ Express',
            style: kDisplayStyle(context),
            textAlign: TextAlign.center,
          ).animate(delay: 200.ms).fadeIn(duration: 700.ms),
          const SizedBox(height: 16),
          Text(
            'Travaillez à votre rythme. Gagnez plus. Soyez votre propre patron.',
            style:
                GoogleFonts.inter(fontSize: 17, color: kTextMuted, height: 1.6),
            textAlign: TextAlign.center,
          ).animate(delay: 350.ms).fadeIn(duration: 600.ms),
          const SizedBox(height: 32),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              _statBadge('50,000+ FCFA', 'par semaine en moyenne'),
              _statBadge('Horaires libres', 'vous choisissez quand'),
              _statBadge('Paiement rapide', 'chaque semaine'),
            ],
          ).animate(delay: 500.ms).fadeIn(duration: 600.ms),
        ],
      ),
    );
  }

  Widget _statBadge(String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: kNavyCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDivider),
      ),
      child: Column(
        children: [
          Text(value,
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: kOrange,
              )),
          Text(label,
              style: GoogleFonts.inter(fontSize: 12, color: kTextMuted)),
        ],
      ),
    );
  }
}

class _PerksSection extends StatelessWidget {
  static const _perks = [
    (
      Icons.schedule_rounded,
      'Horaires flexibles',
      'Travaillez quand vous voulez, autant que vous voulez.'
    ),
    (
      Icons.payments_rounded,
      'Paiement hebdomadaire',
      'Recevez vos gains chaque semaine sur votre mobile money.'
    ),
    (
      Icons.trending_up_rounded,
      'Primes & Bonus',
      'Bonus de performance et primes de fidélité.'
    ),
    (
      Icons.support_agent_rounded,
      'Support dédié',
      'Une équipe disponible 7j/7 pour vous accompagner.'
    ),
    (
      Icons.shield_rounded,
      'Assurance incluse',
      'Couverture assurance lors de vos livraisons.'
    ),
    (
      Icons.star_rounded,
      'Progression rapide',
      'Montez en grade et débloquez plus d\'avantages.'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final cols = isDesktop(context) ? 3 : 2;
    return Container(
      color: kNavyMid,
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 72),
      child: Column(
        children: [
          Text('Pourquoi nous rejoindre ?',
              style: kH1Style(context), textAlign: TextAlign.center),
          const SizedBox(height: 48),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: isDesktop(context) ? 1.5 : 1.2,
            ),
            itemCount: _perks.length,
            itemBuilder: (_, i) => Container(
              padding: const EdgeInsets.all(24),
              decoration: glassCard(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: kOrange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(_perks[i].$1, color: kOrange, size: 22),
                  ),
                  const SizedBox(height: 14),
                  Text(_perks[i].$2,
                      style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: kWhite)),
                  const SizedBox(height: 8),
                  Text(_perks[i].$3,
                      style: GoogleFonts.inter(
                          fontSize: 13, color: kTextMuted, height: 1.6)),
                ],
              ),
            ).animate(delay: (i * 80).ms).fadeIn(duration: 600.ms),
          ),
        ],
      ),
    );
  }
}

class _FormSection extends StatefulWidget {
  @override
  State<_FormSection> createState() => _FormSectionState();
}

class _FormSectionState extends State<_FormSection> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  String _vehicle = 'Moto';
  String _experience = 'Moins de 1 an';
  bool _loading = false;
  bool _success = false;

  static const _vehicles = ['Moto', 'Vélo', 'Voiture', 'Tricycle'];
  static const _experiences = [
    'Moins de 1 an',
    '1 à 2 ans',
    '2 à 5 ans',
    'Plus de 5 ans'
  ];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await FirebaseFirestore.instance.collection('driver_applications').add({
        'name': _nameCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim(),
        'city': _cityCtrl.text.trim(),
        'vehicle': _vehicle,
        'experience': _experience,
        'source': 'website',
        'status': 'pending',
        'createdAt': Timestamp.now(),
      });
      setState(() {
        _loading = false;
        _success = true;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final formWidth = w > 700 ? 560.0 : double.infinity;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad(context), vertical: 80),
      child: Column(
        children: [
          Text('Candidature Livreur',
              style: kH1Style(context), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
              'Remplissez le formulaire ci-dessous. Notre équipe vous contacte sous 24h.',
              style: GoogleFonts.inter(fontSize: 15, color: kTextMuted),
              textAlign: TextAlign.center),
          const SizedBox(height: 40),
          Center(
            child: Container(
              width: formWidth,
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
    return Column(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: kSuccess.withValues(alpha: 0.1),
          ),
          child:
              const Icon(Icons.check_circle_rounded, color: kSuccess, size: 44),
        ).animate().scale(duration: 600.ms, curve: Curves.elasticOut),
        const SizedBox(height: 20),
        Text('Candidature envoyée !',
            style: GoogleFonts.inter(
                fontSize: 22, fontWeight: FontWeight.w700, color: kWhite),
            textAlign: TextAlign.center),
        const SizedBox(height: 10),
        Text(
            'Merci ! Notre équipe examinera votre dossier et vous contactera dans les 24 heures.',
            style:
                GoogleFonts.inter(fontSize: 14, color: kTextMuted, height: 1.6),
            textAlign: TextAlign.center),
      ],
    );
  }

  Widget _formView() {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          _field(_nameCtrl, 'Nom complet', Icons.person_rounded,
              validator: (v) => (v?.isEmpty ?? true) ? 'Obligatoire' : null),
          const SizedBox(height: 16),
          _field(_phoneCtrl, 'Numéro de téléphone', Icons.phone_rounded,
              keyboardType: TextInputType.phone,
              validator: (v) => (v?.isEmpty ?? true) ? 'Obligatoire' : null),
          const SizedBox(height: 16),
          _field(_cityCtrl, 'Ville', Icons.location_city_rounded,
              validator: (v) => (v?.isEmpty ?? true) ? 'Obligatoire' : null),
          const SizedBox(height: 16),
          _dropdown('Type d\'engin', _vehicles, _vehicle,
              (v) => setState(() => _vehicle = v!)),
          const SizedBox(height: 16),
          _dropdown('Expérience de livraison', _experiences, _experience,
              (v) => setState(() => _experience = v!)),
          const SizedBox(height: 28),
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
                  : Text('Envoyer ma candidature',
                      style: GoogleFonts.inter(
                          fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {String? Function(String?)? validator, TextInputType? keyboardType}) {
    return TextFormField(
      controller: ctrl,
      validator: validator,
      keyboardType: keyboardType,
      style: GoogleFonts.inter(color: kWhite, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: kTextMuted, size: 20),
      ),
    );
  }

  Widget _dropdown(String label, List<String> items, String value,
      void Function(String?) onChanged) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      onChanged: onChanged,
      dropdownColor: kNavyCard,
      style: GoogleFonts.inter(color: kWhite, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon:
            const Icon(Icons.arrow_drop_down_rounded, color: kTextMuted),
      ),
      items: items
          .map((i) => DropdownMenuItem(
                value: i,
                child: Text(i),
              ))
          .toList(),
    );
  }
}
