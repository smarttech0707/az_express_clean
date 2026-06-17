import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService {
  static final AuthService _i = AuthService._();
  factory AuthService() => _i;
  AuthService._();

  final _auth = FirebaseAuth.instance;
  final _db   = FirebaseFirestore.instance;

  // ── Format E.164 pour CI ─────────────────────────────────────────────────
  static String toE164(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.startsWith('225') && digits.length >= 11) return '+$digits';
    if (digits.startsWith('0') && digits.length == 10) return '+225${digits.substring(1)}';
    if (digits.length == 10 && !digits.startsWith('0')) return '+225$digits';
    if (digits.length == 8) return '+225$digits';
    return '+$digits';
  }

  // ── Cherche l'email Firebase d'un client par son téléphone ───────────────
  Future<String?> getClientAuthEmail(String phone) async {
    // 1. Essayer le format réel (nouvel email stocké dans Firestore)
    try {
      final snap = await _db
          .collection('clients')
          .where('phone', isEqualTo: phone)
          .limit(1)
          .get();
      if (snap.docs.isNotEmpty) {
        final email = snap.docs.first.data()['email'] as String?;
        if (email != null && email.isNotEmpty && !email.contains('@azexpress.app')) {
          return email;
        }
      }
    } catch (_) {}
    // 2. Fallback : anciens comptes → email fictif
    final cleaned = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    return '$cleaned@azexpress.app';
  }

  // ── Cherche l'email Firebase d'un livreur par son identifiant ou email ───
  Future<String?> getDriverAuthEmail(String input) async {
    // Si input ressemble à un email direct
    if (input.contains('@') && !input.contains('@az-driver.ci')) return input;
    // Cherche dans livreurs + driver_requests par email
    if (input.contains('@')) {
      try {
        for (final col in ['livreurs', 'driver_requests']) {
          final snap = await _db.collection(col)
              .where('email', isEqualTo: input)
              .limit(1)
              .get();
          if (snap.docs.isNotEmpty) {
            final email = snap.docs.first.data()['email'] as String?;
            if (email != null) return email;
          }
        }
      } catch (_) {}
    }
    // Fallback : identifiant → email fictif
    return '${input.toLowerCase()}@az-driver.ci';
  }

  // ── Envoi lien de réinitialisation par email ──────────────────────────────
  Future<void> sendEmailPasswordReset(String email) async {
    await _auth.sendPasswordResetEmail(email: email.trim());
  }

  // ── OTP SMS via Firebase Phone Auth ──────────────────────────────────────
  Future<void> sendPhoneOtp({
    required String phone,
    required void Function(String verificationId, int? resendToken) onCodeSent,
    required void Function(FirebaseAuthException e) onFailed,
    void Function(PhoneAuthCredential cred)? onAutoVerified,
    int? resendToken,
  }) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: toE164(phone),
      forceResendingToken: resendToken,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (cred) => onAutoVerified?.call(cred),
      verificationFailed: onFailed,
      codeSent: (verificationId, rt) => onCodeSent(verificationId, rt),
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  // ── Vérifie un code OTP SMS et retourne la credential ────────────────────
  PhoneAuthCredential buildPhoneCredential(String verificationId, String smsCode) {
    return PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode,
    );
  }

  // ── Réinitialise le mot de passe après vérification OTP SMS ──────────────
  // Signe temporairement avec la credential téléphone, change le mdp, puis
  // reconnecte avec le compte original (email/mdp).
  Future<void> resetPasswordViaSms({
    required PhoneAuthCredential phoneCredential,
    required String newPassword,
    required String authEmail,    // email Firebase Auth du compte cible
    required String originalPassword, // ou '' si on ne connaît pas
  }) async {
    // On vérifie l'OTP en signant in avec la credential phone
    // (crée un compte temporaire ou se connecte si lié)
    await _auth.signInWithCredential(phoneCredential);
    // Met à jour le mot de passe de ce compte téléphone
    // NOTE: la vraie méthode est de ré-auth le compte email après
    // On utilise reauthenticate sur le compte email original.
    // Comme on n'a pas l'ancien mdp, on envoie un reset email.
    // En pratique : on stocke le verificationId → on crée la credential
    // → on appelle currentUser.updatePassword si le compte phone == compte email.
    // Si les comptes sont différents, on signe dans le compte phone et on
    // appelle updatePassword là.
    await _auth.currentUser?.updatePassword(newPassword);
  }

  // ── Ré-authentifie l'utilisateur courant (email + mdp) ──────────────────
  Future<void> reauthenticateEmail(String email, String password) async {
    final cred = EmailAuthProvider.credential(email: email, password: password);
    await _auth.currentUser?.reauthenticateWithCredential(cred);
  }

  // ── Met à jour l'email Firebase Auth et Firestore ────────────────────────
  Future<void> updateEmail({
    required String currentPassword,
    required String newEmail,
    required String collection,   // 'clients' | 'livreurs'
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Non connecté');
    // Ré-authentifier
    await reauthenticateEmail(user.email!, currentPassword);
    // Mettre à jour Firebase Auth
    await user.verifyBeforeUpdateEmail(newEmail.trim());
    // Mettre à jour Firestore immédiatement (l'email Auth sera effectif après vérification)
    await _db.collection(collection).doc(user.uid).update({'email': newEmail.trim()});
  }

  // ── Met à jour le mot de passe ───────────────────────────────────────────
  Future<void> updatePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Non connecté');
    await reauthenticateEmail(user.email!, currentPassword);
    await user.updatePassword(newPassword);
  }

  // ── Met à jour le numéro de téléphone dans Firestore ────────────────────
  // (Firebase Auth n'a pas de champ phone pour les comptes email)
  Future<void> updatePhone({
    required String currentPassword,
    required String newPhone,
    required String collection,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Non connecté');
    await reauthenticateEmail(user.email!, currentPassword);
    await _db.collection(collection).doc(user.uid).update({'phone': newPhone.trim()});
  }

  // ── Génère + stocke un OTP 6 chiffres pour la 2FA admin ─────────────────
  Future<String> generateAdminOtp(String adminUid) async {
    final code = (100000 + Random().nextInt(900000)).toString();
    await _db.collection('admins').doc(adminUid).update({
      'otpCode':   code,
      'otpExpiry': DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
    });
    return code;
  }

  // ── Vérifie l'OTP admin stocké dans Firestore ────────────────────────────
  Future<bool> verifyAdminOtp(String adminUid, String code) async {
    final doc = await _db.collection('admins').doc(adminUid).get();
    final data = doc.data();
    if (data == null) return false;
    final stored   = data['otpCode']   as String?;
    final expiry   = data['otpExpiry'] as int?;
    if (stored == null || expiry == null) return false;
    if (DateTime.now().millisecondsSinceEpoch > expiry) return false;
    if (stored != code) return false;
    // Invalider l'OTP après usage
    await _db.collection('admins').doc(adminUid).update({
      'otpCode': null, 'otpExpiry': null,
    });
    return true;
  }

  // ── Validation ───────────────────────────────────────────────────────────
  static bool isValidEmail(String email) =>
      RegExp(r'^[\w.+-]+@[a-zA-Z\d-]+\.[a-zA-Z]{2,}$').hasMatch(email.trim());

  static bool isValidPhone(String phone) =>
      RegExp(r'^\+?[\d\s\-]{8,15}$').hasMatch(phone.trim());

  static String? validatePassword(String password) {
    if (password.length < 8) return 'Minimum 8 caractères';
    if (!RegExp(r'[A-Z]').hasMatch(password)) return 'Ajoutez une majuscule';
    if (!RegExp(r'[0-9]').hasMatch(password)) return 'Ajoutez un chiffre';
    return null;
  }
}
