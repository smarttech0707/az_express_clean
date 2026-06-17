import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../web_theme.dart';
import '../../web_client_auth.dart';
import '../../widgets/az_logo.dart';

class WebClientLoginPage extends StatefulWidget {
  const WebClientLoginPage({super.key});
  @override
  State<WebClientLoginPage> createState() => _WebClientLoginPageState();
}

class _WebClientLoginPageState extends State<WebClientLoginPage> {
  bool    _isLogin  = true;
  bool    _loading  = false;
  String? _error;

  final _nameCtrl  = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose(); _phoneCtrl.dispose(); _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final phone = _phoneCtrl.text.trim();
    final pass  = _passCtrl.text.trim();
    if (phone.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Remplis tous les champs');
      return;
    }
    if (!_isLogin && _nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Entre ton nom');
      return;
    }

    setState(() { _loading = true; _error = null; });

    final err = _isLogin
        ? await WebClientAuth.instance.login(phone, pass)
        : await WebClientAuth.instance.register(_nameCtrl.text.trim(), phone, pass);

    if (!mounted) return;
    setState(() => _loading = false);
    if (err != null) {
      setState(() => _error = err);
    } else {
      context.go('/app');
    }
  }

  @override
  Widget build(BuildContext context) {
    final mob = isMobile(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: Row(
        children: [
          if (!mob) _LeftPanel(),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(mob ? 24 : 48),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: _FormCard(
                    isLogin:  _isLogin,
                    loading:  _loading,
                    error:    _error,
                    nameCtrl: _nameCtrl,
                    phoneCtrl: _phoneCtrl,
                    passCtrl: _passCtrl,
                    onToggle: () => setState(() {
                      _isLogin = !_isLogin; _error = null;
                    }),
                    onSubmit: _submit,
                  ).animate().fadeIn(duration: 500.ms).slideY(begin: 0.05),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LeftPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        decoration: const BoxDecoration(gradient: kHeroGradient),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const AzLogo(size: 80),
            const SizedBox(height: 24),
            Text('AZ Express',
                style: GoogleFonts.inter(
                    fontSize: 36, fontWeight: FontWeight.w900, color: Colors.white)),
            const SizedBox(height: 12),
            Text('Livraison express à Abengourou',
                style: GoogleFonts.inter(fontSize: 16, color: Colors.white70)),
            const SizedBox(height: 48),
            ...[
              (Icons.bolt_rounded,           'Livraison en 30 min'),
              (Icons.account_balance_wallet,  'Wallet intégré'),
              (Icons.restaurant_rounded,      'Restaurants & Boulangeries'),
              (Icons.local_pharmacy_rounded,  'Pharmacies de garde'),
            ].map((e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 48),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(e.$1, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 16),
                Text(e.$2, style: GoogleFonts.inter(
                    color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
              ]),
            )),
          ],
        ),
      ),
    );
  }
}

class _FormCard extends StatelessWidget {
  final bool     isLogin;
  final bool     loading;
  final String?  error;
  final TextEditingController nameCtrl, phoneCtrl, passCtrl;
  final VoidCallback onToggle, onSubmit;

  const _FormCard({
    required this.isLogin, required this.loading, required this.error,
    required this.nameCtrl, required this.phoneCtrl, required this.passCtrl,
    required this.onToggle, required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(36),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: kDivider.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Center(child: AzLogo(size: 48)),
          const SizedBox(height: 24),
          Text(isLogin ? 'Connexion' : 'Créer un compte',
              style: GoogleFonts.inter(
                  fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 6),
          Text(isLogin ? 'Entre tes identifiants pour accéder à ton espace'
                       : 'Crée ton compte pour commander sur AZ Express',
              style: GoogleFonts.inter(fontSize: 13, color: kTextMuted)),
          const SizedBox(height: 28),

          if (!isLogin) ...[
            _field(nameCtrl, 'Nom complet', Icons.person_rounded),
            const SizedBox(height: 16),
          ],
          _field(phoneCtrl, 'Numéro de téléphone', Icons.phone_rounded,
              type: TextInputType.phone, hint: 'Ex: 07 00 00 00 00'),
          const SizedBox(height: 16),
          _field(passCtrl, 'Mot de passe', Icons.lock_rounded,
              obscure: true, hint: 'Minimum 6 caractères'),

          if (error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.error_outline_rounded, color: Colors.red, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(error!,
                    style: GoogleFonts.inter(color: Colors.red, fontSize: 13))),
              ]),
            ),
          ],

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: loading ? null : onSubmit,
              style: ElevatedButton.styleFrom(
                backgroundColor: kOrange,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: loading
                  ? const SizedBox(width: 22, height: 22,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                  : Text(isLogin ? 'Se connecter' : 'Créer mon compte',
                      style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),

          const SizedBox(height: 20),
          Center(
            child: TextButton(
              onPressed: onToggle,
              child: RichText(
                text: TextSpan(
                  style: GoogleFonts.inter(fontSize: 13, color: kTextMuted),
                  children: [
                    TextSpan(text: isLogin ? "Pas encore de compte ? " : "Déjà un compte ? "),
                    TextSpan(
                      text: isLogin ? "S'inscrire" : "Se connecter",
                      style: const TextStyle(color: kOrange, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {bool obscure = false, TextInputType? type, String? hint}) {
    return TextField(
      controller:   ctrl,
      obscureText:  obscure,
      keyboardType: type,
      style: GoogleFonts.inter(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        labelText:  label,
        hintText:   hint,
        prefixIcon: Icon(icon, color: kTextMuted, size: 20),
      ),
    );
  }
}
