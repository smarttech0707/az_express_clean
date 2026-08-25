import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pharmacie_change_password.dart';
import 'pharmacie_dashboard.dart';
import 'pharmacie_register.dart';
import '../../services/notification_service.dart';
import '../../services/auth_service.dart';
import '../auth/generic_forgot_password_page.dart';

/// Master Prompt 128 — la pharmacie n'a pas d'identité Firebase Auth (le
/// mot de passe est vérifié côté serveur via `pharmacieLogin`, jamais par
/// Firebase Auth — voir CLAUDE.md section Identité). Sans ce mécanisme,
/// aucune session ne pouvait jamais être restaurée après fermeture
/// complète de l'app : ce n'est pas une régression, la persistance
/// n'existait tout simplement pas. Seul l'identifiant de la pharmacie est
/// conservé localement (jamais le mot de passe ni un secret quelconque,
/// conforme à la Partie 12) — revalidé contre Firestore à chaque
/// lancement avant de restaurer le tableau de bord.
const kPharmacieLastIdPrefKey = 'az_pharmacie_last_id';

class PharmacieLogin extends StatefulWidget {
  const PharmacieLogin({super.key});

  @override
  State<PharmacieLogin> createState() => _PharmacieLoginState();
}

class _PharmacieLoginState extends State<PharmacieLogin> {
  final _phoneCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  bool _autoResuming = true;

  @override
  void initState() {
    super.initState();
    _tryAutoResume();
  }

  Future<void> _tryAutoResume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastId = prefs.getString(kPharmacieLastIdPrefKey);
      if (lastId == null || lastId.isEmpty) {
        if (mounted) setState(() => _autoResuming = false);
        return;
      }
      final doc = await FirebaseFirestore.instance
          .collection('pharmacies')
          .doc(lastId)
          .get();
      if (!mounted) return;
      if (!doc.exists) {
        await prefs.remove(kPharmacieLastIdPrefKey);
        setState(() => _autoResuming = false);
        return;
      }
      final data = doc.data()!;
      NotificationService().saveToken(lastId, 'pharmacies');
      final fbUser = FirebaseAuth.instance.currentUser;
      if (fbUser != null) {
        FirebaseFirestore.instance
            .collection('pharmacies')
            .doc(lastId)
            .update({'currentUid': fbUser.uid}).catchError((_) {});
      }
      if (data['mustChangePassword'] == true) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => PharmacieChangePassword(
                pharmacieId: lastId, pharmacieData: data),
          ),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) =>
                PharmacieDashboard(pharmacieId: lastId, pharmacieData: data),
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _autoResuming = false);
    }
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final phone = _phoneCtrl.text.trim().replaceAll(' ', '');
    final pass = _passCtrl.text.trim();

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
        // Pas de lecture de pharmacie_requests ici : contrairement aux rôles
        // Firebase Auth (driver/seller/restaurant/boulangerie), l'appelant
        // n'a à ce stade aucune identité prouvée liée à ce numéro de
        // téléphone (pharmacie_register.dart n'authentifie personne) — une
        // règle isAuth() && resource.data.phone==... serait devinable par
        // n'importe qui (permet d'énumérer les candidatures d'autrui), donc
        // pharmacie_requests reste volontairement admin-only en lecture.
        // Tenter cette lecture ici échouait systématiquement en
        // permission-denied, affichant une erreur Firestore brute au lieu
        // du message générique ci-dessous.
        if (!mounted) return;
        _snack(
            'Numéro non trouvé. Si vous venez de vous inscrire, patientez '
            'que l\'administrateur valide votre demande.',
            Colors.red);
        return;
      }

      final doc = snap.docs.first;
      final data = doc.data();

      // Vérification côté serveur (mot de passe haché, jamais comparé en
      // clair côté client) — migre automatiquement les anciens comptes.
      final fn = FirebaseFunctions.instanceFor(region: 'europe-west1');
      final result = await fn.httpsCallable('pharmacieLogin').call({
        'pharmacieId': doc.id,
        'password': pass,
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
            .collection('pharmacies')
            .doc(doc.id)
            .update({'currentUid': fbUser.uid}).catchError((_) {});
      }
      // Master Prompt 128 — seul l'identifiant est conservé (jamais le mot
      // de passe), pour restaurer la session au prochain lancement.
      (await SharedPreferences.getInstance())
          .setString(kPharmacieLastIdPrefKey, doc.id);
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
    if (_autoResuming) {
      return Scaffold(
        backgroundColor: const Color(0xFFF5F5F5),
        body: Center(child: CircularProgressIndicator(color: red)),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('Espace Pharmacie',
            style: GoogleFonts.urbanist(fontWeight: FontWeight.bold)),
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
                style: GoogleFonts.urbanist(
                    fontSize: 22, fontWeight: FontWeight.bold)),
            Text('Gérez votre statut et vos commandes',
                style: GoogleFonts.urbanist(
                    fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 36),
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Numéro de téléphone',
                prefixIcon: Icon(Icons.phone_outlined, color: red),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
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
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
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
                        userType: 'pharmacie',
                        accentColor: red,
                        title: 'Mot de passe oublié',
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
