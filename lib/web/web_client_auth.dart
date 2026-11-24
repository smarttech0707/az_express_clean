import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/auth_service.dart';

/// Gestion de l'authentification client sur le web.
/// Singleton ChangeNotifier pour que go_router réagisse aux changements.
class WebClientAuth extends ChangeNotifier {
  static final WebClientAuth instance = WebClientAuth._();
  WebClientAuth._() {
    // Même raison que dans AdminAuthService : ce singleton est construit par
    // `webRouter` dès le premier rendu. Sans Firebase, `FirebaseAuth.instance`
    // lèverait pendant le build du routeur et le site resterait vide.
    try {
      FirebaseAuth.instance.authStateChanges().listen((user) {
        _user = user;
        _isClient = false;
        if (user != null && !user.isAnonymous) {
          _checkClient(user.uid);
        } else {
          notifyListeners();
        }
      });
    } catch (e) {
      debugPrint('WebClientAuth : authentification indisponible ($e)');
    }
  }

  User? _user;
  bool _isClient = false;
  String? _clientName;
  int _wallet = 0;

  User? get user => _user;
  bool get isLoggedIn => _user != null && !(_user!.isAnonymous);
  bool get isClient => _isClient;
  String get clientName => _clientName ?? '';
  int get wallet => _wallet;

  Future<void> _checkClient(String uid) async {
    try {
      final doc =
          await FirebaseFirestore.instance.collection('clients').doc(uid).get();
      if (doc.exists) {
        _isClient = true;
        _clientName = doc.data()?['name'] ?? '';
        _wallet = (doc.data()?['wallet'] as num? ?? 0).toInt();
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> reload() async {
    if (_user != null && !_user!.isAnonymous) {
      await _checkClient(_user!.uid);
    }
  }

  /// Domaine de l'email TECHNIQUE des comptes clients créés par le site web.
  ///
  /// Les clients n'ont pas de vraie adresse email côté web : `register()`
  /// fabrique `<téléphone sans espaces>@azexpress.ci` et crée le compte
  /// Firebase avec. Cette valeur détermine donc l'identité Firebase de tous
  /// les comptes existants — ne jamais la changer sans migration.
  static const _webTechnicalDomain = '@azexpress.ci';

  /// Email technique d'un numéro. Utilisé par `register()` ET par `login()`
  /// pour qu'ils ne puissent jamais diverger.
  ///
  /// La normalisation est volontairement limitée à la suppression des espaces,
  /// à l'identique de ce que `register()` a toujours fait : un nettoyage plus
  /// agressif (tirets, points) calculerait un email différent de celui des
  /// comptes déjà créés et les rendrait inaccessibles.
  static String technicalEmailForPhone(String phone) =>
      '${phone.replaceAll(' ', '')}$_webTechnicalDomain';

  /// Détermine l'email Firebase à utiliser pour un identifiant saisi.
  ///
  /// CAUSE DU BUG CORRIGÉ : `login()` ajoutait systématiquement
  /// `@azexpress.ci` à ce que l'utilisateur tapait. Une vraie adresse email
  /// devenait donc `jean@gmail.com@azexpress.ci`, inexistante côté Firebase —
  /// la connexion par email était structurellement impossible, et l'erreur
  /// renvoyée ("Numéro ou mot de passe incorrect") masquait la vraie raison.
  @visibleForTesting
  static String resolveLoginEmail(String identifier) {
    final trimmed = identifier.trim();
    // La présence d'un « @ » est le seul discriminant fiable : aucun numéro de
    // téléphone n'en contient, et c'est le caractère obligatoire d'un email.
    if (trimmed.contains('@')) return trimmed.toLowerCase();
    return technicalEmailForPhone(trimmed);
  }

  /// Connexion client par **email réel OU numéro de téléphone**.
  ///
  /// Une seule tentative d'authentification est effectuée : l'identifiant est
  /// résolu en amont, sans appel réseau supplémentaire ni consommation
  /// inutile du quota anti-abus de Firebase Auth.
  Future<String?> login(String identifier, String password) async {
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: resolveLoginEmail(identifier),
        password: password,
      );
      AuthService().logAuthEvent('login', 'client');
      return null;
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'user-not-found':
        case 'wrong-password':
        case 'invalid-credential':
          return 'Email/numéro ou mot de passe incorrect';
        case 'invalid-email':
          return 'Email ou numéro invalide';
        case 'user-disabled':
          return 'Ce compte a été désactivé';
        case 'too-many-requests':
          return 'Trop de tentatives, réessayez plus tard';
        default:
          return 'Erreur de connexion';
      }
    }
  }

  /// Inscription client — inchangée : le compte reste identifié par son
  /// NUMÉRO, converti en email technique. Rien n'est transformé en inscription
  /// par email.
  Future<String?> register(String name, String phone, String password) async {
    // Garde-fou ajouté avec le support de la connexion par email : désormais
    // que le champ accepte une adresse en mode connexion, un utilisateur peut
    // en saisir une ici par réflexe. Sans ce contrôle, le compte serait créé
    // sous `jean@gmail.com@azexpress.ci` — inutilisable et impossible à
    // retrouver par son numéro.
    if (phone.contains('@')) {
      return 'Entre ton numéro de téléphone, pas une adresse email';
    }
    try {
      // Exactement la même expression qu'auparavant, via le helper partagé :
      // l'email calculé est inchangé pour tous les comptes.
      final email = technicalEmailForPhone(phone);
      final cred = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);
      await FirebaseFirestore.instance
          .collection('clients')
          .doc(cred.user!.uid)
          .set({
        'name': name,
        'phone': phone,
        'wallet': 0,
        'cashOnDeliveryEnabled': true,
        'fakeOrderCount': 0,
        'createdAt': DateTime.now(),
      });
      return null;
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'email-already-in-use':
          return 'Un compte existe déjà avec ce numéro';
        case 'weak-password':
          return 'Mot de passe trop court (min 6 car.)';
        default:
          return 'Erreur lors de la création du compte';
      }
    }
  }

  Future<void> logout() async {
    AuthService().logAuthEvent('logout', 'client');
    await FirebaseAuth.instance.signOut();
    _isClient = false;
    _clientName = null;
    _wallet = 0;
    notifyListeners();
  }
}
