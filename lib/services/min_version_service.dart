import 'package:cloud_firestore/cloud_firestore.dart';

/// Numéro de build injecté à la compilation (`--dart-define=APP_BUILD_NUMBER=13`).
/// 0 = inconnu : l'application n'est alors jamais bloquée (on ne bloque pas
/// sur une information qu'on ne possède pas).
const appBuildNumber = int.fromEnvironment('APP_BUILD_NUMBER');

enum MinVersionStatus { ok, updateRecommended, updateRequired }

/// Mécanisme de version minimale, PRÉPARÉ pour la fermeture de l'acceptation
/// directe Firestore (docs/DRIVER_ACCEPT_RULE_MIGRATION.md). Document
/// `config/app_versions` (lisible de tous, écriture admin) :
///   { driver: { minBuild: 14, enforce: false, message: "..." } }
/// Tant que `enforce` n'est pas explicitement `true`, la version minimale
/// n'est qu'une recommandation. Aucun document = aucun effet.
class MinVersionService {
  static MinVersionStatus evaluate(
      Map<String, dynamic>? config, int currentBuild) {
    if (config == null || currentBuild <= 0) return MinVersionStatus.ok;
    final min = config['minBuild'];
    if (min is! int || min <= 0 || currentBuild >= min) {
      return MinVersionStatus.ok;
    }
    return config['enforce'] == true
        ? MinVersionStatus.updateRequired
        : MinVersionStatus.updateRecommended;
  }

  /// [role] : `driver` (seul rôle utilisé aujourd'hui). Une erreur réseau
  /// n'empêche jamais de travailler : résultat `ok`.
  Future<({MinVersionStatus status, String? message})> check(String role,
      {int? build}) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('config')
          .doc('app_versions')
          .get();
      final raw = doc.data()?[role];
      final config = raw is Map ? Map<String, dynamic>.from(raw) : null;
      return (
        status: evaluate(config, build ?? appBuildNumber),
        message: config?['message'] as String?,
      );
    } catch (_) {
      return (status: MinVersionStatus.ok, message: null);
    }
  }
}
