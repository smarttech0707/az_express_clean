import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../web_theme.dart';
import '../../admin_auth_service.dart';
import '../../widgets/az_logo.dart';
import '../../../screens/admin/admin_mfa_security.dart'
    show AdminSecondFactor, AdminEnrolledFactor;
import '../../../widgets/admin_email_verification_prompt.dart';
import '../../../widgets/password_reset_email_guidance.dart';

class WebAdminLoginPage extends StatefulWidget {
  const WebAdminLoginPage({super.key});

  @override
  State<WebAdminLoginPage> createState() => _WebAdminLoginPageState();
}

class _WebAdminLoginPageState extends State<WebAdminLoginPage> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  bool _showPass = false;
  String? _error;
  bool _emailVerificationRequired = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
      _emailVerificationRequired = false;
    });
    final result = await AdminAuthService.instance.signIn(
      _emailCtrl.text.trim(),
      _passCtrl.text,
    );
    if (!mounted) return;
    if (result.error != null) {
      setState(() {
        _loading = false;
        _error = result.error;
        _emailVerificationRequired = result.emailVerificationRequired;
      });
    } else if (result.success) {
      context.go('/admin/dashboard');
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _resendVerificationEmail() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final error = await AdminAuthService.instance.resendVerificationEmail(
      _emailCtrl.text.trim(),
      _passCtrl.text,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error ?? 'Email de vérification envoyé.';
    });
  }

  Future<void> _verifyMfa() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final auth = AdminAuthService.instance;
    final result = auth.isTotpChallenge
        ? await auth.verifyTotpCode(_otpCtrl.text.trim())
        : await auth.verifySmsCode(_otpCtrl.text.trim());
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = result.error;
    });
    if (result.success) context.go('/admin/dashboard');
  }

  Future<void> _useSmsInstead() async {
    _otpCtrl.clear();
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await AdminAuthService.instance.useSmsInstead();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = result.error;
    });
  }

  Future<void> _selectFactor(AdminEnrolledFactor factor) async {
    _otpCtrl.clear();
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await AdminAuthService.instance.selectFactor(factor);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = result.error;
    });
  }

  Future<void> _cancelMfa() async {
    await AdminAuthService.instance.cancelMfa();
    if (!mounted) return;
    _otpCtrl.clear();
    setState(() => _error = null);
  }

  Future<void> _resetPassword() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Entrez votre email avant de réinitialiser.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await sendResetEmailAndShowGuidance(
        context: context,
        sendEmail: () =>
            FirebaseAuth.instance.sendPasswordResetEmail(email: email),
      );
      if (!mounted) return;
      setState(() => _loading = false);
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
    final auth = AdminAuthService.instance;
    final choosingFactor = auth.requiresFactorChoice;
    final challengeActive = !choosingFactor &&
        (auth.mfaState == WebAdminMfaState.totpAwaitingCode ||
            auth.mfaState == WebAdminMfaState.smsCodeSent ||
            auth.mfaState == WebAdminMfaState.verifying);
    final isTotp = auth.isTotpChallenge;
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
                    padding: const EdgeInsets.symmetric(
                        vertical: 36, horizontal: 32),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFFF6D00), Color(0xFFFF8F00)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: kOrange.withValues(alpha: 0.3),
                          blurRadius: 30,
                          offset: const Offset(0, 10),
                        )
                      ],
                    ),
                    child: Column(children: [
                      const AzLogo(size: 64),
                      const SizedBox(height: 16),
                      Text('Espace Admin',
                          style: GoogleFonts.inter(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: Colors.white)),
                      const SizedBox(height: 4),
                      Text('AZ Express — Accès réservé',
                          style: GoogleFonts.inter(
                              fontSize: 13,
                              color: Colors.white.withValues(alpha: 0.8))),
                    ]),
                  ),
                  const SizedBox(height: 36),

                  if (choosingFactor) ...[
                    Text(
                      'Choisissez votre second facteur',
                      style: GoogleFonts.inter(color: kText, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 18),
                    for (final factor in auth.availableFactors)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: OutlinedButton.icon(
                            onPressed:
                                _loading ? null : () => _selectFactor(factor),
                            icon: Icon(factor.kind == AdminSecondFactor.totp
                                ? Icons.phonelink_lock
                                : Icons.sms_outlined),
                            label: Text(factor.kind == AdminSecondFactor.totp
                                ? 'Application d’authentification'
                                : 'Code SMS${factor.label == null ? '' : ' · ${factor.label}'}'),
                          ),
                        ),
                      ),
                    TextButton(
                      onPressed: _loading ? null : _cancelMfa,
                      child: const Text('Annuler'),
                    ),
                    if (_error != null)
                      Text(
                        _error!,
                        style: GoogleFonts.inter(color: Colors.red),
                        textAlign: TextAlign.center,
                      ),
                  ] else if (challengeActive) ...[
                    if (isTotp) ...[
                      Text(
                        auth.totpSecret != null
                            ? 'Activation obligatoire de la 2FA'
                            : 'Double authentification',
                        style: GoogleFonts.inter(
                            color: kText,
                            fontSize: 16,
                            fontWeight: FontWeight.w700),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        auth.totpSecret != null
                            ? 'Scannez le QR code ou saisissez la clé ci-dessous '
                                'dans votre application d’authentification, puis '
                                'entrez le code à 6 chiffres affiché.'
                            : 'Entrez le code affiché par votre application '
                                'd’authentification.',
                        style: GoogleFonts.inter(color: kTextMuted, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                      if (auth.totpSecret != null) ...[
                        const SizedBox(height: 18),
                        if (auth.totpQrCodeUrl != null)
                          QrImageView(
                            data: auth.totpQrCodeUrl!,
                            size: 180,
                            backgroundColor: Colors.white,
                          ),
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: kOrange.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: kOrange.withValues(alpha: 0.3)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Clé de configuration',
                                  style: GoogleFonts.inter(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13)),
                              const SizedBox(height: 4),
                              SelectableText(
                                auth.totpSecret!.secretKey,
                                style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 15,
                                    letterSpacing: 1.2),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Cette clé ne sera plus affichée après l’enrôlement.',
                                style: GoogleFonts.inter(
                                    fontSize: 11, color: kTextMuted),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                    ] else ...[
                      Text(
                        'Code SMS envoyé au ${auth.maskedPhone}',
                        style: GoogleFonts.inter(color: kText, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 18),
                    ],
                    TextField(
                      controller: _otpCtrl,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      autofocus: true,
                      cursorColor: kOrange,
                      // Couleur du texte saisi explicite : le thème Web
                      // global (`web_app.dart`) est un `ColorScheme.dark`
                      // dont le texte par défaut est clair, invisible sur le
                      // fond blanc de ce champ. Même cause que le contraste
                      // corrigé dans Événementiel, ici sur le code TOTP.
                      style: GoogleFonts.inter(
                        color: kText,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 6,
                      ),
                      onSubmitted: (_) => _verifyMfa(),
                      decoration: InputDecoration(
                        labelText: 'Code de vérification',
                        labelStyle:
                            GoogleFonts.inter(color: kTextMuted, fontSize: 14),
                        hintText: '000000',
                        hintStyle: GoogleFonts.inter(
                            color: kTextMuted.withValues(alpha: 0.7),
                            fontWeight: FontWeight.w600,
                            letterSpacing: 6),
                        counterText: '',
                        filled: true,
                        fillColor: kCard,
                        prefixIcon:
                            const Icon(Icons.security_rounded, color: kTextMuted),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: kDivider),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: kDivider),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: kOrange, width: 2),
                        ),
                        errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: Colors.red),
                        ),
                        focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide:
                              const BorderSide(color: Colors.red, width: 2),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 18),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton(
                        onPressed: _loading ? null : _verifyMfa,
                        child: _loading
                            ? const CircularProgressIndicator()
                            : const Text('Valider la double authentification'),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (!isTotp)
                          TextButton(
                            onPressed: _loading
                                ? null
                                : () async {
                                    final result =
                                        await auth.resendSmsChallenge();
                                    if (mounted) {
                                      setState(() => _error = result.error);
                                    }
                                  },
                            child: const Text('Renvoyer le code'),
                          ),
                        if (isTotp && auth.smsFallbackAvailable)
                          TextButton(
                            onPressed: _loading ? null : _useSmsInstead,
                            child: const Text('Utiliser un code SMS à la place'),
                          ),
                        TextButton(
                          onPressed: _loading ? null : _cancelMfa,
                          child: const Text('Annuler'),
                        ),
                      ],
                    ),
                    if (_error != null)
                      Text(
                        _error!,
                        style: GoogleFonts.inter(color: Colors.red),
                        textAlign: TextAlign.center,
                      ),
                  ] else ...[
                    // Email
                    TextFormField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      style: GoogleFonts.inter(color: kText, fontSize: 15),
                      validator: (v) =>
                          (v?.isEmpty ?? true) ? 'Obligatoire' : null,
                      decoration: InputDecoration(
                        labelText: 'Email administrateur',
                        prefixIcon: const Icon(Icons.email_rounded,
                            color: kTextMuted, size: 20),
                        filled: true,
                        fillColor: kCard,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide:
                              const BorderSide(color: kOrange, width: 2),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 18),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Mot de passe
                    TextFormField(
                      controller: _passCtrl,
                      obscureText: !_showPass,
                      onFieldSubmitted: (_) => _login(),
                      style: GoogleFonts.inter(color: kText, fontSize: 15),
                      validator: (v) =>
                          (v?.isEmpty ?? true) ? 'Obligatoire' : null,
                      decoration: InputDecoration(
                        labelText: 'Mot de passe',
                        prefixIcon: const Icon(Icons.lock_rounded,
                            color: kTextMuted, size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(
                              _showPass
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                              color: kTextMuted,
                              size: 20),
                          onPressed: () =>
                              setState(() => _showPass = !_showPass),
                        ),
                        filled: true,
                        fillColor: kCard,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide:
                              const BorderSide(color: kOrange, width: 2),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 18),
                      ),
                    ),

                    // Mot de passe oublié
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _loading ? null : _resetPassword,
                        child: Text('Mot de passe oublié ?',
                            style: GoogleFonts.inter(
                                fontSize: 13,
                                color: kOrange,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),

                    // Message d'erreur
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: Colors.red.withValues(alpha: 0.3)),
                        ),
                        child: Row(children: [
                          const Icon(Icons.error_outline_rounded,
                              color: Colors.red, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(_error!,
                                  style: GoogleFonts.inter(
                                      fontSize: 13, color: Colors.red))),
                        ]),
                      ),
                    ],
                    AdminEmailVerificationPrompt(
                      visible: _emailVerificationRequired,
                      sending: _loading,
                      remaining: auth.verificationEmailResendRemaining,
                      onResend: _resendVerificationEmail,
                    ),

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
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : Text('Se connecter',
                                style: GoogleFonts.inter(
                                    fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text('Accès réservé aux administrateurs AZ Express.',
                        style:
                            GoogleFonts.inter(fontSize: 12, color: kTextMuted),
                        textAlign: TextAlign.center),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
