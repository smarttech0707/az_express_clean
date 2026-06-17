import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/notification_service.dart';
import '../auth/generic_forgot_password_page.dart';

import 'artisan_dashboard.dart';

class ArtisanLogin extends StatefulWidget {
  const ArtisanLogin({super.key});

  @override
  State<ArtisanLogin> createState() => _ArtisanLoginState();
}

class _ArtisanLoginState extends State<ArtisanLogin> {
  final _phoneCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _obscurePin = true;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final phone = _phoneCtrl.text.trim();
    final pin = _pinCtrl.text.trim();
    if (phone.isEmpty || pin.isEmpty) {
      setState(() => _error = "Veuillez remplir tous les champs");
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Ensure an anonymous Firebase session exists
      var user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        await FirebaseAuth.instance.signInAnonymously();
        user = FirebaseAuth.instance.currentUser;
      }
      final uid = user!.uid;

      // Look up provider by phone + PIN
      final snap = await FirebaseFirestore.instance
          .collection('service_providers')
          .where('phone', isEqualTo: phone)
          .where('artisanPin', isEqualTo: pin)
          .limit(1)
          .get();

      if (snap.docs.isEmpty) {
        setState(() => _error = "Téléphone ou PIN incorrect");
        if (mounted) setState(() => _loading = false);
        return;
      }

      final doc = snap.docs.first;
      final data = Map<String, dynamic>.from(doc.data());

      // Link UID the first time
      if (data['artisanUid'] != uid) {
        await doc.reference.update({'artisanUid': uid});
        data['artisanUid'] = uid;
      }

      NotificationService().saveToken(doc.id, 'service_providers');
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ArtisanDashboard(docId: doc.id, initialData: data),
          ),
        );
      }
    } catch (e) {
      setState(() => _error = "Erreur : $e");
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1565C0),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.handyman_rounded, color: Colors.white, size: 64),
                const SizedBox(height: 16),
                const Text(
                  "Espace Artisan",
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                const Text(
                  "Gérez vos photos de réalisations",
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 40),
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.black26,
                          blurRadius: 20,
                          offset: Offset(0, 8))
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Connexion",
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 18),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: "Numéro de téléphone",
                          prefixIcon: const Icon(Icons.phone),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: Color(0xFF1565C0), width: 2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _pinCtrl,
                        obscureText: _obscurePin,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: InputDecoration(
                          labelText: "Code PIN",
                          hintText: "Fourni par l'administrateur",
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            icon: Icon(_obscurePin
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () =>
                                setState(() => _obscurePin = !_obscurePin),
                          ),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: Color(0xFF1565C0), width: 2),
                          ),
                          counterText: "",
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.red.shade200),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline,
                                  color: Colors.red, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(_error!,
                                    style: const TextStyle(
                                        color: Colors.red, fontSize: 13)),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const GenericForgotPasswordPage(
                                userType:    'artisan',
                                accentColor: Color(0xFF1565C0),
                                title:       'PIN oublié',
                              ),
                            ),
                          ),
                          style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                          child: const Text(
                            'PIN oublié ?',
                            style: TextStyle(
                                color: Color(0xFF1565C0), fontSize: 13),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ScaleButton(
                          onPressed: _loading ? null : _login,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1565C0),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          child: _loading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2.5))
                              : const Text(
                                  "Se connecter",
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  "Votre code PIN vous a été remis par l'équipe AZ Express.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

