import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

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
      _isAdmin = doc.exists;
      if (!_isAdmin) await FirebaseAuth.instance.signOut();
      notifyListeners();
    });
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
      _isAdmin = true;
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
    await FirebaseAuth.instance.signOut();
    _isAdmin = false;
    notifyListeners();
  }
}
