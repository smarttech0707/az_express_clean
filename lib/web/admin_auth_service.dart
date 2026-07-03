import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/auth_service.dart';

class AdminAuthService extends ChangeNotifier {
  static final instance = AdminAuthService._();
  AdminAuthService._() {
    FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user == null) {
        _isAdmin = false;
        notifyListeners();
        return;
      }
      final doc = await FirebaseFirestore.instance
          .collection('admins')
          .doc(user.uid)
          .get();
      _isAdmin = doc.exists && !_isDeactivatedSubAdmin(doc.data());
      if (!_isAdmin) await FirebaseAuth.instance.signOut();
      notifyListeners();
    });
  }

  // Même règle que lib/screens/admin/admin_login.dart : un sous-admin désactivé
  // (role == 'sub' && isActive == false) ne doit pas pouvoir se connecter —
  // avant ce correctif (Master Prompt 57), AdminAuthService ne vérifiait que
  // l'existence du document admins/{uid}, laissant un sous-admin désactivé côté
  // mobile accéder quand même au tableau de bord web (même si chaque lecture/
  // écriture y échouait ensuite côté règles Firestore, isAdmin() vérifiant déjà
  // isActive — ceci ferme le dernier écart d'expérience/permission, pas une
  // fuite de données qui aurait autrement réussi).
  bool _isDeactivatedSubAdmin(Map<String, dynamic>? data) {
    if (data == null) return false;
    final role = data['role'] as String? ?? 'super';
    final isActive = data['isActive'] as bool? ?? true;
    return role == 'sub' && isActive == false;
  }

  bool _isAdmin = false;
  bool get isAdmin => _isAdmin;

  Future<String?> signIn(String email, String password) async {
    try {
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email, password: password,
      );
      final doc = await FirebaseFirestore.instance
          .collection('admins')
          .doc(cred.user!.uid)
          .get();
      if (!doc.exists) {
        await FirebaseAuth.instance.signOut();
        return 'Accès refusé. Ce compte n\'est pas administrateur.';
      }
      if (_isDeactivatedSubAdmin(doc.data())) {
        await FirebaseAuth.instance.signOut();
        return 'Votre compte a été désactivé. Contactez l\'administrateur principal.';
      }
      _isAdmin = true;
      AuthService().logAuthEvent('login', 'admin');
      notifyListeners();
      return null;
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'user-not-found':
        case 'wrong-password':
        case 'invalid-credential':
          return 'Identifiant ou mot de passe incorrect.';
        case 'too-many-requests':
          return 'Trop de tentatives. Réessayez plus tard.';
        default:
          return 'Erreur Firebase : ${e.code}';
      }
    } catch (e) {
      return 'Erreur : $e';
    }
  }

  Future<void> signOut() async {
    AuthService().logAuthEvent('logout', 'admin');
    await FirebaseAuth.instance.signOut();
    _isAdmin = false;
    notifyListeners();
  }
}
