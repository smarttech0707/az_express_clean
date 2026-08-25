import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../ek_constants.dart';
import '../models/ek_deposit_account.dart';
import '../services/ek_service.dart';
import '../utils/ek_deposit_accounts_logic.dart';
import '../widgets/ek_deposit_account_dialog.dart';

class EkAgentRegister extends StatefulWidget {
  const EkAgentRegister({super.key});

  @override
  State<EkAgentRegister> createState() => _EkAgentRegisterState();
}

class _EkAgentRegisterState extends State<EkAgentRegister> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  // Master Prompt — Mission 1 : inscription multi-lignes. Chaque ligne
  // (opérateur + numéro + libellé + principal) est un EkDepositAccount —
  // le même modèle déjà utilisé par ek_deposit_accounts_screen.dart après
  // inscription, pour ne jamais avoir deux représentations différentes des
  // numéros de dépôt d'un même agent.
  final List<EkDepositAccount> _depositAccounts = [];
  bool _submitting = false;
  bool _done = false;
  String? _depositAccountsError;

  final _cities = [
    'Abengourou',
    'Abidjan',
    'Bouaké',
    'Yamoussoukro',
    'Divo',
    'San-Pédro',
    'Daloa',
    'Korhogo',
    'Man',
    'Bondoukou',
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
      final doc =
          await FirebaseFirestore.instance.collection('clients').doc(uid).get();
      if (!mounted) return;
      final d = doc.data();
      if (d != null) {
        _nameCtrl.text = d['name'] ?? '';
        _phoneCtrl.text = d['phone'] ?? '';
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  // ── Gestion des lignes de numéros de dépôt (Mission 1) ──────────────────
  Future<void> _addOrEditAccount([EkDepositAccount? existing]) async {
    final result =
        await showEkDepositAccountDialog(context, existing: existing);
    if (result == null) return;

    if (EkDepositAccountsLogic.isDuplicate(_depositAccounts, result)) {
      setState(() => _depositAccountsError =
          'Ce numéro est déjà enregistré pour ${EkService.operatorLabel(result.operator)}.');
      return;
    }

    setState(() {
      _depositAccountsError = null;
      final merged = EkDepositAccountsLogic.merge(_depositAccounts, result);
      _depositAccounts
        ..clear()
        ..addAll(merged);
    });
  }

  void _removeAccount(EkDepositAccount account) {
    setState(() => _depositAccounts.removeWhere((a) => a.id == account.id));
  }

  /// Opérateurs réellement couverts par au moins un numéro actif — dérivés
  /// des lignes, jamais une sélection séparée qui pourrait diverger.
  List<String> get _coveredOperators =>
      EkDepositAccountsLogic.coveredOperators(_depositAccounts);

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
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                                      color:
                                          Colors.white.withValues(alpha: 0.9),
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
                validator: (v) => (v?.isEmpty ?? true) ? 'Champ requis' : null),
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
                    fontSize: 13, fontWeight: FontWeight.w600, color: kEkText)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white,
                prefixIcon:
                    const Icon(Icons.location_on_rounded, color: kEkGreen),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: kEkDivider)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: kEkDivider)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: kEkGreen, width: 2)),
              ),
              hint: Text('Sélectionner votre ville',
                  style: GoogleFonts.urbanist(color: kEkMuted)),
              validator: (v) => v == null ? 'Choisissez une ville' : null,
              items: _cities
                  .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                  .toList(),
              onChanged: (v) {
                if (v != null) _cityCtrl.text = v;
              },
            ),
            const SizedBox(height: 28),

            // Numéros de dépôt (Mission 1 — plusieurs numéros, y compris
            // plusieurs numéros du même opérateur).
            const _SectionTitle('Vos numéros de dépôt Mobile Money'),
            const SizedBox(height: 6),
            Text(
                'Ajoutez au moins un numéro sur lequel les clients pourront effectuer leurs dépôts. Vous pouvez ajouter plusieurs numéros, y compris plusieurs numéros pour le même opérateur.',
                style: GoogleFonts.urbanist(
                    fontSize: 12, color: kEkMuted, height: 1.5)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFFE65100).withValues(alpha: 0.4)),
              ),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded,
                    color: Color(0xFFE65100), size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Ne communiquez jamais votre code PIN Mobile Money à qui que ce soit, y compris à l\'équipe AZ Express.',
                    style: GoogleFonts.urbanist(
                        fontSize: 11,
                        color: const Color(0xFF5D4037),
                        height: 1.4),
                  ),
                ),
              ]),
            ),
            ..._depositAccounts.map((a) {
              final opColor = EkService.operatorColor(a.operator);
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: opColor.withValues(alpha: 0.12),
                    child: Text(a.operator[0].toUpperCase(),
                        style: TextStyle(
                            color: opColor, fontWeight: FontWeight.bold)),
                  ),
                  title: Text(
                      '${EkService.operatorLabel(a.operator)} · ${a.phoneNumber}'),
                  subtitle: Text(
                      '${a.label ?? 'Sans libellé'} · ${a.isActive ? 'Actif' : 'Désactivé'}'),
                  trailing: Wrap(spacing: 0, children: [
                    if (a.isPrimary)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Chip(
                            label: Text('Principal',
                                style: TextStyle(fontSize: 10)),
                            visualDensity: VisualDensity.compact),
                      ),
                    IconButton(
                        icon: const Icon(Icons.edit, size: 20),
                        tooltip: 'Modifier',
                        onPressed: () => _addOrEditAccount(a)),
                    IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: 'Retirer la ligne',
                        onPressed: () => _removeAccount(a)),
                  ]),
                ),
              );
            }),
            OutlinedButton.icon(
              onPressed: () => _addOrEditAccount(),
              icon: const Icon(Icons.add),
              label: const Text('Ajouter un numéro'),
              style: OutlinedButton.styleFrom(
                foregroundColor: kEkGreen,
                side: const BorderSide(color: kEkGreen),
                minimumSize: const Size(double.infinity, 46),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
            if (_depositAccountsError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_depositAccountsError!,
                    style: GoogleFonts.urbanist(
                        fontSize: 11, color: Colors.red.shade400)),
              ),
            if (_depositAccounts.where((a) => a.isActive).isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Ajoutez au moins un numéro actif',
                    style: GoogleFonts.urbanist(
                        fontSize: 11, color: Colors.red.shade400)),
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
                        width: 24,
                        height: 24,
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
              borderSide: const BorderSide(color: kEkGreen, width: 2)),
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
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Text('🎉', style: TextStyle(fontSize: 72)),
            const SizedBox(height: 24),
            Text('Candidature envoyée !',
                style: GoogleFonts.urbanist(
                    fontSize: 24, fontWeight: FontWeight.w900, color: kEkGreen),
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
                    style: GoogleFonts.urbanist(fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    // Règle Mission 1 : au moins un compte actif requis avant inscription —
    // sans ça, l'agent serait approuvé mais ne pourrait jamais accepter la
    // moindre commande (voir EkAgent.accountsFor()/selectDepositAccount côté
    // serveur, qui ne trouveraient aucun numéro valide).
    if (_depositAccounts.where((a) => a.isActive).isEmpty) {
      setState(
          () => _depositAccountsError = 'Ajoutez au moins un numéro actif');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ajoutez au moins un numéro de dépôt actif'),
          backgroundColor: Colors.red));
      return;
    }

    setState(() => _submitting = true);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => _submitting = false);
      return;
    }

    // `operatorNumbers` (compatibilité historique — Mission 1 : "conserver
    // operatorNumbers uniquement comme compatibilité") reprend le numéro
    // principal actif de chaque opérateur, à défaut le premier actif.
    final operatorNumbers =
        EkDepositAccountsLogic.legacyOperatorNumbers(_depositAccounts);

    await EkService.registerAgent(uid, {
      'name': _nameCtrl.text.trim(),
      'phone': _phoneCtrl.text.trim(),
      'city': _cityCtrl.text.trim(),
      'operators': _coveredOperators,
      'operatorNumbers': operatorNumbers,
      'depositAccounts': _depositAccounts.map((a) => a.toMap()).toList(),
      'status': 'pending',
      'isOnline': false,
      'isVerified': false,
      'isSuspended': false,
      'walletBalance': 0,
      'totalCompleted': 0,
      'rating': 0.0,
      'ratingCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });

    if (mounted) {
      setState(() {
        _submitting = false;
        _done = true;
      });
    }
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
