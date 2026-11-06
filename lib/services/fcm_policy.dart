import 'firebase_emulator_config.dart';

/// Désactivation locale des notifications push (FCM) pour les builds de TEST (Mission 7E-55).
///
/// Pourquoi : un jeton FCM écrit sur un compte fictif (`clients/t7e-client`) est un destinataire potentiel et casse la
/// conservation du lot de test. Avec `--dart-define=DISABLE_FCM=true`, l'application ne demande aucun jeton, n'en écrit
/// aucun, n'écoute ni les messages ni le renouvellement du jeton. Sans ce define (production, builds ordinaires),
/// le comportement est strictement inchangé.
class FcmPolicy {
  FcmPolicy._();

  static const bool disabled = bool.fromEnvironment('DISABLE_FCM');

  /// Vrai si l'application peut enregistrer un jeton et écouter FCM. Pure : testable sans Firebase.
  static bool allowsRegistration({
    bool emulators = FirebaseEmulatorConfig.enabled,
    bool disable = disabled,
  }) =>
      !emulators && !disable;
}
