import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:google_fonts/google_fonts.dart';

import 'pharmacie_dashboard.dart';

class PharmacieChangePassword extends StatefulWidget {
  final String pharmacieId;
  final Map<String, dynamic> pharmacieData;

  const PharmacieChangePassword({
    super.key,
    required this.pharmacieId,
    required this.pharmacieData,
  });

  @override
  State<PharmacieChangePassword> createState() =>
      _PharmacieChangePasswordState();
}

class _PharmacieChangePasswordState extends State<PharmacieChangePassword> {
  final _newCtrl     = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscureNew     = true;
  bool _obscureConfirm = true;
  bool _loading        = false;

  @override
  void dispose() {
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final newPass = _newCtrl.text.trim();
    final confirm = _confirmCtrl.text.trim();

    if (newPass.isEmpty || confirm.isEmpty) {
      _snack('Veuillez remplir tous les champs', Colors.orange);
      return;
    }
    if (newPass.length < 6) {
      _snack('Le mot de passe doit contenir au moins 6 caractères', Colors.orange);
      return;
    }
    if (newPass != confirm) {
      _snack('Les mots de passe ne correspondent pas', Colors.red);
      return;
    }

    setState(() => _loading = true);
    try {
      final fn = FirebaseFunctions.instanceFor(region: 'europe-west1');
      await fn.httpsCallable('setPharmaciePassword').call({
        'pharmacieId': widget.pharmacieId,
        'newPassword': newPass,
      });

      if (!mounted) return;
      final cleanData = Map<String, dynamic>.from(widget.pharmacieData)
        ..remove('password')
        ..remove('accessCode');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => PharmacieDashboard(
            pharmacieId: widget.pharmacieId,
            pharmacieData: {
              ...cleanData,
              'mustChangePassword': false,
            },
          ),
        ),
      );
    } catch (e) {
      if (mounted) _snack('Erreur : $e', Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final red = Colors.red.shade700;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('Définir un mot de passe',
            style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
        backgroundColor: red,
        foregroundColor: Colors.white,
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_reset_rounded,
                      color: Colors.orange.shade700, size: 32),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Première connexion',
                            style: GoogleFonts.inter(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: Colors.orange.shade800)),
                        const SizedBox(height: 2),
                        Text(
                            'Définissez un mot de passe personnel '
                            'pour sécuriser votre accès.',
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                color: Colors.orange.shade700)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            _passField(
              ctrl: _newCtrl,
              label: 'Nouveau mot de passe (min. 6 caractères)',
              obscure: _obscureNew,
              color: red,
              onToggle: () => setState(() => _obscureNew = !_obscureNew),
            ),
            const SizedBox(height: 16),
            _passField(
              ctrl: _confirmCtrl,
              label: 'Confirmer le mot de passe',
              obscure: _obscureConfirm,
              color: red,
              onToggle: () =>
                  setState(() => _obscureConfirm = !_obscureConfirm),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ScaleButton(
                onPressed: _loading ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: red,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text('Enregistrer mon mot de passe',
                        style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _passField({
    required TextEditingController ctrl,
    required String label,
    required bool obscure,
    required Color color,
    required VoidCallback onToggle,
  }) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(Icons.lock_outline, color: color),
        suffixIcon: IconButton(
          icon: Icon(
            obscure
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            color: Colors.grey,
          ),
          onPressed: onToggle,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: color, width: 2),
        ),
        filled: true,
        fillColor: Colors.white,
      ),
    );
  }
}

