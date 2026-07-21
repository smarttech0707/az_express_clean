import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/services/tarif_service.dart';

// BUSINESS RULE:
// Livraison Express
// Jour = 1000 FCFA
// Nuit = 1500 FCFA
// Ne pas modifier sans décision métier.
//
// Verrouillage des 6 heures pivots exactes (Master Prompt « Verrouillage du
// tarif Express de nuit ») — zone centrale (≤8km d'Abengourou), seul endroit
// où le tarif Express est un montant plat directement gouverné par cette
// règle (hors zone, un tarif kilométrique distinct s'applique, non concerné
// par ce verrouillage).
void main() {
  DateTime at(int hour, int minute) => DateTime(2026, 7, 2, hour, minute);

  group('TarifService.compute — règle métier Express jour/nuit', () {
    test('Express à 10h → 1000 FCFA', () {
      final r = TarifService.compute(
        clientLat: TarifService.centerLat,
        clientLng: TarifService.centerLng,
        time: at(10, 0),
      );
      expect(r.expressPrice, 1000);
    });

    test('Express à 19h59 → 1000 FCFA', () {
      final r = TarifService.compute(
        clientLat: TarifService.centerLat,
        clientLng: TarifService.centerLng,
        time: at(19, 59),
      );
      expect(r.expressPrice, 1000);
    });

    test('Express à 20h00 → 1500 FCFA', () {
      final r = TarifService.compute(
        clientLat: TarifService.centerLat,
        clientLng: TarifService.centerLng,
        time: at(20, 0),
      );
      expect(r.expressPrice, 1500);
    });

    test('Express à 23h30 → 1500 FCFA', () {
      final r = TarifService.compute(
        clientLat: TarifService.centerLat,
        clientLng: TarifService.centerLng,
        time: at(23, 30),
      );
      expect(r.expressPrice, 1500);
    });

    test('Express à 05h59 → 1500 FCFA', () {
      final r = TarifService.compute(
        clientLat: TarifService.centerLat,
        clientLng: TarifService.centerLng,
        time: at(5, 59),
      );
      expect(r.expressPrice, 1500);
    });

    test('Express à 06h00 → 1000 FCFA', () {
      final r = TarifService.compute(
        clientLat: TarifService.centerLat,
        clientLng: TarifService.centerLng,
        time: at(6, 0),
      );
      expect(r.expressPrice, 1000);
    });

    test('tarif jour complet dans la zone centrale : standard 500 / express 1000', () {
      final r = TarifService.compute(
        clientLat: TarifService.centerLat,
        clientLng: TarifService.centerLng,
        time: at(14, 0),
      );
      expect(r.standardPrice, 500);
      expect(r.expressPrice, 1000);
      expect(r.isNight, false);
    });

    test('tarif nuit complet dans la zone centrale : standard 1000 / express 1500', () {
      final r = TarifService.compute(
        clientLat: TarifService.centerLat,
        clientLng: TarifService.centerLng,
        time: at(22, 0),
      );
      expect(r.standardPrice, 1000);
      expect(r.expressPrice, 1500);
      expect(r.isNight, true);
    });
  });
}
