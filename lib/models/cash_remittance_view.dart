/// Suivi du reversement des espèces dues au partenaire pour une commande Restaurant/Boulangerie v2 payée en espèces
/// (`orders/{id}.cashRemittance`, écrit UNIQUEMENT par partnerOrderActionCF). Lecture seule.
///
/// Les montants sont CUMULATIFS (comme côté serveur) : `handedOver` = total déclaré par le livreur, `confirmed` = total
/// confirmé par le partenaire. Une déclaration du livreur n'est jamais une confirmation. Le règlement n'est intégral que si
/// le partenaire a confirmé la totalité du dû, ou si l'administration a régularisé (avec un éventuel reliquat arrêté).
class CashRemittanceView {
  final String status;
  final int due;
  final int? handedOver;
  final int confirmed;
  final int? resolvedFinalAmount;
  final String? disputeReason;
  final String? disputeByRole;

  /// `orders.isPaid` : pour une commande en espèces, il ne passe à true que si le livreur a déclaré l'encaissement à la
  /// livraison. false = « Non payé » déclaré (ou encaissement jamais déclaré) : le serveur crée pourtant le dû théorique.
  final bool paymentConfirmed;

  const CashRemittanceView({
    required this.status,
    required this.due,
    required this.handedOver,
    required this.confirmed,
    required this.resolvedFinalAmount,
    required this.disputeReason,
    required this.disputeByRole,
    this.paymentConfirmed = true,
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
    return CashRemittanceView(
      status: status,
      due: due,
      handedOver: _int(r['amountHandedOver']),
      confirmed: _int(r['amountConfirmed']) ?? 0,
      resolvedFinalAmount:
          resolution is Map ? _int(resolution['finalAmount']) : null,
      disputeReason: dispute is Map ? dispute['reason'] as String? : null,
      disputeByRole: dispute is Map ? dispute['byRole'] as String? : null,
      paymentConfirmed: order['isPaid'] == true,
    );
  }

  /// Paiement client non confirmé à la livraison : [due] est un montant THÉORIQUE, l'encaissement réel n'est pas établi
  /// (le serveur n'enregistre aucun montant encaissé distinct). Ne jamais le présenter comme une somme encaissée.
  bool get unpaidReported => !paymentConfirmed;

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
