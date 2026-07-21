import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/auth_service.dart';
import 'reset_password_page.dart';
import '../../theme/app_theme.dart';

enum OtpMode { resetPassword, adminTwoFa }

class OtpVerifyPage extends StatefulWidget {
  final String phone;
  final String? verificationId;   // SMS OTP
  final int?    resendToken;
  final OtpMode mode;
  final String? adminUid;         // pour adminTwoFa

  const OtpVerifyPage({
    super.key,
    required this.phone,
    required this.mode,
    this.verificationId,
    this.resendToken,
    this.adminUid,
  });

  @override
  State<OtpVerifyPage> createState() => _OtpVerifyPageState();
}

class _OtpVerifyPageState extends State<OtpVerifyPage> {
  final List<TextEditingController> _ctrl =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _focus = List.generate(6, (_) => FocusNode());

  bool _loading     = false;
  bool _canResend   = false;
  int  _countdown   = 60;
  Timer? _timer;
  String? _verificationId;
  int?    _resendToken;

  @override
  void initState() {
    super.initState();
    _verificationId = widget.verificationId;
    _resendToken    = widget.resendToken;
    _startCountdown();
  }

  void _startCountdown() {
    setState(() { _canResend = false; _countdown = 60; });
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        _countdown--;
        if (_countdown <= 0) { t.cancel(); _canResend = true; }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in _ctrl) { c.dispose(); }
    for (final f in _focus) { f.dispose(); }
    super.dispose();
  }

  String get _otpCode => _ctrl.map((c) => c.text).join();

  void _onDigit(int index, String value) {
    if (value.length == 6) {
      // Coller un code complet
      for (int i = 0; i < 6 && i < value.length; i++) {
        _ctrl[i].text = value[i];
      }
      _focus[5].requestFocus();
      _verify();
      return;
    }
    if (value.isNotEmpty && index < 5) {
      _focus[index + 1].requestFocus();
    }
    if (value.isNotEmpty && index == 5) {
      _focus[5].unfocus();
      _verify();
    }
  }

  void _onBackspace(int index) {
    if (_ctrl[index].text.isEmpty && index > 0) {
      _focus[index - 1].requestFocus();
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _verify() async {
    final code = _otpCode;
    if (code.length < 6) {
      _snack('Entrez les 6 chiffres du code', Colors.orange);
      return;
    }

    setState(() => _loading = true);

    try {
      if (widget.mode == OtpMode.adminTwoFa) {
        await _verifyAdminOtp(code);
      } else {
        await _verifySmsOtp(code);
      }
    } catch (e) {
      _snack('Code incorrect ou expiré', Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifySmsOtp(String code) async {
    if (_verificationId == null) throw Exception('verificationId manquant');
    final cred = AuthService().buildPhoneCredential(_verificationId!, code);
    // Signe temporairement avec la credential pour valider le code
    await FirebaseAuth.instance.signInWithCredential(cred);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ResetPasswordPage(phoneCredential: cred),
      ),
    );
  }

  Future<void> _verifyAdminOtp(String code) async {
    if (widget.adminUid == null) throw Exception('adminUid manquant');
    final valid = await AuthService().verifyAdminOtp(widget.adminUid!, code);
    if (!valid) throw Exception('OTP invalide');
    // Retourne true au parent (admin_login)
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _resend() async {
    if (!_canResend) return;
    setState(() => _loading = true);
    try {
      await AuthService().sendPhoneOtp(
        phone: widget.phone,
        resendToken: _resendToken,
        onCodeSent: (verificationId, resendToken) {
          _verificationId = verificationId;
          _resendToken    = resendToken;
          _startCountdown();
          _snack('Nouveau code envoyé', Colors.green);
        },
        onFailed: (e) => _snack('Erreur : ${e.message}', Colors.red),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = widget.mode == OtpMode.adminTwoFa;
    final color   = isAdmin ? AppColors.primary : const Color(0xFF167DB7);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(isAdmin ? 'Vérification administrateur' : 'Vérification OTP'),
        backgroundColor: color,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [color, color.withValues(alpha: 0.7)]),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Icon(isAdmin ? Icons.admin_panel_settings : Icons.smartphone,
                      size: 60, color: Colors.white),
                  const SizedBox(height: 12),
                  Text(isAdmin
                      ? 'Double authentification'
                      : 'Code de vérification',
                      style: const TextStyle(color: Colors.white,
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(
                    isAdmin
                        ? 'Un code a été envoyé sur\n${widget.phone}'
                        : 'Code envoyé par SMS au\n${widget.phone}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 36),
            const Text('Entrez le code à 6 chiffres',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),

            // Champs OTP
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(6, (i) => _OtpBox(
                controller: _ctrl[i],
                focusNode: _focus[i],
                color: color,
                onChanged: (val) => _onDigit(i, val),
                onBackspace: () => _onBackspace(i),
                index: i,
                total: 6,
              )),
            ),

            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: _loading ? null : _verify,
                style: ElevatedButton.styleFrom(
                  backgroundColor: color,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                child: _loading
                    ? const SizedBox(width: 24, height: 24,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5))
                    : const Text('Vérifier le code',
                        style: TextStyle(color: Colors.white, fontSize: 16,
                            fontWeight: FontWeight.bold)),
              ),
            ),

            const SizedBox(height: 20),

            // Renvoyer le code (uniquement pour SMS OTP)
            if (widget.mode == OtpMode.resetPassword) ...[
              if (_canResend)
                TextButton.icon(
                  onPressed: _resend,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Renvoyer le code'),
                  style: TextButton.styleFrom(foregroundColor: color),
                )
              else
                Text(
                  'Renvoyer dans $_countdown secondes',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OtpBox extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final Color color;
  final void Function(String) onChanged;
  final VoidCallback onBackspace;
  // Master Prompt 125 (Partie 6) — sans ceci, un lecteur d'écran annonçait
  // seulement "champ de texte" pour chacune des 6 cases OTP, sans jamais dire
  // laquelle ; purement additif (défauts sûrs), aucun changement de logique.
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
