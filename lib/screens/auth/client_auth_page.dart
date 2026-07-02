import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../l10n/app_text.dart';
import '../../services/notification_service.dart';
import '../../services/auth_service.dart';
import '../main_dashboard.dart';
import '../seller/seller_dashboard.dart';
import 'forgot_password_page.dart';

class ClientAuthPage extends StatefulWidget {
  const ClientAuthPage({super.key});

  @override
  State<ClientAuthPage> createState() => _ClientAuthPageState();
}

class _ClientAuthPageState extends State<ClientAuthPage>
    with SingleTickerProviderStateMixin {
  bool _isLogin  = true;
  bool _loading  = false;
  bool _obscurePass    = true;
  bool _obscureConfirm = true;

  final _phoneCtrl   = TextEditingController();
  final _nameCtrl    = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _passCtrl    = TextEditingController();
  final _confirmCtrl = TextEditingController();

  // Champ unique pour le login (phone OU email)
  final _loginCtrl = TextEditingController();

  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350));
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeIn);
    _animCtrl.forward();
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    _loginCtrl.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  Future<void> _submit() async {
    final password = _passCtrl.text.trim();

    if (_isLogin) {
      final input = _loginCtrl.text.trim();
      if (input.isEmpty || password.isEmpty) {
        _snack(context.tr('fill_required'), Colors.orange);
        return;
      }
      setState(() => _loading = true);
      try {
        await _doLogin(input, password);
      } on FirebaseAuthException catch (e) {
        if (mounted) _snack(_authError(e.code), Colors.red);
      } catch (e) {
        if (mounted) _snack('Erreur : $e', Colors.red);
      }
      if (mounted) setState(() => _loading = false);
    } else {
      final name    = _nameCtrl.text.trim();
      final phone   = _phoneCtrl.text.trim();
      final email   = _emailCtrl.text.trim();
      final confirm = _confirmCtrl.text.trim();

      if (name.isEmpty || phone.isEmpty || email.isEmpty || password.isEmpty) {
        _snack(context.tr('fill_required'), Colors.orange);
        return;
      }
      if (!AuthService.isValidEmail(email)) {
        _snack('Adresse email invalide', Colors.orange);
        return;
      }
      if (!AuthService.isValidPhone(phone)) {
        _snack('Numéro de téléphone invalide', Colors.orange);
        return;
      }
      final passErr = AuthService.validatePassword(password);
      if (passErr != null) {
        _snack(passErr, Colors.orange);
        return;
      }
      if (password != confirm) {
        _snack('Les mots de passe ne correspondent pas', Colors.orange);
        return;
      }
      setState(() => _loading = true);
      try {
        await _doRegister(email, password, name, phone);
      } on FirebaseAuthException catch (e) {
        if (mounted) _snack(_authError(e.code), Colors.red);
      } catch (e) {
        if (mounted) _snack('Erreur : $e', Colors.red);
      }
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _doLogin(String input, String password) async {
    final current = FirebaseAuth.instance.currentUser;
    if (current != null && current.isAnonymous) {
      await FirebaseAuth.instance.signOut();
    }

    UserCredential? credential;
    bool isSeller = false;

    // Détermine l'email Firebase à utiliser
    String authEmail;
    if (input.contains('@')) {
      // Entrée = email direct
      authEmail = input;
    } else {
      // Entrée = téléphone → cherche l'email dans Firestore
      final resolved = await AuthService().getClientAuthEmail(input);
      if (resolved == null) {
        if (mounted) _snack('Numéro de téléphone introuvable', Colors.red);
        setState(() => _loading = false);
        return;
      }
      authEmail = resolved;
    }

    try {
      credential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: authEmail, password: password);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found' ||
          e.code == 'invalid-credential' ||
          e.code == 'wrong-password') {
        // Essayer compte vendeur
        final phone = input.replaceAll(' ', '');
        final sellerEmail = input.contains('@') ? input : '$phone@az-seller.ci';
        credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: sellerEmail, password: password);
        isSeller = true;
      } else {
        rethrow;
      }
    }

    if (!mounted) return;

    if (isSeller) {
      final uid = credential.user!.uid;
      final sellerDoc = await FirebaseFirestore.instance
          .collection('sellers').doc(uid).get();
      if (!mounted) return;
      if (!sellerDoc.exists || !(sellerDoc.data()?['isActive'] ?? false)) {
        await FirebaseAuth.instance.signOut();
        try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
        _snack("Compte inactif. Contactez l'administrateur.", Colors.red);
        setState(() => _loading = false);
        return;
      }
      AuthService().logAuthEvent('login', 'seller');
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => SellerDashboard(
          sellerId: uid, sellerData: sellerDoc.data()!)),
        (route) => false,
      );
    } else {
      AuthService().logAuthEvent('login', 'client');
      _goToDashboard();
    }
  }

  Future<void> _doRegister(
      String email, String password, String name, String phone) async {
    final current = FirebaseAuth.instance.currentUser;
    if (current != null && current.isAnonymous) {
      await FirebaseAuth.instance.signOut();
    }

    // Vérifier si le téléphone existe déjà
    final phoneExists = await FirebaseFirestore.instance
        .collection('clients')
        .where('phone', isEqualTo: phone)
        .limit(1)
        .get();
    if (phoneExists.docs.isNotEmpty) {
      throw FirebaseAuthException(
          code: 'phone-already-in-use',
          message: 'Ce numéro est déjà associé à un compte');
    }

    // Utiliser le vrai email comme identifiant Firebase Auth
    final cred = await FirebaseAuth.instance
        .createUserWithEmailAndPassword(email: email, password: password);
    final uid = cred.user?.uid;
    if (uid == null) throw Exception('Échec création compte');

    await FirebaseFirestore.instance.collection('clients').doc(uid).set({
      'name':                  name,
      'phone':                 phone,
      'email':                 email,
      'wallet':                0,
      'cashOnDeliveryEnabled': true,
      'fakeOrderCount':        0,
      'createdAt':             FieldValue.serverTimestamp(),
    });

    if (!mounted) return;
    _snack('${context.tr('account_created')} $name !', Colors.green);
    _goToDashboard();
  }

  void _goToDashboard() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) NotificationService().saveToken(uid, 'clients');
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const MainDashboard()),
      (route) => false,
    );
  }

  String _authError(String code) {
    switch (code) {
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return context.tr('auth_invalid_cred');
      case 'email-already-in-use':
        return context.tr('auth_already_exists');
      case 'phone-already-in-use':
        return 'Ce numéro est déjà associé à un compte';
      case 'weak-password':
        return context.tr('password_min');
      case 'too-many-requests':
        return context.tr('auth_too_many');
      case 'network-request-failed':
        return context.tr('auth_no_network');
      default:
        return '${context.tr('error')} : $code';
    }
  }

  void _toggleMode() {
    setState(() => _isLogin = !_isLogin);
    _animCtrl.reset();
    _animCtrl.forward();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFFF6D00), Color(0xFFFF8F00), Color(0xFFFFB300)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.arrow_back,
                            color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Text('AZ EXPRESS',
                        style: TextStyle(color: Colors.white, fontSize: 20,
                            fontWeight: FontWeight.w900, letterSpacing: 2)),
                  ],
                ),
              ),

              // Illustration
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  children: [
                    const Icon(Icons.account_circle, size: 72, color: Colors.white),
                    const SizedBox(height: 8),
                    Text(context.tr('client_space'),
                        style: const TextStyle(color: Colors.white,
                            fontSize: 22, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(context.tr('client_tagline'),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                  ],
                ),
              ),

              // Card formulaire
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(32)),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                    child: FadeTransition(
                      opacity: _fadeAnim,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isLogin ? context.tr('login') : context.tr('create_account'),
                            style: const TextStyle(fontSize: 24,
                                fontWeight: FontWeight.bold, color: Colors.black87),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _isLogin ? context.tr('login_desc') : context.tr('register_desc'),
                            style: const TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                          const SizedBox(height: 28),

                          // ── INSCRIPTION ──────────────────────────────────
                          if (!_isLogin) ...[
                            _Field(controller: _nameCtrl,
                                label: context.tr('full_name'),
                                icon: Icons.person_outline,
                                type: TextInputType.name),
                            const SizedBox(height: 14),
                            _Field(controller: _phoneCtrl,
                                label: context.tr('phone_number'),
                                icon: Icons.phone_outlined,
                                type: TextInputType.phone,
                                hint: '07XXXXXXXX'),
                            const SizedBox(height: 14),
                            _Field(controller: _emailCtrl,
                                label: 'Adresse email',
                                icon: Icons.email_outlined,
                                type: TextInputType.emailAddress,
                                hint: 'exemple@email.com'),
                            const SizedBox(height: 14),
                            _PasswordField(
                                controller: _passCtrl,
                                label: context.tr('password'),
                                hint: '8 car. min, 1 maj, 1 chiffre',
                                show: !_obscurePass,
                                onToggle: () => setState(() => _obscurePass = !_obscurePass)),
                            const SizedBox(height: 14),
                            _PasswordField(
                                controller: _confirmCtrl,
                                label: 'Confirmer le mot de passe',
                                hint: 'Retapez le mot de passe',
                                show: !_obscureConfirm,
                                onToggle: () => setState(() => _obscureConfirm = !_obscureConfirm)),
                          ],

                          // ── CONNEXION ────────────────────────────────────
                          if (_isLogin) ...[
                            _Field(controller: _loginCtrl,
                                label: 'Téléphone ou email',
                                icon: Icons.account_circle_outlined,
                                type: TextInputType.emailAddress,
                                hint: '07XXXXXXXX ou email@exemple.com'),
                            const SizedBox(height: 14),
                            _PasswordField(
                                controller: _passCtrl,
                                label: context.tr('password'),
                                hint: context.tr('password_hint'),
                                show: !_obscurePass,
                                onToggle: () => setState(() => _obscurePass = !_obscurePass)),
                            const SizedBox(height: 4),
                            Align(
                              alignment: Alignment.centerRight,
                              child: GestureDetector(
                                onTap: () => Navigator.push(context,
                                    MaterialPageRoute(builder: (_) =>
                                        ForgotPasswordPage(
                                          prefillPhone: _loginCtrl.text.contains('@')
                                              ? null
                                              : _loginCtrl.text.trim(),
                                        ))),
                                child: const Text('Mot de passe oublié ?',
                                    style: TextStyle(color: Color(0xFFFF6D00),
                                        fontSize: 13, fontWeight: FontWeight.w600)),
                              ),
                            ),
                          ],

                          const SizedBox(height: 28),

                          // Bouton principal
                          SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: ScaleButton(
                              onPressed: _loading ? null : _submit,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFF6D00),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16)),
                                elevation: 4,
                              ),
                              child: _loading
                                  ? const SizedBox(width: 24, height: 24,
                                      child: CircularProgressIndicator(
                                          color: Colors.white, strokeWidth: 2.5))
                                  : Text(
                                      _isLogin ? context.tr('btn_login') : context.tr('btn_register'),
                                      style: const TextStyle(color: Colors.white,
                                          fontSize: 16, fontWeight: FontWeight.bold)),
                            ),
                          ),

                          const SizedBox(height: 20),

                          Center(
                            child: GestureDetector(
                              onTap: _toggleMode,
                              child: RichText(
                                text: TextSpan(
                                  style: const TextStyle(fontSize: 14, color: Colors.black87),
                                  children: [
                                    TextSpan(text: _isLogin
                                        ? context.tr('no_account')
                                        : context.tr('have_account')),
                                    TextSpan(
                                      text: _isLogin
                                          ? context.tr('sign_up')
                                          : context.tr('btn_login'),
                                      style: const TextStyle(
                                          color: Color(0xFFFF6D00),
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 16),

                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF3E0),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.orange.shade200),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.account_balance_wallet,
                                    color: Colors.orange.shade700, size: 20),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(context.tr('wallet_hint'),
                                      style: const TextStyle(
                                          fontSize: 12, color: Colors.black87)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Widgets réutilisables ────────────────────────────────────────────────────

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType type;
  final String? hint;
  const _Field({required this.controller, required this.label,
      required this.icon, required this.type, this.hint});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, color: const Color(0xFFFF6D00)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFFF6D00), width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }
}

class _PasswordField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool show;
  final VoidCallback onToggle;
  const _PasswordField({required this.controller, required this.label,
      this.hint, required this.show, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: !show,
      keyboardType: TextInputType.visiblePassword,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: const Icon(Icons.lock_outline, color: Color(0xFFFF6D00)),
        suffixIcon: IconButton(
          icon: Icon(show ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              color: Colors.grey),
          onPressed: onToggle,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFFF6D00), width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }
}
