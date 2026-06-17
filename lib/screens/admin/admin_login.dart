import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/notification_service.dart';
import 'admin_dashboard.dart';
import '../auth/generic_forgot_password_page.dart';
import 'admin_otp_page.dart';

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
      if (adminPhone != null && adminPhone.isNotEmpty) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => AdminOtpPage(
            adminUid:   cred.user!.uid,
            adminPhone: adminPhone,
            adminData:  adminData,
          )),
        );
      } else {
        // Aucun téléphone enregistré → accès direct + avertissement
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              '⚠️ Ajoutez un numéro de téléphone à votre profil admin pour activer la 2FA.'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),
        ));
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
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text("Administration"),
        backgroundColor: const Color(0xFFFF6D00),
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
                  colors: [Color(0xFFFF6D00), Color(0xFFFFB300)],
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
                      accentColor: Color(0xFFFF6D00),
                      title:       'Mot de passe oublié',
                    ),
                  ),
                ),
                child: const Text(
                  'Mot de passe oublié ?',
                  style: TextStyle(color: Color(0xFFFF6D00), fontSize: 13),
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
                  backgroundColor: const Color(0xFFFF6D00),
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
