import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../screens/admin/admin_mfa_security.dart';
import '../services/auth_service.dart';
import '../services/email_verification_resend_guard.dart';

enum WebAdminMfaState { idle, sending, codeSent, verifying }

class WebAdminAuthResult {
  final bool success;
  final bool challengeRequired;
  final String? error;
  final bool emailVerificationRequired;

  const WebAdminAuthResult._({
    required this.success,
    required this.challengeRequired,
    this.error,
    this.emailVerificationRequired = false,
  });

  const WebAdminAuthResult.success()
      : this._(success: true, challengeRequired: false);
  const WebAdminAuthResult.challenge()
      : this._(success: false, challengeRequired: true);
  const WebAdminAuthResult.failure(
    String message, {
    bool emailVerificationRequired = false,
  }) : this._(
          success: false,
          challengeRequired: false,
          error: message,
          emailVerificationRequired: emailVerificationRequired,
        );
}

class AdminAuthService extends ChangeNotifier {
  static final instance = AdminAuthService._();
  AdminAuthService._() {
    FirebaseAuth.instance.authStateChanges().listen(_restoreSession);
  }

  bool _isAdmin = false;
  bool get isAdmin => _isAdmin;
  WebAdminMfaState _mfaState = WebAdminMfaState.idle;
  WebAdminMfaState get mfaState => _mfaState;
  String? _verificationId;
  int? _resendToken;
  MultiFactorResolver? _resolver;
  MultiFactorSession? _enrollmentSession;
  String? _enrollmentUid;
  String? _enrollmentPhone;
  PhoneMultiFactorInfo? _phoneHint;
  String get maskedPhone =>
      _maskPhone(_phoneHint?.phoneNumber ?? _enrollmentPhone ?? 'numéro Admin');
  final _verificationGuard = EmailVerificationResendGuard();

  Duration get verificationEmailResendRemaining =>
      _verificationGuard.remaining();

  Future<void> _restoreSession(User? user) async {
    if (user == null) {
      _isAdmin = false;
      notifyListeners();
      return;
    }
    // Un compte sans facteur enrôlé ne peut jamais être restauré comme
    // session Admin Web authentifiée.
    if ((await user.multiFactor.getEnrolledFactors()).isEmpty) {
      _isAdmin = false;
      notifyListeners();
      return;
    }
    _isAdmin = await _validateRole(user);
    if (!_isAdmin) await FirebaseAuth.instance.signOut();
    notifyListeners();
  }

  Future<WebAdminAuthResult> signIn(String email, String password) async {
    _resetChallenge();
    try {
      final credential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);
      final user = credential.user!;
      final admin = await _adminData(user.uid);
      final access = validateAdminRecord(admin);
      if (!access.allowed) {
        await FirebaseAuth.instance.signOut();
        return const WebAdminAuthResult.failure(
            'Accès refusé. Compte Admin invalide ou désactivé.');
      }
      if (!user.emailVerified) {
        await FirebaseAuth.instance.signOut();
        return const WebAdminAuthResult.failure(
          'Vérifiez votre adresse email avant la 2FA Admin.',
          emailVerificationRequired: true,
        );
      }
      final phone = admin?['phone'] as String?;
      if (phone == null || phone.isEmpty) {
        await FirebaseAuth.instance.signOut();
        return const WebAdminAuthResult.failure(
            '2FA obligatoire : aucun téléphone Admin configuré.');
      }
      _enrollmentUid = user.uid;
      _enrollmentPhone = phone;
      _enrollmentSession = await user.multiFactor.getSession();
      return _sendChallenge();
    } on FirebaseAuthMultiFactorException catch (error) {
      _resolver = error.resolver;
      final hints = error.resolver.hints.whereType<PhoneMultiFactorInfo>();
      if (hints.isEmpty) {
        return const WebAdminAuthResult.failure(
            'Aucun facteur SMS Admin enrôlé.');
      }
      _phoneHint = hints.first;
      return _sendChallenge();
    } on FirebaseAuthException catch (error) {
      return WebAdminAuthResult.failure(_loginMessage(error.code));
    } catch (_) {
      return const WebAdminAuthResult.failure(
          'Impossible de démarrer la double authentification.');
    }
  }

  Future<WebAdminAuthResult> resendChallenge() => _sendChallenge(resend: true);

  Future<String?> resendVerificationEmail(String email, String password) async {
    if (!_verificationGuard.canSend()) {
      final seconds =
          (_verificationGuard.remaining().inMilliseconds / 1000).ceil();
      return 'Attendez encore ${seconds}s avant un nouvel envoi.';
    }
    try {
      final credential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);
      final user = credential.user;
      if (user == null || user.emailVerified) {
        return 'Cette adresse email est déjà vérifiée.';
      }
      await user.sendEmailVerification();
      _verificationGuard.markSent();
      return null;
    } on FirebaseAuthException catch (error) {
      return error.code == 'too-many-requests'
          ? 'Trop de demandes. Réessayez plus tard.'
          : 'Impossible d’envoyer l’email de vérification.';
    } finally {
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {}
    }
  }

  Future<WebAdminAuthResult> _sendChallenge({bool resend = false}) async {
    _mfaState = WebAdminMfaState.sending;
    notifyListeners();
    final completer = Completer<WebAdminAuthResult>();
    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: _resolver == null ? _enrollmentPhone : null,
        multiFactorSession: _resolver?.session ?? _enrollmentSession,
        multiFactorInfo: _phoneHint,
        forceResendingToken: resend ? _resendToken : null,
        verificationCompleted: (credential) async {
          final result = await _complete(credential);
          if (!completer.isCompleted) completer.complete(result);
        },
        verificationFailed: (error) {
          _mfaState = WebAdminMfaState.idle;
          notifyListeners();
          if (!completer.isCompleted) {
            completer.complete(
                WebAdminAuthResult.failure(adminMfaErrorMessage(error.code)));
          }
        },
        codeSent: (verificationId, resendToken) {
          _verificationId = verificationId;
          _resendToken = resendToken;
          _mfaState = WebAdminMfaState.codeSent;
          notifyListeners();
          if (!completer.isCompleted) {
            completer.complete(const WebAdminAuthResult.challenge());
          }
        },
        codeAutoRetrievalTimeout: (verificationId) {
          _verificationId ??= verificationId;
        },
      );
      return completer.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => const WebAdminAuthResult.failure(
            'Le challenge MFA a expiré avant l’envoi.'),
      );
    } on FirebaseAuthException catch (error) {
      _mfaState = WebAdminMfaState.idle;
      notifyListeners();
      return WebAdminAuthResult.failure(adminMfaErrorMessage(error.code));
    }
  }

  Future<WebAdminAuthResult> verifyCode(String code) async {
    final verificationId = _verificationId;
    if (verificationId == null || code.length != 6) {
      return const WebAdminAuthResult.failure(
          'Entrez le code SMS à 6 chiffres.');
    }
    return _complete(PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: code,
    ));
  }

  Future<WebAdminAuthResult> _complete(PhoneAuthCredential credential) async {
    if (_mfaState == WebAdminMfaState.verifying) {
      return const WebAdminAuthResult.failure('Validation déjà en cours.');
    }
    _mfaState = WebAdminMfaState.verifying;
    notifyListeners();
    try {
      User user;
      if (_resolver != null) {
        final result = await _resolver!.resolveSignIn(
          PhoneMultiFactorGenerator.getAssertion(credential),
        );
        user = result.user!;
      } else {
        final current = FirebaseAuth.instance.currentUser;
        if (current == null || current.uid != _enrollmentUid) {
          throw FirebaseAuthException(code: 'user-mismatch');
        }
        await current.multiFactor.enroll(
          PhoneMultiFactorGenerator.getAssertion(credential),
          displayName: 'Téléphone Admin AZ Express',
        );
        user = current;
      }
      await user.reload();
      await user.getIdToken(true);
      if (!await _validateRole(user)) {
        await FirebaseAuth.instance.signOut();
        throw FirebaseAuthException(code: 'admin-role-rejected');
      }
      _isAdmin = true;
      _mfaState = WebAdminMfaState.idle;
      unawaited(AuthService().logAuthEvent('login', 'admin'));
      notifyListeners();
      return const WebAdminAuthResult.success();
    } on FirebaseAuthException catch (error) {
      _mfaState = WebAdminMfaState.codeSent;
      notifyListeners();
      return WebAdminAuthResult.failure(adminMfaErrorMessage(error.code));
    }
  }

  Future<Map<String, dynamic>?> _adminData(String uid) async =>
      (await FirebaseFirestore.instance.collection('admins').doc(uid).get())
          .data();

  Future<bool> _validateRole(User user) async =>
      validateAdminRecord(await _adminData(user.uid)).allowed;

  Future<void> cancelMfa() async {
    _resetChallenge();
    await FirebaseAuth.instance.signOut();
    _isAdmin = false;
    notifyListeners();
  }

  Future<void> signOut() async {
    unawaited(AuthService().logAuthEvent('logout', 'admin'));
    await FirebaseAuth.instance.signOut();
    _resetChallenge();
    _isAdmin = false;
    notifyListeners();
  }

  void _resetChallenge() {
    _resolver = null;
    _enrollmentSession = null;
    _enrollmentUid = null;
    _enrollmentPhone = null;
    _phoneHint = null;
    _verificationId = null;
    _resendToken = null;
    _mfaState = WebAdminMfaState.idle;
  }

  String _loginMessage(String code) => switch (code) {
        'user-not-found' ||
        'wrong-password' ||
        'invalid-credential' =>
          'Identifiant ou mot de passe incorrect.',
        'too-many-requests' => 'Trop de tentatives. Réessayez plus tard.',
        _ => 'Erreur Firebase : $code',
      };

  String _maskPhone(String phone) {
    if (phone.length <= 4) return '***';
    return '${phone.substring(0, 3)}•••${phone.substring(phone.length - 2)}';
  }
}
