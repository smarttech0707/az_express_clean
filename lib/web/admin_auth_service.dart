import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../screens/admin/admin_mfa_security.dart';
import '../screens/admin/admin_otp_page.dart'
    show
        AdminMfaMode,
        AdminEnrollmentSecret,
        prepareAdminEnrollmentSession,
        adminOtpErrorMessage,
        adminFactorsFromHints,
        normalizeAdminMfaPhone;
import '../services/auth_service.dart';
import '../services/email_verification_resend_guard.dart';

/// États du flux MFA Admin Web.
///
/// `totpAwaitingCode` couvre aussi bien l'enrôlement (secret/QR affichés,
/// premier code attendu) que la connexion (facteur TOTP déjà enrôlé, code
/// courant attendu) : dans les deux cas l'écran attend un code à 6 chiffres
/// sans dépendance réseau SMS.
enum WebAdminMfaState {
  idle,
  choosingFactor,
  totpAwaitingCode,
  smsSending,
  smsCodeSent,
  verifying,
}

/// Restriction temporaire Web (correction P0, audit admin Android/Web) :
/// les règles Firestore des collections affichées par le tableau de bord
/// Web (`sos_alerts`, `driver_applications`, `partner_applications`,
/// `contact_messages`, `event_providers`) exigent `isAdmin()` strict, soit
/// `role == 'super'` (voir `firestore.rules`) — elles n'ont pas d'équivalent
/// `hasAdminPermission()` pour les sous-admins. Tant que ce n'est pas aligné
/// côté règles, un sous-admin ne doit jamais atteindre le tableau de bord
/// Web : il verrait des listes vides ou des erreurs de permission plutôt que
/// ses propres données. N'affecte pas Android, qui n'appelle pas cette
/// fonction. Fonction pure et publique (plutôt que privée) pour rester
/// testable sans Firebase, comme `validateAdminRecord`.
bool isWebSuperAdmin(Map<String, dynamic>? data) => data?['role'] == 'super';

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

/// Authentification administrateur Web, second facteur compris.
///
/// Reprend la politique de sécurité du flux mobile (`admin_login.dart` /
/// `admin_otp_page.dart` / `admin_mfa_security.dart`) sans dupliquer son
/// code d'interface : les mêmes fonctions pures (`resolveAdminSecondFactor`,
/// `adminFactorsFromHints`, `prepareAdminEnrollmentSession`, …) décident ici
/// aussi, un `ChangeNotifier` pilotant une interface Web distincte.
///
/// TOTP est le facteur prioritaire (indépendant du réseau SMS). Un
/// administrateur sans numéro de téléphone peut s'enrôler et se connecter
/// uniquement avec une application d'authentification ; le SMS reste
/// disponible en repli pour les comptes qui ont un numéro enregistré.
class AdminAuthService extends ChangeNotifier {
  static final instance = AdminAuthService._();
  AdminAuthService._() {
    // Ce singleton est construit par `webRouter` (son `refreshListenable`),
    // donc dès le premier rendu du site. Si Firebase n'a pas pu s'initialiser,
    // `FirebaseAuth.instance` lève et l'exception remonte pendant le build du
    // routeur — c'est-à-dire un écran vide, exactement le symptôme qu'on
    // cherche à éliminer. On tolère donc l'absence de Firebase : aucun
    // événement d'authentification n'arrive, `isAdmin` reste false, et les
    // pages publiques s'affichent normalement. Le comportement habituel
    // (Firebase disponible) est inchangé.
    try {
      FirebaseAuth.instance.authStateChanges().listen(_restoreSession);
    } catch (e) {
      debugPrint('AdminAuthService : authentification indisponible ($e)');
    }
  }

  bool _isAdmin = false;
  bool get isAdmin => _isAdmin;
  WebAdminMfaState _mfaState = WebAdminMfaState.idle;
  WebAdminMfaState get mfaState => _mfaState;

  AdminMfaMode? _mode;
  MultiFactorResolver? _resolver;
  AdminFactorResolution? _resolution;
  AdminEnrolledFactor? _selectedFactor;

  MultiFactorSession? _enrollmentSession;
  String? _enrollmentUid;
  String? _enrollmentPhone;

  // Le secret TOTP ne vit qu'en mémoire, le temps de l'enrôlement : jamais en
  // Firestore, jamais en préférences, jamais journalisé.
  TotpSecret? _totpSecret;
  String? _totpQrCodeUrl;

  PhoneMultiFactorInfo? _phoneHint;
  String? _verificationId;
  int? _resendToken;

  final _verificationGuard = EmailVerificationResendGuard();

  /// Facteurs réellement enrôlés, à choisir lorsque plusieurs existent.
  List<AdminEnrolledFactor> get availableFactors =>
      _resolution?.available ?? const <AdminEnrolledFactor>[];
  bool get requiresFactorChoice => _mfaState == WebAdminMfaState.choosingFactor;
  AdminEnrolledFactor? get selectedFactor => _selectedFactor;

  /// Vrai lorsque l'écran doit afficher le flux TOTP (secret/QR à l'enrôlement,
  /// simple champ de code à la connexion).
  bool get isTotpChallenge =>
      _mfaState == WebAdminMfaState.totpAwaitingCode ||
      (_mfaState == WebAdminMfaState.verifying &&
          (_selectedFactor?.kind == AdminSecondFactor.totp ||
              (_mode == AdminMfaMode.enrollment && _totpSecret != null)));

  /// Secret affiché une seule fois pendant l'enrôlement TOTP (jamais après).
  TotpSecret? get totpSecret => _totpSecret;
  String? get totpQrCodeUrl => _totpQrCodeUrl;

  /// Vrai pendant un enrôlement TOTP si un numéro Admin est enregistré : la
  /// bascule SMS reste possible, exactement comme sur mobile.
  bool get smsFallbackAvailable =>
      _mode == AdminMfaMode.enrollment &&
      _totpSecret != null &&
      (_enrollmentPhone?.isNotEmpty == true);

  String get maskedPhone =>
      _maskPhone(_phoneHint?.phoneNumber ?? _enrollmentPhone ?? 'numéro Admin');

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
    if (!_isAdmin) await _safeSignOut();
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
        await _safeSignOut();
        return const WebAdminAuthResult.failure(
            'Accès refusé. Compte Admin invalide ou désactivé.');
      }
      if (!isWebSuperAdmin(admin)) {
        await _safeSignOut();
        return const WebAdminAuthResult.failure(
            'L’administration Web est réservée aux administrateurs principaux '
            '(rôle super) pour le moment. Les sous-administrateurs peuvent '
            'utiliser l’application mobile AZ Express.');
      }
      if (!user.emailVerified) {
        await _safeSignOut();
        return const WebAdminAuthResult.failure(
          'Vérifiez votre adresse email avant la 2FA Admin.',
          emailVerificationRequired: true,
        );
      }
      // `signInWithEmailAndPassword` n'a levé aucune
      // FirebaseAuthMultiFactorException : aucun second facteur n'est encore
      // enrôlé sur ce compte. L'enrôlement devient le seul chemin vers le
      // tableau de bord — il n'exige plus de numéro de téléphone, l'
      // application d'authentification (TOTP) étant désormais le facteur
      // proposé en premier (même politique que `admin_login.dart`).
      _mode = AdminMfaMode.enrollment;
      _enrollmentUid = user.uid;
      _enrollmentPhone = admin?['phone'] as String?;
      return _beginEnrollment(user, password);
    } on FirebaseAuthMultiFactorException catch (error) {
      _mode = AdminMfaMode.signIn;
      _resolver = error.resolver;
      final resolution =
          resolveAdminSecondFactor(adminFactorsFromHints(error.resolver.hints));
      _resolution = resolution;
      if (!resolution.allowed) {
        return const WebAdminAuthResult.failure(
            'Aucun second facteur Admin n’est enrôlé (ni application '
                'd’authentification, ni SMS).');
      }
      if (resolution.requiresChoice) {
        _mfaState = WebAdminMfaState.choosingFactor;
        notifyListeners();
        return const WebAdminAuthResult.challenge();
      }
      return _useFactor(resolution.single!);
    } on FirebaseAuthException catch (error) {
      return WebAdminAuthResult.failure(adminMfaErrorMessage(error.code));
    } catch (_) {
      return const WebAdminAuthResult.failure(
          'Impossible de démarrer la double authentification.');
    }
  }

  /// Choix explicite d'un facteur lorsque plusieurs sont enrôlés (connexion).
  Future<WebAdminAuthResult> selectFactor(AdminEnrolledFactor factor) =>
      _useFactor(factor);

  Future<WebAdminAuthResult> _useFactor(AdminEnrolledFactor factor) async {
    _selectedFactor = factor;
    if (factor.kind == AdminSecondFactor.totp) {
      _mfaState = WebAdminMfaState.totpAwaitingCode;
      notifyListeners();
      return const WebAdminAuthResult.challenge();
    }
    final hints = _resolver!.hints.whereType<PhoneMultiFactorInfo>();
    _phoneHint = hints.firstWhere(
      (candidate) => candidate.uid == factor.enrollmentId,
      orElse: () => hints.first,
    );
    return _sendSmsChallenge();
  }

  Future<WebAdminAuthResult> _beginEnrollment(
      User user, String password) async {
    try {
      _enrollmentSession = await prepareAdminEnrollmentSession(
        secret: AdminEnrollmentSecret(password),
        reauthenticate: (pwd) async {
          final email = user.email;
          if (email == null || email.isEmpty) {
            throw FirebaseAuthException(code: 'user-mismatch');
          }
          await user.reauthenticateWithCredential(
            EmailAuthProvider.credential(email: email, password: pwd),
          );
        },
        getSession: user.multiFactor.getSession,
      );
      _totpSecret =
          await TotpMultiFactorGenerator.generateSecret(_enrollmentSession!);
      _totpQrCodeUrl = await _totpSecret!.generateQrCodeUrl(
        accountName: user.email,
        issuer: 'AZ Express',
      );
      _mfaState = WebAdminMfaState.totpAwaitingCode;
      notifyListeners();
      return const WebAdminAuthResult.challenge();
    } on FirebaseAuthException catch (error) {
      await _safeSignOut();
      _mfaState = WebAdminMfaState.idle;
      notifyListeners();
      return WebAdminAuthResult.failure(adminOtpErrorMessage(error.code));
    } catch (_) {
      await _safeSignOut();
      _mfaState = WebAdminMfaState.idle;
      notifyListeners();
      return const WebAdminAuthResult.failure(
          'Impossible de préparer l’enrôlement 2FA.');
    }
  }

  /// Repli SMS explicite pendant l'enrôlement — le SMS reste pleinement
  /// supporté, il n'est simplement plus le seul chemin possible. Jamais
  /// proposé si aucun numéro Admin n'est enregistré.
  Future<WebAdminAuthResult> useSmsInstead() async {
    if (_mode != AdminMfaMode.enrollment) {
      return const WebAdminAuthResult.failure('Action invalide hors enrôlement.');
    }
    final phone = _enrollmentPhone;
    if (phone == null || phone.isEmpty) {
      return const WebAdminAuthResult.failure(
          'Aucun numéro Admin configuré pour le repli SMS.');
    }
    _totpSecret = null;
    _totpQrCodeUrl = null;
    return _sendSmsChallenge();
  }

  Future<WebAdminAuthResult> resendSmsChallenge() =>
      _sendSmsChallenge(resend: true);

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
      await _safeSignOut();
    }
  }

  Future<WebAdminAuthResult> _sendSmsChallenge({bool resend = false}) async {
    _mfaState = WebAdminMfaState.smsSending;
    notifyListeners();
    final completer = Completer<WebAdminAuthResult>();
    try {
      String? phoneNumber;
      if (_mode == AdminMfaMode.enrollment && _resolver == null) {
        final phone = _enrollmentPhone;
        if (phone == null || phone.isEmpty) {
          throw FirebaseAuthException(code: 'invalid-phone-number');
        }
        phoneNumber = normalizeAdminMfaPhone(phone);
      }
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        multiFactorSession: _resolver?.session ?? _enrollmentSession,
        multiFactorInfo: _phoneHint,
        forceResendingToken: resend ? _resendToken : null,
        verificationCompleted: (credential) async {
          final result = await _completeWithAssertion(
            () async => PhoneMultiFactorGenerator.getAssertion(credential),
            displayName: 'Téléphone Admin AZ Express',
          );
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
          _mfaState = WebAdminMfaState.smsCodeSent;
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

  /// Vérifie un code d'application d'authentification. Le code est validé
  /// localement AVANT tout appel réseau, et n'est jamais journalisé.
  Future<WebAdminAuthResult> verifyTotpCode(String code) async {
    final error = validateAdminTotpCode(code);
    if (error != null) return WebAdminAuthResult.failure(error);
    if (_mode == AdminMfaMode.enrollment) {
      final secret = _totpSecret;
      if (secret == null) {
        return const WebAdminAuthResult.failure(
            'Aucun enrôlement actif. Recommencez la connexion Admin.');
      }
      return _completeWithAssertion(
        () => TotpMultiFactorGenerator.getAssertionForEnrollment(
            secret, code.trim()),
        displayName: 'Authenticator Admin AZ Express',
      );
    }
    final selected = _selectedFactor;
    if (selected == null) {
      return const WebAdminAuthResult.failure('Aucun facteur sélectionné.');
    }
    return _completeWithAssertion(
      () => TotpMultiFactorGenerator.getAssertionForSignIn(
          selected.enrollmentId, code.trim()),
    );
  }

  Future<WebAdminAuthResult> verifySmsCode(String code) async {
    final verificationId = _verificationId;
    if (verificationId == null || code.trim().length != 6) {
      return const WebAdminAuthResult.failure(
          'Entrez le code SMS à 6 chiffres.');
    }
    return _completeWithAssertion(
      () async => PhoneMultiFactorGenerator.getAssertion(
        PhoneAuthProvider.credential(
          verificationId: verificationId,
          smsCode: code.trim(),
        ),
      ),
      displayName: 'Téléphone Admin AZ Express',
    );
  }

  Future<WebAdminAuthResult> _completeWithAssertion(
    Future<MultiFactorAssertion> Function() buildAssertion, {
    String? displayName,
  }) async {
    if (_mfaState == WebAdminMfaState.verifying) {
      return const WebAdminAuthResult.failure('Validation déjà en cours.');
    }
    final previousState = _mfaState;
    _mfaState = WebAdminMfaState.verifying;
    notifyListeners();
    try {
      final assertion = await buildAssertion();
      User user;
      if (_mode == AdminMfaMode.enrollment) {
        final current = FirebaseAuth.instance.currentUser;
        if (current == null || current.uid != _enrollmentUid) {
          throw FirebaseAuthException(code: 'user-mismatch');
        }
        await current.multiFactor.enroll(assertion, displayName: displayName);
        user = current;
      } else {
        final result = await _resolver!.resolveSignIn(assertion);
        user = result.user!;
      }
      await user.reload();
      await user.getIdToken(true);
      if (!await _validateRole(user)) {
        await _safeSignOut();
        throw FirebaseAuthException(code: 'admin-role-rejected');
      }
      _isAdmin = true;
      _mfaState = WebAdminMfaState.idle;
      unawaited(AuthService().logAuthEvent('login', 'admin'));
      _clearSecrets();
      notifyListeners();
      return const WebAdminAuthResult.success();
    } on FirebaseAuthException catch (error) {
      _mfaState = previousState;
      notifyListeners();
      return WebAdminAuthResult.failure(adminOtpErrorMessage(error.code));
    } catch (_) {
      _mfaState = previousState;
      notifyListeners();
      return const WebAdminAuthResult.failure(
          'Échec de la double authentification.');
    }
  }

  Future<Map<String, dynamic>?> _adminData(String uid) async =>
      (await FirebaseFirestore.instance.collection('admins').doc(uid).get())
          .data();

  Future<bool> _validateRole(User user) async {
    final admin = await _adminData(user.uid);
    return validateAdminRecord(admin).allowed && isWebSuperAdmin(admin);
  }

  Future<void> cancelMfa() async {
    _resetChallenge();
    await _safeSignOut();
    _isAdmin = false;
    notifyListeners();
  }

  Future<void> signOut() async {
    unawaited(AuthService().logAuthEvent('logout', 'admin'));
    await _safeSignOut();
    _resetChallenge();
    _isAdmin = false;
    notifyListeners();
  }

  Future<void> _safeSignOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
  }

  void _resetChallenge() {
    _mode = null;
    _resolver = null;
    _resolution = null;
    _selectedFactor = null;
    _enrollmentSession = null;
    _enrollmentUid = null;
    _enrollmentPhone = null;
    _phoneHint = null;
    _totpSecret = null;
    _totpQrCodeUrl = null;
    _verificationId = null;
    _resendToken = null;
    _mfaState = WebAdminMfaState.idle;
  }

  void _clearSecrets() {
    _totpSecret = null;
    _totpQrCodeUrl = null;
  }

  String _maskPhone(String phone) {
    if (phone.length <= 4) return '***';
    return '${phone.substring(0, 3)}•••${phone.substring(phone.length - 2)}';
  }
}
