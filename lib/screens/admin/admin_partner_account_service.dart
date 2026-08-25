import 'package:cloud_functions/cloud_functions.dart';

class AdminPartnerAccountService {
  static final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  static Future<String> create({
    required String kind,
    required String email,
    required String password,
    Map<String, dynamic> profile = const {},
  }) async {
    final result =
        await _functions.httpsCallable('manageAdminPartnerAccount').call({
      'action': 'create',
      'kind': kind,
      'email': email,
      'password': password,
      'profile': profile,
    });
    return (result.data as Map)['uid'] as String;
  }

  static Future<void> updatePassword({
    required String kind,
    required String uid,
    required String password,
  }) =>
      _functions.httpsCallable('manageAdminPartnerAccount').call({
        'action': 'updatePassword',
        'kind': kind,
        'uid': uid,
        'password': password,
      });
}
