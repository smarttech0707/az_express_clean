import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';
import '../models/cash_remittance_view.dart';
import '../services/partner_cash_service.dart';
import '../theme/app_theme.dart';
import 'app_button.dart';
import 'driver_partner_order_panel.dart' show SingleFlight;

enum CashRole { driver, partner, admin }

typedef CashActionRunner = Future<CashActionResult> Function(
  String orderId,
  CashAction action, {
  int? amount,
  String? reason,
  String? requestId,
  int? finalAmount,
  String? justification,
});

Future<CashActionResult> _defaultRunner(
  String orderId,
  CashAction action, {
  int? amount,
  String? reason,
  String? requestId,
  int? finalAmount,
  String? justification,
}) =>
    PartnerCashService.run(
      orderId: orderId,
      action: action,
      amount: amount,
      reason: reason,
      requestId: requestId,
      finalAmount: finalAmount,
      justification: justification,
    );

/// Suivi et actions de reversement cash d'une commande v2 en espèces, pour le livreur, le restaurateur ou l'administrateur.
/// L'état affiché vient du flux Firestore ([view]), jamais d'un succès supposé ; toutes les actions passent par
/// partnerOrderActionCF ([runner]). Aucun wallet, aucune écriture directe.
class CashRemittancePanel extends StatefulWidget {
  final String orderId;
  final CashRemittanceView view;
  final CashRole role;

  /// Total encaissé auprès du client (montant serveur), affiché au livreur.
  final int? totalCollected;
  final CashActionRunner? runner;
  const CashRemittancePanel({
    super.key,
    required this.orderId,
    required this.view,
    required this.role,
    this.totalCollected,
    this.runner,
  });

  @override
  State<CashRemittancePanel> createState() => _CashRemittancePanelState();
}

class _CashRemittancePanelState extends State<CashRemittancePanel> {
  final SingleFlight _flight = SingleFlight();
  bool _busy = false;
  String? _error;

  // Décision administrative : le même identifiant sert à tout rejeu des MÊMES paramètres (idempotence serveur).
  String? _resolveKey;
  String? _resolveRequestId;

  CashActionRunner get _run => widget.runner ?? _defaultRunner;

  Future<void> _perform(
    CashAction action, {
    int? amount,
    String? reason,
    String? requestId,
    int? finalAmount,
    String? justification,
  }) async {
    // Verrou posé avant tout await : un second appui est ignoré.
    final started = await _flight.run(() async {
      if (mounted) {
        setState(() {
          _busy = true;
          _error = null;
        });
      }
      String? success;
      String? failure;
      try {
        final r = await _run(
          widget.orderId,
          action,
          amount: amount,
          reason: reason,
          requestId: requestId,
          finalAmount: finalAmount,
          justification: justification,
        );
        success = r.replay ? 'Action déjà prise en compte.' : r.message;
      } on CashActionException catch (e) {
        failure = e.userMessage;
      } catch (_) {
        failure = const CashActionException('NETWORK', '', retryable: true)
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
    });
    if (!started) return;
  }

  Future<void> _declare() async {
    final v = widget.view;
    final amount = await showDialog<int>(
      context: context,
      builder: (_) => _AmountDialog(
        title: 'Déclarer un reversement',
        label: 'Total remis au restaurant (FCFA)',
        helper:
            'Indiquez le TOTAL remis, y compris ce que le restaurant a déjà confirmé (${v.confirmed} FCFA). '
            'Maximum ${v.due} FCFA.',
        minExclusive: v.confirmed,
        max: v.due,
      ),
    );
    if (amount == null || !mounted) return;
    final ok = await _confirm(
      title: 'Confirmer la déclaration',
      body:
          'Vous déclarez avoir remis $amount FCFA au restaurant, sur ${v.due} FCFA dus.\n\n'
          'Le restaurant devra confirmer la réception : votre déclaration ne règle pas la commande.'
          '${amount < v.due ? '\nIl restera ${v.due - amount} FCFA à reverser.' : ''}',
      action: 'Déclarer $amount FCFA',
    );
    if (ok && mounted) await _perform(CashAction.declare, amount: amount);
  }

  Future<void> _confirmReceipt() async {
    final v = widget.view;
    final amount = await showDialog<int>(
      context: context,
      builder: (_) => _AmountDialog(
        title: 'Confirmer la réception',
        label: 'Total réellement reçu (FCFA)',
        helper:
            'Indiquez le TOTAL réellement reçu en espèces pour cette commande. Dû : ${v.due} FCFA'
            '${v.handedOver != null ? ' · déclaré par le livreur : ${v.handedOver} FCFA' : ''}.',
        minExclusive: v.confirmed > 0 ? v.confirmed - 1 : 0,
        max: v.due,
      ),
    );
    if (amount == null || !mounted) return;
    final ok = await _confirm(
      title: 'Confirmer la réception',
      body: 'Vous confirmez avoir reçu $amount FCFA sur ${v.due} FCFA dus.\n\n'
          '${amount >= v.due ? 'La commande sera réglée intégralement.' : 'Le règlement sera PARTIEL : il restera ${v.due - amount} FCFA dus.'}',
      action: 'Confirmer $amount FCFA',
    );
    if (ok && mounted) await _perform(CashAction.confirm, amount: amount);
  }

  Future<void> _dispute() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _TextDialog(
        title: 'Contester le reversement',
        label: 'Motif (10 à 300 caractères)',
        min: 10,
        max: 300,
        action: 'Contester',
      ),
    );
    if (reason == null || !mounted) return;
    final ok = await _confirm(
      title: 'Confirmer la contestation',
      body: 'Vous contestez ce reversement :\n« $reason »\n\n'
          'Le dossier sera bloqué (plus de déclaration ni de confirmation) jusqu’à la décision de l’administration. '
          'Aucun montant n’est modifié par cette contestation.',
      action: 'Contester',
    );
    if (ok && mounted) await _perform(CashAction.dispute, reason: reason);
  }

  Future<void> _resolve() async {
    final v = widget.view;
    final decision = await showDialog<({int amount, String justification})>(
      context: context,
      builder: (_) => _ResolveDialog(due: v.due),
    );
    if (decision == null || !mounted) return;
    final ok = await _confirm(
      title: 'Décision administrative',
      body:
          'Montant final retenu : ${decision.amount} FCFA sur ${v.due} FCFA dus.\n'
          '${decision.amount < v.due ? 'Reliquat arrêté : ${v.due - decision.amount} FCFA (tracé pour rapprochement, jamais débité automatiquement).' : 'Aucun reliquat.'}\n\n'
          'Cette décision clôt le dossier.',
      action: 'Valider la décision',
    );
    if (!ok || !mounted) return;
    // Mêmes paramètres ⇒ même identifiant (rejeu sûr après coupure) ; paramètres modifiés ⇒ nouvelle décision.
    final key = '${decision.amount}|${decision.justification}';
    if (_resolveKey != key || _resolveRequestId == null) {
      _resolveKey = key;
      _resolveRequestId = const Uuid().v4();
    }
    await _perform(
      CashAction.resolve,
      requestId: _resolveRequestId,
      finalAmount: decision.amount,
      justification: decision.justification,
    );
  }

  Future<bool> _confirm(
      {required String title,
      required String body,
      required String action}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Retour')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            child: Text(action, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final color = v.closed && !v.closedWithShortfall
        ? AppColors.successStrong
        : v.disputed || v.closedWithShortfall
            ? AppColors.errorStrong
            : AppColors.warning;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Espèces dues au restaurant',
              style: GoogleFonts.urbanist(
                  fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          if (v.unpaidReported) ...[
            Text(
              'Paiement du client non confirmé à la livraison (« Non payé »). Le montant dû ci-dessous est THÉORIQUE : '
              'la somme réellement encaissée n’est pas connue. Il n’est pas effacé ; en cas de désaccord, utilisez la contestation.',
              style: GoogleFonts.urbanist(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.errorStrong),
            ),
            const SizedBox(height: 6),
          ],
          if (widget.role == CashRole.driver && widget.totalCollected != null)
            _row(
                v.unpaidReported
                    ? 'Total à encaisser (théorique)'
                    : 'Total encaissé auprès du client',
                '${widget.totalCollected} FCFA'),
          _row(v.unpaidReported ? 'Dû au restaurant (théorique)' : 'Dû au restaurant',
              '${v.due} FCFA'),
          _row('Déclaré remis par le livreur',
              v.handedOver == null ? 'Aucun' : '${v.handedOver} FCFA'),
          _row('Confirmé reçu par le restaurant', '${v.confirmed} FCFA'),
          _row(
              v.closed && v.outstanding == 0
                  ? 'Reste dû'
                  : 'Reste dû au restaurant',
              '${v.outstanding} FCFA',
              bold: true),
          const SizedBox(height: 6),
          Text(v.statusLabel,
              style: GoogleFonts.urbanist(
                  fontSize: 12, fontWeight: FontWeight.w700, color: color)),
          if (v.disputed && v.disputeReason != null) ...[
            const SizedBox(height: 4),
            Text(
              'Motif${v.disputeByRole == 'partner' ? ' (restaurant)' : v.disputeByRole == 'driver' ? ' (livreur)' : ''} : ${v.disputeReason}',
              style: GoogleFonts.urbanist(
                  fontSize: 12, color: AppColors.textMuted),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!,
                style: GoogleFonts.urbanist(
                    fontSize: 12,
                    color: AppColors.errorStrong,
                    fontWeight: FontWeight.w600)),
          ],
          ..._actions(v),
        ],
      ),
    );
  }

  List<Widget> _actions(CashRemittanceView v) {
    final buttons = <Widget>[];
    switch (widget.role) {
      case CashRole.driver:
        if (v.canDeclare) {
          buttons.add(AppButton(
              label: 'Déclarer un reversement',
              icon: Icons.payments_rounded,
              loading: _busy,
              onPressed: _busy ? null : _declare));
        }
        if (v.canDispute) {
          buttons.add(AppButton(
              label: 'Contester',
              variant: AppButtonVariant.danger,
              onPressed: _busy ? null : _dispute));
        }
      case CashRole.partner:
        if (v.canConfirm) {
          buttons.add(AppButton(
              label: 'Confirmer la réception',
              icon: Icons.check_circle_rounded,
              variant: AppButtonVariant.success,
              loading: _busy,
              onPressed: _busy ? null : _confirmReceipt));
        }
        if (v.canDispute) {
          buttons.add(AppButton(
              label: 'Contester',
              variant: AppButtonVariant.danger,
              onPressed: _busy ? null : _dispute));
        }
      case CashRole.admin:
        if (v.canResolve) {
          buttons.add(AppButton(
              label: v.disputed ? 'Trancher le litige' : 'Régulariser',
              icon: Icons.gavel_rounded,
              loading: _busy,
              onPressed: _busy ? null : _resolve));
        }
    }
    if (buttons.isEmpty) return const [];
    return [
      const SizedBox(height: 10),
      for (var i = 0; i < buttons.length; i++) ...[
        if (i > 0) const SizedBox(height: 8),
        buttons[i],
      ],
    ];
  }

  Widget _row(String label, String value, {bool bold = false}) {
    final style = GoogleFonts.urbanist(
        fontSize: 13, fontWeight: bold ? FontWeight.bold : FontWeight.w500);
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

/// Saisie d'un montant entier : > [minExclusive] et ≤ [max]. Le contrôleur appartient à la boîte (libéré après sa fermeture).
class _AmountDialog extends StatefulWidget {
  final String title;
  final String label;
  final String helper;
  final int minExclusive;
  final int max;
  const _AmountDialog({
    required this.title,
    required this.label,
    required this.helper,
    required this.minExclusive,
    required this.max,
  });

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final n = int.tryParse(_controller.text.trim());
    if (n == null || n <= widget.minExclusive || n > widget.max) {
      setState(() => _error =
          'Montant entier requis, supérieur à ${widget.minExclusive} et au plus ${widget.max} FCFA.');
      return;
    }
    Navigator.pop(context, n);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.helper, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              TextField(
                controller: _controller,
                keyboardType: TextInputType.number,
                decoration:
                    InputDecoration(labelText: widget.label, errorText: _error),
                onSubmitted: (_) => _submit(),
              ),
            ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Retour')),
        ElevatedButton(onPressed: _submit, child: const Text('Continuer')),
      ],
    );
  }
}

/// Saisie d'un texte de [min] à [max] caractères (motif de contestation).
class _TextDialog extends StatefulWidget {
  final String title;
  final String label;
  final int min;
  final int max;
  final String action;
  const _TextDialog(
      {required this.title,
      required this.label,
      required this.min,
      required this.max,
      required this.action});

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final t = _controller.text.trim();
    if (t.length < widget.min || t.length > widget.max) {
      setState(
          () => _error = 'Entre ${widget.min} et ${widget.max} caractères.');
      return;
    }
    Navigator.pop(context, t);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: TextField(
          controller: _controller,
          maxLength: widget.max,
          maxLines: 3,
          decoration:
              InputDecoration(labelText: widget.label, errorText: _error),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Retour')),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
          child:
              Text(widget.action, style: const TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

/// Décision administrative : montant final (0..dû) et justification de 10 à 500 caractères, tous deux exigés par le serveur.
class _ResolveDialog extends StatefulWidget {
  final int due;
  const _ResolveDialog({required this.due});

  @override
  State<_ResolveDialog> createState() => _ResolveDialogState();
}

class _ResolveDialogState extends State<_ResolveDialog> {
  final _amount = TextEditingController();
  final _justification = TextEditingController();
  String? _amountError;
  String? _justificationError;

  @override
  void dispose() {
    _amount.dispose();
    _justification.dispose();
    super.dispose();
  }

  void _submit() {
    final n = int.tryParse(_amount.text.trim());
    final j = _justification.text.trim();
    final amountError = (n == null || n < 0 || n > widget.due)
        ? 'Montant entier entre 0 et ${widget.due} FCFA.'
        : null;
    final justificationError = (j.length < 10 || j.length > 500)
        ? 'Justification de 10 à 500 caractères.'
        : null;
    if (amountError != null || justificationError != null) {
      setState(() {
        _amountError = amountError;
        _justificationError = justificationError;
      });
      return;
    }
    Navigator.pop(context, (amount: n!, justification: j));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Décision administrative'),
      content: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'Dû au restaurant : ${widget.due} FCFA. Le montant final est le total réellement reçu par le restaurant ; '
                  'tout reliquat est arrêté et tracé, jamais débité automatiquement.',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              TextField(
                controller: _amount,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: 'Montant final retenu (FCFA)',
                    errorText: _amountError),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _justification,
                maxLength: 500,
                maxLines: 3,
                decoration: InputDecoration(
                    labelText: 'Justification (10 à 500 caractères)',
                    errorText: _justificationError),
              ),
            ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Retour')),
        ElevatedButton(onPressed: _submit, child: const Text('Continuer')),
      ],
    );
  }
}
