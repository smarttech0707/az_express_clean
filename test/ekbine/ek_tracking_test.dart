import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/ekbine/ek_tracking.dart';
import 'package:az_express/ekbine/models/ek_order.dart';

EkOrder order({
  String status = 'pending',
  String paymentMethod = 'wallet',
  bool walletDebited = true,
  int debitedAmount = 1000,
  int amount = 1000,
  String? depositProofUrl,
  String? proofUrl,
  DateTime? startedAt,
  String? agentId,
}) =>
    EkOrder(
      id: 'o1',
      clientId: 'c1',
      clientName: 'Client',
      clientPhone: '0700000000',
      agentId: agentId,
      operator: 'orange',
      serviceId: 'credit',
      serviceLabel: 'Crédit Orange',
      beneficiaryNumber: '0700000000',
      amount: amount,
      fee: 0,
      totalPaid: amount,
      commissionAZ: 0,
      agentEarning: paymentMethod == 'wallet' ? amount : 0,
      paymentMethod: paymentMethod,
      status: status,
      depositProofUrl: depositProofUrl,
      proofUrl: proofUrl,
      startedAt: startedAt,
      walletDebited: walletDebited,
      debitedAmount: debitedAmount,
    );

void main() {
  group('wallet prépayé (débit prouvé)', () {
    test('aucune étape ni section de dépôt : le client ne paie jamais deux fois', () {
      final o = order(status: 'deposit_confirmed', agentId: 'a1');
      expect(ekIsPrepaidByWallet(o), isTrue);
      expect(ekTrackingSteps(o), isNot(contains('awaiting_deposit')));
      expect(ekShowDepositSection(o), isFalse);
      expect(ekShowDepositSection(order(status: 'awaiting_deposit')), isFalse);
    });

    test('statut réel : « Agent » est l\'étape courante à deposit_confirmed', () {
      final o = order(status: 'deposit_confirmed', agentId: 'a1');
      final steps = ekTrackingSteps(o);
      expect(steps[ekCurrentStepIndex(o)], 'deposit_confirmed');
      expect(ekStepLabel(o, 'deposit_confirmed'), 'Agent');
      expect(ekStatusText(o), contains('paiement déjà effectué'));
    });

    test('la frise suit pending → agent → en cours → preuve → terminé', () {
      for (final e in {'pending': 0, 'deposit_confirmed': 1, 'in_progress': 2, 'proof_sent': 3, 'completed': 4}.entries) {
        expect(ekCurrentStepIndex(order(status: e.key)), e.value, reason: e.key);
      }
    });

    test('lancement : annulation depuis deposit_confirmed désactivée par défaut, avant acceptation conservée', () {
      expect(kEkCancelFromDepositConfirmed, isFalse);
      expect(ekCanClientCancel(order(status: 'pending')), isTrue);
      expect(ekCanClientCancel(order(status: 'deposit_confirmed')), isFalse);
    });

    test('interrupteur activé : annulation avant exécution, retirée dès le démarrage ou la preuve', () {
      bool can(EkOrder o) => ekCanClientCancel(o, allowFromDepositConfirmed: true);
      expect(can(order(status: 'pending')), isTrue);
      expect(can(order(status: 'deposit_confirmed')), isTrue);
      expect(can(order(status: 'deposit_confirmed', startedAt: DateTime(2026))), isFalse);
      expect(can(order(status: 'deposit_confirmed', proofUrl: 'u')), isFalse);
      expect(can(order(status: 'in_progress')), isFalse);
      expect(can(order(status: 'proof_sent')), isFalse);
      expect(can(order(status: 'completed')), isFalse);
      expect(can(order(status: 'cancelled')), isFalse);
    });
  });

  group('paiement hors wallet : parcours de dépôt inchangé', () {
    EkOrder nonWallet(String status, {String? proof}) => order(
        status: status, paymentMethod: 'orange_money', walletDebited: false, debitedAmount: 0, depositProofUrl: proof);

    test('étape et section de dépôt conservées', () {
      final o = nonWallet('awaiting_deposit');
      expect(ekIsPrepaidByWallet(o), isFalse);
      expect(ekTrackingSteps(o), contains('awaiting_deposit'));
      expect(ekShowDepositSection(o), isTrue);
      expect(ekStepLabel(o, 'awaiting_deposit'), 'Dépôt');
      expect(ekStepLabel(o, 'deposit_confirmed'), 'Confirmé');
    });

    test('preuve envoyée / rejetée restent sur l\'étape dépôt ; dépôt confirmé a sa propre étape', () {
      for (final s in ['awaiting_deposit', 'deposit_proof_sent', 'deposit_rejected']) {
        final o = nonWallet(s, proof: s == 'awaiting_deposit' ? null : 'u');
        expect(ekTrackingSteps(o)[ekCurrentStepIndex(o)], 'awaiting_deposit', reason: s);
      }
      final confirmed = nonWallet('deposit_confirmed', proof: 'u');
      expect(ekTrackingSteps(confirmed)[ekCurrentStepIndex(confirmed)], 'deposit_confirmed');
      expect(ekShowDepositSection(confirmed), isTrue, reason: 'preuve consultable');
    });

    test('annulation : seulement avant toute preuve de dépôt, jamais depuis deposit_confirmed', () {
      expect(ekCanClientCancel(nonWallet('pending')), isTrue);
      expect(ekCanClientCancel(nonWallet('awaiting_deposit')), isTrue);
      expect(ekCanClientCancel(nonWallet('awaiting_deposit', proof: 'u')), isFalse);
      expect(ekCanClientCancel(nonWallet('deposit_confirmed', proof: 'u')), isFalse);
    });
  });

  group('commandes wallet historiques ou preuve incohérente : aucun contournement', () {
    test('sans preuve de débit → parcours de dépôt existant', () {
      final o = order(status: 'awaiting_deposit', walletDebited: false, debitedAmount: 0);
      expect(ekIsPrepaidByWallet(o), isFalse);
      expect(ekShowDepositSection(o), isTrue);
      expect(ekCanClientCancel(order(status: 'deposit_confirmed', walletDebited: false, debitedAmount: 0), allowFromDepositConfirmed: true), isFalse);
    });

    test('montant débité différent du montant de la commande → pas prépayé', () {
      expect(ekIsPrepaidByWallet(order(debitedAmount: 10)), isFalse);
      expect(ekIsPrepaidByWallet(order(walletDebited: true, debitedAmount: 0)), isFalse);
    });

    test('statut « assigned » hérité : rattaché à l\'étape de l\'agent / du dépôt selon le mode', () {
      final prepaid = order(status: 'assigned');
      expect(ekTrackingSteps(prepaid)[ekCurrentStepIndex(prepaid)], 'deposit_confirmed');
      final legacy = order(status: 'assigned', walletDebited: false, debitedAmount: 0);
      expect(ekTrackingSteps(legacy)[ekCurrentStepIndex(legacy)], 'awaiting_deposit');
    });
  });
}
