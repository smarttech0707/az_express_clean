import 'ek_constants.dart';
import 'models/ek_order.dart';

// Règles d'affichage du suivi E-Kbine, sans dépendance à Firebase (testables).
//
// Une commande payée par wallet avec débit PROUVÉ par le serveur (`walletDebited`) est déjà réglée : le client ne
// doit jamais être invité à payer une seconde fois (dépôt chez l'agent). Les commandes hors wallet et les commandes
// wallet historiques (sans preuve) gardent le parcours de dépôt existant.

/// Annulation proposée depuis deposit_confirmed (commande wallet prépayée, agent affecté, service non commencé).
/// DÉSACTIVÉE au lancement : doit rester alignée sur EK_CANCEL_FROM_DEPOSIT_CONFIRMED côté serveur
/// (functions/.env). Le serveur reste seul juge : un bouton affiché alors que le serveur refuse ne rembourse rien.
const kEkCancelFromDepositConfirmed = false;

/// Le client a déjà payé via son wallet AZ, preuve serveur à l'appui.
bool ekIsPrepaidByWallet(EkOrder o) =>
    o.paymentMethod == 'wallet' &&
    o.walletDebited &&
    o.debitedAmount > 0 &&
    o.debitedAmount == o.amount;

/// Étapes affichées dans la frise de suivi.
List<String> ekTrackingSteps(EkOrder o) => ekIsPrepaidByWallet(o)
    ? const ['pending', 'deposit_confirmed', 'in_progress', 'proof_sent', 'completed']
    : const [
        'pending',
        'awaiting_deposit',
        'deposit_confirmed',
        'in_progress',
        'proof_sent',
        'completed',
      ];

/// Position du statut réel dans [ekTrackingSteps] (-1 si le statut n'appartient pas à la frise).
int ekCurrentStepIndex(EkOrder o) {
  var status = o.status;
  if (status == 'deposit_proof_sent' || status == 'deposit_rejected') {
    status = 'awaiting_deposit';
  }
  if (status == 'assigned') {
    status = ekIsPrepaidByWallet(o) ? 'deposit_confirmed' : 'awaiting_deposit';
  }
  return ekTrackingSteps(o).indexOf(status);
}

String ekStepLabel(EkOrder o, String step) {
  switch (step) {
    case 'pending':
      return 'Attente';
    case 'awaiting_deposit':
      return 'Dépôt';
    case 'deposit_confirmed':
      return ekIsPrepaidByWallet(o) ? 'Agent' : 'Confirmé';
    case 'in_progress':
      return 'En cours';
    case 'proof_sent':
      return 'Preuve';
    case 'completed':
      return 'Terminé';
    default:
      return step;
  }
}

/// Texte de statut affiché au client (le statut réel, sans étape de paiement déjà accomplie).
String ekStatusText(EkOrder o) {
  if (ekIsPrepaidByWallet(o) && o.status == 'deposit_confirmed') {
    return o.startedAt == null
        ? 'Agent affecté — paiement déjà effectué avec votre wallet'
        : 'En cours';
  }
  return ekStatusLabels[o.status] ?? o.status;
}

/// La section « preuve de paiement / dépôt » n'existe que pour les commandes à payer à l'agent.
bool ekShowDepositSection(EkOrder o) =>
    !ekIsPrepaidByWallet(o) &&
    (o.depositProofUrl != null || o.status == 'awaiting_deposit');

/// Annulation proposée au client. Le serveur (ekCancelOrderCF) revérifie tout dans une transaction.
bool ekCanClientCancel(EkOrder o, {bool allowFromDepositConfirmed = kEkCancelFromDepositConfirmed}) {
  if (o.status == 'pending') return true;
  if (o.status == 'awaiting_deposit') return o.depositProofUrl == null;
  return allowFromDepositConfirmed &&
      ekIsPrepaidByWallet(o) &&
      o.status == 'deposit_confirmed' &&
      o.startedAt == null &&
      o.proofUrl == null;
}
