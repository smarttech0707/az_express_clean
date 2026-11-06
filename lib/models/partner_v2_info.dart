import 'package:cloud_functions/cloud_functions.dart' show FirebaseFunctionsException;

/// Ligne d'article d'une commande Restaurant/Boulangerie v2 (lue dans `items`, jamais recalculée).
class PartnerV2Line {
  final String name;
  final int qty;
  final int subtotal;
  const PartnerV2Line(this.name, this.qty, this.subtotal);

  @override
  bool operator ==(Object other) =>
      other is PartnerV2Line &&
      name == other.name &&
      qty == other.qty &&
      subtotal == other.subtotal;

  @override
  int get hashCode => Object.hash(name, qty, subtotal);
}

/// Données d'une commande partenaire v2 utiles au livreur. Lecture seule : tous les montants sont ceux du serveur.
/// `budget` d'une v2 = frais de livraison (jamais les produits) ; le total payé par le client est [totalAmount].
class PartnerV2Info {
  final String? sellerStatus;
  final List<PartnerV2Line> lines;
  final int? productAmount;
  final int? deliveryFee;
  final int? totalAmount;

  /// Refus par le restaurant (`partnerRefusal`) ; [refusalReason] est le motif saisi par le restaurant, null s'il n'en a pas donné.
  final bool refusedByPartner;
  final String? refusalReason;

  const PartnerV2Info({
    required this.sellerStatus,
    required this.lines,
    required this.productAmount,
    required this.deliveryFee,
    required this.totalAmount,
    this.refusedByPartner = false,
    this.refusalReason,
  });

  static const sellerTypes = ['restaurant', 'boulangerie'];

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  /// null pour toute commande qui n'est pas une v2 Restaurant/Boulangerie : les flux historiques ne sont pas concernés.
  static PartnerV2Info? tryParse(Map<String, dynamic> data) {
    if (data['amountsVersion'] != 2 ||
        !sellerTypes.contains(data['sellerType'])) {
      return null;
    }
    final items = data['items'];
    final seller = data['sellerStatus'];
    final refusal = data['partnerRefusal'];
    final reason = refusal is Map ? refusal['reason'] : null;
    return PartnerV2Info(
      sellerStatus: seller is String && seller.isNotEmpty ? seller : null,
      lines: [
        if (items is List)
          for (final it in items.whereType<Map>())
            PartnerV2Line('${it['name'] ?? 'Article'}', _int(it['qty']) ?? 0,
                _int(it['subtotal']) ?? 0),
      ],
      productAmount: _int(data['productAmount']),
      deliveryFee: _int(data['deliveryFee']),
      totalAmount: _int(data['totalAmount']),
      refusedByPartner: refusal is Map,
      refusalReason:
          reason is String && reason.trim().isNotEmpty ? reason.trim() : null,
    );
  }

  /// Le restaurant a déclaré la commande prête. Seule valeur qui autorise la récupération (le serveur et les règles
  /// Firestore revérifient : cet indicateur ne sert qu'à ne pas proposer une action vouée au refus).
  bool get readyForPickup => sellerStatus == 'ready';

  /// Montant à montrer au CLIENT : le total payé. `budget` d'une v2 n'est que le frais de livraison (voir ci-dessus).
  static int clientAmount(int budget, PartnerV2Info? v2) => v2?.totalAmount ?? budget;

  /// Titre d'une commande annulée vu par le client (statut serveur `cancelled`).
  String get cancelledTitle =>
      refusedByPartner ? 'Refusée par le restaurant' : 'Annulée';

  /// Message client pour une commande annulée. Le motif n'est affiché que s'il a été fourni par le restaurant.
  String get cancelledMessage => refusedByPartner
      ? (refusalReason != null
          ? 'Motif du restaurant : $refusalReason'
          : 'Le restaurant a refusé votre commande.')
      : 'Cette commande a été annulée.';

  /// Une commande annulée reste visible pour le client uniquement pour les v2 (les flux historiques gardent leur affichage).
  static bool visibleToClient(String status, PartnerV2Info? v2) =>
      status != 'cancelled' || v2 != null;

  /// Message de l'échec d'une annulation demandée par le client. Le refus serveur est conservé (jamais contourné).
  static String cancelFailureMessage(Object error) {
    final text = error is FirebaseFunctionsException
        ? '${error.code} ${error.message ?? ''} ${error.details ?? ''}'
        : error.toString();
    if (text.contains('ORDER_IN_PREPARATION') ||
        text.contains('commencé la préparation')) {
      return "Le restaurant a déjà commencé la préparation de votre commande. Vous ne pouvez plus l'annuler depuis l'application.";
    }
    if (text.contains('ne peut plus être annulée') ||
        text.contains('ORDER_NOT_CANCELLABLE')) {
      return "Cette commande ne peut plus être annulée.";
    }
    return "Échec de l'annulation. Réessayez dans quelques instants.";
  }

  String get preparationLabel {
    switch (sellerStatus) {
      case 'ready':
        return 'Prête à récupérer';
      case 'preparing':
        return 'En préparation';
      default:
        return 'En attente de préparation';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PartnerV2Info &&
      sellerStatus == other.sellerStatus &&
      productAmount == other.productAmount &&
      deliveryFee == other.deliveryFee &&
      totalAmount == other.totalAmount &&
      refusedByPartner == other.refusedByPartner &&
      refusalReason == other.refusalReason &&
      lines.length == other.lines.length &&
      Iterable.generate(lines.length).every((i) => lines[i] == other.lines[i]);

  @override
  int get hashCode => Object.hash(
      sellerStatus, productAmount, deliveryFee, totalAmount, lines.length);
}
