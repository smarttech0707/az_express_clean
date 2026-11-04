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

  const PartnerV2Info({
    required this.sellerStatus,
    required this.lines,
    required this.productAmount,
    required this.deliveryFee,
    required this.totalAmount,
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
    );
  }

  /// Le restaurant a déclaré la commande prête. Seule valeur qui autorise la récupération (le serveur et les règles
  /// Firestore revérifient : cet indicateur ne sert qu'à ne pas proposer une action vouée au refus).
  bool get readyForPickup => sellerStatus == 'ready';

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
      lines.length == other.lines.length &&
      Iterable.generate(lines.length).every((i) => lines[i] == other.lines[i]);

  @override
  int get hashCode => Object.hash(
      sellerStatus, productAmount, deliveryFee, totalAmount, lines.length);
}
