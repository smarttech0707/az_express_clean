import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../auth/generic_forgot_password_page.dart';

import 'seller_dashboard.dart';
import 'seller_register.dart';
import '../../services/notification_service.dart';
import '../../services/subscription_service.dart';

class SellerLogin extends StatefulWidget {
  const SellerLogin({super.key});

  @override
  State<SellerLogin> createState() => _SellerLoginState();
}

class _SellerLoginState extends State<SellerLogin> {
  final _phoneCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  bool _showPass = false;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final phone = _phoneCtrl.text.trim().replaceAll(' ', '');
    final pass = _passCtrl.text;

    if (phone.isEmpty || pass.isEmpty) {
      _snack("Entrez votre téléphone et mot de passe", Colors.red);
      return;
    }

    setState(() => _loading = true);

    try {
      final credential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(
        email: "$phone@az-seller.ci",
        password: pass,
      );

      final uid = credential.user!.uid;

      final doc = await FirebaseFirestore.instance
          .collection("sellers")
          .doc(uid)
          .get();

      if (!mounted) return;

      if (!doc.exists || !(doc.data()?['isActive'] ?? false)) {
        await FirebaseAuth.instance.signOut();
        try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}
        if (!mounted) return;
        setState(() => _loading = false);

        // Check if there is a pending/rejected request
        final req = await FirebaseFirestore.instance
            .collection('seller_requests')
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
          _snack('Compte inactif. Contactez l\'administrateur.', Colors.red);
        }
        return;
      }

      final sellerData = doc.data()!;
      NotificationService().saveToken(uid, 'sellers');
      if (!mounted) return;
      await SubscriptionService.checkAndRenew('sellers', uid);
      if (!mounted) return;
      setState(() => _loading = false);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => SellerDashboard(
            sellerId: uid,
            sellerData: sellerData,
          ),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      String msg = "Identifiants incorrects";
      if (e.code == 'too-many-requests') msg = "Trop de tentatives. Réessayez plus tard.";
      if (e.code == 'network-request-failed') msg = "Pas de connexion internet";
      _snack(msg, Colors.red);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack("Erreur : $e", Colors.red);
    }
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1565C0), Color(0xFF1E88E5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // ── HEADER ─────────────────────────────────────
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 32, 24, 0),
                child: Column(
                  children: [
                    Icon(Icons.storefront_rounded,
                        color: Colors.white, size: 64),
                    SizedBox(height: 16),
                    Text(
                      "Espace Vendeur",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      "Gérez vos commandes et livraisons",
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // ── FORM ───────────────────────────────────────
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFFF5F5F5),
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(32)),
                  ),
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Connexion",
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 24),

                      // Phone
                      TextField(
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: "Numéro de téléphone",
                          hintText: "07 00 00 00 00",
                          prefixIcon: const Icon(Icons.phone_rounded,
                              color: Color(0xFF1565C0)),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Password
                      TextField(
                        controller: _passCtrl,
                        obscureText: !_showPass,
                        decoration: InputDecoration(
                          labelText: "Mot de passe",
                          prefixIcon: const Icon(Icons.lock_rounded,
                              color: Color(0xFF1565C0)),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _showPass
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: Colors.grey,
                            ),
                            onPressed: () =>
                                setState(() => _showPass = !_showPass),
                          ),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: (_) => _login(),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const GenericForgotPasswordPage(
                                userType:    'seller',
                                accentColor: Color(0xFF1565C0),
                                title:       'Mot de passe oublié',
                              ),
                            ),
                          ),
                          child: const Text(
                            'Mot de passe oublié ?',
                            style: TextStyle(
                                color: Color(0xFF1565C0), fontSize: 13),
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
                              ? const CircularProgressIndicator(
                                  color: Colors.white)
                              : const Text(
                                  "Se connecter",
                                  style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold),
                                ),
                        ),
                      ),

                      const Spacer(),

                      Center(
                        child: TextButton(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const SellerRegister()),
                          ),
                          child: const Text(
                            "Pas encore inscrit ? S'inscrire",
                            style: TextStyle(
                                color: Color(0xFF1565C0), fontSize: 13),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

