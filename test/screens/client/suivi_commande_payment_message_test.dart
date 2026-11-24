import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/screens/client/suivi_commande.dart';

void main() {
  const suspended =
      'Ce paiement est suspendu : le support AZ Express va le traiter. Rien n\'a été débité.';

  test('bénéficiaire fermé : message de suspension, sans détail interne', () {
    final msg = paymentErrorMessage(
        '[firebase_functions/failed-precondition] BENEFICIARY_ACCOUNT_CLOSED: operation suspendue');
    expect(msg, suspended);
    for (final leak in ['sealed', 'anonymized', 'absent', 'livreurs', 'pharmacies', 'tombstone']) {
      expect(msg.toLowerCase().contains(leak), isFalse);
    }
  });

  test('commande en revue : même message de suspension', () {
    expect(paymentErrorMessage('ORDER_UNDER_REVIEW: commande en revue administrative'), suspended);
  });

  test('autres erreurs inchangées', () {
    expect(paymentErrorMessage('SOLDE_INSUFFISANT:100:500'), 'Solde insuffisant. Rechargez votre wallet.');
    expect(paymentErrorMessage('PAYMENT_ORDER_NOT_PAYABLE: commande non payable'), 'Cette commande ne peut plus être payée.');
    expect(paymentErrorMessage('boom'), 'Erreur paiement : boom');
  });
}
