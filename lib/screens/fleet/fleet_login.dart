import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/notification_service.dart';
import 'fleet_dashboard.dart';
import '../auth/generic_forgot_password_page.dart';

class FleetLogin extends StatefulWidget {
  const FleetLogin({super.key});

  @override
  State<FleetLogin> createState() => _FleetLoginState();
}

class _FleetLoginState extends State<FleetLogin> {
  final _idCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  bool _showPass = false;

  Future<void> _login() async {
    final id = _idCtrl.text.trim().toLowerCase();
    final pass = _passCtrl.text;

    if (id.isEmpty || pass.isEmpty) {
      _snack("Entrez votre identifiant et mot de passe", Colors.red);
      return;
    }

    setState(() => _loading = true);

    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: "$id@az-fleet.ci",
        password: pass,
      );

      final uid = credential.user!.uid;

      final doc = await FirebaseFirestore.instance
          .collection("fleet_owners")
          .doc(uid)
          .get();

      if (!mounted) return;

      if (!doc.exists) {
        setState(() => _loading = false);
        _snack("Compte introuvable. Contactez l'administrateur.", Colors.red);
        await FirebaseAuth.instance.signOut();
        return;
      }

      final data   = doc.data() as Map<String, dynamic>;
      final status = (data['status'] as String?) ?? 'approved';

      if (status == 'pending') {
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        setState(() => _loading = false);
        _snack("Votre compte est en attente d'approbation par l'administrateur.", Colors.orange);
        return;
      }

      if (status == 'rejected') {
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        setState(() => _loading = false);
        _snack("Votre demande a été refusée. Contactez l'administrateur.", Colors.red);
        return;
      }

      final ownerName = (data['name'] as String?) ?? 'Patron';

      NotificationService().saveToken(uid, 'fleet_owners');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => FleetDashboard(ownerId: uid, ownerName: ownerName),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found' ||
          e.code == 'wrong-password' ||
          e.code == 'invalid-credential' ||
          e.code == 'invalid-email') {
        _snack("Identifiant ou mot de passe incorrect", Colors.red);
      } else {
        _snack("Erreur : ${e.message}", Colors.red);
      }
    } catch (e) {
      _snack("Erreur de connexion. Vérifiez votre réseau.", Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
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
        title: const Text("Espace Patron de Flotte"),
        backgroundColor: const Color(0xFF6A1B9A),
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
                  colors: [Color(0xFF6A1B9A), Color(0xFF8E24AA)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Column(
                children: [
                  Icon(Icons.motorcycle, size: 70, color: Colors.white),
                  SizedBox(height: 10),
                  Text(
                    "Connexion Patron",
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 4),
                  Text(
                    "Gérez votre flotte et vos gains",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _idCtrl,
              decoration: InputDecoration(
                labelText: "Identifiant",
                hintText: "Votre ID de connexion",
                prefixIcon: const Icon(Icons.badge),
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
                      userType:    'fleet',
                      accentColor: Color(0xFF6A1B9A),
                      title:       'Mot de passe oublié',
                    ),
                  ),
                ),
                child: const Text(
                  'Mot de passe oublié ?',
                  style: TextStyle(color: Color(0xFF6A1B9A), fontSize: 13),
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
                  backgroundColor: const Color(0xFF6A1B9A),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                        "Se connecter",
                        style: TextStyle(fontSize: 18, color: Colors.white),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
