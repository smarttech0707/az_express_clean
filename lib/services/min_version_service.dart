import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Numéro de build injecté à la compilation (`--dart-define=APP_BUILD_NUMBER=13`) par `scripts/build_mobile.py`,
/// qui refuse un build sans numéro positif. 0 = inconnu (build lancé hors script, web, anciens binaires) :
/// l'application n'est alors jamais bloquée (on ne bloque pas sur une information qu'on ne possède pas).
const appBuildNumber = int.fromEnvironment('APP_BUILD_NUMBER');

enum MinVersionStatus { ok, updateRecommended, updateRequired }

typedef MinVersionResult = ({
  MinVersionStatus status,
  String? message,
  String? updateUrl,
});

/// Source du document `config/app_versions` complet (`null` = document absent). Elle lève une exception si la lecture
/// échoue (réseau, permission) : [MinVersionService.check] la traite alors comme « aucune contrainte ».
typedef MinVersionSource = Future<Map<String, dynamic>?> Function();

Future<Map<String, dynamic>?> _readFromFirestore() async {
  final doc = await FirebaseFirestore.instance
      .collection('config')
      .doc('app_versions')
      .get();
  return doc.data();
}

/// Mécanisme de version minimale, PRÉPARÉ pour la fermeture de l'acceptation
/// directe Firestore (docs/DRIVER_ACCEPT_RULE_MIGRATION.md). Document
/// `config/app_versions` (lisible de tous, écriture admin) :
///   { driver: { minBuild: 14, enforce: false, message: "...",
///               minBuildAndroid: 14, minBuildIos: 3,
///               updateUrl: "https://...", updateUrlAndroid: "...", updateUrlIos: "..." } }
/// Les clés par plateforme sont facultatives et priment sur `minBuild` / `updateUrl` : les numéros de build
/// Android et iOS ne sont pas forcément alignés (`--build-number` de l'IPA).
/// Tant que `enforce` n'est pas explicitement `true`, la version minimale
/// n'est qu'une recommandation. Aucun document = aucun effet.
///
/// Traitement des valeurs, CHAMP PAR CHAMP (une valeur invalide n'invalide jamais les autres champs) :
/// - `minBuild`, `minBuildAndroid`, `minBuildIos` : entier de 1 à [maxBuildNumber], éventuellement stocké sous forme
///   décimale entière (`14.0` = 14). Refusés (champ ignoré) : texte, booléen, liste, `null`, 0, négatif, non fini
///   (NaN, infini), fractionnaire (`14.5`, jamais arrondi), supérieur à [maxBuildNumber]. Une clé de plateforme
///   refusée laisse `minBuild` commun en vigueur ; un `minBuild` refusé sans clé de plateforme valide = aucune contrainte.
/// - `enforce` : seul le booléen `true` bloque. Toute autre valeur (`"true"`, `1`, absente…) = simple recommandation.
/// - `message` : texte non vide d'au plus [maxMessageLength] caractères (espaces de bord retirés). Autre valeur
///   (nombre, trop long, vide…) : ignorée, le message par défaut de l'écran est utilisé.
/// - `updateUrl*` : voir [safeUpdateUrl]. Un lien refusé retire seulement le bouton « Mettre à jour ».
/// - entrée du rôle absente ou qui n'est pas une table : aucune contrainte.
/// Lecture impossible (hors ligne, permission) ou erreur inattendue : aucune contrainte, jamais de blocage.
///
/// Ce contrôle est une barrière d'expérience, PAS une frontière de sécurité : les règles Firestore ne voient pas la
/// version de l'application.
class MinVersionService {
  MinVersionService({MinVersionSource? source}) : _source = source ?? _readFromFirestore;

  final MinVersionSource _source;

  /// Plus grand numéro de build accepté (limite du `versionCode` Google Play, identique à `scripts/build_mobile.py`).
  static const maxBuildNumber = 2100000000;

  /// Longueur maximale d'un message serveur ; au-delà il est ignoré (jamais tronqué en silence).
  static const maxMessageLength = 500;

  /// Hôtes autorisés pour le lien de mise à jour (domaines déjà utilisés par le projet : Hosting, Play, App Store).
  static const _allowedUpdateHosts = {
    'az-express-b0469.web.app',
    'play.google.com',
    'apps.apple.com',
  };

  static const MinVersionResult _noConstraint =
      (status: MinVersionStatus.ok, message: null, updateUrl: null);

  /// Numéro de build valide ou `null` (voir règles de la classe). Ne convertit jamais une valeur fractionnaire.
  static int? parseBuild(Object? value) {
    int number;
    if (value is int) {
      number = value;
    } else if (value is double) {
      if (!value.isFinite ||
          value != value.truncateToDouble() ||
          value.abs() > maxBuildNumber) {
        return null;
      }
      number = value.toInt();
    } else {
      return null;
    }
    return number >= 1 && number <= maxBuildNumber ? number : null;
  }

  /// Message affichable ou `null` (voir règles de la classe).
  static String? sanitizedMessage(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    if (text.isEmpty || text.length > maxMessageLength) return null;
    return text;
  }

  static MinVersionStatus evaluate(
      Map<String, dynamic>? config, int currentBuild) {
    if (config == null || currentBuild <= 0) return MinVersionStatus.ok;
    final min = parseBuild(config['minBuild']);
    if (min == null || currentBuild >= min) return MinVersionStatus.ok;
    return config['enforce'] == true
        ? MinVersionStatus.updateRequired
        : MinVersionStatus.updateRecommended;
  }

  /// Applique les clés propres à la plateforme (`android` / `ios`) ; autre plateforme ou clé absente : valeurs communes.
  static Map<String, dynamic>? forPlatform(
      Map<String, dynamic>? config, String? platform) {
    if (config == null || platform == null) return config;
    final suffix = platform == 'android'
        ? 'Android'
        : platform == 'ios'
            ? 'Ios'
            : null;
    if (suffix == null) return config;
    final merged = Map<String, dynamic>.from(config);
    final min = parseBuild(config['minBuild$suffix']);
    if (min != null) merged['minBuild'] = min;
    final url = config['updateUrl$suffix'];
    if (url is String) merged['updateUrl'] = url;
    return merged;
  }

  /// Lien de mise à jour valide ou `null` : https, hôte connu, sans identifiants. Un lien inattendu n'est jamais ouvert.
  static String? safeUpdateUrl(Object? raw) {
    if (raw is! String) return null;
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        !_allowedUpdateHosts.contains(uri.host)) {
      return null;
    }
    return uri.toString();
  }

  static String? get _currentPlatform {
    if (kIsWeb) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return null;
    }
  }

  /// [role] : `driver`, `client`, `restaurant`, `seller`, `boulangerie`, `pharmacie`, `artisan`, `fleet`,
  /// `immobilier`, `ekbine`, `admin`. Une erreur de lecture n'empêche jamais de travailler : résultat `ok`.
  Future<MinVersionResult> check(String role,
      {int? build, String? platform}) async {
    final Map<String, dynamic>? data;
    try {
      data = await _source();
    } catch (_) {
      return _noConstraint;
    }
    try {
      final raw = data?[role];
      final config = forPlatform(
          raw is Map
              ? {
                  for (final e in raw.entries)
                    if (e.key is String) e.key as String: e.value
                }
              : null,
          platform ?? _currentPlatform);
      return (
        status: evaluate(config, build ?? appBuildNumber),
        message: sanitizedMessage(config?['message']),
        updateUrl: safeUpdateUrl(config?['updateUrl']),
      );
    } catch (_) {
      return _noConstraint;
    }
  }
}
