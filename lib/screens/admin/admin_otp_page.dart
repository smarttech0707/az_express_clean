import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/notification_service.dart';
import '../../theme/app_theme.dart';
import 'admin_dashboard.dart';
import 'admin_mfa_security.dart';

enum AdminMfaMode { signIn, enrollment }

@visibleForTesting
class AdminEnrollmentSecret {
  String? _password;

  AdminEnrollmentSecret(String password) : _password = password;

  bool get isAvailable => _password?.isNotEmpty == true;

  String? consume() {
    final password = _password;
    _password = null;
    return password;
  }

  void clear() => _password = null;
}

@visibleForTesting
Future<T> prepareAdminEnrollmentSession<T>({
  required AdminEnrollmentSecret? secret,
  required Future<void> Function(String password) reauthenticate,
  required Future<T> Function() getSession,
}) async {
  final password = secret?.consume();
  if (password == null || password.isEmpty) {
    throw FirebaseAuthException(code: 'missing-enrollment-password');
  }
  await reauthenticate(password);
  return getSession();
}

@visibleForTesting
String adminOtpErrorMessage(String code) => switch (code) {
      'requires-recent-login' =>
        'Votre session n’est plus assez récente. Reconnectez-vous avec votre mot de passe pour recommencer l’inscription 2FA.',
      'missing-enrollment-password' =>
        'Le mot de passe n’est plus disponible. Reconnectez-vous pour recommencer l’inscription 2FA.',
      'session-expired' =>
        'Le code SMS a expiré. Recommencez la connexion admin pour recevoir un nouveau code.',
      _ => adminMfaErrorMessage(code),
    };

/// Résout exclusivement un vrai challenge Firebase MFA. En mode enrollment,
/// le compte Admin existant est enrôlé avant tout accès au tableau de bord.
class AdminOtpPage extends StatefulWidget {
  final AdminMfaMode mode;
  final MultiFactorResolver? resolver;
  final String? adminUid;
  final String? adminPhone;
  final AdminEnrollmentSecret? enrollmentSecret;

  const AdminOtpPage.signIn({super.key, required this.resolver})
      : mode = AdminMfaMode.signIn,
        adminUid = null,
        adminPhone = null,
        enrollmentSecret = null;

  const AdminOtpPage.enrollment({
    super.key,
    required this.adminUid,
    required this.adminPhone,
    required this.enrollmentSecret,
  })  : mode = AdminMfaMode.enrollment,
        resolver = null;

  @override
  State<AdminOtpPage> createState() => _AdminOtpPageState();
}

class _AdminOtpPageState extends State<AdminOtpPage> {
  final _controllers = List.generate(6, (_) => TextEditingController());
  final _focusNodes = List.generate(6, (_) => FocusNode());
  String? _verificationId;
  int? _resendToken;
  PhoneMultiFactorInfo? _phoneHint;
  MultiFactorSession? _enrollmentSession;
  Timer? _countdownTimer;
  Timer? _sendTimeout;
  int _countdown = 60;
  bool _sending = false;
  bool _verifying = false;
  bool _sendFailed = false;
  bool _completed = false;
  final _navigationGuard = SingleNavigationGuard();

  String get _phoneLabel =>
      _phoneHint?.phoneNumber ?? widget.adminPhone ?? 'numéro enregistré';
  String get _code => _controllers.map((controller) => controller.text).join();
  bool get _canResend => _countdown <= 0 && !_sending && !_verifying;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareChallenge());
  }

  Future<void> _prepareChallenge({bool resend = false}) async {
    if (_sending || _verifying || _completed) return;
    setState(() {
      _sending = true;
      _sendFailed = false;
    });
    debugPrint('[ADMIN_MFA] challenge commencé mode=${widget.mode.name}');
    try {
      MultiFactorSession session;
      PhoneMultiFactorInfo? hint;
      String? phoneNumber;
      if (widget.mode == AdminMfaMode.signIn) {
        final resolver = widget.resolver!;
        final phoneHints = resolver.hints.whereType<PhoneMultiFactorInfo>();
        if (phoneHints.isEmpty) {
          throw FirebaseAuthException(
            code: 'unsupported-second-factor',
            message: 'Aucun second facteur SMS n’est enrôlé.',
          );
        }
        hint = phoneHints.first;
        _phoneHint = hint;
        session = resolver.session;
      } else {
        final user = FirebaseAuth.instance.currentUser;
        if (user == null || user.uid != widget.adminUid) {
          throw FirebaseAuthException(code: 'user-mismatch');
        }
        _enrollmentSession ??= await prepareAdminEnrollmentSession(
          secret: widget.enrollmentSecret,
          reauthenticate: (password) async {
            final email = user.email;
            if (email == null || email.isEmpty) {
              throw FirebaseAuthException(code: 'user-mismatch');
            }
            await user.reauthenticateWithCredential(
              EmailAuthProvider.credential(email: email, password: password),
            );
          },
          getSession: user.multiFactor.getSession,
        );
        session = _enrollmentSession!;
        phoneNumber = widget.adminPhone;
      }

      _sendTimeout?.cancel();
      _sendTimeout = Timer(const Duration(seconds: 30), () {
        if (!mounted || _verificationId != null) return;
        setState(() {
          _sending = false;
          _sendFailed = true;
        });
        _snack('Le challenge SMS a expiré avant son envoi.', Colors.orange);
      });

      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        multiFactorSession: session,
        multiFactorInfo: hint,
        forceResendingToken: resend ? _resendToken : null,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (credential) => _completeWith(credential),
        verificationFailed: _onVerificationFailed,
        codeSent: (verificationId, resendToken) {
          if (!mounted || _completed) return;
          _sendTimeout?.cancel();
          debugPrint('[ADMIN_MFA] challenge créé mode=${widget.mode.name}');
          setState(() {
            _verificationId = verificationId;
            _resendToken = resendToken;
            _sending = false;
            _sendFailed = false;
          });
          _startCountdown();
        },
        codeAutoRetrievalTimeout: (verificationId) {
          _verificationId ??= verificationId;
        },
      );
    } on FirebaseAuthException catch (e) {
      _onVerificationFailed(e);
    } catch (e, stackTrace) {
      debugPrint('[ADMIN_MFA] création challenge échouée '
          'type=${e.runtimeType} exception=$e\n$stackTrace');
      if (mounted) {
        setState(() {
          _sending = false;
          _sendFailed = true;
        });
        _snack('Impossible de créer le challenge 2FA.', Colors.red);
      }
    }
  }

  void _onVerificationFailed(FirebaseAuthException error) {
    _sendTimeout?.cancel();
    final stackTrace = StackTrace.current;
    debugPrint('[ADMIN_MFA] challenge refusé code=${error.code} '
        'message=${error.message} exception=$error\n$stackTrace');
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sendFailed = true;
    });
    _snack(_messageFor(error), Colors.red);
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    setState(() => _countdown = 60);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _countdown--);
      if (_countdown <= 0) timer.cancel();
    });
  }

  Future<void> _verify() async {
    if (_code.length != 6) {
      _snack('Entrez les 6 chiffres du code.', Colors.orange);
      return;
    }
    final verificationId = _verificationId;
    if (verificationId == null) {
      _snack('Aucun challenge actif. Renvoyez le code.', Colors.red);
      return;
    }
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: _code,
    );
    await _completeWith(credential);
  }

  Future<void> _completeWith(PhoneAuthCredential credential) async {
    if (_verifying || _completed) return;
    setState(() => _verifying = true);
    try {
      User user;
      if (widget.mode == AdminMfaMode.signIn) {
        final result = await widget.resolver!.resolveSignIn(
          PhoneMultiFactorGenerator.getAssertion(credential),
        );
        user = result.user!;
      } else {
        final current = FirebaseAuth.instance.currentUser;
        if (current == null || current.uid != widget.adminUid) {
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
      final adminDoc = await FirebaseFirestore.instance
          .collection('admins')
          .doc(user.uid)
          .get();
      final data = adminDoc.data();
      final access = validateAdminRecord(data);
      if (!adminDoc.exists || !access.allowed) {
        await FirebaseAuth.instance.signOut();
        throw FirebaseAuthException(code: 'admin-role-rejected');
      }

      _completed = true;
      debugPrint('[ADMIN_MFA] validation réussie uid=${_maskedUid(user.uid)}');
      NotificationService().saveToken(user.uid, 'admins');
      unawaited(AuthService().logAuthEvent('login', 'admin'));
      if (!mounted || !_navigationGuard.acquire()) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => AdminDashboard(
            adminData: <String, dynamic>{'uid': user.uid, ...data!},
          ),
        ),
      );
    } on FirebaseAuthException catch (e, stackTrace) {
      debugPrint('[ADMIN_MFA] echec code=${e.code} message=${e.message} '
          'exception=$e\n$stackTrace');
      _clearCode();
      _snack(_messageFor(e), Colors.red);
    } finally {
      if (mounted && !_completed) setState(() => _verifying = false);
    }
  }

  String _messageFor(FirebaseAuthException error) {
    return adminOtpErrorMessage(error.code);
  }

  void _clearCode() {
    for (final controller in _controllers) {
      controller.clear();
    }
    if (mounted) _focusNodes.first.requestFocus();
  }

  String _maskedUid(String uid) => uid.length <= 6
      ? '***'
      : '${uid.substring(0, 3)}…${uid.substring(uid.length - 3)}';

  void _snack(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }

  void _onDigit(int index, String value) {
    if (value.length == 6) {
      for (var i = 0; i < 6; i++) {
        _controllers[i].text = value[i];
      }
      _verify();
    } else if (value.isNotEmpty && index < 5) {
      _focusNodes[index + 1].requestFocus();
    } else if (value.isNotEmpty) {
      _verify();
    }
  }

  @override
  void dispose() {
    _sendTimeout?.cancel();
    _countdownTimer?.cancel();
    // En mode enrôlement, la première authentification ne doit jamais
    // survivre à l'abandon du second facteur.
    if (!_completed && widget.mode == AdminMfaMode.enrollment) {
      widget.enrollmentSecret?.clear();
      unawaited(FirebaseAuth.instance.signOut());
    }
    for (final controller in _controllers) {
      controller.dispose();
    }
    for (final focusNode in _focusNodes) {
      focusNode.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vérification administrateur'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Icon(Icons.admin_panel_settings,
                  size: 64, color: AppColors.primary),
              const SizedBox(height: 16),
              Text(
                widget.mode == AdminMfaMode.enrollment
                    ? 'Activation obligatoire de la 2FA'
                    : 'Double authentification',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text('Code SMS envoyé au\n$_phoneLabel',
                  textAlign: TextAlign.center),
              const SizedBox(height: 28),
              if (_sending)
                const CircularProgressIndicator(color: AppColors.primary)
              else if (_sendFailed)
                ElevatedButton.icon(
                  onPressed: _prepareChallenge,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Réessayer'),
                )
              else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: List.generate(
                    6,
                    (index) => SizedBox(
                      width: 44,
                      child: TextField(
                        controller: _controllers[index],
                        focusNode: _focusNodes[index],
                        keyboardType: TextInputType.number,
                        maxLength: 1,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(counterText: ''),
                        onChanged: (value) => _onDigit(index, value),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _verifying ? null : _verify,
                    child: _verifying
                        ? const CircularProgressIndicator()
                        : const Text('Valider l’accès'),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed:
                      _canResend ? () => _prepareChallenge(resend: true) : null,
                  child: Text(_canResend
                      ? 'Renvoyer le code'
                      : 'Renvoyer dans $_countdown secondes'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
