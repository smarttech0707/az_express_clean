import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';

import 'boulangerie_dashboard.dart';
import 'boulangerie_register.dart';
import '../../services/notification_service.dart';
import '../../services/subscription_service.dart';
import '../../services/auth_service.dart';
import '../auth/generic_forgot_password_page.dart';

class BoulangerieLogin extends StatefulWidget {
  const BoulangerieLogin({super.key});

  @override
  State<BoulangerieLogin> createState() => _BoulangerieLoginState();
}

class _BoulangerieLoginState extends State<BoulangerieLogin> {
  final _phoneCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  // Master Prompt 128 — voir driver_login.dart pour le contexte complet.
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
      final doc = await FirebaseFirestore.instance
          .collection('boulangeries')
          .doc(user.uid)
          .get();
      if (!mounted) return;
      if (doc.exists && (doc.data()?['isActive'] ?? false)) {
        NotificationService().saveToken(user.uid, 'boulangeries');
        await SubscriptionService.checkAndRenew('boulangeries', user.uid);
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => BoulangerieDashboard(
              boulangerieId: user.uid,
              boulangerieData: doc.data()!,
            ),
          ),
        );
        return;
      }
    } catch (_) {
      // Retombe sur le formulaire.
    }
    if (mounted) setState(() => _autoResuming = false);
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final phone = _phoneCtrl.text.trim().replaceAll(' ', '');
    final pass  = _passCtrl.text;

    if (phone.isEmpty || pass.isEmpty) {
      _snack('Veuillez remplir tous les champs', Colors.orange);
      return;
    }

    setState(() => _loading = true);

    try {
      final credential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(
        email: '$phone@az-boulangerie.ci',
        password: pass,
      );

      final uid = credential.user!.uid;
      final doc = await FirebaseFirestore.instance
          .collection('boulangeries')
          .doc(uid)
          .get();

      if (!doc.exists || !(doc.data()?['isActive'] ?? false)) {
        await FirebaseAuth.instance.signOut();
        try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
        if (!mounted) return;

        final req = await FirebaseFirestore.instance
            .collection('boulangerie_requests')
            .doc(uid)
            .get();
        if (!mounted) return;
        if (req.exists) {
          final status = req.data()?['status'] ?? '';
          if (status == 'pending') {
            _snack('Votre demande est en cours d\'examen par l\'administrateur.', Colors.orange);
          } else if (status == 'rejected') {
            _snack('Votre demande a été refusée. Contactez l\'administrateur.', Colors.red);
          } else {
            _snack('Compte inactif. Contactez l\'administrateur.', Colors.red);
          }
        } else {
          _snack('Compte introuvable. Contactez l\'administrateur.', Colors.red);
        }
        return;
      }

      NotificationService().saveToken(uid, 'boulangeries');
      AuthService().logAuthEvent('login', 'boulangerie');
      if (!mounted) return;
      await SubscriptionService.checkAndRenew('boulangeries', uid);
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => BoulangerieDashboard(
            boulangerieId: uid,
            boulangerieData: doc.data()!,
          ),
        ),
      );
    } on FirebaseAuthException catch (e) {
      final msg = e.code == 'user-not-found' || e.code == 'wrong-password'
          ? 'Numéro ou mot de passe incorrect.'
          : 'Erreur : ${e.message}';
      _snack(msg, Colors.red);
    } catch (e) {
      _snack('Erreur : $e', Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
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

  @override
  Widget build(BuildContext context) {
    const brown = Color(0xFF5D4037);
    if (_autoResuming) {
      return const Scaffold(
        backgroundColor: Color(0xFFF5F5F5),
        body: Center(child: CircularProgressIndicator(color: brown)),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('Espace Boulangerie',
            style: GoogleFonts.urbanist(fontWeight: FontWeight.bold)),
        backgroundColor: brown,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 24),
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF4E342E), Color(0xFF8D6E63)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.brown.withValues(alpha: 0.35),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(Icons.bakery_dining_rounded,
                  color: Colors.white, size: 44),
            ),
            const SizedBox(height: 20),
            Text('Connexion Boulangerie',
                style: GoogleFonts.urbanist(
                    fontSize: 22, fontWeight: FontWeight.bold)),
            Text('Gérez votre menu et vos commandes',
                style: GoogleFonts.urbanist(
                    fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 36),

            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Numéro de téléphone',
                prefixIcon: const Icon(Icons.phone_outlined, color: brown),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: brown, width: 2),
                ),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _passCtrl,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Mot de passe',
                prefixIcon: const Icon(Icons.lock_outline, color: brown),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: Colors.grey,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: brown, width: 2),
                ),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const BoulangerieRegister()),
                  ),
                  child: const Text(
                    'Pas encore inscrit ?',
                    style: TextStyle(color: Color(0xFF5D4037), fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const GenericForgotPasswordPage(
                        userType:    'boulangerie',
                        accentColor: Color(0xFF5D4037),
                        title:       'Mot de passe oublié',
                      ),
                    ),
                  ),
                  child: const Text(
                    'Mot de passe oublié ?',
                    style: TextStyle(color: Color(0xFF5D4037), fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              height: 54,
              child: ScaleButton(
                onPressed: _loading ? null : _login,
                style: ElevatedButton.styleFrom(
                  backgroundColor: brown,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text('Se connecter',
                        style: GoogleFonts.urbanist(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

