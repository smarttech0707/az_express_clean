import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/order_model.dart';
import '../models/partner_v2_info.dart';
import '../theme/app_theme.dart';

/// Une seule action à la fois : tout appel pendant qu'une action est en cours est ignoré (double appui, réponse tardive).
/// Le verrou est libéré à la fin de l'action, réussie ou non (erreur réseau : le livreur peut réessayer).
class SingleFlight {
  bool _busy = false;
  bool get busy => _busy;

  /// Retourne false si l'appel a été ignoré.
  Future<bool> run(Future<void> Function() action) async {
    if (_busy) return false;
    _busy = true;
    try {
      await action();
      return true;
    } finally {
      _busy = false;
    }
  }
}

/// Règles d'affichage et de garde du livreur pour une commande Restaurant/Boulangerie v2. Sans effet financier : ce ne sont
/// que des gardes d'interface ; le serveur (confirmPickup / deliverOrderCF) et les règles Firestore revérifient tout.
class DriverPartnerPickup {
  DriverPartnerPickup._();

  /// La récupération peut-elle être proposée ? Toujours oui pour une commande historique ; pour une v2, seulement quand
  /// le restaurant a déclaré la commande prête (état lu dans le flux Firestore, jamais supposé).
  static bool canPickUp(OrderModel order) =>
      order.partnerV2 == null || order.partnerV2!.readyForPickup;

  static const blockedMessage =
      'Le restaurant n\'a pas encore déclaré la commande prête. Attendez avant de la récupérer.';

  /// Libellé du bouton principal avant récupération.
  static String pickupButtonLabel(OrderModel order, {required bool proofUi}) {
    if (!canPickUp(order)) return 'En préparation — attendez le restaurant';
    return proofUi ? 'Scanner le QR code / récupérer' : 'Colis récupéré';
  }

  /// Montants de l'encaissement en espèces (v2) : tout vient du serveur, rien n'est calculé ici.
  /// Retourne null si un montant manque : on n'affiche alors aucune explication plutôt qu'un chiffre inventé.
  static ({int collect, int toRestaurant, int deliveryFee})? cashBreakdown(
      PartnerV2Info info) {
    final total = info.totalAmount,
        product = info.productAmount,
        fee = info.deliveryFee;
    if (total == null || product == null || fee == null) return null;
    return (collect: total, toRestaurant: product, deliveryFee: fee);
  }
}

/// Panneau livreur d'une commande v2 : état de préparation, produits à récupérer, montants distincts, explication cash.
class DriverPartnerOrderPanel extends StatelessWidget {
  final OrderModel order;

  /// Gain estimé du livreur sur les frais de livraison (calculé par l'appelant avec la même fonction que le reste de l'écran).
  final int? estimatedGain;
  const DriverPartnerOrderPanel(
      {super.key, required this.order, this.estimatedGain});

  String _money(int? v) => v == null ? '—' : '$v FCFA';

  @override
  Widget build(BuildContext context) {
    final info = order.partnerV2;
    if (info == null) return const SizedBox.shrink();
    final picked = order.status == 'picked_up';
    final ready = info.readyForPickup;
    final cash = order.paymentMethod == 'cash';
    final breakdown = DriverPartnerPickup.cashBreakdown(info);
    final bannerColor =
        picked || ready ? AppColors.successStrong : AppColors.warning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!picked)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: bannerColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Row(children: [
              Icon(
                  ready
                      ? Icons.check_circle_rounded
                      : Icons.hourglass_top_rounded,
                  color: bannerColor,
                  size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ready
                      ? 'Prête à récupérer — vous pouvez récupérer la commande.'
                      : '${info.preparationLabel} — ne récupérez pas encore la commande.',
                  style: GoogleFonts.urbanist(
                      fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            ]),
          ),
        if (info.lines.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('À récupérer',
              style: GoogleFonts.urbanist(
                  fontSize: 12, color: AppColors.textLight)),
          for (final l in info.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text('${l.qty} × ${l.name}',
                  style: GoogleFonts.urbanist(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ),
        ],
        const Divider(height: 18),
        _row('Produits (pour le restaurant)', _money(info.productAmount)),
        _row('Frais de livraison (votre rémunération brute)',
            _money(info.deliveryFee)),
        _row('Total payé par le client', _money(info.totalAmount), bold: true),
        if (estimatedGain != null)
          _row('Votre gain estimé', _money(estimatedGain),
              color: AppColors.successStrong),
        const SizedBox(height: 6),
        if (cash && breakdown != null)
          Text(
            'Paiement en espèces : encaissez ${breakdown.collect} FCFA auprès du client. '
            'Sur ce montant, ${breakdown.toRestaurant} FCFA reviennent au restaurant (à lui remettre) ; '
            'les ${breakdown.deliveryFee} FCFA de frais de livraison sont votre rémunération brute.',
            style:
                GoogleFonts.urbanist(fontSize: 12, color: AppColors.textMuted),
          )
        else if (!cash)
          Text(
            'Déjà payée par wallet : n\'encaissez rien auprès du client.',
            style:
                GoogleFonts.urbanist(fontSize: 12, color: AppColors.textMuted),
          ),
      ],
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? color}) {
    final style = GoogleFonts.urbanist(
        fontSize: 13,
        fontWeight: bold ? FontWeight.bold : FontWeight.w500,
        color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Expanded(child: Text(label, style: style)),
        const SizedBox(width: 8),
        Text(value, style: style),
      ]),
    );
  }
}
