import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/notification_service.dart';
import '../../services/auth_service.dart';
import '../../screens/auth/forgot_password_page.dart';
import 'driver_dashboard.dart';
import 'driver_register.dart';

class DriverLogin extends StatefulWidget {
  const DriverLogin({super.key});

  @override
  State<DriverLogin> createState() => _DriverLoginState();
}

class _DriverLoginState extends State<DriverLogin> {
  final _idCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  bool _showPass = false;

  // Master Prompt 128 — session persistante : Firebase Auth garde déjà la
  // session en local nativement, mais cet écran ne l'a jamais consultée
  // avant d'afficher le formulaire, forçant une reconnexion manuelle à
  // chaque lancement même quand une session livreur valide existe déjà.
  // `true` uniquement s'il y a un utilisateur réel (non anonyme) à
  // vérifier, pour ne jamais faire clignoter le formulaire pour rien.
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
          .collection('livreurs')
          .doc(user.uid)
          .get();
      if (!mounted) return;
      if (doc.exists) {
        // Même chemin exact que `_login()` en cas de succès — aucune
        // nouvelle règle métier inventée (pas de vérification isSuspended
        // ici : le formulaire de connexion manuel ne le fait pas non plus
        // aujourd'hui, la suspension est déjà appliquée ailleurs, à
        // l'acceptation d'une commande).
        final driverName = doc['name'] ?? 'Livreur';
        NotificationService().saveToken(user.uid, 'livreurs');
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => DriverDashboard(driverId: user.uid, driverName: driverName),
          ),
        );
        return;
      }
    } catch (_) {
      // Silencieux : retombe simplement sur le formulaire de connexion
      // normal, comme si aucune session n'existait.
    }
    if (mounted) setState(() => _autoResuming = false);
  }

  Future<void> _login() async {
    final id = _idCtrl.text.trim().toLowerCase();
    final pass = _passCtrl.text;

    if (id.isEmpty || pass.isEmpty) {
      _snack("Entrez votre identifiant et mot de passe", Colors.red);
      return;
    }

    if (pass.length < 6) {
      _snack("Le mot de passe doit contenir au moins 6 caractères", Colors.red);
      return;
    }

    setState(() => _loading = true);

    try {
      // 1. Déterminer l'email Firebase Auth
      final authEmail = await AuthService().getDriverAuthEmail(id);
      if (authEmail == null) {
        _snack("Identifiant introuvable. Vérifiez vos informations.", Colors.red);
        setState(() => _loading = false);
        return;
      }

      // 2. Connexion Firebase Auth
      final credential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(
        email: authEmail,
        password: pass,
      );

      final uid = credential.user!.uid;

      // 2. Vérifier si le livreur est approuvé
      final doc = await FirebaseFirestore.instance
          .collection("livreurs")
          .doc(uid)
          .get();

      if (!mounted) return;

      if (!doc.exists) {
        // Pas encore approuvé — vérifier si demande en attente
        final req = await FirebaseFirestore.instance
            .collection("driver_requests")
            .doc(uid)
            .get();

        await FirebaseAuth.instance.signOut();
        try { await FirebaseAuth.instance.signInAnonymously(); } catch (_) {}

        if (!mounted) return;
        setState(() => _loading = false);

        if (req.exists) {
          _snack(
            "Votre demande est en attente d'approbation par l'administrateur.",
            Colors.orange,
          );
        } else {
          _snack("Compte introuvable. Contactez l'administrateur.", Colors.red);
        }
        return;
      }

      // 3. Approuvé → accès au dashboard
      final driverName = doc["name"] ?? "Livreur";
      NotificationService().saveToken(uid, 'livreurs');
      AuthService().logAuthEvent('login', 'livreur');

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) =>
              DriverDashboard(driverId: uid, driverName: driverName),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found' ||
          e.code == 'wrong-password' ||
          e.code == 'invalid-credential' ||
          e.code == 'invalid-email') {
        _snack("Identifiant/email ou mot de passe incorrect", Colors.red);
      } else {
        _snack("Une erreur est survenue. Veuillez réessayer.", Colors.red);
      }
    } catch (e) {
      _snack("Erreur de connexion. Vérifiez votre réseau.", Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg, Color color) {
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
    // Master Prompt 128 (Partie 13/14) — pendant la vérification (une
    // seule lecture Firestore, quasi instantanée), ne jamais montrer le
    // formulaire "Connexion..."/"Chargement..." si une session valide est
    // sur le point d'être restaurée.
    if (_autoResuming) {
      return const Scaffold(
        backgroundColor: Color(0xFFF5F5F5),
        body: Center(child: CircularProgressIndicator(color: Color(0xFF167DB7))),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text("Espace Livreur"),
        backgroundColor: const Color(0xFF167DB7),
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
                  colors: [Color(0xFF167DB7), Color(0xFF1E88E5)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Column(
                children: [
                  Icon(Icons.delivery_dining, size: 70, color: Colors.white),
                  SizedBox(height: 10),
                  Text(
                    "Connexion Livreur",
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 4),
                  Text(
                    "Connectez-vous pour accéder à vos courses",
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _idCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: "Identifiant ou email",
                hintText: "Votre ID ou adresse email",
                prefixIcon: const Icon(Icons.badge),
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
              decoration: InputDecoration(
                labelText: "Mot de passe",
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon: Icon(
                      _showPass ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPass = !_showPass),
                ),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ForgotPasswordPage())),
                child: const Text('Mot de passe oublié ?',
                    style: TextStyle(color: Color(0xFF167DB7),
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ScaleButton(
                onPressed: _loading ? null : _login,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF167DB7),
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
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 8),
            const Text(
              "Vous n'avez pas encore de compte ?",
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const DriverRegister()),
                ),
                icon: const Icon(Icons.person_add, color: Color(0xFF167DB7)),
                label: const Text(
                  "Créer un compte",
                  style: TextStyle(
                      fontSize: 16,
                      color: Color(0xFF167DB7),
                      fontWeight: FontWeight.bold),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF167DB7), width: 2),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
