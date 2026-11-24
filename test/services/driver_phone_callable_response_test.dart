import 'package:flutter_test/flutter_test.dart';

// SEC-01 S6.9 : migration de `web_client_dashboard.dart::_callDriver`,
// `suivi_commande.dart::_callDriver` et
// `customer_tracking_screen.dart::_loadDriverInfoById` vers l'appel
// `getDriverPhoneForOrderCF` (S6.8) au lieu d'une lecture directe de
// `livreurs.phone`. Les trois sites partagent la même expression
// d'extraction de la réponse `{success, data: {phone}, error, message,
// code}` renvoyée par la callable. Un test d'intégration réel (appel
// `httpsCallable` simulé) n'est pas réalisable ici : aucun paquet de
// simulation Cloud Functions dans le dépôt (même limite déjà documentée
// pour Firestore, cf. test/screens/driver/driver_accept_selfie_test.dart).
// Ce test isole donc l'expression de parsing exacte utilisée aux 3 sites.
String? extractPhone(dynamic callableResult) =>
    ((callableResult as Map?)?['data'] as Map?)?['phone'] as String?;

void main() {
  group('Extraction du téléphone depuis la réponse de getDriverPhoneForOrderCF', () {
    test('réponse normale → numéro extrait', () {
      expect(
        extractPhone({'success': true, 'data': {'phone': '+2250700000001'}}),
        '+2250700000001',
      );
    });

    test('data absent (ex. réponse vide) → null, pas de crash', () {
      expect(extractPhone({'success': false}), isNull);
    });

    test('phone absent dans data → null', () {
      expect(extractPhone({'data': {}}), isNull);
    });

    test('réponse non-Map (ex. null) → null', () {
      expect(extractPhone(null), isNull);
    });

    test('type inattendu pour phone → null, pas de crash', () {
      expect(extractPhone({'data': {'phone': 12345}}), isNull);
    });
  });
}
