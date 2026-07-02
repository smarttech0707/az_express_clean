import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/auth_service.dart';
import '../../services/notification_service.dart';
import 'admin_dashboard.dart';

/// Écran 2FA admin : envoie un OTP par Firebase Phone Auth
/// sur le téléphone enregistré de l'admin, puis vérifie.
class AdminOtpPage extends StatefulWidget {
  final String adminUid;
  final String adminPhone;
  final Map<String, dynamic> adminData;
  const AdminOtpPage({
    super.key,
    required this.adminUid,
    required this.adminPhone,
    required this.adminData,
  });

  @override
  State<AdminOtpPage> createState() => _AdminOtpPageState();
}

class _AdminOtpPageState extends State<AdminOtpPage> {
  final List<TextEditingController> _ctrl =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _focus = List.generate(6, (_) => FocusNode());

  bool    _loading         = false;
  bool    _codeSent        = false;
  bool    _canResend       = false;
  int     _countdown       = 60;
  String? _verificationId;
  int?    _resendToken;

  @override
  void initState() {
    super.initState();
    _sendOtp();
  }

  @override
  void dispose() {
    for (final c in _ctrl) { c.dispose(); }
    for (final f in _focus) { f.dispose(); }
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

  Future<void> _sendOtp({int? resendToken}) async {
    setState(() { _loading = true; _codeSent = false; });
    try {
      await AuthService().sendPhoneOtp(
        phone: widget.adminPhone,
        resendToken: resendToken,
        onCodeSent: (vid, rt) {
          _verificationId = vid;
          _resendToken    = rt;
          if (!mounted) return;
          setState(() { _loading = false; _codeSent = true; });
          _startCountdown();
        },
        onFailed: (e) {
          if (!mounted) return;
          setState(() => _loading = false);
          _snack('Échec envoi SMS : ${e.message}', Colors.red);
        },
      );
    } catch (_) {
      if (mounted) setState(() => _loading = false);
      _snack('Impossible d\'envoyer le code SMS', Colors.red);
    }
  }

  void _startCountdown() {
    setState(() { _canResend = false; _countdown = 60; });
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      setState(() { _countdown--; });
      if (_countdown <= 0) {
        if (mounted) setState(() => _canResend = true);
        return false;
      }
      return true;
    });
  }

  String get _otpCode => _ctrl.map((c) => c.text).join();

  void _onDigit(int index, String value) {
    if (value.length == 6) {
      for (int i = 0; i < 6; i++) { _ctrl[i].text = value[i]; }
      _focus[5].requestFocus();
      _verify();
      return;
    }
    if (value.isNotEmpty && index < 5) _focus[index + 1].requestFocus();
    if (value.isNotEmpty && index == 5) { _focus[5].unfocus(); _verify(); }
  }

  void _onBackspace(int index) {
    if (_ctrl[index].text.isEmpty && index > 0) _focus[index - 1].requestFocus();
  }

  Future<void> _verify() async {
    final code = _otpCode;
    if (code.length < 6) { _snack('Entrez les 6 chiffres du code', Colors.orange); return; }
    if (_verificationId == null) { _snack('Aucun code envoyé', Colors.red); return; }

    setState(() => _loading = true);
    try {
      final cred = AuthService().buildPhoneCredential(_verificationId!, code);
      // Ré-authentification 2FA via la credential phone
      await FirebaseAuth.instance.currentUser
          ?.reauthenticateWithCredential(cred);
      NotificationService().saveToken(widget.adminUid, 'admins');
      AuthService().logAuthEvent('login', 'admin');
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
            builder: (_) => AdminDashboard(adminData: widget.adminData)),
      );
    } on FirebaseAuthException catch (e) {
      _snack(e.code == 'invalid-verification-code'
          ? 'Code incorrect. Vérifiez et réessayez.'
          : 'Erreur : ${e.message}', Colors.red);
      for (final c in _ctrl) { c.clear(); }
      _focus[0].requestFocus();
    } catch (_) {
      _snack('Code incorrect ou expiré', Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Vérification administrateur'),
        backgroundColor: const Color(0xFFFF6D00),
        foregroundColor: Colors.white,
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFFFF6D00), Color(0xFFFFB300)]),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  const Icon(Icons.admin_panel_settings,
                      size: 60, color: Colors.white),
                  const SizedBox(height: 12),
                  const Text('Double authentification',
                      style: TextStyle(color: Colors.white, fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    _codeSent
                        ? 'Code envoyé par SMS au\n${widget.adminPhone}'
                        : 'Envoi du code en cours...',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            if (_loading && !_codeSent) ...[
              const CircularProgressIndicator(color: Color(0xFFFF6D00)),
              const SizedBox(height: 16),
              const Text('Envoi du code SMS...', style: TextStyle(color: Colors.grey)),
            ] else ...[
              const Text('Entrez le code à 6 chiffres',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(6, (i) => _OtpBox(
                  controller: _ctrl[i],
                  focusNode: _focus[i],
                  onChanged: (v) => _onDigit(i, v),
                  onBackspace: () => _onBackspace(i),
                )),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _loading ? null : _verify,
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
                      : const Text('Valider l\'accès',
                          style: TextStyle(color: Colors.white, fontSize: 16,
                              fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 16),
              if (_canResend)
                TextButton.icon(
                  onPressed: () => _sendOtp(resendToken: _resendToken),
                  icon: const Icon(Icons.refresh, color: Color(0xFFFF6D00)),
                  label: const Text('Renvoyer le code',
                      style: TextStyle(color: Color(0xFFFF6D00))),
                )
              else
                Text('Renvoyer dans $_countdown secondes',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
            ],

            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.orange, size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Ce code expire dans 5 minutes. '
                      'Si vous ne le recevez pas, vérifiez votre numéro dans votre profil admin.',
                      style: TextStyle(fontSize: 12, color: Colors.black87),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OtpBox extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final void Function(String) onChanged;
  final VoidCallback onBackspace;
  const _OtpBox({required this.controller, required this.focusNode,
      required this.onChanged, required this.onBackspace});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: 56,
      child: KeyboardListener(
        focusNode: FocusNode(),
        onKeyEvent: (e) {
          if (e.logicalKey.keyLabel == 'Backspace') onBackspace();
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
              borderSide: const BorderSide(color: Color(0xFFFF6D00), width: 2),
            ),
            contentPadding: EdgeInsets.zero,
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
