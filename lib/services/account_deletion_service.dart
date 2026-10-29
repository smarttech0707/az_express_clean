import 'dart:convert';
import 'dart:math';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Accuse de reception d'une demande manuelle, pas une suppression Auth.
class AccountDeletionRequestResult {
  final String requestId;
  final String status;
  final String? reason;
  final bool authDeleted;
  final bool profileAnonymized;
  const AccountDeletionRequestResult(this.requestId, {this.status = 'pending', this.reason,
    this.authDeleted = false, this.profileAnonymized = false});
  bool get completed => status == 'completed' && authDeleted && profileAnonymized;
  bool get accessClosed => completed || status == 'quarantined' || status == 'cleanup_pending';
  factory AccountDeletionRequestResult.fromData(dynamic data) {
    if (data is! Map || data['requestId'] is! String ||
        !['pending','blocked','quarantined','cleanup_pending','completed'].contains(data['status']) ||
        (data['status'] == 'completed' && (data['authDeleted'] != true || data['profileAnonymized'] != true))) {
      throw const FormatException('Confirmation serveur invalide');
    }
    return AccountDeletionRequestResult(data['requestId'] as String,
      status: data['status'] as String, reason: data['reason'] as String?,
      authDeleted: data['authDeleted'] == true, profileAnonymized: data['profileAnonymized'] == true);
  }
  String get message => completed ? 'Compte supprimé' :
      'Demande de suppression enregistrée. Suppression non terminée.';
  String get details {
    switch(reason) {
      case 'reauthentication_required': return 'Reconnectez-vous ou confirmez votre mot de passe pour autoriser la suppression.';
      case 'balance_regularization_required':
      case 'financial_regularization_required': return 'Un solde doit etre regularise. Votre demande reste enregistree. Contactez le support.';
      case 'active_mission_or_reference':
      case 'active_or_unresolved_operation': return 'Une mission ou une operation est encore en cours. Terminez-la puis demandez une reprise.';
      case 'waiting_for_inflight_operations': return 'Les nouvelles operations sont bloquees. Le serveur attend la fin des operations deja engagees.';
      case 'server_rollout_not_enabled': return 'Le traitement serveur n est pas encore active. Votre demande est conservee.';
      case 'server_retry_required': return 'Un traitement serveur a echoue. Reprise prevue ; aucune suppression complete n est confirmee.';
      default: return completed ? 'Les donnees personnelles du profil ont ete anonymisees. Les pieces transactionnelles necessaires restent soumises a une revue de conservation.' : 'La demande reste en attente. Le support peut consulter son etat et les blocages.';
    }
  }
}

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
    'artisan': 'Artisan / prestataire de services',
    'event_provider': "Prestataire d'événements",
  };

  /// Rôles sans moteur de suppression automatique : la demande arrive dans la file manuelle
  /// (`account_deletion_requests`), traitée par un administrateur. L'artisan n'a pas de compte Firebase
  /// personnel (session anonyme), le prestataire d'événements n'est pas inventorié par le moteur serveur.
  static const Set<String> manualOnlyRoles = {'artisan', 'event_provider'};

  static Future<AccountDeletionRequestResult> submitRequest({
    required String role, required String contactPhone, String? contactEmail,
    String? reason, String requestedVia = 'app', String? password,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (requestedVia == 'app' && roleCollections.containsKey(role) && user != null && !user.isAnonymous) {
      if (password != null && password.isNotEmpty) {
        if (!user.providerData.any((p) => p.providerId == 'password') || user.email == null) {
          throw StateError('Reconnectez-vous avec votre fournisseur de connexion avant de reessayer.');
        }
        await user.reauthenticateWithCredential(EmailAuthProvider.credential(email: user.email!, password: password));
        await user.getIdToken(true);
      }
      final prefs = await SharedPreferences.getInstance();
      final prior = prefs.getString('accountDeletionRecovery');
      Map<String,dynamic>? recovery;
      if (prior != null) { recovery = jsonDecode(prior) as Map<String,dynamic>; }
      if (recovery?['uid'] != user.uid) {
        final random = Random.secure();
        recovery = {'uid': user.uid, 'token': List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2,'0')).join()};
        if (!await prefs.setString('accountDeletionRecovery',jsonEncode(recovery))) {
          throw StateError('Impossible de conserver le suivi de la demande. Aucune demande envoyee.');
        }
      }
      AccountDeletionRequestResult result;
      try {
        final response = await FirebaseFunctions.instanceFor(region:'europe-west1')
          .httpsCallable('requestAccountDeletionCF').call({'role':role,'recoveryToken':recovery!['token'],'allProfilesConsent':true});
        result = AccountDeletionRequestResult.fromData(response.data);
      } on FirebaseFunctionsException {
        // A response can be lost after deletion. Only the server receipt confirms it.
        result = await checkLastRequest();
      }
      if (result.accessClosed) await FirebaseAuth.instance.signOut();
      return result;
    }
    return submitRequestUsing(role: role, contactPhone: contactPhone,
      contactEmail: contactEmail, reason: reason, requestedVia: requestedVia,
      authenticatedUid: user != null && !user.isAnonymous ? user.uid : null,
      write: (data) async {
        final ref = FirebaseFirestore.instance.collection('account_deletion_requests').doc();
        await ref.set({...data, 'createdAt': FieldValue.serverTimestamp()});
        return ref.id;
      });
  }

  static Future<AccountDeletionRequestResult> checkLastRequest() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('accountDeletionRecovery');
    if (value == null) throw StateError('Aucune demande suivie sur cet appareil.');
    final recovery = jsonDecode(value) as Map<String,dynamic>;
    final response = await FirebaseFunctions.instanceFor(region:'europe-west1')
      .httpsCallable('getAccountDeletionStatusCF').call({'uid':recovery['uid'],'recoveryToken':recovery['token']});
    return AccountDeletionRequestResult.fromData(response.data);
  }

  /// Point d'injection pour tests sans compte reel. Ne supprime aucune donnee.
  static Future<AccountDeletionRequestResult> submitRequestUsing({
    required String role, required String contactPhone,
    required Future<String> Function(Map<String, dynamic>) write,
    String? authenticatedUid, String? contactEmail, String? reason,
    String requestedVia = 'app',
  }) async {
    if (!roleCollections.containsKey(role) && !manualOnlyRoles.contains(role)) throw ArgumentError('Role inconnu');
    final phone = contactPhone.trim();
    if (phone.isEmpty || phone.length > 30) throw ArgumentError('Telephone invalide');
    if (!['app', 'web'].contains(requestedVia)) throw ArgumentError('Origine invalide');
    final id = await write({
      'role': role, 'uid': authenticatedUid,
      // Un UID de session n'est pas une preuve du document partenaire a supprimer.
      'docId': null, 'contactPhone': phone,
      if (contactEmail != null && contactEmail.trim().isNotEmpty) 'contactEmail': contactEmail.trim(),
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      'status': 'pending', 'requestedVia': requestedVia,
    });
    if (id.isEmpty) throw StateError('Enregistrement non confirme.');
    return AccountDeletionRequestResult(id);
  }

  /// L'ancien enchainement Firestore puis Auth n'est pas atomique et peut perdre
  /// le profil/wallet tout en laissant Auth actif. Bloque sans mutation.
  @Deprecated('Utiliser submitRequest en attendant un traitement serveur securise')
  static Future<void> deleteClientAccountNow({required String password}) async {
    throw StateError('Suppression immediate indisponible. Envoyez une demande de suppression. '
        'Aucun compte ni aucune donnee n ont ete supprimes.');
  }
}
