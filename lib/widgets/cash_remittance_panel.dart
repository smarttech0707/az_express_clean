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
  String? decision,
});

Future<CashActionResult> _defaultRunner(
  String orderId,
  CashAction action, {
  int? amount,
  String? reason,
  String? requestId,
  int? finalAmount,
  String? justification,
  String? decision,
}) =>
    PartnerCashService.run(
      orderId: orderId,
      action: action,
      amount: amount,
      reason: reason,
      requestId: requestId,
      finalAmount: finalAmount,
      justification: justification,
      decision: decision,
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

  // Examen d'un non-paiement : UN identifiant (UUID v4) par tentative LOGIQUE, créé une seule fois à la confirmation et
  // conservé tant que l'issue est inconnue (coupure réseau) : « Réessayer » le rejoue à l'identique, le serveur dédoublonne.
  // Il est libéré dès que l'issue est connue (succès, rejeu ou refus) ou sur abandon explicite : une nouvelle décision, même
  // de texte identique, reçoit un nouvel identifiant.
  _PendingReview? _pendingReview;

  CashActionRunner get _run => widget.runner ?? _defaultRunner;

  @override
  void didUpdateWidget(CashRemittancePanel old) {
    super.didUpdateWidget(old);
    // Le flux Firestore montre que l'examen a eu lieu (même si la réponse s'est perdue) : plus rien à rejouer.
    if (_pendingReview != null && !widget.view.canReviewPayment) {
      _pendingReview = null;
    }
  }

  Future<_Outcome> _perform(
    CashAction action, {
    int? amount,
    String? reason,
    String? requestId,
    int? finalAmount,
    String? justification,
    String? decision,
  }) async {
    // Verrou posé avant tout await : un second appui est ignoré.
    var outcome = _Outcome.ignored;
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
          decision: decision,
        );
        success = r.replay ? 'Action déjà prise en compte.' : r.message;
        outcome = _Outcome.ok;
      } on CashActionException catch (e) {
        failure = e.userMessage;
        outcome = e.retryable ? _Outcome.retryable : _Outcome.refused;
      } catch (_) {
        failure = const CashActionException('NETWORK', '', retryable: true)
            .userMessage;
        outcome = _Outcome.retryable;
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
    return started ? outcome : _Outcome.ignored;
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

  /// Livreur : signalement d'un non-paiement APRÈS la livraison (le serveur l'exige). La boîte gère elle-même motif,
  /// double appui et erreurs serveur ; l'état affiché vient ensuite du flux Firestore.
  Future<void> _reportNonPayment() async {
    final done = await showDialog<CashActionResult>(
      context: context,
      builder: (_) =>
          NonPaymentReportDialog(orderId: widget.orderId, runner: widget.runner),
    );
    // Annoncé seulement APRÈS la réponse du serveur (la boîte ne se ferme avec un résultat qu'à ce moment-là).
    if (done != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(nonPaymentReportedMessage(done))));
    }
  }

  Future<void> _reviewPayment() async {
    final decision =
        await showDialog<({String decision, String justification})>(
      context: context,
      builder: (_) => const _ReviewDialog(),
    );
    if (decision == null || !mounted) return;
    final confirms = decision.decision == 'confirm_unpaid';
    final ok = await _confirm(
      title: 'Examen du non-paiement',
      body: confirms
          ? 'Vous confirmez que le client n’a pas payé.\n\n'
              'Cette décision ne règle PAS le reversement : le montant dû au restaurant reste inchangé et doit être '
              'régularisé séparément (Régulariser). Aucun wallet n’est modifié.'
          : 'Vous infirmez le signalement de non-paiement.\n\n'
              'Le circuit normal de reversement continue. Aucun montant n’est modifié.',
      action: confirms ? 'Confirmer le non-paiement' : 'Infirmer le signalement',
    );
    if (!ok || !mounted) return;
    // Nouvelle tentative logique ⇒ nouvel identifiant, généré une seule fois (jamais recréé à une erreur réseau).
    setState(() => _pendingReview =
        _PendingReview(decision.decision, decision.justification));
    await _submitReview();
  }

  /// Envoie (ou rejoue à l'identique) la décision en attente. L'identifiant n'est libéré que lorsque l'issue est connue.
  Future<void> _submitReview() async {
    final p = _pendingReview;
    if (p == null) return;
    final outcome = await _perform(
      CashAction.reviewNonPayment,
      requestId: p.requestId,
      decision: p.decision,
      justification: p.justification,
    );
    if (!mounted) return;
    if (outcome == _Outcome.ok || outcome == _Outcome.refused) {
      setState(() => _pendingReview = null);
    }
  }

  void _abandonReview() => setState(() {
        _pendingReview = null;
        _error = null;
      });

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
          Text(v.paymentLabel,
              key: const ValueKey('cash-payment-label'),
              style: GoogleFonts.urbanist(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: v.unpaidReported
                      ? AppColors.errorStrong
                      : AppColors.textMuted)),
          if (v.paymentReason != null && v.unpaidReported)
            Text('Motif du livreur : ${v.paymentReason}',
                style: GoogleFonts.urbanist(
                    fontSize: 12, color: AppColors.textMuted)),
          if (v.paymentReviewJustification != null)
            Text('Examen : ${v.paymentReviewJustification}',
                style: GoogleFonts.urbanist(
                    fontSize: 12, color: AppColors.textMuted)),
          if (v.amountsTheoretical) ...[
            const SizedBox(height: 4),
            Text(
              v.unpaidReported
                  ? 'Le montant dû ci-dessous est THÉORIQUE : la somme réellement encaissée n’est pas connue. '
                      'Il n’est pas effacé ; en cas de désaccord, utilisez la contestation.'
                  : 'L’encaissement n’est pas renseigné : les montants ci-dessous sont THÉORIQUES, la somme réellement encaissée n’est pas connue.',
              style: GoogleFonts.urbanist(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: v.unpaidReported
                      ? AppColors.errorStrong
                      : AppColors.textMuted),
            ),
          ],
          const SizedBox(height: 6),
          if (widget.role == CashRole.driver && widget.totalCollected != null)
            _row(
                v.amountsTheoretical
                    ? 'Total à encaisser (théorique)'
                    : 'Total encaissé auprès du client',
                '${widget.totalCollected} FCFA'),
          _row(
              v.amountsTheoretical
                  ? 'Dû au restaurant (théorique)'
                  : 'Dû au restaurant',
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
        if (v.canReportNonPayment) {
          buttons.add(AppButton(
              label: 'Signaler un non-paiement',
              icon: Icons.report_gmailerrorred_rounded,
              variant: AppButtonVariant.danger,
              onPressed: _busy ? null : _reportNonPayment));
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
        final pending = _pendingReview;
        if (v.canReviewPayment && pending != null) {
          // Issue inconnue (coupure) : la MÊME décision se rejoue avec le même identifiant, ou s'abandonne explicitement.
          buttons.add(AppButton(
              label: 'Réessayer la décision',
              icon: Icons.refresh_rounded,
              loading: _busy,
              onPressed: _busy ? null : _submitReview));
          buttons.add(AppButton(
              label: 'Abandonner la décision',
              variant: AppButtonVariant.danger,
              onPressed: _busy ? null : _abandonReview));
        } else if (v.canReviewPayment) {
          buttons.add(AppButton(
              label: 'Examiner le non-paiement',
              icon: Icons.fact_check_rounded,
              loading: _busy,
              onPressed: _busy ? null : _reviewPayment));
        }
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

enum _Outcome { ignored, ok, retryable, refused }

/// Décision d'examen en attente d'une issue connue. [requestId] (UUID v4) est créé une seule fois, à la construction.
class _PendingReview {
  final String requestId = const Uuid().v4();
  final String decision;
  final String justification;
  _PendingReview(this.decision, this.justification);
}

/// Message d'annonce d'un signalement, construit UNIQUEMENT à partir de la réponse du serveur.
String nonPaymentReportedMessage(CashActionResult r) => r.replay
    ? 'Non-paiement déjà signalé : vérification administrative en attente.'
    : 'Non-paiement signalé : vérification administrative en attente.';

/// Signalement d'un non-paiement par le livreur final, APRÈS la livraison confirmée par le serveur. La boîte possède son
/// contrôleur, verrouille le double appui, affiche l'erreur serveur sans se fermer (motif conservé pour réessayer) et ne se
/// ferme, avec le résultat du serveur, qu'après sa réponse. Un rejeu est sans effet côté serveur.
/// Elle ne modifie ni le dû ni aucun wallet : une vérification administrative est ouverte.
class NonPaymentReportDialog extends StatefulWidget {
  final String orderId;
  final CashActionRunner? runner;
  const NonPaymentReportDialog({super.key, required this.orderId, this.runner});

  @override
  State<NonPaymentReportDialog> createState() => _NonPaymentReportDialogState();
}

class _NonPaymentReportDialogState extends State<NonPaymentReportDialog> {
  final _controller = TextEditingController();
  final SingleFlight _flight = SingleFlight();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _controller.text.trim();
    if (reason.length < 10 || reason.length > 300) {
      setState(() => _error = 'Motif de 10 à 300 caractères.');
      return;
    }
    await _flight.run(() async {
      setState(() {
        _busy = true;
        _error = null;
      });
      String? failure;
      CashActionResult? result;
      try {
        result = await (widget.runner ?? _defaultRunner)(
            widget.orderId, CashAction.declareNonPayment,
            reason: reason);
      } on CashActionException catch (e) {
        failure = e.userMessage;
      } catch (_) {
        failure = const CashActionException('NETWORK', '', retryable: true)
            .userMessage;
      }
      if (!mounted) return;
      if (result != null) {
        Navigator.pop(context, result);
        return;
      }
      setState(() {
        _busy = false;
        _error = failure;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Signaler un non-paiement'),
      content: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Vous déclarez que le client n’a pas payé cette commande. Votre déclaration sera vérifiée par l’administration : '
                  'elle ne supprime pas le montant dû au restaurant et ne bloque pas le client.',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              TextField(
                controller: _controller,
                enabled: !_busy,
                maxLength: 300,
                maxLines: 3,
                decoration: InputDecoration(
                    labelText: 'Motif (10 à 300 caractères)',
                    errorText: _error),
              ),
            ]),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Plus tard')),
        ElevatedButton(
          onPressed: _busy ? null : _submit,
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Signaler', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

/// Examen administratif d'un non-paiement : décision + justification (10 à 500 caractères), exigées par le serveur.
class _ReviewDialog extends StatefulWidget {
  const _ReviewDialog();

  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  final _justification = TextEditingController();
  String _decision = 'confirm_unpaid';
  String? _error;

  @override
  void dispose() {
    _justification.dispose();
    super.dispose();
  }

  void _submit() {
    final j = _justification.text.trim();
    if (j.length < 10 || j.length > 500) {
      setState(() => _error = 'Justification de 10 à 500 caractères.');
      return;
    }
    Navigator.pop(context, (decision: _decision, justification: j));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Examiner le non-paiement'),
      content: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Le livreur déclare que le client n’a pas payé. Cet examen n’efface pas le montant dû et ne règle pas le reversement.',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                  key: const ValueKey('review-confirm'),
                  label: const Text('Confirmer le non-paiement'),
                  selected: _decision == 'confirm_unpaid',
                  onSelected: (_) =>
                      setState(() => _decision = 'confirm_unpaid'),
                ),
                ChoiceChip(
                  key: const ValueKey('review-refute'),
                  label: const Text('Infirmer le signalement'),
                  selected: _decision == 'refute',
                  onSelected: (_) => setState(() => _decision = 'refute'),
                ),
              ]),
              const SizedBox(height: 8),
              TextField(
                controller: _justification,
                maxLength: 500,
                maxLines: 3,
                decoration: InputDecoration(
                    labelText: 'Justification (10 à 500 caractères)',
                    errorText: _error),
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
