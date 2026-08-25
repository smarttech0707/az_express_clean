import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../widgets/scale_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../auth/generic_forgot_password_page.dart';
import 'admin_otp_page.dart';
import 'admin_dashboard.dart';
import 'admin_mfa_security.dart';
import '../../theme/app_theme.dart';
import '../../services/email_verification_resend_guard.dart';
import '../../widgets/admin_email_verification_prompt.dart';

const bool _adminSkipTwoFactorBuildFlag =
    bool.fromEnvironment('ADMIN_SKIP_2FA', defaultValue: false);

@visibleForTesting
bool adminDevelopmentBypassAllowed({
  required bool isDebug,
  required bool buildFlagEnabled,
  required bool credentialsAccepted,
  required bool adminDocumentExists,
  required bool roleActive,
  required bool emailVerified,
  required bool phoneConfigured,
}) =>
    isDebug &&
    buildFlagEnabled &&
    credentialsAccepted &&
    adminDocumentExists &&
    roleActive &&
    emailVerified &&
    phoneConfigured;

@visibleForTesting
bool adminDevelopmentRoleAllowed(Map<String, dynamic> adminData) {
  final role = adminData['role'] as String?;
  return adminData['isActive'] == true &&
      (role == 'super' || (role == 'sub' && adminData['permissions'] is List));
}

class AdminLogin extends StatefulWidget {
  const AdminLogin({super.key});

  @override
  State<AdminLogin> createState() => _AdminLoginState();
}

class _AdminLoginState extends State<AdminLogin> {
  final _idCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _showPass = false;
  bool _loading = false;
  bool _emailVerificationRequired = false;
  bool _resendingVerificationEmail = false;
  String? _verificationEmail;
  final _verificationGuard = EmailVerificationResendGuard();

  // Master Prompt 128 — voir driver_login.dart pour le contexte complet.
  // Choix de sécurité délibéré, différent des 8 autres rôles corrigés
  // dans cette même passe : l'auto-reprise ici ne saute JAMAIS la 2FA par
  // SMS si un téléphone est enregistré — seul le mot de passe (déjà
  // prouvé par la session Firebase persistée) est court-circuité. La 2FA
  // reste un second facteur réel à chaque lancement pour ce rôle à hauts
  // privilèges, pas une case cochée une seule fois pour toujours.
  bool _autoResuming = false;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && !user.isAnonymous) {
      _autoResuming = true;
      _tryAutoResume(user);
    }
  }

  Future<void> _tryAutoResume(User user) async {
    // Une ouverture de l'écran Admin représente une nouvelle session sensible :
    // ne jamais réutiliser silencieusement une session persistée pour éviter le
    // second facteur.
    await FirebaseAuth.instance.signOut();
    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (_) {}
    if (mounted) setState(() => _autoResuming = false);
  }

  Future<void> _login() async {
    FocusScope.of(context).unfocus();

    final id = _idCtrl.text.trim();
    final pass = _passCtrl.text;

    if (id.isEmpty || pass.isEmpty) {
      _error("Remplissez tous les champs");
      return;
    }

    setState(() => _loading = true);
    setState(() => _emailVerificationRequired = false);

    try {
      final cred = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: id, password: pass);

      // ── Vérification que l'uid est dans la collection /admins ──────────
      final adminDoc = await FirebaseFirestore.instance
          .collection('admins')
          .doc(cred.user!.uid)
          .get();

      if (!adminDoc.exists) {
        await FirebaseAuth.instance.signOut();
        try {
          await FirebaseAuth.instance.signInAnonymously();
        } catch (_) {}
        if (!mounted) return;
        setState(() => _loading = false);
        _error("Accès refusé. Vous n'êtes pas administrateur.");
        return;
      }

      if (!mounted) return;
      setState(() => _loading = false);

      // Build adminData — all Firestore fields + uid. Backward compat: missing role = 'super'
      final adminData = <String, dynamic>{
        'uid': cred.user!.uid,
        ...adminDoc.data()!,
      };
      final access = validateAdminRecord(adminData);
      if (!access.allowed) {
        await FirebaseAuth.instance.signOut();
        try {
          await FirebaseAuth.instance.signInAnonymously();
        } catch (_) {}
        if (!mounted) return;
        setState(() => _loading = false);
        _error(
            "Votre compte a été désactivé. Contactez l'administrateur principal.");
        return;
      }

      if (!cred.user!.emailVerified) {
        await FirebaseAuth.instance.signOut();
        try {
          await FirebaseAuth.instance.signInAnonymously();
        } catch (_) {}
        if (!mounted) return;
        setState(() {
          _emailVerificationRequired = true;
          _verificationEmail = id;
        });
        _error('Vérifiez votre adresse email avant d’utiliser la 2FA Admin.');
        return;
      }

      final adminPhone = adminData['phone'] as String?;
      final hasPhone = adminPhone != null && adminPhone.isNotEmpty;
      if (!hasPhone) {
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        _error('2FA obligatoire : aucun téléphone Admin n’est configuré.');
        return;
      }
      final skipTwoFactor = adminDevelopmentBypassAllowed(
        isDebug: kDebugMode,
        buildFlagEnabled: _adminSkipTwoFactorBuildFlag,
        credentialsAccepted: cred.user != null,
        adminDocumentExists: adminDoc.exists,
        roleActive: adminDevelopmentRoleAllowed(adminData),
        emailVerified: cred.user!.emailVerified,
        phoneConfigured: hasPhone,
      );
      if (skipTwoFactor) {
        _passCtrl.clear();
        debugPrint(
            '[ADMIN_MFA] ATTENTION: 2FA SMS contournée en mode debug explicite');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => AdminDashboard(
              adminData: adminData,
              twoFactorBypassed: true,
            ),
          ),
        );
        return;
      }
      debugPrint(
          '[ADMIN_MFA] enrôlement requis uid=${_maskedUid(cred.user!.uid)}');
      final enrollmentSecret = AdminEnrollmentSecret(pass);
      _passCtrl.clear();
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => AdminOtpPage.enrollment(
            adminUid: cred.user!.uid,
            adminPhone: adminPhone,
            enrollmentSecret: enrollmentSecret,
          ),
        ),
      );
    } on FirebaseAuthMultiFactorException catch (e) {
      debugPrint('[ADMIN_MFA] second facteur requis code=${e.code}');
      if (!mounted) return;
      setState(() => _loading = false);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => AdminOtpPage.signIn(resolver: e.resolver),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      switch (e.code) {
        case 'user-not-found':
        case 'wrong-password':
        case 'invalid-credential':
          _error("Identifiant ou mot de passe incorrect");
        case 'too-many-requests':
          _error("Trop de tentatives. Réessayez plus tard.");
        default:
          _error("Erreur Firebase : ${e.code}");
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _error("Erreur : ${e.toString()}");
    }
  }

  String _maskedUid(String uid) => uid.length <= 6
      ? '***'
      : '${uid.substring(0, 3)}…${uid.substring(uid.length - 3)}';

  Future<void> _resendVerificationEmail() async {
    if (!_verificationGuard.canSend()) {
      final seconds =
          (_verificationGuard.remaining().inMilliseconds / 1000).ceil();
      _error('Attendez encore ${seconds}s avant un nouvel envoi.');
      return;
    }
    final email = _verificationEmail ?? _idCtrl.text.trim();
    final password = _passCtrl.text;
    if (email.isEmpty || password.isEmpty) {
      _error('Renseignez à nouveau votre email et votre mot de passe.');
      return;
    }
    setState(() => _resendingVerificationEmail = true);
    try {
      final credential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);
      final user = credential.user;
      if (user == null || user.emailVerified) {
        throw FirebaseAuthException(code: 'email-already-verified');
      }
      await user.sendEmailVerification();
      _verificationGuard.markSent();
      _error('Email de vérification envoyé.');
    } on FirebaseAuthException catch (e) {
      _error(e.code == 'too-many-requests'
          ? 'Trop de demandes. Réessayez plus tard.'
          : 'Impossible d’envoyer l’email de vérification.');
    } finally {
      try {
        await FirebaseAuth.instance.signOut();
        await FirebaseAuth.instance.signInAnonymously();
      } catch (_) {}
      if (mounted) setState(() => _resendingVerificationEmail = false);
    }
  }

  void _error(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_autoResuming) {
      return const Scaffold(
        backgroundColor: Color(0xFFF5F5F5),
        body:
            Center(child: CircularProgressIndicator(color: AppColors.primary)),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text("Administration"),
        backgroundColor: AppColors.primary,
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
                gradient: const LinearGradient(
                  colors: [AppColors.primary, Color(0xFFFFB300)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Column(
                children: [
                  Icon(Icons.admin_panel_settings,
                      size: 64, color: Colors.white),
                  SizedBox(height: 10),
                  Text(
                    "Espace Admin",
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 4),
                  Text(
                    "AZ Express — Accès réservé",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 36),
            TextField(
              controller: _idCtrl,
              decoration: InputDecoration(
                labelText: "Identifiant",
                prefixIcon: const Icon(Icons.person),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passCtrl,
              obscureText: !_showPass,
              onSubmitted: (_) => _login(),
              decoration: InputDecoration(
                labelText: "Mot de passe",
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon:
                      Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPass = !_showPass),
                ),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const GenericForgotPasswordPage(
                      userType: 'admin',
                      accentColor: AppColors.primary,
                      title: 'Mot de passe oublié',
                    ),
                  ),
                ),
                child: const Text(
                  'Mot de passe oublié ?',
                  style: TextStyle(color: AppColors.primary, fontSize: 13),
                ),
              ),
            ),
            AdminEmailVerificationPrompt(
              visible: _emailVerificationRequired,
              sending: _resendingVerificationEmail,
              remaining: _verificationGuard.remaining(),
              onResend: _resendVerificationEmail,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ScaleButton(
                onPressed: _loading ? null : _login,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        "Se connecter",
                        style: TextStyle(
                            fontSize: 18,
                            color: Colors.white,
                            fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
