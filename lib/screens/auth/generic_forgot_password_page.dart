import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../services/auth_service.dart';

/// Réinitialisation mot de passe / PIN pour tous les types d'utilisateurs
/// professionnels (non-client).
///
/// userType : 'fleet' | 'admin' | 'seller' | 'restaurant' |
///            'pharmacie' | 'boulangerie' | 'artisan'
class GenericForgotPasswordPage extends StatefulWidget {
  final String userType;
  final Color accentColor;
  final String title;

  const GenericForgotPasswordPage({
    super.key,
    required this.userType,
    required this.accentColor,
    required this.title,
  });

  @override
  State<GenericForgotPasswordPage> createState() =>
      _GenericForgotPasswordPageState();
}

enum _Step { identifier, otp, newSecret }

class _GenericForgotPasswordPageState extends State<GenericForgotPasswordPage> {
  _Step _step = _Step.identifier;
  bool _loading = false;

  // Étape 1
  final _identCtrl = TextEditingController();

  // Étape 2 – OTP
  final List<TextEditingController> _otpCtrl =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _otpFocus = List.generate(6, (_) => FocusNode());
  String? _verificationId;
  int? _resendToken;
  bool _canResend = false;
  int _countdown = 60;
  Timer? _timer;

  // Étape 3 – Nouveau secret
  final _secretCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _showSecret = false;

  // ── Accesseurs ───────────────────────────────────────────────────────────

  bool get _isArtisan => widget.userType == 'artisan';
  bool get _isAdmin => widget.userType == 'admin';

  String get _secretLabel =>
      _isArtisan ? 'Nouveau code PIN (4-6 chiffres)' : 'Nouveau mot de passe';

  // ── Dispose ──────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _identCtrl.dispose();
    _secretCtrl.dispose();
    _confirmCtrl.dispose();
    for (final c in _otpCtrl) {
      c.dispose();
    }
    for (final f in _otpFocus) {
      f.dispose();
    }
    _timer?.cancel();
    super.dispose();
  }

  // ── Utilitaires ──────────────────────────────────────────────────────────

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── Étape 1 : envoi OTP (ou lien email pour admin) ───────────────────────

  Future<void> _sendOtp() async {
    final ident = _identCtrl.text.trim().replaceAll(' ', '');
    if (ident.isEmpty) {
      _snack('Veuillez remplir le champ', Colors.orange);
      return;
    }

    // Admin → lien de réinitialisation par email
    if (_isAdmin) {
      setState(() => _loading = true);
      try {
        await FirebaseAuth.instance.sendPasswordResetEmail(email: ident);
        if (!mounted) return;
        _snack(
            'Lien envoyé à $ident. Vérifiez votre boîte mail.', Colors.green);
        Navigator.pop(context);
      } on FirebaseAuthException catch (e) {
        _snack(
          e.code == 'user-not-found'
              ? 'Aucun compte trouvé pour cette adresse'
              : 'Erreur : ${e.message}',
          Colors.red,
        );
      } finally {
        if (mounted) setState(() => _loading = false);
      }
      return;
    }

    // Tous les autres → OTP SMS
    setState(() => _loading = true);
    try {
      await AuthService().sendPhoneOtp(
        phone: ident,
        onCodeSent: (verificationId, resendToken) {
          _verificationId = verificationId;
          _resendToken = resendToken;
          if (!mounted) return;
          setState(() {
            _step = _Step.otp;
            _loading = false;
          });
          _startCountdown();
        },
        onFailed: (e) {
          if (mounted) setState(() => _loading = false);
          _snack('Erreur SMS : ${e.message}', Colors.red);
        },
      );
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _snack('Erreur : $e', Colors.red);
    }
  }

  void _startCountdown() {
    setState(() {
      _canResend = false;
      _countdown = 60;
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _countdown--;
        if (_countdown <= 0) {
          t.cancel();
          _canResend = true;
        }
      });
    });
  }

  // ── Étape 2 : vérification OTP ───────────────────────────────────────────

  String get _otpCode => _otpCtrl.map((c) => c.text).join();

  void _onOtpDigit(int index, String value) {
    if (value.length == 6) {
      for (int i = 0; i < 6; i++) {
        _otpCtrl[i].text = value[i];
      }
      _otpFocus[5].requestFocus();
      _verifyOtp();
      return;
    }
    if (value.isNotEmpty && index < 5) _otpFocus[index + 1].requestFocus();
    if (value.isNotEmpty && index == 5) {
      _otpFocus[5].unfocus();
      _verifyOtp();
    }
  }

  void _onOtpBackspace(int index) {
    if (_otpCtrl[index].text.isEmpty && index > 0) {
      _otpFocus[index - 1].requestFocus();
    }
  }

  Future<void> _verifyOtp() async {
    if (_otpCode.length < 6) return;
    if (_verificationId == null) {
      _snack('Erreur de vérification. Recommencez.', Colors.red);
      return;
    }
    setState(() => _loading = true);
    try {
      final cred =
          AuthService().buildPhoneCredential(_verificationId!, _otpCode);
      await FirebaseAuth.instance.signInWithCredential(cred);
      if (!mounted) return;
      setState(() {
        _step = _Step.newSecret;
        _loading = false;
      });
    } on FirebaseAuthException {
      if (mounted) setState(() => _loading = false);
      _snack('Code incorrect ou expiré', Colors.red);
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _snack('Erreur : $e', Colors.red);
    }
  }

  Future<void> _resendOtp() async {
    if (!_canResend) return;
    final phone = _identCtrl.text.trim().replaceAll(' ', '');
    setState(() => _loading = true);
    try {
      await AuthService().sendPhoneOtp(
        phone: phone,
        resendToken: _resendToken,
        onCodeSent: (vid, rt) {
          _verificationId = vid;
          _resendToken = rt;
          _startCountdown();
          _snack('Nouveau code envoyé', Colors.green);
        },
        onFailed: (e) => _snack('Erreur : ${e.message}', Colors.red),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Étape 3 : enregistrer le nouveau secret ──────────────────────────────

  String? _validateSecret(String val) {
    if (_isArtisan) {
      if (val.length < 4 || val.length > 6) {
        return 'Le PIN doit contenir 4 à 6 chiffres';
      }
      if (!RegExp(r'^\d+$').hasMatch(val)) {
        return 'Le PIN doit contenir uniquement des chiffres';
      }
      return null;
    }
    return AuthService.validatePassword(val);
  }

  Future<void> _saveSecret() async {
    final val = _secretCtrl.text;
    final confirm = _confirmCtrl.text;

    final err = _validateSecret(val);
    if (err != null) {
      _snack(err, Colors.orange);
      return;
    }
    if (val != confirm) {
      _snack('Les valeurs ne correspondent pas', Colors.red);
      return;
    }

    setState(() => _loading = true);
    try {
      final fn = FirebaseFunctions.instanceFor(region: 'europe-west1');
      await fn.httpsCallable('resetAccountPassword').call({
        'userType': widget.userType,
        'phone': _identCtrl.text.trim().replaceAll(' ', ''),
        'newValue': val,
      });

      if (!mounted) return;
      _snack(
        _isArtisan
            ? 'Code PIN mis à jour avec succès !'
            : 'Mot de passe mis à jour avec succès !',
        Colors.green,
      );

      // Déconnecter la session téléphonique temporaire
      await FirebaseAuth.instance.signOut();
      try {
        await FirebaseAuth.instance.signInAnonymously();
      } catch (_) {}

      if (!mounted) return;
      Navigator.pop(context);
    } on FirebaseFunctionsException catch (e) {
      _snack(e.message ?? 'Erreur lors de la réinitialisation', Colors.red);
    } catch (e) {
      _snack('Erreur : $e', Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final color = widget.accentColor;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: color,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 16),
            _buildHero(color),
            const SizedBox(height: 32),
            if (_step == _Step.identifier) _buildIdentifierStep(color),
            if (_step == _Step.otp) _buildOtpStep(color),
            if (_step == _Step.newSecret) _buildSecretStep(color),
          ],
        ),
      ),
    );
  }

  // ── Hero ─────────────────────────────────────────────────────────────────

  Widget _buildHero(Color color) {
    final IconData icon;
    final String subtitle;
    switch (_step) {
      case _Step.identifier:
        icon = _isAdmin ? Icons.email_outlined : Icons.phone_outlined;
        subtitle = _isAdmin
            ? 'Entrez votre adresse email pour recevoir\nun lien de réinitialisation'
            : 'Entrez votre numéro de téléphone\npour recevoir un code SMS';
      case _Step.otp:
        icon = Icons.smartphone;
        subtitle = 'Code envoyé par SMS au\n${_identCtrl.text.trim()}';
      case _Step.newSecret:
        icon = Icons.lock_open_outlined;
        subtitle = _isArtisan
            ? 'Créez un nouveau code PIN'
            : 'Créez un nouveau mot de passe sécurisé';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      decoration: BoxDecoration(
        gradient:
            LinearGradient(colors: [color, color.withValues(alpha: 0.72)]),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(icon, size: 56, color: Colors.white),
          const SizedBox(height: 12),
          Text(
            _isArtisan ? 'PIN oublié' : 'Mot de passe oublié',
            style: const TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ── Étape 1 widget ───────────────────────────────────────────────────────

  Widget _buildIdentifierStep(Color color) {
    return Column(
      children: [
        TextField(
          controller: _identCtrl,
          keyboardType:
              _isAdmin ? TextInputType.emailAddress : TextInputType.phone,
          autofillHints: _isAdmin
              ? const [AutofillHints.email]
              : const [AutofillHints.telephoneNumber],
          decoration: InputDecoration(
            labelText: _isAdmin ? 'Adresse email' : 'Numéro de téléphone',
            hintText: _isAdmin ? 'admin@example.com' : '07 00 00 00 00',
            prefixIcon: Icon(
              _isAdmin ? Icons.email_outlined : Icons.phone_outlined,
              color: color,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: color, width: 2),
            ),
            filled: true,
            fillColor: Colors.white,
          ),
          onSubmitted: (_) => _sendOtp(),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: _loading ? null : _sendOtp,
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
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
                : Text(
                    _isAdmin
                        ? 'Envoyer le lien de réinitialisation'
                        : 'Envoyer le code SMS',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold),
                  ),
          ),
        ),
      ],
    );
  }

  // ── Étape 2 widget (OTP) ─────────────────────────────────────────────────

  Widget _buildOtpStep(Color color) {
    return Column(
      children: [
        const Text(
          'Entrez le code à 6 chiffres',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(
            6,
            (i) => _OtpBox(
              controller: _otpCtrl[i],
              focusNode: _otpFocus[i],
              color: color,
              onChanged: (val) => _onOtpDigit(i, val),
              onBackspace: () => _onOtpBackspace(i),
              index: i,
              total: 6,
            ),
          ),
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: _loading ? null : _verifyOtp,
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
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
                : const Text(
                    'Vérifier le code',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold),
                  ),
          ),
        ),
        const SizedBox(height: 20),
        _canResend
            ? TextButton.icon(
                onPressed: _resendOtp,
                icon: const Icon(Icons.refresh),
                label: const Text('Renvoyer le code'),
                style: TextButton.styleFrom(foregroundColor: color),
              )
            : Text(
                'Renvoyer dans $_countdown secondes',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
              ),
      ],
    );
  }

  // ── Étape 3 widget (nouveau secret) ─────────────────────────────────────

  Widget _buildSecretStep(Color color) {
    return Column(
      children: [
        if (!_isArtisan) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.2)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Le mot de passe doit contenir :',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                SizedBox(height: 6),
                _Rule(text: 'Au moins 8 caractères'),
                _Rule(text: 'Au moins 1 majuscule (A-Z)'),
                _Rule(text: 'Au moins 1 chiffre (0-9)'),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        _SecretField(
          controller: _secretCtrl,
          label: _secretLabel,
          isNumeric: _isArtisan,
          maxLen: _isArtisan ? 6 : null,
          showSecret: _showSecret,
          color: color,
          onToggle: () => setState(() => _showSecret = !_showSecret),
        ),
        const SizedBox(height: 14),
        _SecretField(
          controller: _confirmCtrl,
          label: _isArtisan ? 'Confirmer le PIN' : 'Confirmer le mot de passe',
          isNumeric: _isArtisan,
          maxLen: _isArtisan ? 6 : null,
          showSecret: _showSecret,
          color: color,
          onToggle: () => setState(() => _showSecret = !_showSecret),
          onSubmit: _saveSecret,
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: _loading ? null : _saveSecret,
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
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
                : Text(
                    _isArtisan
                        ? 'Enregistrer le PIN'
                        : 'Enregistrer le mot de passe',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold),
                  ),
          ),
        ),
      ],
    );
  }
}

// ── Widgets privés ───────────────────────────────────────────────────────────

class _OtpBox extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final Color color;
  final void Function(String) onChanged;
  final VoidCallback onBackspace;
  // Master Prompt 125 (Partie 6) — purement additif, défauts sûrs.
  final int index;
  final int total;

  const _OtpBox({
    required this.controller,
    required this.focusNode,
    required this.color,
    required this.onChanged,
    required this.onBackspace,
    this.index = 0,
    this.total = 6,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Chiffre ${index + 1} sur $total du code de vérification',
      textField: true,
      child: SizedBox(
        width: 46,
        height: 56,
        child: KeyboardListener(
          focusNode: FocusNode(),
          onKeyEvent: (event) {
            if (event.logicalKey.keyLabel == 'Backspace') onBackspace();
          },
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            maxLength: 1,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              counterText: '',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: color, width: 2),
              ),
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

class _SecretField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool isNumeric;
  final int? maxLen;
  final bool showSecret;
  final Color color;
  final VoidCallback onToggle;
  final VoidCallback? onSubmit;

  const _SecretField({
    required this.controller,
    required this.label,
    required this.isNumeric,
    required this.showSecret,
    required this.color,
    required this.onToggle,
    this.maxLen,
    this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: !showSecret,
      keyboardType: isNumeric ? TextInputType.number : TextInputType.text,
      maxLength: maxLen,
      decoration: InputDecoration(
        labelText: label,
        counterText: '',
        prefixIcon: Icon(Icons.lock_outline, color: color),
        suffixIcon: IconButton(
          icon: Icon(
            showSecret ? Icons.visibility_off : Icons.visibility,
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
      onSubmitted: onSubmit != null ? (_) => onSubmit!() : null,
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
          const Icon(Icons.check_circle_outline, size: 14, color: Colors.grey),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
