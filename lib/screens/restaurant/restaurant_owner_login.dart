import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';

import 'restaurant_owner_dashboard.dart';
import '../../services/notification_service.dart';
import '../../services/subscription_service.dart';
import '../../services/auth_service.dart';
import '../auth/generic_forgot_password_page.dart';

class RestaurantOwnerLogin extends StatefulWidget {
  const RestaurantOwnerLogin({super.key});

  @override
  State<RestaurantOwnerLogin> createState() => _RestaurantOwnerLoginState();
}

class _RestaurantOwnerLoginState extends State<RestaurantOwnerLogin> {
  final _phoneCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  bool _loading  = false;
  bool _obscure  = true;

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
      final current = FirebaseAuth.instance.currentUser;
      if (current != null && current.isAnonymous) {
        await FirebaseAuth.instance.signOut();
      }

      final email = '$phone@az-restaurant.ci';
      final cred = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: pass);
      final uid = cred.user!.uid;

      // Check approval status
      final ownerDoc = await FirebaseFirestore.instance
          .collection('restaurant_owners')
          .doc(uid)
          .get();

      if (!ownerDoc.exists) {
        // Check if still pending
        final reqDoc = await FirebaseFirestore.instance
            .collection('restaurant_requests')
            .doc(uid)
            .get();

        await FirebaseAuth.instance.signOut();
        try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}

        if (!mounted) return;
        if (reqDoc.exists) {
          final status = reqDoc.data()?['status'] ?? 'pending';
          if (status == 'pending') {
            _snack('Votre demande est en cours d\'examen. Patientez 24h.', Colors.orange);
          } else if (status == 'rejected') {
            _snack('Votre demande a été refusée. Contactez l\'admin.', Colors.red);
          } else {
            _snack('Compte non approuvé. Contactez l\'admin.', Colors.red);
          }
        } else {
          _snack('Compte non trouvé. Contactez l\'administrateur.', Colors.red);
        }
        return;
      }

      final ownerData = ownerDoc.data()!;
      final restaurantId = ownerData['restaurantId'] as String?;
      if (restaurantId == null) {
        await FirebaseAuth.instance.signOut();
        try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
        if (!mounted) return;
        _snack('Restaurant introuvable. Contactez l\'admin.', Colors.red);
        return;
      }

      final restoDoc = await FirebaseFirestore.instance
          .collection('restaurants')
          .doc(restaurantId)
          .get();

      if (!restoDoc.exists) {
        await FirebaseAuth.instance.signOut();
        try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
        if (!mounted) return;
        _snack('Restaurant introuvable. Contactez l\'admin.', Colors.red);
        return;
      }

      NotificationService().saveToken(uid, 'restaurants');
      AuthService().logAuthEvent('login', 'restaurant');
      if (!mounted) return;
      await SubscriptionService.checkAndRenew('restaurants', restaurantId);
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => RestaurantOwnerDashboard(
            ownerId: uid,
            restaurantId: restaurantId,
            restaurantData: restoDoc.data()!,
          ),
        ),
      );
    } on FirebaseAuthException catch (e) {
      await FirebaseAuth.instance.signOut();
      try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
      if (!mounted) return;
      if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
        _snack('Numéro ou mot de passe incorrect.', Colors.red);
      } else {
        _snack('Erreur : ${e.message}', Colors.red);
      }
    } catch (e) {
      await FirebaseAuth.instance.signOut();
      try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
      if (!mounted) return;
      _snack('Erreur : $e', Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('Espace Restaurateur',
            style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 20),
            // Hero
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1565C0), Color(0xFF1E88E5)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF1565C0).withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(Icons.restaurant_rounded,
                  color: Colors.white, size: 42),
            ),
            const SizedBox(height: 20),
            Text('Connexion',
                style: GoogleFonts.inter(
                    fontSize: 22, fontWeight: FontWeight.bold)),
            Text('Accédez à votre espace restaurateur',
                style: GoogleFonts.inter(
                    fontSize: 13, color: Colors.grey.shade600)),

            const SizedBox(height: 36),

            // Phone field
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Numéro de téléphone',
                prefixIcon: const Icon(Icons.phone_outlined,
                    color: Color(0xFF1565C0)),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:
                      const BorderSide(color: Color(0xFF1565C0), width: 2),
                ),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),

            // Password field
            TextField(
              controller: _passCtrl,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Mot de passe',
                prefixIcon: const Icon(Icons.lock_outline,
                    color: Color(0xFF1565C0)),
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
                  borderSide:
                      const BorderSide(color: Color(0xFF1565C0), width: 2),
                ),
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
                      userType:    'restaurant',
                      accentColor: Color(0xFF1565C0),
                      title:       'Mot de passe oublié',
                    ),
                  ),
                ),
                child: Text(
                  'Mot de passe oublié ?',
                  style: GoogleFonts.inter(
                      color: const Color(0xFF1565C0), fontSize: 13),
                ),
              ),
            ),
            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              height: 54,
              child: ScaleButton(
                onPressed: _loading ? null : _login,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text('Se connecter',
                        style: GoogleFonts.inter(
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

