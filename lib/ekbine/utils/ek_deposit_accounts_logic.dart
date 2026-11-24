import '../models/ek_deposit_account.dart';

/// Logique pure de fusion/validation des numéros de dépôt E-Kbine — extraite
/// de `ek_agent_register.dart`/`ek_deposit_accounts_screen.dart` (qui
/// dupliquaient la même logique) pour qu'elle reste testable sans Firebase
/// ni widgets, même discipline que le reste du projet (ex.
/// `functions/passwordHash.js` extrait pour la même raison côté serveur).
class EkDepositAccountsLogic {
  EkDepositAccountsLogic._();

  /// Fusionne [incoming] dans [current] : remplace la ligne de même id si
  /// elle existe déjà, sinon l'ajoute. Si [incoming] devient principal,
  /// l'ancien principal du même opérateur est automatiquement rétrogradé —
  /// jamais deux principaux actifs simultanés pour un même opérateur
  /// (Mission 1 : "lorsqu'un nouveau numéro devient principal, retirer
  /// automatiquement principal de l'ancien").
  static List<EkDepositAccount> merge(
    List<EkDepositAccount> current,
    EkDepositAccount incoming,
  ) {
    final without = current.where((a) => a.id != incoming.id).toList();
    if (!incoming.isPrimary) return [...without, incoming];
    return [
      ...without.map((a) =>
          a.operator == incoming.operator ? a.copyWith(isPrimary: false) : a),
      incoming,
    ];
  }

  /// Retourne `true` si [incoming] duplique un numéro déjà présent pour le
  /// même opérateur (même numéro normalisé), en excluant la ligne qu'on est
  /// justement en train de modifier (même id).
  static bool isDuplicate(
    List<EkDepositAccount> current,
    EkDepositAccount incoming,
  ) =>
      current.any((a) =>
          a.id != incoming.id &&
          a.operator == incoming.operator &&
          EkDepositAccount.normalizePhone(a.phoneNumber) ==
              EkDepositAccount.normalizePhone(incoming.phoneNumber));

  /// Opérateurs réellement couverts par au moins un numéro actif — jamais
  /// une sélection séparée qui pourrait diverger des lignes réelles.
  static List<String> coveredOperators(List<EkDepositAccount> accounts) =>
      accounts.where((a) => a.isActive).map((a) => a.operator).toSet().toList();

  /// Au moins un numéro actif est-il présent dans la liste ?
  static bool hasActiveAccount(List<EkDepositAccount> accounts) =>
      accounts.any((a) => a.isActive);

  /// Le numéro principal actif de chaque opérateur couvert (à défaut, le
  /// premier numéro actif de cet opérateur) — utilisé pour reconstruire le
  /// champ historique `operatorNumbers` (compatibilité, jamais la source de
  /// vérité) à partir des lignes réelles.
  static Map<String, String> legacyOperatorNumbers(
    List<EkDepositAccount> accounts,
  ) {
    final result = <String, String>{};
    for (final operator in coveredOperators(accounts)) {
      final candidates =
          accounts.where((a) => a.operator == operator && a.isActive);
      final chosen = candidates.where((a) => a.isPrimary).isNotEmpty
          ? candidates.firstWhere((a) => a.isPrimary)
          : candidates.first;
      result[operator] = chosen.phoneNumber;
    }
    return result;
  }
}
