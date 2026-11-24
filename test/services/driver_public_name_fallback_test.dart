import 'package:flutter_test/flutter_test.dart';

// SEC-01 S6.1 : migration name-only de `conversations_page.dart`,
// `web_client_dashboard.dart::_rateDriver` et le flux de notation de
// `suivi_commande.dart` depuis `livreurs` vers `driver_public`. Les trois
// sites partagent le même repli ("Livreur"/"le livreur") quand le document
// `driver_public/{driverId}` n'existe pas encore ou que son champ `name`
// n'est pas (ou plus) présent — cas réel : fenêtre de synchronisation
// serveur (`driverPublicSync.js`) documentée dans
// docs/SEC01_S6_0_READ_ONLY_MIGRATION_PLAN.md §5. Un test widget complet
// pilotant un vrai flux Firestore n'est pas réalisable ici : aucun paquet de
// simulation Firestore dans le dépôt (cf. test/screens/driver/driver_accept_selfie_test.dart,
// test/screens/driver/driver_profil_rating_test.dart). Ce test isole donc
// l'expression de repli exacte utilisée après migration.
String nameWithFallback(Map<String, dynamic>? data, String fallback) =>
    (data?['name'] as String?) ?? fallback;

void main() {
  group('Nom du livreur depuis driver_public (après migration S6.1)', () {
    test('nom présent → affiché tel quel', () {
      expect(nameWithFallback({'name': 'Koffi'}, 'le livreur'), 'Koffi');
    });

    test('document driver_public inexistant (data == null) → repli', () {
      expect(nameWithFallback(null, 'le livreur'), 'le livreur');
    });

    test('champ name absent (sync non encore faite) → repli', () {
      expect(nameWithFallback({}, 'le livreur'), 'le livreur');
    });

    test('champ name explicitement null → repli', () {
      expect(nameWithFallback({'name': null}, 'le livreur'), 'le livreur');
    });

    test('champ name de type inattendu → repli, pas de crash', () {
      expect(nameWithFallback({'name': 42}, 'le livreur'), 'le livreur');
    });

    test('repli spécifique à conversations_page ("Livreur")', () {
      expect(nameWithFallback({}, 'Livreur'), 'Livreur');
    });
  });
}
