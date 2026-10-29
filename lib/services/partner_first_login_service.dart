import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Revendication posée par le serveur tant que le mot de passe temporaire d'un
/// partenaire (restaurant, vendeur, boulangerie) créé par l'administration n'a
/// pas été remplacé. L'état AUTORITAIRE reste côté serveur
/// (`partner_provisioning/{uid}.mustChangePassword`, illisible et inscriptible
/// uniquement par les Cloud Functions) : cette revendication ne sert qu'à
/// savoir, sans appel réseau supplémentaire, qu'il faut afficher l'écran.
const String kPartnerMustChangeClaim = 'partnerMustChangePassword';

bool claimsRequirePasswordChange(Map<String, dynamic>? claims) =>
    claims != null && claims[kPartnerMustChangeClaim] == true;

/// Politique de mot de passe (identique au serveur) : minimum 8 caractères, au
/// moins une majuscule et un chiffre. Retourne `null` si le mot de passe est
/// acceptable, sinon le message à afficher. Le serveur revalide toujours.
String? validatePartnerPassword(String value, {String? temporaryPassword}) {
  if (value.length < 8) return 'Au moins 8 caractères.';
  if (!RegExp(r'[A-Z]').hasMatch(value)) return 'Au moins une majuscule.';
  if (!RegExp(r'[0-9]').hasMatch(value)) return 'Au moins un chiffre.';
  if (temporaryPassword != null && value == temporaryPassword) {
    return 'Choisissez un mot de passe différent du mot de passe temporaire.';
  }
  return null;
}

/// Erreur affichable à l'utilisateur (jamais de détail technique ni de mot de
/// passe).
class PartnerFirstLoginException implements Exception {
  final String message;
  const PartnerFirstLoginException(this.message);
  @override
  String toString() => message;
}

class PartnerFirstLoginService {
  PartnerFirstLoginService({FirebaseAuth? auth, FirebaseFunctions? functions})
      : _auth = auth,
        _functions = functions;

  final FirebaseAuth? _auth;
  final FirebaseFunctions? _functions;

  FirebaseAuth get auth => _auth ?? FirebaseAuth.instance;
  FirebaseFunctions get functions =>
      _functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1');

  /// Le compte doit-il changer son mot de passe temporaire ?
  ///
  /// Le jeton ne sert qu'à éviter un appel réseau pour les comptes ordinaires
  /// (sans revendication). Dès qu'il affirme « obligatoire », le SERVEUR est
  /// l'autorité : il confirme l'état réel et retire lui-même une
  /// revendication périmée (changement déjà effectué). Toute erreur (réseau,
  /// jeton illisible) lève une exception : l'appelant refuse alors l'accès
  /// (fail-closed), jamais l'inverse.
  Future<bool> mustChangePassword(User user) async {
    final token = await user.getIdTokenResult();
    if (!claimsRequirePasswordChange(token.claims)) return false;
    final result = await functions
        .httpsCallable('completePartnerFirstPasswordChange')
        .call({'statusOnly': true});
    final required = (result.data as Map)['required'] == true;
    if (!required) await user.getIdToken(true); // jeton sans revendication
    return required;
  }

  /// Change le mot de passe temporaire :
  ///  1. ré-authentification avec le mot de passe temporaire (session fraîche,
  ///     exigée par le serveur) ;
  ///  2. le SERVEUR change le mot de passe, révoque les sessions et lève le
  ///     drapeau — jamais le client ;
  ///  3. reconnexion avec le nouveau mot de passe et vérification que la
  ///     revendication a bien disparu du jeton.
  Future<void> changePassword({
    required String email,
    required String temporaryPassword,
    required String newPassword,
  }) async {
    final localError =
        validatePartnerPassword(newPassword, temporaryPassword: temporaryPassword);
    if (localError != null) throw PartnerFirstLoginException(localError);

    try {
      final user = auth.currentUser;
      if (user == null) {
        throw const PartnerFirstLoginException(
            'Session expirée. Reconnectez-vous avec votre mot de passe temporaire.');
      }
      await user.reauthenticateWithCredential(
          EmailAuthProvider.credential(email: email, password: temporaryPassword));
      // Jeton rafraîchi : il porte la nouvelle date d'authentification.
      await auth.currentUser!.getIdToken(true);

      await functions
          .httpsCallable('completePartnerFirstPasswordChange')
          .call({'newPassword': newPassword});
    } on FirebaseAuthException catch (e) {
      throw PartnerFirstLoginException(_authMessage(e));
    } on FirebaseFunctionsException catch (e) {
      throw PartnerFirstLoginException(_functionsMessage(e));
    }

    // Les sessions ont été révoquées par le serveur : nouvelle connexion.
    try {
      final credential = await auth.signInWithEmailAndPassword(
          email: email, password: newPassword);
      final token = await credential.user!.getIdTokenResult(true);
      if (claimsRequirePasswordChange(token.claims)) {
        throw const PartnerFirstLoginException(
            'Le changement n\'a pas pu être confirmé. Réessayez.');
      }
    } on FirebaseAuthException catch (e) {
      throw PartnerFirstLoginException(
          'Mot de passe modifié, mais la reconnexion a échoué (${_authMessage(e)}). '
          'Connectez-vous avec votre NOUVEAU mot de passe.');
    }
  }

  String _authMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'wrong-password':
      case 'invalid-credential':
      case 'invalid-login-credentials':
        return 'Mot de passe temporaire incorrect. Si vous avez déjà choisi '
            'un nouveau mot de passe, connectez-vous avec celui-ci.';
      case 'too-many-requests':
        return 'Trop de tentatives. Réessayez plus tard.';
      case 'network-request-failed':
        return 'Connexion interrompue. Vérifiez votre réseau et réessayez.';
      case 'requires-recent-login':
      case 'user-token-expired':
      case 'user-disabled':
        return 'Session expirée. Reconnectez-vous.';
      default:
        return 'Authentification impossible. Réessayez.';
    }
  }

  String _functionsMessage(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'invalid-argument':
        return e.message ?? 'Mot de passe refusé.';
      case 'resource-exhausted':
        return 'Trop de tentatives. Réessayez dans une heure.';
      case 'unauthenticated':
        return 'Session expirée. Reconnectez-vous avec votre mot de passe '
            'temporaire.';
      case 'failed-precondition':
        return 'Aucun changement requis pour ce compte.';
      case 'unavailable':
      case 'deadline-exceeded':
        return 'Connexion interrompue. Si vous aviez validé, reconnectez-vous '
            'avec votre NOUVEAU mot de passe ; sinon réessayez.';
      default:
        return 'Changement impossible. Réessayez.';
    }
  }
}
