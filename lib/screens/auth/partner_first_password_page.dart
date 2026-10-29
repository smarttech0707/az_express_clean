import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/partner_first_login_service.dart';
import '../../theme/app_theme.dart';

/// Changement OBLIGATOIRE du mot de passe temporaire d'un partenaire créé par
/// l'administration (restaurant, vendeur, boulangerie).
///
/// L'écran ne peut pas être quitté sans réussir ou se déconnecter. Le serveur
/// change lui-même le mot de passe et lève le drapeau : cet écran ne fait que
/// collecter les valeurs et afficher le résultat.
class PartnerFirstPasswordPage extends StatefulWidget {
  const PartnerFirstPasswordPage({
    super.key,
    required this.email,
    this.service,
  });

  final String email;
  final PartnerFirstLoginService? service;

  /// Porte d'accès unique, à appeler avant d'ouvrir un tableau de bord
  /// partenaire (connexion, reprise automatique, autres points d'entrée).
  /// Retourne `true` si l'accès est autorisé.
  ///
  /// Échec fermé : si l'état du compte ne peut pas être lu, l'accès est refusé.
  static Future<bool> ensureActivated(
    BuildContext context,
    User user, {
    PartnerFirstLoginService? service,
  }) async {
    final svc = service ?? PartnerFirstLoginService();
    final bool mustChange;
    try {
      mustChange = await svc.mustChangePassword(user);
    } catch (_) {
      return false;
    }
    if (!mustChange) return true;
    if (!context.mounted) return false;
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PartnerFirstPasswordPage(
          email: user.email ?? '',
          service: svc,
        ),
      ),
    );
    return done == true;
  }

  @override
  State<PartnerFirstPasswordPage> createState() =>
      _PartnerFirstPasswordPageState();
}

class _PartnerFirstPasswordPageState extends State<PartnerFirstPasswordPage> {
  final _temporaryCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _show = false;
  bool _busy = false;
  String? _error;

  PartnerFirstLoginService get _service =>
      widget.service ?? PartnerFirstLoginService();

  @override
  void dispose() {
    _temporaryCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final temporary = _temporaryCtrl.text;
    final newPassword = _newCtrl.text;
    if (temporary.isEmpty) {
      setState(() => _error = 'Saisissez votre mot de passe temporaire.');
      return;
    }
    final policy =
        validatePartnerPassword(newPassword, temporaryPassword: temporary);
    if (policy != null) {
      setState(() => _error = policy);
      return;
    }
    if (newPassword != _confirmCtrl.text) {
      setState(() => _error = 'Les deux mots de passe ne correspondent pas.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _service.changePassword(
        email: widget.email,
        temporaryPassword: temporary,
        newPassword: newPassword,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on PartnerFirstLoginException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Changement impossible. Réessayez.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    if (_busy) return;
    Navigator.pop(context, false);
  }

  Widget _rule(String label, bool ok) => Row(
        children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
              size: 16, color: ok ? AppColors.success : Colors.grey),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final value = _newCtrl.text;
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('Définissez votre mot de passe'),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'Pour la sécurité de votre compte, remplacez le mot de passe '
                'temporaire reçu par un mot de passe personnel. Vous ne '
                'pourrez accéder à votre espace professionnel qu\'après ce '
                'changement.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 20),
              TextField(
                key: const Key('temporaryPassword'),
                controller: _temporaryCtrl,
                obscureText: !_show,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Mot de passe temporaire',
                  prefixIcon: Icon(Icons.lock_clock_rounded),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('newPassword'),
                controller: _newCtrl,
                obscureText: !_show,
                enabled: !_busy,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Nouveau mot de passe',
                  prefixIcon: const Icon(Icons.lock_rounded),
                  suffixIcon: IconButton(
                    tooltip: _show ? 'Masquer' : 'Afficher',
                    icon: Icon(_show
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _rule('Au moins 8 caractères', value.length >= 8),
              _rule('Une majuscule', RegExp(r'[A-Z]').hasMatch(value)),
              _rule('Un chiffre', RegExp(r'[0-9]').hasMatch(value)),
              const SizedBox(height: 14),
              TextField(
                key: const Key('confirmPassword'),
                controller: _confirmCtrl,
                obscureText: !_show,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Confirmer le nouveau mot de passe',
                  prefixIcon: Icon(Icons.lock_outline_rounded),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Semantics(
                  liveRegion: true,
                  child: Text(_error!,
                      key: const Key('firstLoginError'),
                      style: const TextStyle(color: AppColors.error)),
                ),
              ],
              const SizedBox(height: 22),
              ElevatedButton(
                key: const Key('submitFirstPassword'),
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Enregistrer et continuer'),
              ),
              TextButton(
                onPressed: _busy ? null : _signOut,
                child: const Text('Se déconnecter'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
