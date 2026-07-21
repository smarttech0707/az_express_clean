import 'dart:async';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/feexpay_service.dart';
import '../../services/wallet_service.dart';
import '../../models/feexpay_transaction.dart';
import '../../widgets/tap_effect.dart';
import '../../theme/app_theme.dart';

// ─── Constantes visuelles ───────────────────────────────────────────────────
const _kOrange  = AppColors.primary;
const _kOrangeL = Color(0xFFFF8F00);
const _kBg      = Color(0xFFF5F5F5);

// ─── Opérateurs ─────────────────────────────────────────────────────────────
class _Operator {
  final String id;
  final String label;
  final Color  color;
  final String hint;
  final String logo;
  const _Operator(this.id, this.label, this.color, this.hint, this.logo);
}

const _operators = [
  _Operator('mtn',    'MTN',    Color(0xFFFFBB00), 'Ex: 05 00 00 00 00', 'assets/payment/mtn.png'),
  _Operator('orange', 'Orange', Color(0xFFFF6600), 'Ex: 07 00 00 00 00', 'assets/payment/orange.png'),
  _Operator('moov',   'Moov',   Color(0xFF005EB8), 'Ex: 01 00 00 00 00', 'assets/payment/moov.png'),
  _Operator('wave',   'Wave',   Color(0xFF00B9F1), 'Ex: 07 00 00 00 00', 'assets/payment/wave.png'),
];

const _presets = [500, 1000, 2000, 5000, 10000, 25000];

// ═══════════════════════════════════════════════════════════════════════════
// ÉCRAN PRINCIPAL
// ═══════════════════════════════════════════════════════════════════════════
class RechargeWalletScreen extends StatefulWidget {
  final String userType;
  const RechargeWalletScreen({super.key, this.userType = 'client'});

  @override
  State<RechargeWalletScreen> createState() => _RechargeWalletScreenState();
}

class _RechargeWalletScreenState extends State<RechargeWalletScreen> {
  // ── Formulaire ──────────────────────────────────────────────────────────
  int     _selectedPreset  = 1000;
  bool    _useCustomAmount = false;
  String  _selectedOp      = 'mtn';
  int     _walletBalance   = 0;

  final _amountCtrl = TextEditingController();
  final _phoneCtrl  = TextEditingController();

  // ── États paiement ──────────────────────────────────────────────────────
  bool    _loading      = false;
  String? _txId;
  FeexPayTransaction? _tx;
  String? _errorMsg;
  StreamSubscription<FeexPayTransaction?>? _txSub;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  @override
  void dispose() {
    _txSub?.cancel();
    _amountCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  String get _collection {
    const map = {
      'driver':      'livreurs',
      'seller':      'sellers',
      'restaurant':  'restaurants',
      'boulangerie': 'boulangeries',
      'pharmacie':   'pharmacies',
    };
    return map[widget.userType] ?? 'clients';
  }

  Future<void> _loadUserData() async {
    final balance = await WalletService.getBalance(collection: _collection);
    await WalletService.getUserName(collection: _collection);
    if (mounted) {
      setState(() {
        _walletBalance = balance;
      });
    }
  }

  int get _amount =>
      _useCustomAmount
          ? (int.tryParse(_amountCtrl.text.trim()) ?? 0)
          : _selectedPreset;

  _Operator get _currentOp =>
      _operators.firstWhere((o) => o.id == _selectedOp);

  // ── Lancer le paiement ──────────────────────────────────────────────────
  Future<void> _startPayment() async {
    final phone = _phoneCtrl.text.trim();

    if (_amount < 100) {
      _showError('Montant minimum : 100 FCFA');
      return;
    }
    if (phone.length < 8) {
      _showError('Numéro de téléphone invalide');
      return;
    }

    setState(() {
      _loading  = true;
      _errorMsg = null;
    });

    try {
      final txId = await FeexPayService.initiatePayment(
        amount:   _amount,
        phone:    phone,
        operator: _selectedOp,
        userType: widget.userType,
      );

      if (!mounted) return;
      setState(() {
        _txId    = txId;
        _loading = false;
      });

      // Écouter le statut en temps réel
      _txSub = FeexPayService.watchTransaction(txId).listen((tx) {
        if (!mounted) return;
        setState(() => _tx = tx);
        if (tx != null && (tx.isCompleted || tx.isFailed || tx.isCancelled)) {
          _txSub?.cancel();
          if (tx.isCompleted) _loadUserData(); // rafraîchir le solde
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading  = false;
        _errorMsg = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700),
    );
  }

  void _reset() {
    _txSub?.cancel();
    setState(() {
      _txId    = null;
      _tx      = null;
      _errorMsg = null;
    });
  }

  // ── BUILD ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: CustomScrollView(
        slivers: [
          // ── AppBar avec solde ──────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 180,
            pinned: true,
            backgroundColor: _kOrange,
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFFE65100), _kOrangeL],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.account_balance_wallet_rounded,
                          color: Colors.white70, size: 32),
                      const SizedBox(height: 8),
                      Text('Mon Wallet',
                          style: GoogleFonts.urbanist(
                              color: Colors.white70, fontSize: 13)),
                      Text(
                        _fmtAmount(_walletBalance),
                        style: GoogleFonts.urbanist(
                            color: Colors.white,
                            fontSize: 42,
                            fontWeight: FontWeight.w900,
                            height: 1.1),
                      ),
                      Text('FCFA',
                          style: GoogleFonts.urbanist(
                              color: Colors.white70,
                              fontSize: 14,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),
            title: Text('Recharger mon Wallet',
                style: GoogleFonts.urbanist(
                    fontWeight: FontWeight.w600, fontSize: 16)),
            centerTitle: true,
          ),

          // ── Contenu ───────────────────────────────────────────────────
          SliverPadding(
            padding: const EdgeInsets.all(20),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (_txId == null) ...[
                  _buildForm(),
                ] else ...[
                  _buildPaymentStatus(),
                ],
              ]),
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FORMULAIRE
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Sélection montant ────────────────────────────────────────────
        _sectionTitle('Montant à recharger'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            ..._presets.map((p) => _AmountChip(
              amount:   p,
              selected: !_useCustomAmount && _selectedPreset == p,
              onTap: () => setState(() {
                _selectedPreset  = p;
                _useCustomAmount = false;
              }),
            )),
            _CustomChip(
              selected: _useCustomAmount,
              onTap: () => setState(() => _useCustomAmount = true),
            ),
          ],
        ),
        if (_useCustomAmount) ...[
          const SizedBox(height: 12),
          _inputField(
            ctrl:  _amountCtrl,
            hint:  'Montant personnalisé (min 100 FCFA)',
            icon:  Icons.edit_rounded,
            type:  TextInputType.number,
            onChange: (_) => setState(() {}),
          ),
        ],

        const SizedBox(height: 28),

        // ── Sélection opérateur ──────────────────────────────────────────
        _sectionTitle('Opérateur Mobile Money'),
        const SizedBox(height: 12),
        Row(
          children: _operators.map((op) {
            final selected = _selectedOp == op.id;
            return Expanded(
              child: TapEffect(
                onTap: () => setState(() => _selectedOp = op.id),
                scaleDown: 0.93,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: selected
                        ? op.color.withValues(alpha: 0.15)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: selected ? op.color : Colors.grey.shade300,
                      width: selected ? 2 : 1,
                    ),
                    boxShadow: selected
                        ? [BoxShadow(
                            color: op.color.withValues(alpha: 0.25),
                            blurRadius: 8, offset: const Offset(0, 3))]
                        : null,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(
                          color: op.color.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(6),
                        child: Image.asset(
                          op.logo,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Text(
                            op.label[0],
                            style: TextStyle(
                              color: op.color,
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(op.label,
                          style: GoogleFonts.urbanist(
                            fontSize: 10.5,
                            fontWeight: selected
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: selected ? op.color : Colors.black87,
                          )),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),

        const SizedBox(height: 28),

        // ── Numéro de téléphone ──────────────────────────────────────────
        _sectionTitle('Numéro ${_currentOp.label}'),
        const SizedBox(height: 12),
        _inputField(
          ctrl:  _phoneCtrl,
          hint:  _currentOp.hint,
          icon:  Icons.phone_rounded,
          type:  TextInputType.phone,
        ),

        const SizedBox(height: 8),
        _infoBox(
          'Vous recevrez une demande de confirmation sur ce numéro.',
          _kOrange,
        ),

        if (_errorMsg != null) ...[
          const SizedBox(height: 12),
          _warningBox(_errorMsg!),
        ],

        const SizedBox(height: 28),

        // ── Récapitulatif ────────────────────────────────────────────────
        if (_amount > 0) _buildSummary(),

        const SizedBox(height: 20),

        // ── Bouton ───────────────────────────────────────────────────────
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ScaleButton(
            onPressed: _loading || _amount < 100 ? null : _startPayment,
            style: ElevatedButton.styleFrom(
              backgroundColor: _kOrange,
              disabledBackgroundColor: Colors.grey.shade300,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              elevation: 2,
            ),
            child: _loading
                ? const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5))
                : Text(
                    'Payer  ${_fmtAmount(_amount)} FCFA  →',
                    style: GoogleFonts.urbanist(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16),
                  ),
          ),
        ),

        const SizedBox(height: 12),
        Center(
          child: Text(
            'Paiement sécurisé via FeexPay',
            style: GoogleFonts.urbanist(fontSize: 11, color: Colors.grey),
          ),
        ),

        const SizedBox(height: 32),

        // ── Historique ───────────────────────────────────────────────────
        _buildHistory(),
      ],
    );
  }

  Widget _buildSummary() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kOrange.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          _summaryRow('Montant',   '${_fmtAmount(_amount)} FCFA'),
          const Divider(height: 16),
          _summaryRow('Opérateur', _currentOp.label),
          const Divider(height: 16),
          _summaryRow('Téléphone', _phoneCtrl.text.trim().isEmpty
              ? '—' : _phoneCtrl.text.trim()),
          const Divider(height: 16),
          _summaryRow('Nouveau solde',
            '${_fmtAmount(_walletBalance + _amount)} FCFA',
            bold: true,
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value, {bool bold = false}) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label,
          style: GoogleFonts.urbanist(
              fontSize: 13, color: Colors.grey.shade600)),
      Text(value,
          style: GoogleFonts.urbanist(
              fontSize: 13,
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              color: bold ? _kOrange : Colors.black87)),
    ],
  );

  // ══════════════════════════════════════════════════════════════════════════
  // STATUT PAIEMENT
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildPaymentStatus() {
    final isDone     = _tx?.isCompleted  ?? false;
    final isFailed   = _tx?.isFailed     ?? false;
    final isCancelled = _tx?.isCancelled ?? false;
    final isPending  = !isDone && !isFailed && !isCancelled;

    final icon  = isDone      ? Icons.check_circle_rounded
        : isFailed            ? Icons.cancel_rounded
        : isCancelled         ? Icons.cancel_outlined
        : Icons.hourglass_top_rounded;

    final color = isDone      ? const Color(0xFF2E7D32)
        : isFailed || isCancelled ? Colors.red
        : _kOrange;

    final title = isDone      ? 'Wallet crédité  ✓'
        : isFailed            ? 'Paiement échoué'
        : isCancelled         ? 'Paiement annulé'
        : 'En attente de confirmation…';

    final subtitle = isDone
        ? 'Votre wallet a été crédité de ${_fmtAmount(_amount)} FCFA.\nNouvel solde : ${_fmtAmount(_walletBalance)} FCFA.'
        : isFailed
            ? 'Le paiement n\'a pas abouti. Votre solde n\'a pas été modifié.'
            : isCancelled
                ? 'Paiement annulé. Votre solde n\'a pas été modifié.'
                : 'Confirmez le paiement de ${_fmtAmount(_amount)} FCFA sur votre téléphone ${_currentOp.label}.';

    return Column(
      children: [
        const SizedBox(height: 40),

        // ── Icône animée ─────────────────────────────────────────────────
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: isPending
              ? SizedBox(
                  key: const ValueKey('spin'),
                  width: 80, height: 80,
                  child: CircularProgressIndicator(
                      color: color, strokeWidth: 3))
              : Icon(icon,
                  key: ValueKey(icon), color: color, size: 80),
        ),

        const SizedBox(height: 24),

        Text(title,
            style: GoogleFonts.urbanist(
              fontSize: 22, fontWeight: FontWeight.bold, color: color)),

        const SizedBox(height: 12),

        Text(subtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.urbanist(
                fontSize: 14, color: Colors.grey.shade600, height: 1.5)),

        if (isPending) ...[
          const SizedBox(height: 20),
          _infoBox(
            'Cette page se met à jour automatiquement.\nNe fermez pas l\'application.',
            _kOrange,
          ),
        ],

        const SizedBox(height: 32),

        // ── Bouton ───────────────────────────────────────────────────────
        SizedBox(
          width: double.infinity,
          child: ScaleButton(
            onPressed: isDone
                ? () => Navigator.pop(context)
                : isFailed || isCancelled
                    ? _reset
                    : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: isDone ? const Color(0xFF2E7D32) : _kOrange,
              disabledBackgroundColor: Colors.grey.shade200,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            child: Text(
              isDone
                  ? 'Fermer'
                  : isFailed || isCancelled
                      ? 'Réessayer'
                      : 'En attente…',
              style: GoogleFonts.urbanist(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16),
            ),
          ),
        ),

        if (isPending) ...[
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Vérifier plus tard',
                style: GoogleFonts.urbanist(color: Colors.grey)),
          ),
        ],
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HISTORIQUE
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildHistory() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Historique des recharges'),
        const SizedBox(height: 12),
        StreamBuilder<List<FeexPayTransaction>>(
          stream: FeexPayService.watchMyTransactions(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                  child: CircularProgressIndicator(color: _kOrange));
            }
            final txs = snap.data ?? [];
            if (txs.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      Icon(Icons.receipt_long_outlined,
                          size: 52, color: Colors.grey.shade400),
                      const SizedBox(height: 10),
                      Text('Aucune transaction',
                          style: GoogleFonts.urbanist(
                              color: Colors.grey, fontSize: 14)),
                    ],
                  ),
                ),
              );
            }
            return Column(
              children: txs.map((tx) => _TxTile(tx: tx)).toList(),
            );
          },
        ),
      ],
    );
  }

  // ── Helpers UI ──────────────────────────────────────────────────────────
  Widget _sectionTitle(String text) => Text(
        text,
        style: GoogleFonts.urbanist(
            fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black54),
      );

  Widget _infoBox(String text, Color color) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: color, size: 16),
            const SizedBox(width: 8),
            Expanded(
                child: Text(text,
                    style: GoogleFonts.urbanist(
                        fontSize: 12, color: Colors.grey.shade700))),
          ],
        ),
      );

  Widget _warningBox(String text) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.shade200),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Colors.red.shade700, size: 16),
            const SizedBox(width: 8),
            Expanded(
                child: Text(text,
                    style: GoogleFonts.urbanist(
                        fontSize: 12, color: Colors.red.shade700))),
          ],
        ),
      );

  Widget _inputField({
    required TextEditingController ctrl,
    required String hint,
    required IconData icon,
    TextInputType? type,
    ValueChanged<String>? onChange,
  }) =>
      TextField(
        controller: ctrl,
        keyboardType: type,
        onChanged: onChange,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.urbanist(fontSize: 13),
          prefixIcon: Icon(icon, size: 18, color: Colors.grey),
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.grey.shade300)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.grey.shade300)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: _kOrange, width: 1.8)),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// CHIP MONTANT
// ─────────────────────────────────────────────────────────────────────────────
class _AmountChip extends StatelessWidget {
  final int amount;
  final bool selected;
  final VoidCallback onTap;
  const _AmountChip({required this.amount, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: BoxDecoration(
            color: selected ? _kOrange : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? _kOrange : Colors.grey.shade300),
          ),
          child: Text(
            '${_fmtAmount(amount)} F',
            style: GoogleFonts.urbanist(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: selected ? Colors.white : Colors.black87,
            ),
          ),
        ),
      );
}

class _CustomChip extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  const _CustomChip({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: BoxDecoration(
            color: selected ? _kOrange : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? _kOrange : Colors.grey.shade300),
          ),
          child: Text(
            'Autre montant',
            style: GoogleFonts.urbanist(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: selected ? Colors.white : Colors.black87,
            ),
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// TUILE TRANSACTION HISTORIQUE
// ─────────────────────────────────────────────────────────────────────────────
class _TxTile extends StatelessWidget {
  final FeexPayTransaction tx;
  const _TxTile({required this.tx});

  @override
  Widget build(BuildContext context) {
    final isOk = tx.isCompleted;
    final color = isOk ? const Color(0xFF2E7D32) : Colors.red;
    final icon  = isOk
        ? Icons.add_circle_rounded
        : tx.isCancelled
            ? Icons.cancel_rounded
            : Icons.error_rounded;
    final statusLabel = isOk
        ? 'Créditée'
        : tx.isCancelled
            ? 'Annulée'
            : tx.isPending
                ? 'En attente'
                : 'Échouée';

    final d = tx.createdAt;
    final dateStr =
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}'
        '  ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${tx.paymentMethod.toUpperCase()} — ${tx.provider}',
                  style: GoogleFonts.urbanist(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                Text(dateStr,
                    style: GoogleFonts.urbanist(
                        color: Colors.grey, fontSize: 11)),
                Text(statusLabel,
                    style: GoogleFonts.urbanist(
                        color: color, fontSize: 11, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Text(
            '+${_fmtAmount(tx.amount)} F',
            style: GoogleFonts.urbanist(
                fontWeight: FontWeight.bold, color: color, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

// ── Helper formatage ──────────────────────────────────────────────────────────
String _fmtAmount(int v) {
  if (v >= 1000) {
    return '${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}';
  }
  return v.toString();
}

