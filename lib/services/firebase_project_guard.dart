import 'package:firebase_core/firebase_core.dart';

/// Garde de démarrage des builds de TEST (Android préproduction).
///
/// Pourquoi : sur Android, `Firebase.initializeApp(options)` lève `duplicate-app`
/// (toléré) car le plugin natif a DÉJÀ créé l'application par défaut depuis
/// `google-services.json`. Les `--dart-define` de préproduction ne prouvent donc
/// pas à quel projet l'application parle réellement : un `google-services.json`
/// de production embarqué par erreur enverrait toutes les lectures et écritures
/// vers la production. Cette garde lit le projet EFFECTIF.
///
/// Inactive par défaut : sans `--dart-define=AZ_REQUIRED_FIREBASE_PROJECT=...`
/// (builds de production existants), elle ne fait rien et le comportement ne change pas.
class FirebaseProjectGuard {
  FirebaseProjectGuard._();

  static const String requiredProject =
      String.fromEnvironment('AZ_REQUIRED_FIREBASE_PROJECT');

  /// Code affiché et renvoyé comme diagnostic de démarrage.
  static const String blockedCode = 'WRONG_FIREBASE_PROJECT';

  /// Seul projet que cette garde autorise (liste blanche). Aucun identifiant de
  /// production n'est écrit dans le code : tout autre define est refusé, ce qui
  /// couvre aussi la production sans l'embarquer dans l'APK de test.
  static const String allowedProject = 'az-express-preprod';

  static bool get active => requiredProject.isNotEmpty;

  /// `null` si le démarrage peut continuer, sinon [blockedCode].
  /// Pure : testable sans Firebase.
  static String? evaluate({
    required String required,
    required String? effectiveProject,
  }) {
    if (required.isEmpty) return null; // build ordinaire : aucune garde
    if (required != allowedProject) return blockedCode;
    if (effectiveProject == null || effectiveProject.isEmpty) return blockedCode;
    return effectiveProject == required ? null : blockedCode;
  }

  /// Lit le projet de l'application Firebase réellement initialisée.
  /// Si la lecture échoue alors que la garde est active, on bloque (fail-closed).
  static String? check({
    String required = requiredProject,
    String? Function()? readEffectiveProject,
  }) {
    if (required.isEmpty) return null;
    String? effective;
    try {
      effective = (readEffectiveProject ??
          () => Firebase.app().options.projectId)();
    } catch (_) {
      effective = null;
    }
    return evaluate(required: required, effectiveProject: effective);
  }
}
