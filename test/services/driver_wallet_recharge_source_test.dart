import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// La recharge manuelle (espèces remises au bureau) est la seule source de crédit des livreurs au lancement :
// elle passe par la Cloud Function (plafond, autorisation admin, idempotence, audit), jamais par une écriture
// directe du solde depuis l'application.
void main() {
  test('rechargeDriverWallet : appel serveur avec clé de confirmation, sans écriture de solde', () {
    final src = File('lib/services/firestore_service.dart').readAsStringSync();
    final start = src.indexOf('Future<int> rechargeDriverWallet(');
    final end = src.indexOf('Future<void> assignDriverToFleet(');
    expect(start, greaterThan(0));
    final body = src.substring(start, end);
    expect(body.contains("httpsCallable('adminDriverRechargeCF')"), isTrue);
    expect(body.contains('required String idempotencyKey'), isTrue);
    expect(body.contains('amount <= 0'), isTrue);
    expect(body.contains('runTransaction'), isFalse);
    expect(body.contains('.update('), isFalse);
  });

  test('les deux écrans admin passent par la confirmation (aucun appel direct au service)', () {
    for (final f in [
      'lib/screens/admin/admin_recharge_page.dart',
      'lib/screens/admin/drivers_page.dart',
    ]) {
      final src = File(f).readAsStringSync();
      expect(src.contains('confirmAndRechargeDriver('), isTrue, reason: f);
      expect(src.contains('rechargeDriverWallet('), isFalse, reason: f);
    }
    final flow =
        File('lib/screens/admin/driver_recharge_flow.dart').readAsStringSync();
    final dialog = flow.indexOf('showDialog<bool>');
    final key = flow.indexOf('newRechargeKey()');
    expect(dialog, greaterThan(0));
    // La clé n'existe qu'après la confirmation du montant.
    expect(key, greaterThan(dialog));
  });
}
