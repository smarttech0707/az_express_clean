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
  final role = data['role'] as String?;
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
      'invalid-verification-code' => 'Code incorrect. Vérifiez et réessayez.',
      'session-expired' => 'Code expiré. Renvoyez un nouveau code.',
      'too-many-requests' => 'Trop de tentatives. Réessayez plus tard.',
      'quota-exceeded' => 'Quota SMS temporairement atteint.',
      'admin-role-rejected' =>
        'Accès refusé : rôle Admin invalide ou désactivé.',
      'unsupported-second-factor' => 'Aucun facteur SMS Admin n’est enrôlé.',
      'app-not-authorized' ||
      'missing-client-identifier' =>
        'Cette version Android n’est pas autorisée pour la vérification SMS.',
      _ => 'Échec de la double authentification ($code).',
    };

class SingleNavigationGuard {
  bool _used = false;

  bool acquire() {
    if (_used) return false;
    _used = true;
    return true;
  }
}
