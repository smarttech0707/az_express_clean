import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Flux unique de suppression de compte, couvrant les 9 rôles réels de l'app.
///
/// Deux mécanismes distincts, choisis selon ce que chaque rôle permet réellement :
/// - `deleteClientAccountNow()` : suppression immédiate, réservée au rôle client
///   (seul rôle avec un compte Firebase Auth email/mot de passe + une règle
///   Firestore `allow delete` déjà accordée au propriétaire) — réutilise le
///   flux déjà en production dans `profil_client.dart`, comportement inchangé.
/// - `submitRequest()` : pour les 9 rôles (y compris client), enregistre une
///   demande dans `account_deletion_requests` (Cloud-Function-free, traitée
///   manuellement par un admin) — le seul mécanisme possible pour les 8 autres
///   rôles, dont plusieurs n'ont pas de compte Firebase Auth propre (ex. les
///   pharmacies utilisent une authentification Firestore custom, voir
///   `pharmacie_login.dart`) et dont aucun n'a de règle Firestore autorisant
///   une auto-suppression de leur document (élargir ces règles serait un
///   changement de posture de sécurité à part entière, hors du périmètre de
///   ce correctif de conformité Play Store).
///
/// Utilisé à la fois depuis l'app (authentifié, `role`/`contactPhone` déjà
/// connus) et depuis la page web publique `/delete-account` (non authentifié,
/// l'utilisateur saisit lui-même son rôle et son contact).
class AccountDeletionService {
  AccountDeletionService._();

  /// Rôle applicatif -> nom de la collection Firestore correspondante.
  static const Map<String, String> roleCollections = {
    'client': 'clients',
    'livreur': 'livreurs',
    'seller': 'sellers',
    'restaurant': 'restaurants',
    'pharmacie': 'pharmacies',
    'boulangerie': 'boulangeries',
    'ekbine_agent': 'ekbine_agents',
    'real_estate_agent': 'real_estate_agents',
    'fleet_owner': 'fleet_owners',
  };

  /// Libellés français affichés dans les sélecteurs de rôle (app + web).
  static const Map<String, String> roleLabels = {
    'client': 'Client',
    'livreur': 'Livreur',
    'seller': 'Vendeur Marketplace',
    'restaurant': 'Restaurant',
    'pharmacie': 'Pharmacie',
    'boulangerie': 'Boulangerie',
    'ekbine_agent': 'Agent Ekbine',
    'real_estate_agent': 'Agent immobilier',
    'fleet_owner': 'Patron de flotte',
  };

  /// Enregistre une demande de suppression de compte — étape 1 (« demande
  /// suppression ») pour tout rôle. Traitée manuellement par un admin, qui
  /// désactive le compte puis efface les données personnelles selon le délai
  /// légal déjà annoncé dans la politique de confidentialité (30 jours, sauf
  /// obligation de conservation — ex. historique financier).
  static Future<void> submitRequest({
    required String role,
    required String contactPhone,
    String? contactEmail,
    String? reason,
    String requestedVia = 'app',
  }) async {
    if (!roleCollections.containsKey(role)) {
      throw ArgumentError('Rôle de compte inconnu : $role');
    }
    final phone = contactPhone.trim();
    if (phone.isEmpty) {
      throw ArgumentError(
          'Un numéro de téléphone est requis pour identifier la demande.');
    }
    final uid = FirebaseAuth.instance.currentUser?.uid;
    await FirebaseFirestore.instance
        .collection('account_deletion_requests')
        .add({
      'role': role,
      'docId': uid,
      'uid': uid,
      'contactPhone': phone,
      if (contactEmail != null && contactEmail.trim().isNotEmpty)
        'contactEmail': contactEmail.trim(),
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      'status': 'pending',
      'requestedVia': requestedVia,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Suppression immédiate — client uniquement. Même comportement exact que
  /// l'implémentation historique de `profil_client.dart` (ré-authentification
  /// obligatoire, suppression du document Firestore puis du compte Firebase
  /// Auth) — extrait ici pour être réutilisable, pas réécrit.
  static Future<void> deleteClientAccountNow({required String password}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Aucun utilisateur connecté.');
    }
    final email = user.email;
    if (email == null || email.isEmpty) {
      throw StateError(
          'Ce compte n\'a pas de mot de passe défini — utilisez plutôt la demande '
          'de suppression standard (submitRequest).');
    }

    final cred = EmailAuthProvider.credential(email: email, password: password);
    await user.reauthenticateWithCredential(cred);

    await FirebaseFirestore.instance
        .collection('clients')
        .doc(user.uid)
        .delete();
    await user.delete();
  }
}
