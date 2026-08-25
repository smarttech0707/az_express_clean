import 'package:url_launcher/url_launcher.dart';

class CallService {
  /// appeler un numéro
  static Future<void> callPhone(String phoneNumber) async {
    final Uri phoneUri = Uri(
      scheme: 'tel',
      path: phoneNumber,
    );

    if (await canLaunchUrl(phoneUri)) {
      await launchUrl(phoneUri);
    } else {
      throw 'Impossible de lancer l’appel';
    }
  }
}
