import 'package:cloud_functions/cloud_functions.dart';

/// Shared callable transport for both administrator artisan screens.
class ArtisanAccountService {
  ArtisanAccountService({FirebaseFunctions? functions})
      : functions = functions ??
            FirebaseFunctions.instanceFor(region: 'europe-west1');

  final FirebaseFunctions functions;

  Future<bool> setPin({
    required String providerId,
    required String pin,
    bool approve = false,
  }) async {
    final result = await functions.httpsCallable('setArtisanPin').call({
      'providerId': providerId,
      'pin': pin,
      'approve': approve,
    });
    // A repeated approval never rotates the existing PIN. Only display the
    // locally held PIN when the server confirms that it is still usable.
    return (result.data as Map)['pinSet'] == true;
  }
}
