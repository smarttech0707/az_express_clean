import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';

import 'pharmacie_change_password.dart';
import 'pharmacie_dashboard.dart';
import 'pharmacie_register.dart';
import '../../services/notification_service.dart';
import '../../services/auth_service.dart';
import '../auth/generic_forgot_password_page.dart';

class PharmacieLogin extends StatefulWidget {
  const PharmacieLogin({super.key});

  @override
  State<PharmacieLogin> createState() => _PharmacieLoginState();
}

class _PharmacieLoginState extends State<PharmacieLogin> {
  final _phoneCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final phone = _phoneCtrl.text.trim().replaceAll(' ', '');
    final pass  = _passCtrl.text.trim();

    if (phone.isEmpty || pass.isEmpty) {
      _snack('Veuillez remplir tous les champs', Colors.orange);
      return;
    }

    setState(() => _loading = true);

    try {
      final snap = await FirebaseFirestore.instance
          .collection('pharmacies')
          .where('phone', isEqualTo: phone)
          .limit(1)
          .get();

      if (snap.docs.isEmpty) {
        // Check if there is a pending/rejected self-registration request
        final req = await FirebaseFirestore.instance
            .collection('pharmacie_requests')
            .doc(phone)
            .get();
        if (!mounted) return;
        if (req.exists) {
          final status = req.data()?['status'] ?? '';
          if (status == 'pending') {
            _snack('Votre demande est en cours d\'examen par l\'administrateur.', Colors.orange);
          } else if (status == 'rejected') {
            _snack('Votre demande a été refusée. Contactez l\'administrateur.', Colors.red);
          } else {
            _snack('Numéro non trouvé. Contactez l\'administrateur.', Colors.red);
          }
        } else {
          _snack('Numéro non trouvé. Contactez l\'administrateur.', Colors.red);
        }
        return;
      }

      final doc  = snap.docs.first;
      final data = doc.data();

      // Vérification côté serveur (mot de passe haché, jamais comparé en
      // clair côté client) — migre automatiquement les anciens comptes.
      final fn = FirebaseFunctions.instanceFor(region: 'europe-west1');
      final result = await fn.httpsCallable('pharmacieLogin').call({
        'pharmacieId': doc.id,
        'password':    pass,
      });
      final loginData = Map<String, dynamic>.from(result.data as Map);

      if (loginData['success'] != true) {
        _snack('Mot de passe incorrect.', Colors.red);
        return;
      }
      final mustChangePassword = loginData['mustChangePassword'] == true;

      NotificationService().saveToken(doc.id, 'pharmacies');
      AuthService().logAuthEvent('login', 'pharmacie');
      // Lie l'UID Firebase anonyme au document pharmacie pour isPharmacieOwnerOfOrder()
      final fbUser = FirebaseAuth.instance.currentUser;
      if (fbUser != null) {
        FirebaseFirestore.instance
            .collection('pharmacies').doc(doc.id)
            .update({'currentUid': fbUser.uid}).catchError((_) {});
      }
      if (!mounted) return;

      if (mustChangePassword) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => PharmacieChangePassword(
              pharmacieId: doc.id,
              pharmacieData: data,
            ),
          ),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => PharmacieDashboard(
              pharmacieId: doc.id,
              pharmacieData: data,
            ),
          ),
        );
      }
    } catch (e) {
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
    final red = Colors.red.shade700;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('Espace Pharmacie',
            style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
        backgroundColor: red,
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
                gradient: LinearGradient(
                  colors: [Colors.red.shade800, Colors.red.shade500],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.red.withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(Icons.local_pharmacy_rounded,
                  color: Colors.white, size: 42),
            ),
            const SizedBox(height: 20),
            Text('Connexion Pharmacie',
                style: GoogleFonts.inter(
                    fontSize: 22, fontWeight: FontWeight.bold)),
            Text('Gérez votre statut et vos commandes',
                style: GoogleFonts.inter(
                    fontSize: 13, color: Colors.grey.shade600)),

            const SizedBox(height: 36),

            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Numéro de téléphone',
                prefixIcon: Icon(Icons.phone_outlined, color: red),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: red, width: 2),
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
                prefixIcon: Icon(Icons.lock_outline, color: red),
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
                  borderSide: BorderSide(color: red, width: 2),
                ),
                filled: true,
                fillColor: Colors.white,
              ),
            ),

            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const PharmacieRegister()),
                  ),
                  child: Text(
                    'Pas encore inscrit ?',
                    style: TextStyle(color: red, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => GenericForgotPasswordPage(
                        userType:    'pharmacie',
                        accentColor: red,
                        title:       'Mot de passe oublié',
                      ),
                    ),
                  ),
                  child: Text(
                    'Mot de passe oublié ?',
                    style: TextStyle(color: red, fontSize: 13),
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
                  backgroundColor: red,
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

