import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/partner_order_action_service.dart';
import '../theme/app_theme.dart';
import '../models/cash_remittance_view.dart';
import 'app_button.dart';
import 'cash_remittance_panel.dart';

/// Ligne d'article d'une commande v2 (lue dans `items`, jamais recalculée).
class PartnerV2Line {
  final String name;
  final int qty;
  final int subtotal;
  const PartnerV2Line(this.name, this.qty, this.subtotal);
}

/// Vue d'une commande Restaurant/Boulangerie version 2 (amountsVersion == 2) lue dans le document `orders`.
/// Les montants affichés sont ceux du serveur : productAmount (partenaire), deliveryFee (livreur), totalAmount (client).
/// `budget` vaut deliveryFee pour une v2 : il n'est JAMAIS un montant de produits.
class PartnerV2OrderView {
  final String id;
  final String status;
  final String? sellerStatus;
  final bool partnerAccepted;
  final bool refusedByPartner;
  final String paymentMethod;
  final int? productAmount;
  final int? deliveryFee;
  final int? totalAmount;
  final List<PartnerV2Line> lines;
  final String description;
  final DateTime? createdAt;

  /// Suivi du reversement des espèces (commande v2 livrée et payée en espèces), sinon null.
  final CashRemittanceView? cash;

  const PartnerV2OrderView({
    required this.id,
    required this.status,
    required this.sellerStatus,
    required this.partnerAccepted,
    required this.refusedByPartner,
    required this.paymentMethod,
    required this.productAmount,
    required this.deliveryFee,
    required this.totalAmount,
    required this.lines,
    required this.description,
    required this.createdAt,
    this.cash,
  });

  static bool isV2(Map<String, dynamic> d) => d['amountsVersion'] == 2;

  /// Montant des produits d'une commande, pour les totaux du restaurant : productAmount en v2, budget pour l'historique.
  static int partnerRevenueOf(Map<String, dynamic> d) {
    final v = isV2(d) ? d['productAmount'] : d['budget'];
    return v is num ? v.toInt() : 0;
  }

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  factory PartnerV2OrderView.fromMap(String id, Map<String, dynamic> d,
      {DateTime? createdAt}) {
    final items = d['items'];
    final lines = <PartnerV2Line>[
      if (items is List)
        for (final it in items.whereType<Map>())
          PartnerV2Line('${it['name'] ?? 'Article'}', _int(it['qty']) ?? 0,
              _int(it['subtotal']) ?? 0),
    ];
    final seller = d['sellerStatus'];
    return PartnerV2OrderView(
      id: id,
      status: (d['status'] as String?) ?? 'pending',
      sellerStatus: seller is String && seller.isNotEmpty ? seller : null,
      partnerAccepted: d['partnerAcceptedAtMs'] is num,
      refusedByPartner: d['partnerRefusal'] != null,
      paymentMethod: (d['paymentMethod'] as String?) ?? 'cash',
      productAmount: _int(d['productAmount']),
      deliveryFee: _int(d['deliveryFee']),
      totalAmount: _int(d['totalAmount']),
      lines: lines,
      description: (d['description'] as String?) ?? 'Commande',
      createdAt: createdAt,
      cash: CashRemittanceView.tryParse(d),
    );
  }

  bool get closed => status == 'delivered' || status == 'cancelled';
  bool get pickedUp => status == 'picked_up';

  /// Actions possibles, dérivées de l'état serveur (jamais d'un état local optimiste). Le serveur revérifie tout.
  bool get canStartPreparation => !closed && !pickedUp && sellerStatus == null;
  bool get canRefuse => !closed && !pickedUp && sellerStatus == null;
  bool get canMarkReady => !closed && !pickedUp && sellerStatus == 'preparing';

  String get preparationLabel {
    if (status == 'cancelled') return refusedByPartner ? 'Refusée' : 'Annulée';
    switch (sellerStatus) {
      case 'preparing':
        return 'En préparation';
      case 'ready':
        return 'Prête';
      default:
        return partnerAccepted
            ? 'Acceptée, préparation à déclarer'
            : 'À accepter';
    }
  }

  String get deliveryLabel {
    switch (status) {
      case 'pending':
        return partnerAccepted
            ? 'Recherche d\'un livreur'
            : 'Livreur : après votre acceptation';
      case 'broadcast':
        return 'Recherche d\'un livreur';
      case 'assigned':
        return 'Livreur contacté';
      case 'accepted':
        return 'Livreur en route';
      case 'picked_up':
        return 'En livraison';
      case 'delivered':
        return 'Livrée';
      case 'cancelled':
        return 'Annulée';
      default:
        return status;
    }
  }

  /// Texte d'aide affiché tant que la préparation est déclarée mais la commande pas encore prête.
  bool get showPreparingHint =>
      !closed && !pickedUp && sellerStatus == 'preparing';
}

typedef PartnerActionRunner = Future<PartnerActionResult>
    Function(String orderId, PartnerAction action, {String? reason});

Future<PartnerActionResult> _defaultRunner(String orderId, PartnerAction action,
        {String? reason}) =>
    PartnerOrderActionService.run(
        orderId: orderId, action: action, reason: reason);

/// Carte d'une commande v2 dans le tableau de bord restaurateur. Toutes les actions passent par partnerOrderActionCF
/// (via [runner]) ; l'état affiché vient du flux Firestore, jamais d'un succès supposé.
class PartnerV2OrderCard extends StatefulWidget {
  final PartnerV2OrderView order;
  final PartnerActionRunner? runner;
  final CashActionRunner? cashRunner;
  const PartnerV2OrderCard({super.key, required this.order, this.runner, this.cashRunner});

  @override
  State<PartnerV2OrderCard> createState() => _PartnerV2OrderCardState();
}

class _PartnerV2OrderCardState extends State<PartnerV2OrderCard> {
  bool _busy = false;
  String? _error;

  PartnerActionRunner get _run => widget.runner ?? _defaultRunner;

  Future<void> _perform(PartnerAction action, {String? reason}) async {
    // Verrou posé avant tout await : un second appui est ignoré.
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? success;
    String? failure;
    try {
      final r = await _run(widget.order.id, action, reason: reason);
      success = r.replay ? 'Action déjà prise en compte.' : r.message;
    } on PartnerActionException catch (e) {
      failure = e.userMessage;
    } catch (_) {
      failure = const PartnerActionException('NETWORK', '', retryable: true)
          .userMessage;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failure;
    });
    if (success != null && success.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(success)));
    }
  }

  Future<void> _confirmStart() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Accepter et préparer'),
        content: const Text(
          'Vous acceptez la commande et déclarez que la préparation commence.\n\n'
          'AZ Express recherche ensuite un livreur. Une fois la préparation commencée, la commande ne peut plus être refusée : '
          'pensez à la marquer « prête » dès qu\'elle l\'est.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Retour')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('Accepter et préparer',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _perform(PartnerAction.startPreparation);
  }

  Future<void> _confirmRefuse() async {
    // null = retour ; sinon le motif saisi (éventuellement vide : le serveur ne l'exige pas).
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _RefuseDialog(),
    );
    if (reason != null && mounted) {
      await _perform(PartnerAction.refuse, reason: reason);
    }
  }

  String _money(int? v) => v == null ? '—' : '$v FCFA';

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final closedBad = o.status == 'cancelled';
    final prepColor = closedBad
        ? AppColors.error
        : o.sellerStatus == 'ready'
            ? AppColors.successStrong
            : o.sellerStatus == 'preparing'
                ? AppColors.blueDark
                : AppColors.warning;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: AppShadow.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(o.createdAt != null ? _ago(o.createdAt!) : 'Commande',
                  style: GoogleFonts.urbanist(
                      fontSize: 12, color: AppColors.textLight)),
            ),
            _chip(o.preparationLabel, prepColor),
          ]),
          const SizedBox(height: 8),
          if (o.lines.isEmpty)
            Text(o.description,
                style: GoogleFonts.urbanist(
                    fontWeight: FontWeight.w600, fontSize: 14))
          else
            for (final l in o.lines)
              _row('${l.qty} × ${l.name}', _money(l.subtotal), size: 13),
          const Divider(height: 18),
          _row('Produits (pour vous)', _money(o.productAmount)),
          _row('Frais de livraison (livreur)', _money(o.deliveryFee)),
          _row('Total payé par le client', _money(o.totalAmount), bold: true),
          const SizedBox(height: 4),
          Text(
            o.paymentMethod == 'wallet'
                ? 'Payée par wallet'
                : 'Paiement en espèces à la livraison',
            style:
                GoogleFonts.urbanist(fontSize: 12, color: AppColors.textLight),
          ),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.delivery_dining_rounded,
                size: 16, color: AppColors.textLight),
            const SizedBox(width: 6),
            Expanded(
                child: Text(o.deliveryLabel,
                    style: GoogleFonts.urbanist(
                        fontSize: 12, fontWeight: FontWeight.w600))),
          ]),
          if (o.showPreparingHint) ...[
            const SizedBox(height: 8),
            Text(
              'Préparation déclarée : AZ Express recherche un livreur. Marquez la commande « prête » dès qu\'elle l\'est.',
              style:
                  GoogleFonts.urbanist(fontSize: 12, color: AppColors.blueDark),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: GoogleFonts.urbanist(
                    fontSize: 12,
                    color: AppColors.errorStrong,
                    fontWeight: FontWeight.w600)),
          ],
          if (o.cash != null)
            CashRemittancePanel(
              orderId: o.id,
              view: o.cash!,
              role: CashRole.partner,
              runner: widget.cashRunner,
            ),
          if (o.canStartPreparation || o.canMarkReady)
            const SizedBox(height: 12),
          if (o.canStartPreparation)
            Row(children: [
              Expanded(
                child: AppButton(
                  label: 'Accepter et préparer',
                  icon: Icons.restaurant_rounded,
                  loading: _busy,
                  onPressed: _busy ? null : _confirmStart,
                ),
              ),
              if (o.canRefuse) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: AppButton(
                    label: 'Refuser',
                    variant: AppButtonVariant.danger,
                    onPressed: _busy ? null : _confirmRefuse,
                  ),
                ),
              ],
            ]),
          if (o.canMarkReady)
            AppButton(
              label: 'Marquer prête',
              icon: Icons.check_circle_rounded,
              variant: AppButtonVariant.success,
              loading: _busy,
              onPressed: _busy ? null : () => _perform(PartnerAction.markReady),
            ),
        ],
      ),
    );
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.sm)),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w700)),
      );

  Widget _row(String label, String value,
      {bool bold = false, double size = 14}) {
    final style = GoogleFonts.urbanist(
        fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.w500);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Expanded(child: Text(label, style: style)),
        const SizedBox(width: 8),
        Text(value, style: style),
      ]),
    );
  }

  String _ago(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 60) {
      return 'Il y a ${diff.inMinutes < 0 ? 0 : diff.inMinutes} min';
    }
    if (diff.inHours < 24) return 'Il y a ${diff.inHours}h';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

/// Boîte de refus : possède son propre contrôleur (libéré avec la boîte, après l'animation de fermeture).
class _RefuseDialog extends StatefulWidget {
  const _RefuseDialog();

  @override
  State<_RefuseDialog> createState() => _RefuseDialogState();
}

class _RefuseDialogState extends State<_RefuseDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Refuser la commande'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Le client sera remboursé intégralement. Cette action est définitive.'),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              maxLength: 200,
              decoration:
                  const InputDecoration(labelText: 'Motif (facultatif)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Retour')),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
          child: const Text('Refuser', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
