import 'package:cloud_functions/cloud_functions.dart';

/// Appels à la fonction serveur `manageAdminPartnerAccount`.
///
/// Aucun mot de passe n'est choisi ni transmis par l'administrateur : le
/// serveur génère un mot de passe TEMPORAIRE, renvoyé une seule fois dans la
/// réponse (`tempPassword`) pour être communiqué au partenaire, qui devra en
/// définir un personnel à sa première connexion.
class AdminPartnerAccountService {
  static final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  static Future<Map> _call(Map<String, dynamic> payload) async {
    final result =
        await _functions.httpsCallable('manageAdminPartnerAccount').call(payload);
    return result.data as Map;
  }

  /// Crée le compte Auth ET finalise le profil côté serveur (vendeur,
  /// boulangerie). `profile` doit être complet : le serveur refuse un profil
  /// incomplet avant toute création de compte. `isActive` n'a d'effet que pour
  /// un vendeur (défaut serveur : actif).
  static Future<({String uid, String tempPassword})> create({
    required String kind,
    required String email,
    Map<String, dynamic> profile = const {},
    bool? isActive,
  }) async {
    final data = await _call({
      'action': 'create',
      'kind': kind,
      'email': email,
      'profile': profile,
      if (isActive != null) 'isActive': isActive,
    });
    return (
      uid: data['uid'] as String,
      tempPassword: data['tempPassword'] as String,
    );
  }

  /// Crée un restaurant COMPLET : compte Auth, document `restaurants`,
  /// association `restaurant_owners/{uid}`. L'identifiant de connexion doit
  /// être `<téléphone>@az-restaurant.ci` (celui que reconstruit l'écran de
  /// connexion restaurateur).
  static Future<({String uid, String restaurantId, String tempPassword})>
      createRestaurant({
    required String email,
    required Map<String, dynamic> profile,
    bool isOpen = false,
  }) async {
    final data = await _call({
      'action': 'create',
      'kind': 'restaurant',
      'email': email,
      'profile': profile,
      'isOpen': isOpen,
    });
    return (
      uid: data['uid'] as String,
      restaurantId: data['restaurantId'] as String,
      tempPassword: data['tempPassword'] as String,
    );
  }

  /// Attribue un responsable (nouveau compte) à un restaurant HISTORIQUE déjà
  /// existant, sans jamais créer ni modifier l'établissement. Réservé au
  /// super-administrateur côté serveur. Opération explicite : jamais appelée
  /// automatiquement.
  static Future<({String uid, String restaurantId, String tempPassword})>
      assignRestaurantOwner({
    required String restaurantId,
    required String ownerName,
    required String phone,
    required String email,
  }) async {
    final data = await _call({
      'action': 'assignOwner',
      'kind': 'restaurant',
      'restaurantId': restaurantId,
      'ownerName': ownerName,
      'phone': phone,
      'email': email,
    });
    return (
      uid: data['uid'] as String,
      restaurantId: data['restaurantId'] as String,
      tempPassword: data['tempPassword'] as String,
    );
  }

  /// Réinitialisation : le serveur génère un NOUVEAU mot de passe temporaire
  /// (l'ancien cesse de fonctionner) et impose un nouveau changement à la
  /// prochaine connexion.
  static Future<String> resetToTemporaryPassword({
    required String kind,
    required String uid,
  }) async {
    final data = await _call({
      'action': 'updatePassword',
      'kind': kind,
      'uid': uid,
    });
    return data['tempPassword'] as String;
  }
}
