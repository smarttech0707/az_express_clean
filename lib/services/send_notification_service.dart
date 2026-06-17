// Les notifications sont gérées via firebase_messaging (notification_service.dart).
// Cette classe est conservée pour compatibilité mais n'envoie pas de requêtes réseau.
class SendNotificationService {
  static Future<void> send(String token, String title, String body) async {
    // Notifications envoyées via Firebase Cloud Functions côté serveur.
  }
}
