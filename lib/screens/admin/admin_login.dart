import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/notification_service.dart';
import '../../services/auth_service.dart';
import 'admin_dashboard.dart';
import '../auth/generic_forgot_password_page.dart';
import 'admin_otp_page.dart';
import '../../theme/app_theme.dart';

class AdminLogin extends StatefulWidget {
  const AdminLogin({super.key});

  @override
  State<AdminLogin> createState() => _AdminLoginState();
}

// ⚠️⚠️⚠️ MASTER PROMPT 134 — DÉSACTIVATION TEMPORAIRE, MODE DÉVELOPPEMENT UNIQUEMENT ⚠️⚠️⚠️
// Contourne la 2FA SMS admin (Firebase Phone Auth) pour débloquer les tests
// pendant que le blocage Play Integrity/reCAPTCHA (Master Prompt 133 — cause :
// cette build n'est pas distribuée via Google Play, donc jamais "reconnue")
// empêche l'envoi réel de SMS. Ne désactive QUE l'étape OTP : la vérification
// de rôle admin (document `admins/{uid}` + `isActive` pour les sous-admins)
// reste entièrement appliquée avant, inchangée.
// Garde-fou double :
//   1. `kDebugMode` est une constante de compilation Dart — `false` dans tout
//      build release/profile (`flutter build apk/appbundle --release`), donc
//      cette branche est éliminée à la compilation et NE PEUT PAS partir en
//      production par oubli.
//   2. `_kBypassAdminOtpInDebug` reste un second interrupteur explicite —
//      repasser à `false` ici réactive l'OTP même en debug, sans toucher au
//      reste du fichier.
// AVANT PUBLICATION : repasser `_kBypassAdminOtpInDebug` à `false` (ou
// simplement supprimer ce bloc) — voir Master Prompt 134 dans CLAUDE.md.
const bool _kBypassAdminOtpInDebug = true;
bool get _otpBypassActive => kDebugMode && _kBypassAdminOtpInDebug;

class _AdminLoginState extends State<AdminLogin> {
  final _idCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _showPass = false;
  bool _loading = false;

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
    try {
      final adminDoc = await FirebaseFirestore.instance
          .collection('admins')
          .doc(user.uid)
          .get();
      if (!mounted) return;
      if (!adminDoc.exists) {
        setState(() => _autoResuming = false);
        return;
      }
      final adminData = <String, dynamic>{'uid': user.uid, ...adminDoc.data()!};
      adminData['role'] ??= 'super';
      if (adminData['role'] == 'sub' && adminData['isActive'] == false) {
        setState(() => _autoResuming = false);
        return;
      }

      NotificationService().saveToken(user.uid, 'admins');
      final adminPhone = adminData['phone'] as String?;
      final hasPhone = adminPhone != null && adminPhone.isNotEmpty;
      if (hasPhone && !_otpBypassActive) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => AdminOtpPage(
            adminUid:   user.uid,
            adminPhone: adminPhone,
            adminData:  adminData,
          )),
        );
      } else {
        if (hasPhone && _otpBypassActive) {
          debugPrint('⚠️ [DEV MODE] OTP admin SMS contourné (Master Prompt 134, '
              '_kBypassAdminOtpInDebug=true) — À NE JAMAIS EXPÉDIER EN PRODUCTION.');
        }
        AuthService().logAuthEvent('login', 'admin');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => AdminDashboard(adminData: adminData)),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _autoResuming = false);
    }
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
        try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
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
      adminData['role'] ??= 'super';

      // Compte sous-admin désactivé
      if (adminData['role'] == 'sub' && adminData['isActive'] == false) {
        await FirebaseAuth.instance.signOut();
        try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
        if (!mounted) return;
        setState(() => _loading = false);
        _error("Votre compte a été désactivé. Contactez l'administrateur principal.");
        return;
      }

      NotificationService().saveToken(cred.user!.uid, 'admins');

      // ── 2FA : vérification OTP par SMS si l'admin a un téléphone ──────────
      final adminPhone = adminData['phone'] as String?;
      final hasPhone = adminPhone != null && adminPhone.isNotEmpty;
      if (hasPhone && !_otpBypassActive) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => AdminOtpPage(
            adminUid:   cred.user!.uid,
            adminPhone: adminPhone,
            adminData:  adminData,
          )),
        );
      } else {
        if (!hasPhone) {
          // Aucun téléphone enregistré → accès direct + avertissement
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                '⚠️ Ajoutez un numéro de téléphone à votre profil admin pour activer la 2FA.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 5),
          ));
        } else {
          // Téléphone présent mais OTP volontairement contourné (dev only)
          debugPrint('⚠️ [DEV MODE] OTP admin SMS contourné (Master Prompt 134, '
              '_kBypassAdminOtpInDebug=true) — À NE JAMAIS EXPÉDIER EN PRODUCTION.');
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('🛠️ Mode développement : 2FA SMS contournée.'),
            backgroundColor: Colors.blueGrey,
            duration: Duration(seconds: 4),
          ));
        }
        AuthService().logAuthEvent('login', 'admin');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => AdminDashboard(adminData: adminData)),
        );
      }
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
        body: Center(child: CircularProgressIndicator(color: AppColors.primary)),
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
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
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
                  icon: Icon(
                      _showPass ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPass = !_showPass),
                ),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
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
                      userType:    'admin',
                      accentColor: AppColors.primary,
                      title:       'Mot de passe oublié',
                    ),
                  ),
                ),
                child: const Text(
                  'Mot de passe oublié ?',
                  style: TextStyle(color: AppColors.primary, fontSize: 13),
                ),
              ),
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
