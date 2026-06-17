import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Gestion de l'authentification client sur le web.
/// Singleton ChangeNotifier pour que go_router réagisse aux changements.
class WebClientAuth extends ChangeNotifier {
  static final WebClientAuth instance = WebClientAuth._();
  WebClientAuth._() {
    FirebaseAuth.instance.authStateChanges().listen((user) {
      _user = user;
      _isClient = false;
      if (user != null && !user.isAnonymous) {
        _checkClient(user.uid);
      } else {
        notifyListeners();
      }
    });
  }

  User?   _user;
  bool    _isClient = false;
  String? _clientName;
  int     _wallet   = 0;

  User?   get user       => _user;
  bool    get isLoggedIn => _user != null && !(_user!.isAnonymous);
  bool    get isClient   => _isClient;
  String  get clientName => _clientName ?? '';
  int     get wallet     => _wallet;

  Future<void> _checkClient(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('clients').doc(uid).get();
      if (doc.exists) {
        _isClient   = true;
        _clientName = doc.data()?['name'] ?? '';
        _wallet     = (doc.data()?['wallet'] as num? ?? 0).toInt();
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> reload() async {
    if (_user != null && !_user!.isAnonymous) {
      await _checkClient(_user!.uid);
    }
  }

  Future<String?> login(String phone, String password) async {
    try {
      final email = '${phone.replaceAll(' ', '')}@azexpress.ci';
      await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email, password: password);
      return null;
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'user-not-found':
        case 'wrong-password':
        case 'invalid-credential': return 'Numéro ou mot de passe incorrect';
        case 'too-many-requests':  return 'Trop de tentatives, réessayez plus tard';
        default:                   return 'Erreur de connexion';
      }
    }
  }

  Future<String?> register(String name, String phone, String password) async {
    try {
      final email = '${phone.replaceAll(' ', '')}@azexpress.ci';
      final cred  = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email, password: password);
      await FirebaseFirestore.instance.collection('clients').doc(cred.user!.uid).set({
        'name':                 name,
        'phone':                phone,
        'wallet':               0,
        'cashOnDeliveryEnabled': true,
        'fakeOrderCount':       0,
        'createdAt':            DateTime.now(),
      });
      return null;
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'email-already-in-use': return 'Un compte existe déjà avec ce numéro';
        case 'weak-password':        return 'Mot de passe trop court (min 6 car.)';
        default:                     return 'Erreur lors de la création du compte';
      }
    }
  }

  Future<void> logout() async {
    await FirebaseAuth.instance.signOut();
    _isClient   = false;
    _clientName = null;
    _wallet     = 0;
    notifyListeners();
  }
}
