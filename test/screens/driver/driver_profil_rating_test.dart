import 'package:flutter_test/flutter_test.dart';

// Régression SEC-01 S6.0.3 : `driver_profil.dart` lisait `data["rating"]`,
// un champ jamais écrit sur `livreurs/{id}` (voir
// docs/SEC01_S6_0_2_RESIDUAL_DEBT_AUDIT.md). Le champ réellement maintenu par
// le serveur est `avgRating`. Ce test isole l'expression de lecture exacte
// utilisée dans `_DriverProfilState.build()` (DocumentSnapshot/FakeFirebaseFirestore
// non simulables ici : aucun paquet de simulation Firestore dans le dépôt,
// cf. test/screens/driver/driver_accept_selfie_test.dart).
double _readDriverRating(Map<String, dynamic> data) =>
    (data["avgRating"] as num? ?? 0).toDouble();

void main() {
  group('DriverProfil — lecture de la note (avgRating)', () {
    test('valeur numérique présente (double)', () {
      expect(_readDriverRating({'avgRating': 4.5}), 4.5);
    });

    test('valeur numérique présente (int)', () {
      expect(_readDriverRating({'avgRating': 5}), 5.0);
    });

    test('champ absent → 0.0 (pas de crash)', () {
      expect(_readDriverRating({}), 0.0);
    });

    test('champ explicitement null → 0.0', () {
      expect(_readDriverRating({'avgRating': null}), 0.0);
    });

    test('champ non numérique (type inattendu) → 0.0, pas de crash', () {
      expect(_readDriverRating({'avgRating': 'abc'}), 0.0);
    });

    test('ancien champ "rating" (plus jamais écrit) est ignoré', () {
      // Avant la correction, ce champ legacy était lu par erreur ; il ne doit
      // plus influencer l'affichage même s'il existe encore sur un vieux doc.
      expect(_readDriverRating({'rating': 3.0, 'avgRating': 4.2}), 4.2);
    });
  });
}
