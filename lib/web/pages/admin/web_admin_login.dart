import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../web_theme.dart';
import '../../admin_auth_service.dart';
import '../../widgets/az_logo.dart';

class WebAdminLoginPage extends StatefulWidget {
  const WebAdminLoginPage({super.key});

  @override
  State<WebAdminLoginPage> createState() => _WebAdminLoginPageState();
}

class _WebAdminLoginPageState extends State<WebAdminLoginPage> {
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  final _formKey   = GlobalKey<FormState>();
  bool _loading    = false;
  bool _showPass   = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });
    final err = await AdminAuthService.instance.signIn(
      _emailCtrl.text.trim(), _passCtrl.text,
    );
    if (!mounted) return;
    if (err != null) {
      setState(() { _loading = false; _error = err; });
    } else {
      context.go('/admin/dashboard');
    }
  }

  Future<void> _resetPassword() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Entrez votre email avant de réinitialiser.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Email de réinitialisation envoyé à $email',
            style: GoogleFonts.inter(color: Colors.white)),
          backgroundColor: kSuccess,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.code == 'user-not-found'
            ? 'Aucun compte trouvé avec cet email.'
            : 'Erreur : ${e.code}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Logo + titre
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 32),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFFF6D00), Color(0xFFFF8F00)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [BoxShadow(
                        color: kOrange.withValues(alpha: 0.3),
                        blurRadius: 30, offset: const Offset(0, 10),
                      )],
                    ),
                    child: Column(children: [
                      const AzLogo(size: 64),
                      const SizedBox(height: 16),
                      Text('Espace Admin', style: GoogleFonts.inter(
                        fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
                      const SizedBox(height: 4),
                      Text('AZ Express — Accès réservé', style: GoogleFonts.inter(
                        fontSize: 13, color: Colors.white.withValues(alpha: 0.8))),
                    ]),
                  ),
                  const SizedBox(height: 36),

                  // Email
                  TextFormField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    style: GoogleFonts.inter(color: kText, fontSize: 15),
                    validator: (v) => (v?.isEmpty ?? true) ? 'Obligatoire' : null,
                    decoration: InputDecoration(
                      labelText: 'Email administrateur',
                      prefixIcon: const Icon(Icons.email_rounded, color: kTextMuted, size: 20),
                      filled: true,
                      fillColor: kCard,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: kOrange, width: 2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Mot de passe
                  TextFormField(
                    controller: _passCtrl,
                    obscureText: !_showPass,
                    onFieldSubmitted: (_) => _login(),
                    style: GoogleFonts.inter(color: kText, fontSize: 15),
                    validator: (v) => (v?.isEmpty ?? true) ? 'Obligatoire' : null,
                    decoration: InputDecoration(
                      labelText: 'Mot de passe',
                      prefixIcon: const Icon(Icons.lock_rounded, color: kTextMuted, size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(_showPass ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                          color: kTextMuted, size: 20),
                        onPressed: () => setState(() => _showPass = !_showPass),
                      ),
                      filled: true,
                      fillColor: kCard,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: kOrange, width: 2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                    ),
                  ),

                  // Mot de passe oublié
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _loading ? null : _resetPassword,
                      child: Text('Mot de passe oublié ?',
                        style: GoogleFonts.inter(
                          fontSize: 13, color: kOrange, fontWeight: FontWeight.w600)),
                    ),
                  ),

                  // Message d'erreur
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.error_outline_rounded, color: Colors.red, size: 16),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_error!, style: GoogleFonts.inter(
                          fontSize: 13, color: Colors.red))),
                      ]),
                    ),
                  ],

                  const SizedBox(height: 24),

                  // Bouton connexion
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _login,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kOrange,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      ),
                      child: _loading
                          ? const SizedBox(width: 22, height: 22,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : Text('Se connecter', style: GoogleFonts.inter(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('Accès réservé aux administrateurs AZ Express.',
                    style: GoogleFonts.inter(fontSize: 12, color: kTextMuted),
                    textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
