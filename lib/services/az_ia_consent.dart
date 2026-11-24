import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Consentement explicite au partage de données avec les fournisseurs d'IA
/// externes d'AZ IA (exigence App Store 5.1.1(i) / 5.1.2(i)).
///
/// Stocké par compte sur l'appareil. Une nouvelle [version] (liste de données
/// ou de fournisseurs modifiée) redemande le consentement.
class AzIaConsent {
  const AzIaConsent._();

  static const int version = 1;

  /// Adresse publique de la politique de confidentialité.
  static const String privacyUrl = 'https://az-express-b0469.web.app/confidentialite';

  static String _key(String uid) => 'az_ia_consent_v${version}_$uid';

  static Future<bool> isGranted(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key(uid)) ?? false;
    } catch (e) {
      // Doute = pas de consentement : rien n'est transmis.
      debugPrint('[AZ IA] lecture consentement impossible : $e');
      return false;
    }
  }

  static Future<void> grant(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key(uid), true);
  }

  static Future<void> revoke(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(uid));
  }
}
