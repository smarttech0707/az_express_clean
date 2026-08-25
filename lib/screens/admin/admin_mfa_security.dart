class AdminAccessDecision {
  final bool allowed;
  final String? errorCode;

  const AdminAccessDecision._(this.allowed, this.errorCode);

  const AdminAccessDecision.allowed() : this._(true, null);
  const AdminAccessDecision.rejected(String code) : this._(false, code);
}

AdminAccessDecision validateAdminRecord(Map<String, dynamic>? data) {
  if (data == null) {
    return const AdminAccessDecision.rejected('admin-role-rejected');
  }
  final role = data['role'] as String? ?? 'super';
  if (role != 'super' && role != 'sub') {
    return const AdminAccessDecision.rejected('admin-role-rejected');
  }
  if (role == 'sub' && data['isActive'] == false) {
    return const AdminAccessDecision.rejected('admin-role-rejected');
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
