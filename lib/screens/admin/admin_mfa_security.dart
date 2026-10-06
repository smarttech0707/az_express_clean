class AdminAccessDecision {
  final bool allowed;
  final String? errorCode;

  const AdminAccessDecision._(this.allowed, this.errorCode);

  const AdminAccessDecision.allowed() : this._(true, null);
  const AdminAccessDecision.rejected(String code) : this._(false, code);
}

const adminPermissionKeys = <String>{
  'livreurs',
  'commandes',
  'gains',
  'classement',
  'carte',
  'zones',
  'demandes',
  'restaurants',
  'demandes_resto',
  'demandes_vendeurs',
  'demandes_boulangeries',
  'demandes_pharmacies',
  'pharmacies',
  'boutique',
  'recharges',
  'flottes',
  'locations',
  'residences',
  'services',
  'eventiel',
  'tricycle',
  'sos',
  'anti_fraude',
  'cash_marchand',
  'support',
  'ai_dashboard',
  'boulangeries',
  'ekbine',
  'purger',
};

bool isAdminSessionValid({
  required String? currentUid,
  required bool isAnonymous,
  required String expectedUid,
  required Map<String, dynamic>? adminData,
}) =>
    currentUid == expectedUid &&
    !isAnonymous &&
    validateAdminRecord(adminData).allowed;

AdminAccessDecision validateAdminRecord(Map<String, dynamic>? data) {
  if (data == null) {
    return const AdminAccessDecision.rejected('admin-role-rejected');
  }
  if (data['isActive'] != true) {
    return const AdminAccessDecision.rejected('admin-role-rejected');
  }
  final role = data['role'];
  if (role != 'super' && role != 'sub') {
    return const AdminAccessDecision.rejected('admin-role-rejected');
  }
  if (role == 'sub') {
    final permissions = data['permissions'];
    if (permissions is! List ||
        permissions.any((permission) =>
            permission is! String ||
            !adminPermissionKeys.contains(permission))) {
      return const AdminAccessDecision.rejected('admin-role-rejected');
    }
  }
  return const AdminAccessDecision.allowed();
}

String adminMfaErrorMessage(String code) => switch (code) {
      'user-not-found' ||
      'wrong-password' ||
      'invalid-credential' =>
        'Identifiant ou mot de passe incorrect.',
      'network-request-failed' ||
      'unavailable' =>
        'Connexion réseau indisponible. Vérifiez votre connexion et réessayez.',
      'permission-denied' =>
        'Accès Firestore refusé lors de la vérification Admin. Contactez l’administrateur.',
      'user-token-expired' ||
      'invalid-user-token' ||
      'user-mismatch' =>
        'Session expirée. Recommencez la connexion Admin.',
      'missing-verification-id' => 'Aucun challenge actif. Renvoyez le code.',
      'invalid-verification-code' => 'Code incorrect. Vérifiez et réessayez.',
      'session-expired' => 'Code expiré. Renvoyez un nouveau code.',
      'too-many-requests' => 'Trop de tentatives. Réessayez plus tard.',
      'quota-exceeded' => 'Quota SMS temporairement atteint.',
      'invalid-phone-number' =>
        'Le numéro Admin est invalide. Utilisez un numéro ivoirien valide.',
      'admin-role-rejected' =>
        'Accès refusé : rôle Admin invalide ou désactivé.',
      'unsupported-second-factor' =>
        'Aucun second facteur Admin n’est enrôlé (ni application '
            'd’authentification, ni SMS).',
      'totp-challenge-timeout' =>
        'Le code a expiré. Ouvrez votre application d’authentification et '
            'saisissez le code affiché actuellement.',
      'requires-recent-login' =>
        'Votre session n’est plus assez récente. Reconnectez-vous avec votre '
            'mot de passe pour continuer.',
      'maximum-second-factor-count-exceeded' =>
        'Nombre maximal de seconds facteurs atteint. Supprimez un facteur '
            'existant avant d’en ajouter un autre.',
      'second-factor-already-enrolled' =>
        'Ce second facteur est déjà enrôlé sur ce compte Admin.',
      'app-not-authorized' ||
      'missing-client-identifier' =>
        'Cette version Android n’est pas autorisée pour la vérification SMS.',
      _ => 'Échec de la double authentification ($code).',
    };

/// Seconds facteurs MFA Admin réellement pris en charge par Identity Platform.
///
/// `totp` est volontairement déclaré en premier : c'est l'ordre de préférence
/// appliqué par [resolveAdminSecondFactor], une application d'authentification
/// ne dépendant d'aucun réseau SMS (voir l'incident Error 39).
enum AdminSecondFactor { totp, sms }

/// Facteur déjà enrôlé, décrit SANS type Firebase pour que la sélection reste
/// vérifiable sans Firebase Auth ni appareil réel.
class AdminEnrolledFactor {
  final AdminSecondFactor kind;

  /// `MultiFactorInfo.uid` — requis par `getAssertionForSignIn`.
  final String enrollmentId;

  /// Libellé d'affichage (numéro masqué par Firebase pour le SMS, nom donné à
  /// l'enrôlement pour TOTP). Jamais un secret.
  final String? label;

  const AdminEnrolledFactor({
    required this.kind,
    required this.enrollmentId,
    this.label,
  });
}

/// Décision de second facteur : un facteur unique à utiliser, un choix à
/// présenter, ou un refus explicite.
class AdminFactorResolution {
  final List<AdminEnrolledFactor> available;
  final AdminEnrolledFactor? single;
  final bool requiresChoice;
  final String? errorCode;

  const AdminFactorResolution._({
    required this.available,
    this.single,
    this.requiresChoice = false,
    this.errorCode,
  });

  bool get allowed => errorCode == null;
}

/// Choisit le second facteur à utiliser parmi ceux réellement enrôlés.
///
/// Aucun facteur exploitable renvoie `unsupported-second-factor` — le même code
/// que le flux SMS historique, donc le même message et le même refus d'accès :
/// cette fonction ne crée jamais de chemin vers le tableau de bord.
AdminFactorResolution resolveAdminSecondFactor(
    List<AdminEnrolledFactor> factors) {
  final usable = factors
      .where((factor) => factor.enrollmentId.trim().isNotEmpty)
      .toList()
    // TOTP d'abord : indépendant du réseau SMS.
    ..sort((a, b) => a.kind.index.compareTo(b.kind.index));

  if (usable.isEmpty) {
    return const AdminFactorResolution._(
      available: <AdminEnrolledFactor>[],
      errorCode: 'unsupported-second-factor',
    );
  }
  if (usable.length == 1) {
    return AdminFactorResolution._(available: usable, single: usable.first);
  }
  return AdminFactorResolution._(available: usable, requiresChoice: true);
}

/// Longueur imposée par Identity Platform pour un code TOTP.
const int kAdminTotpCodeLength = 6;

/// Valide le code AVANT tout appel réseau. Retourne `null` si le code est
/// acceptable, sinon un message français affichable tel quel.
///
/// Ne journalise jamais la valeur reçue.
String? validateAdminTotpCode(String raw) {
  final code = raw.trim();
  if (code.isEmpty) {
    return 'Entrez le code à $kAdminTotpCodeLength chiffres affiché par votre '
        'application d’authentification.';
  }
  if (!RegExp(r'^[0-9]+$').hasMatch(code)) {
    return 'Le code ne doit contenir que des chiffres.';
  }
  if (code.length != kAdminTotpCodeLength) {
    return 'Le code doit contenir exactement $kAdminTotpCodeLength chiffres.';
  }
  return null;
}

class SingleNavigationGuard {
  bool _used = false;

  bool acquire() {
    if (_used) return false;
    _used = true;
    return true;
  }
}
