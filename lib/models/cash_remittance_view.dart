/// Suivi du reversement des espèces dues au partenaire pour une commande Restaurant/Boulangerie v2 payée en espèces
/// (`orders/{id}.cashRemittance`, écrit UNIQUEMENT par partnerOrderActionCF). Lecture seule.
///
/// Les montants sont CUMULATIFS (comme côté serveur) : `handedOver` = total déclaré par le livreur, `confirmed` = total
/// confirmé par le partenaire. Une déclaration du livreur n'est jamais une confirmation. Le règlement n'est intégral que si
/// le partenaire a confirmé la totalité du dû, ou si l'administration a régularisé (avec un éventuel reliquat arrêté).
/// État du PAIEMENT du client en espèces (`orders/{id}.cashPayment`, écrit par le serveur seulement). Toujours une
/// déclaration du livreur ou une décision administrative : jamais une preuve d'encaissement, et jamais un montant encaissé.
enum CashPaymentState {
  /// Le livreur a déclaré avoir encaissé (déclaration, pas une preuve).
  declaredPaid,

  /// Rien n'est établi : ancienne application, commande antérieure au suivi, ou aucune déclaration. `isPaid:false` seul ne prouve rien.
  unknown,

  /// Le livreur déclare un non-paiement ; l'administration ne l'a pas encore examiné.
  nonPaymentPending,

  /// L'administration a confirmé le non-paiement (le reversement reste à régulariser par décision distincte).
  nonPaymentConfirmed,

  /// L'administration a infirmé le signalement de non-paiement.
  nonPaymentRefuted,
}

class CashRemittanceView {
  final String status;
  final int due;
  final int? handedOver;
  final int confirmed;
  final int? resolvedFinalAmount;
  final String? disputeReason;
  final String? disputeByRole;

  final CashPaymentState payment;

  /// Motif saisi par le livreur et justification de l'examen administratif (si présents).
  final String? paymentReason;
  final String? paymentReviewJustification;

  const CashRemittanceView({
    required this.status,
    required this.due,
    required this.handedOver,
    required this.confirmed,
    required this.resolvedFinalAmount,
    required this.disputeReason,
    required this.disputeByRole,
    this.payment = CashPaymentState.declaredPaid,
    this.paymentReason,
    this.paymentReviewJustification,
  });

  static int? _int(Object? v) => v is num && v == v.toInt() ? v.toInt() : null;

  /// null si la commande n'est pas une v2 en espèces avec un suivi de reversement valide : les commandes historiques et
  /// les paiements wallet ne sont jamais concernés.
  static CashRemittanceView? tryParse(Map<String, dynamic> order) {
    if (order['amountsVersion'] != 2 || order['paymentMethod'] != 'cash') {
      return null;
    }
    final r = order['cashRemittance'];
    if (r is! Map) return null;
    final due = _int(r['amountDue']);
    final status = r['status'];
    if (due == null || due < 0 || status is! String) return null;
    final resolution = r['resolution'];
    final dispute = r['dispute'];
    final cp = order['cashPayment'];
    return CashRemittanceView(
      status: status,
      due: due,
      handedOver: _int(r['amountHandedOver']),
      confirmed: _int(r['amountConfirmed']) ?? 0,
      resolvedFinalAmount:
          resolution is Map ? _int(resolution['finalAmount']) : null,
      disputeReason: dispute is Map ? dispute['reason'] as String? : null,
      disputeByRole: dispute is Map ? dispute['byRole'] as String? : null,
      payment: _parsePayment(cp, order['isPaid']),
      paymentReason: cp is Map ? cp['reason'] as String? : null,
      paymentReviewJustification: cp is Map && cp['review'] is Map
          ? (cp['review'] as Map)['justification'] as String?
          : null,
    );
  }

  /// Sans `cashPayment` (commande v2 antérieure au suivi) : `isPaid:true` = encaissement déclaré ; sinon INCONNU, jamais
  /// « non payé » (`isPaid:false` ne prouve rien).
  static CashPaymentState _parsePayment(Object? cp, Object? isPaid) {
    if (cp is! Map) {
      return isPaid == true
          ? CashPaymentState.declaredPaid
          : CashPaymentState.unknown;
    }
    switch (cp['status']) {
      case 'confirmed':
        return CashPaymentState.declaredPaid;
      case 'non_payment_declared':
        switch (cp['verification']) {
          case 'confirmed_unpaid':
            return CashPaymentState.nonPaymentConfirmed;
          case 'refuted':
            return CashPaymentState.nonPaymentRefuted;
          default:
            return CashPaymentState.nonPaymentPending;
        }
      default:
        return CashPaymentState.unknown;
    }
  }

  /// Un non-paiement est déclaré (en attente ou confirmé) : [due] est un montant THÉORIQUE, l'encaissement réel n'est pas
  /// établi (le serveur n'enregistre aucun montant encaissé distinct). Ne jamais le présenter comme une somme encaissée.
  bool get unpaidReported =>
      payment == CashPaymentState.nonPaymentPending ||
      payment == CashPaymentState.nonPaymentConfirmed;

  /// Montants à présenter comme théoriques : non-paiement déclaré ou encaissement inconnu.
  bool get amountsTheoretical =>
      unpaidReported || payment == CashPaymentState.unknown;

  /// Le livreur peut encore signaler un non-paiement (seulement si rien n'est déclaré et que le dossier n'est pas clos).
  bool get canReportNonPayment =>
      payment == CashPaymentState.unknown && !closed;

  /// L'administration peut examiner un non-paiement en attente (le serveur exige le rôle super-administrateur).
  bool get canReviewPayment => payment == CashPaymentState.nonPaymentPending;

  String get paymentLabel {
    switch (payment) {
      case CashPaymentState.declaredPaid:
        return 'Paiement déclaré encaissé par le livreur (déclaration, non vérifiée)';
      case CashPaymentState.unknown:
        return 'Paiement du client non renseigné (inconnu)';
      case CashPaymentState.nonPaymentPending:
        return 'Non-paiement déclaré par le livreur — en attente d’examen';
      case CashPaymentState.nonPaymentConfirmed:
        return 'Non-paiement confirmé par l’administration';
      case CashPaymentState.nonPaymentRefuted:
        return 'Signalement de non-paiement infirmé par l’administration';
    }
  }

  bool get resolved => status == 'resolved';
  bool get disputed => status == 'disputed';
  bool get fullyConfirmed => status == 'confirmed' && confirmed >= due;

  /// Dossier clos (confirmation intégrale ou régularisation administrative).
  bool get closed => resolved || fullyConfirmed;

  /// Même formule que le serveur : le montant reçu est la décision finale de l'administrateur si elle existe, sinon le
  /// montant confirmé par le partenaire.
  int get received => resolved ? (resolvedFinalAmount ?? confirmed) : confirmed;

  /// Reste dû au partenaire. Strictement positif ⇒ jamais présenté comme un règlement intégral.
  int get outstanding => (due - received).clamp(0, due).toInt();

  /// Dossier clos mais avec un reliquat arrêté par décision administrative.
  bool get closedWithShortfall => closed && outstanding > 0;

  // Actions possibles (le serveur revérifie tout : états, montants, droits).
  bool get canDeclare => !closed && !disputed;
  bool get canConfirm => !closed && !disputed;
  bool get canDispute => !closed && !disputed;
  bool get canResolve => !closed;

  String get statusLabel {
    if (resolved) {
      return outstanding > 0
          ? 'Régularisé par l\'administration — reliquat de $outstanding FCFA non réglé'
          : 'Régularisé par l\'administration';
    }
    if (fullyConfirmed) return 'Réglé intégralement';
    if (disputed) return 'Contesté — décision de l\'administration attendue';
    if (status == 'confirmed') {
      return 'Réglé partiellement — il reste $outstanding FCFA';
    }
    if (status == 'declared') {
      return 'Remise déclarée par le livreur — en attente de confirmation du restaurant';
    }
    return 'Aucun reversement déclaré';
  }
}
