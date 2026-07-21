import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../ek_constants.dart';
import '../services/ek_service.dart';

class EkAgentRegister extends StatefulWidget {
  const EkAgentRegister({super.key});

  @override
  State<EkAgentRegister> createState() => _EkAgentRegisterState();
}

class _EkAgentRegisterState extends State<EkAgentRegister> {
  final _formKey    = GlobalKey<FormState>();
  final _nameCtrl   = TextEditingController();
  final _phoneCtrl  = TextEditingController();
  final _cityCtrl   = TextEditingController();
  final Set<String> _selectedOps = {};
  final Map<String, TextEditingController> _opNumCtrl = {};
  bool _submitting  = false;
  bool _done        = false;

  final _cities = [
    'Abengourou', 'Abidjan', 'Bouaké', 'Yamoussoukro', 'Divo',
    'San-Pédro', 'Daloa', 'Korhogo', 'Man', 'Bondoukou',
  ];

  @override
  void initState() {
    super.initState();
    _prefillFromProfile();
  }

  Future<void> _prefillFromProfile() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('clients').doc(uid).get();
      if (!mounted) return;
      final d = doc.data();
      if (d != null) {
        _nameCtrl.text  = d['name'] ?? '';
        _phoneCtrl.text = d['phone'] ?? '';
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _cityCtrl.dispose();
    for (final c in _opNumCtrl.values) { c.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return _buildSuccess();

    return Scaffold(
      backgroundColor: kEkBg,
      appBar: AppBar(
        backgroundColor: kEkDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('Devenir Agent E-Kbine',
            style: GoogleFonts.urbanist(
                fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // Intro card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [kEkGreen, kEkTeal],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('💚 Rejoignez la communauté',
                    style: GoogleFonts.urbanist(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                ...[
                  '75% des frais de service vous reviennent',
                  'Travaillez à votre rythme, où vous voulez',
                  'Paiement direct dans votre wallet',
                ].map((t) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(children: [
                        const Icon(Icons.check_circle_rounded,
                            color: Colors.white, size: 14),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(t,
                              style: GoogleFonts.urbanist(
                                  color: Colors.white.withValues(alpha: 0.9),
                                  fontSize: 12)),
                        ),
                      ]),
                    )),
              ]),
            ),
            const SizedBox(height: 28),

            // Personal info
            const _SectionTitle('Informations personnelles'),
            const SizedBox(height: 14),
            _buildField('Nom complet', _nameCtrl,
                hint: 'Votre nom et prénom',
                icon: Icons.person_rounded,
                validator: (v) =>
                    (v?.isEmpty ?? true) ? 'Champ requis' : null),
            const SizedBox(height: 14),
            _buildField('Téléphone', _phoneCtrl,
                hint: '07 XX XX XX XX',
                icon: Icons.phone_rounded,
                keyboardType: TextInputType.phone,
                formatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (v) =>
                    (v?.length ?? 0) < 8 ? 'Numéro invalide' : null),
            const SizedBox(height: 14),

            // City dropdown
            Text('Ville d\'activité',
                style: GoogleFonts.urbanist(
                    fontSize: 13, fontWeight: FontWeight.w600,
                    color: kEkText)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white,
                prefixIcon: const Icon(Icons.location_on_rounded,
                    color: kEkGreen),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: kEkDivider)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: kEkDivider)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(
                        color: kEkGreen, width: 2)),
              ),
              hint: Text('Sélectionner votre ville',
                  style: GoogleFonts.urbanist(color: kEkMuted)),
              validator: (v) => v == null ? 'Choisissez une ville' : null,
              items: _cities
                  .map((c) =>
                      DropdownMenuItem(value: c, child: Text(c)))
                  .toList(),
              onChanged: (v) {
                if (v != null) _cityCtrl.text = v;
              },
            ),
            const SizedBox(height: 28),

            // Operators
            const _SectionTitle('Opérateurs que vous supportez'),
            const SizedBox(height: 6),
            Text(
                'Sélectionnez uniquement les opérateurs sur lesquels vous pouvez effectuer des opérations.',
                style: GoogleFonts.urbanist(fontSize: 12, color: kEkMuted,
                    height: 1.5)),
            const SizedBox(height: 14),
            ...ekOperators.map((op) {
              final id    = op['id'] as String;
              final color = Color(op['color'] as int);
              final bg    = Color(op['bg'] as int);
              final sel   = _selectedOps.contains(id);
              _opNumCtrl.putIfAbsent(id, TextEditingController.new);
              return Column(children: [
                GestureDetector(
                  onTap: () => setState(() {
                    if (sel) {
                      _selectedOps.remove(id);
                    } else {
                      _selectedOps.add(id);
                    }
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: EdgeInsets.only(bottom: sel ? 0.0 : 10.0),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: sel ? color.withValues(alpha: 0.08) : bg,
                      borderRadius: BorderRadius.only(
                        topLeft:     const Radius.circular(14),
                        topRight:    const Radius.circular(14),
                        bottomLeft:  Radius.circular(sel ? 0 : 14),
                        bottomRight: Radius.circular(sel ? 0 : 14),
                      ),
                      border: Border.all(
                          color: sel ? color : color.withValues(alpha: 0.2),
                          width: sel ? 2 : 1),
                    ),
                    child: Row(children: [
                      Text(op['emoji'] as String,
                          style: const TextStyle(fontSize: 26)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(op['label'] as String,
                            style: GoogleFonts.urbanist(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: color)),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 24, height: 24,
                        decoration: BoxDecoration(
                          color: sel ? color : Colors.transparent,
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: sel ? color : kEkDivider,
                              width: 2),
                        ),
                        child: sel
                            ? const Icon(Icons.check,
                                color: Colors.white, size: 14)
                            : null,
                      ),
                    ]),
                  ),
                ),
                if (sel)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.04),
                      borderRadius: const BorderRadius.only(
                        bottomLeft:  Radius.circular(14),
                        bottomRight: Radius.circular(14),
                      ),
                      border: Border(
                        left:   BorderSide(color: color, width: 2),
                        right:  BorderSide(color: color, width: 2),
                        bottom: BorderSide(color: color, width: 2),
                      ),
                    ),
                    child: TextFormField(
                      controller: _opNumCtrl[id],
                      keyboardType: TextInputType.phone,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: GoogleFonts.urbanist(
                          fontSize: 15, fontWeight: FontWeight.w700),
                      decoration: InputDecoration(
                        labelText: 'Votre numéro ${op['label']}',
                        hintText: op['id'] == 'orange' ? '07XXXXXXXX'
                            : op['id'] == 'mtn'    ? '05XXXXXXXX'
                            : op['id'] == 'moov'   ? '01XXXXXXXX'
                            : '07XXXXXXXX',
                        labelStyle: GoogleFonts.urbanist(color: color, fontSize: 13),
                        hintStyle: GoogleFonts.urbanist(color: kEkMuted),
                        prefixIcon: Icon(Icons.phone_android_rounded,
                            color: color),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: color)),
                        enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: color.withValues(alpha: 0.4))),
                        focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: color, width: 2)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                      validator: (v) {
                        if (_selectedOps.contains(id) &&
                            (v?.length ?? 0) < 8) {
                          return 'Numéro ${op['label']} invalide';
                        }
                        return null;
                      },
                    ),
                  ),
              ]);
            }),

            if (_selectedOps.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Sélectionnez au moins un opérateur',
                    style: GoogleFonts.urbanist(
                        fontSize: 11,
                        color: Colors.red.shade400)),
              ),

            const SizedBox(height: 28),

            // Terms
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'En vous inscrivant, vous acceptez d\'exécuter les services de manière '
                'honnête et professionnelle. Toute fraude entraîne une suspension définitive. '
                'Votre inscription sera examinée par l\'équipe AZ Express avant activation.',
                style: GoogleFonts.urbanist(
                    fontSize: 11, color: kEkMuted, height: 1.6),
              ),
            ),

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ScaleButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kEkGreen,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 24, height: 24,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5))
                    : Text('Soumettre ma candidature',
                        style: GoogleFonts.urbanist(
                            fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _buildField(
    String label,
    TextEditingController ctrl, {
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    List<TextInputFormatter>? formatters,
    String? Function(String?)? validator,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: GoogleFonts.urbanist(
              fontSize: 13, fontWeight: FontWeight.w600, color: kEkText)),
      const SizedBox(height: 8),
      TextFormField(
        controller: ctrl,
        keyboardType: keyboardType,
        inputFormatters: formatters,
        validator: validator,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.urbanist(color: kEkMuted),
          prefixIcon: Icon(icon, color: kEkGreen),
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: kEkDivider)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: kEkDivider)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: kEkGreen, width: 2)),
          errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Colors.red)),
        ),
      ),
    ]);
  }

  Widget _buildSuccess() {
    return Scaffold(
      backgroundColor: kEkBg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
            const Text('🎉', style: TextStyle(fontSize: 72)),
            const SizedBox(height: 24),
            Text('Candidature envoyée !',
                style: GoogleFonts.urbanist(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: kEkGreen),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
                'Notre équipe examinera votre profil sous 24–48h. '
                'Vous serez notifié par SMS dès que votre compte est activé.',
                style: GoogleFonts.urbanist(
                    fontSize: 14, color: kEkMuted, height: 1.6),
                textAlign: TextAlign.center),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ScaleButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: kEkGreen,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: Text('Retour à l\'accueil',
                    style: GoogleFonts.urbanist(
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_selectedOps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Sélectionnez au moins un opérateur'),
              backgroundColor: Colors.red));
      return;
    }

    setState(() => _submitting = true);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) { setState(() => _submitting = false); return; }

    final operatorNumbers = {
      for (final id in _selectedOps)
        if ((_opNumCtrl[id]?.text.trim() ?? '').isNotEmpty)
          id: _opNumCtrl[id]!.text.trim(),
    };

    await EkService.registerAgent(uid, {
      'name':            _nameCtrl.text.trim(),
      'phone':           _phoneCtrl.text.trim(),
      'city':            _cityCtrl.text.trim(),
      'operators':       _selectedOps.toList(),
      'operatorNumbers': operatorNumbers,
      'status':          'pending',
      'isOnline':        false,
      'isVerified':      false,
      'isSuspended':     false,
      'walletBalance':   0,
      'totalCompleted':  0,
      'rating':          0.0,
      'ratingCount':     0,
      'createdAt':       FieldValue.serverTimestamp(),
    });

    if (mounted) setState(() { _submitting = false; _done = true; });
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: GoogleFonts.urbanist(
            fontSize: 15, fontWeight: FontWeight.w800, color: kEkText));
  }
}

