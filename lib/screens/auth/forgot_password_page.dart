import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/auth_service.dart';
import 'otp_verify_page.dart';
import '../../theme/app_theme.dart';
import '../../widgets/password_reset_email_guidance.dart';

/// Rôles qui passent par cet écran. Tous les deux disposent d'une adresse
/// e-mail RÉELLE, validée à l'inscription — contrairement aux partenaires
/// (vendeur/restaurant/boulangerie/flotte), dont l'e-mail Firebase Auth est
/// technique (`07…@az-seller.ci`) et donc non délivrable.
enum AccountRecoveryRole { client, driver }

/// Le canal SMS est-il proposé pour ce rôle ?
///
/// Il est masqué pour le livreur : le chemin SMS aboutit à
/// `ResetPasswordPage`, qui appelle `resetAccountPassword` avec
/// `userType: 'client'` CODÉ EN DUR (reset_password_page.dart). La
/// réinitialisation viserait donc la collection `clients`, jamais `livreurs` —
/// et `resetAccountPassword` n'a de toute façon aucune entrée `livreur` dans sa
/// table de collections côté Cloud Function. Corriger cela proprement exige de
/// modifier `functions/passwordReset.js`, hors du périmètre de ce correctif
/// Flutter : on évite donc d'engager le livreur dans un flux trompeur plutôt
/// que de le laisser réinitialiser le mauvais compte.
@visibleForTesting
bool smsRecoveryAvailable(AccountRecoveryRole role) =>
    role == AccountRecoveryRole.client;

/// Avertissement affiché quand le canal SMS reste proposé : Firebase Phone Auth
/// est actuellement en échec côté projet (`INTERNAL (13) / Error code: 39`),
/// alors que le lien e-mail passe par un autre service et fonctionne.
const String kSmsRecoveryWarning =
    'Le SMS peut être indisponible actuellement. Utilisez le lien par e-mail '
    'si possible.';

class ForgotPasswordPage extends StatefulWidget {
  final String? prefillPhone;
  final AccountRecoveryRole role;
  const ForgotPasswordPage({
    super.key,
    this.prefillPhone,
    this.role = AccountRecoveryRole.client,
  });

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  // E-mail par défaut : c'est le seul canal de récupération réellement
  // fonctionnel aujourd'hui pour ces deux rôles (voir kSmsRecoveryWarning).
  bool _bySms = false;
  bool _loading = false;

  bool get _smsAvailable => smsRecoveryAvailable(widget.role);

  @override
  void initState() {
    super.initState();
    if (widget.prefillPhone != null) {
      _phoneCtrl.text = widget.prefillPhone!;
    }
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  Future<void> _submitEmail() async {
    final email = _emailCtrl.text.trim();
    if (!AuthService.isValidEmail(email)) {
      _snack('Adresse email invalide', Colors.orange);
      return;
    }
    setState(() => _loading = true);
    try {
      await sendResetEmailAndShowGuidance(
        context: context,
        sendEmail: () => AuthService().sendEmailPasswordReset(email),
      );
      if (!mounted) return;
      Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      _snack(
          e.code == 'user-not-found'
              ? 'Aucun compte trouvé avec cet email'
              : 'Erreur : ${e.message}',
          Colors.red);
    } catch (_) {
      _snack('Erreur. Vérifiez votre connexion.', Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitSms() async {
    // Défense en profondeur : même si la carte SMS réapparaissait un jour dans
    // l'interface, un livreur ne doit jamais atteindre un reset qui viserait
    // la collection `clients`.
    if (!_smsAvailable) {
      _snack(
        'La réinitialisation par SMS n’est pas disponible pour ce compte. '
        'Utilisez le lien par e-mail.',
        Colors.orange,
      );
      return;
    }
    final phone = _phoneCtrl.text.trim();
    if (!AuthService.isValidPhone(phone)) {
      _snack('Numéro de téléphone invalide', Colors.orange);
      return;
    }
    setState(() => _loading = true);
    try {
      await AuthService().sendPhoneOtp(
        phone: phone,
        onCodeSent: (verificationId, resendToken) {
          if (!mounted) return;
          setState(() => _loading = false);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => OtpVerifyPage(
                phone: phone,
                verificationId: verificationId,
                resendToken: resendToken,
                mode: OtpMode.resetPassword,
              ),
            ),
          );
        },
        onFailed: (e) {
          if (!mounted) return;
          setState(() => _loading = false);
          _snack(_smsError(e.code), Colors.red);
        },
      );
    } catch (_) {
      if (mounted) setState(() => _loading = false);
      _snack(
          'Impossible d\'envoyer le SMS. Vérifiez votre numéro.', Colors.red);
    }
  }

  String _smsError(String code) {
    switch (code) {
      case 'invalid-phone-number':
        return 'Numéro de téléphone invalide';
      case 'too-many-requests':
        return 'Trop de tentatives. Réessayez plus tard.';
      case 'quota-exceeded':
        return 'Quota SMS dépassé. Utilisez l\'email.';
      default:
        return 'Erreur SMS : $code';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Mot de passe oublié'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primary, Color(0xFFFFB300)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lock_reset, size: 48, color: Colors.white),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Récupération de compte',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        SizedBox(height: 4),
                        Text(
                            'Recevez un lien de réinitialisation\npar e-mail',
                            style:
                                TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            const Text('Choisissez une méthode :',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),

            // Sélecteur SMS / Email — l'e-mail est présenté en premier, et le
            // SMS n'apparaît que pour les rôles où ce canal est exploitable.
            Row(
              children: [
                Expanded(
                    child: _MethodCard(
                  icon: Icons.email_outlined,
                  label: 'Recevoir un lien\npar e-mail',
                  selected: !_bySms,
                  color: const Color(0xFF1E88E5),
                  onTap: () => setState(() => _bySms = false),
                )),
                if (_smsAvailable) ...[
                  const SizedBox(width: 12),
                  Expanded(
                      child: _MethodCard(
                    icon: Icons.sms_outlined,
                    label: 'Recevoir un code\npar SMS',
                    selected: _bySms,
                    color: AppColors.primary,
                    onTap: () => setState(() => _bySms = true),
                  )),
                ],
              ],
            ),

            if (_smsAvailable) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF8E1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFFFE082)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 18, color: Color(0xFFF57F17)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(kSmsRecoveryWarning,
                          style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              Text(
                'La réinitialisation se fait par e-mail pour ce compte.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ],

            const SizedBox(height: 28),

            if (_bySms) ...[
              const Text('Votre numéro de téléphone',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 8),
              TextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  hintText: 'ex: 0701234567 ou +2250701234567',
                  prefixIcon: const Icon(Icons.phone_outlined,
                      color: AppColors.primary),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide:
                        const BorderSide(color: AppColors.primary, width: 2),
                  ),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                ),
              ),
              const SizedBox(height: 8),
              Text('Un code à 6 chiffres sera envoyé par SMS',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ] else ...[
              const Text('Votre adresse email',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 8),
              TextField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: 'exemple@email.com',
                  prefixIcon: const Icon(Icons.email_outlined,
                      color: Color(0xFF1E88E5)),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide:
                        const BorderSide(color: Color(0xFF1E88E5), width: 2),
                  ),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                ),
              ),
              const SizedBox(height: 8),
              Text('Un lien de réinitialisation sera envoyé à cet email',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ],

            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed:
                    _loading ? null : (_bySms ? _submitSms : _submitEmail),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _bySms ? AppColors.primary : const Color(0xFF1E88E5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                child: _loading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5))
                    : Text(
                        _bySms
                            ? 'Envoyer le code SMS'
                            : 'Envoyer le lien email',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold),
                      ),
              ),
            ),

            const SizedBox(height: 20),
            Center(
              child: Text(
                'Vous ne recevez rien ?\nContactez le support AZ Express.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MethodCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  const _MethodCard(
      {required this.icon,
      required this.label,
      required this.selected,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.1) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? color : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: selected ? color : Colors.grey, size: 32),
            const SizedBox(height: 8),
            Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected ? color : Colors.grey.shade600,
                )),
          ],
        ),
      ),
    );
  }
}
