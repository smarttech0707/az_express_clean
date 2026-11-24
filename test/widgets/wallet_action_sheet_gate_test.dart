import 'package:az_express/constants/app_constants.dart';
import 'package:az_express/widgets/wallet_action_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paiements électroniques désactivés pour le lancement (espèces uniquement)', () {
    expect(AppConfig.electronicPaymentsEnabled, isFalse);
  });

  for (final action in WalletAction.values) {
    testWidgets('$action : message explicatif, aucun écran ni appel FeexPay', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => WalletActionSheet.show(
              context,
              action: action,
              userId: 'u1',
              userType: 'driver',
              userName: 'Livreur',
              currentBalance: 0,
            ),
            child: const Text('ouvrir'),
          ),
        ),
      ));
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
      expect(find.text('Service bientôt disponible'), findsOneWidget);
      expect(find.textContaining(AppConfig.supportPhone), findsOneWidget);
      // Ni l'écran de recharge FeexPay ni le formulaire de retrait.
      expect(find.textContaining('FeexPay'), findsNothing);
      await tester.tap(find.text('Compris'));
      await tester.pumpAndSettle();
      expect(find.text('Service bientôt disponible'), findsNothing);
    });
  }
}
