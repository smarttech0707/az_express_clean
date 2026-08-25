import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';

class ResetPasswordPage extends StatefulWidget {
  final PhoneAuthCredential? phoneCredential;
  final String phone;
  const ResetPasswordPage({
    super.key,
    required this.phone,
    this.phoneCredential,
  });

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _showPass = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _save() async {
    final pass = _passCtrl.text;
    final confirm = _confirmCtrl.text;

    final err = AuthService.validatePassword(pass);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    if (pass != confirm) {
      setState(() => _error = 'Les mots de passe ne correspondent pas');
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || user.phoneNumber == null) {
        throw Exception('Session téléphonique expirée. Recommencez.');
      }
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('resetAccountPassword')
          .call(<String, dynamic>{
        'userType': 'client',
        'phone': widget.phone,
        'newValue': pass,
      });
      if (!mounted) return;
      _snack('Mot de passe mis à jour avec succès !', Colors.green);
      // Déconnecter et retourner à l'accueil
      await FirebaseAuth.instance.signOut();
      try {
        await FirebaseAuth.instance.signInAnonymously();
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } on FirebaseAuthException catch (e) {
      _snack(
          e.code == 'weak-password'
              ? 'Mot de passe trop faible'
              : 'Erreur : ${e.message}',
          Colors.red);
    } catch (e) {
      _snack(e.toString(), Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Nouveau mot de passe'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [AppColors.primary, Color(0xFFFFB300)]),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lock_open, size: 48, color: Colors.white),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Créer un nouveau mot de passe',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.bold)),
                        SizedBox(height: 4),
                        Text('Choisissez un mot de passe sécurisé',
                            style:
                                TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Règles de sécurité
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Le mot de passe doit contenir :',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  SizedBox(height: 6),
                  _Rule(text: 'Au moins 8 caractères'),
                  _Rule(text: 'Au moins 1 majuscule (A-Z)'),
                  _Rule(text: 'Au moins 1 chiffre (0-9)'),
                ],
              ),
            ),

            const SizedBox(height: 24),

            _PassField(
              controller: _passCtrl,
              label: 'Nouveau mot de passe',
              showPass: _showPass,
              onToggle: () => setState(() => _showPass = !_showPass),
            ),
            const SizedBox(height: 14),
            _PassField(
              controller: _confirmCtrl,
              label: 'Confirmer le mot de passe',
              showPass: _showPass,
              onToggle: () => setState(() => _showPass = !_showPass),
            ),

            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],

            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: _loading ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                child: _loading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5))
                    : const Text('Enregistrer le mot de passe',
                        style: TextStyle(
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
}

class _Rule extends StatelessWidget {
  final String text;
  const _Rule({required this.text});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline,
              size: 14, color: Colors.orange.shade700),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _PassField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool showPass;
  final VoidCallback onToggle;
  const _PassField(
      {required this.controller,
      required this.label,
      required this.showPass,
      required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: !showPass,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.lock_outline, color: AppColors.primary),
        suffixIcon: IconButton(
          icon: Icon(
              showPass
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: Colors.grey),
          onPressed: onToggle,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }
}
