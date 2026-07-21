import 'dart:async';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../screens/client/recharge_wallet_screen.dart';
import '../services/feexpay_service.dart';
import 'tap_effect.dart';

export '../services/feexpay_service.dart';

enum WalletAction { recharge, withdraw }

class WalletActionSheet extends StatefulWidget {
  final String userId;
  final String userType;
  final String userName;
  final int currentBalance;

  const WalletActionSheet({
    super.key,
    required this.userId,
    required this.userType,
    required this.userName,
    required this.currentBalance,
  });

  static Future<void> show(
    BuildContext context, {
    required WalletAction action,
    required String userId,
    required String userType,
    required String userName,
    required int currentBalance,
  }) {
    if (action == WalletAction.recharge) {
      return Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RechargeWalletScreen(userType: userType),
        ),
      );
    }
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WalletActionSheet(
        userId:         userId,
        userType:       userType,
        userName:       userName,
        currentBalance: currentBalance,
      ),
    );
  }

  @override
  State<WalletActionSheet> createState() => _WalletActionSheetState();
}

class _WalletActionSheetState extends State<WalletActionSheet> {
  static const _presets = [500, 1000, 2000, 5000, 10000, 25000];
  static const _kBlue = Color(0xFF1565C0);

  int    _selectedPreset  = 1000;
  bool   _useCustom       = false;
  String _operator        = 'wave';
  bool   _loading         = false;
  String? _withdrawStatus;
  String? _errorMsg;

  final _customCtrl = TextEditingController();
  final _phoneCtrl  = TextEditingController();

  int get _amount =>
      _useCustom ? (int.tryParse(_customCtrl.text.trim()) ?? 0) : _selectedPreset;

  @override
  void dispose() {
    _customCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _startWithdrawal() async {
    if (_amount < 500) {
      _snack('Montant minimum : 500 FCFA', Colors.red);
      return;
    }
    if (_amount > widget.currentBalance) {
      _snack('Solde insuffisant (${_fmt(widget.currentBalance)} FCFA)', Colors.red);
      return;
    }
    final phone = _phoneCtrl.text.trim();
    if (phone.length < 8) {
      _snack('Numéro de téléphone invalide', Colors.red);
      return;
    }

    setState(() { _loading = true; _errorMsg = null; });
    try {
      final res = await FeexPayService.initiateWithdrawal(
        amount:   _amount,
        phone:    phone,
        operator: _operator,
        userType: widget.userType,
        userName: widget.userName,
      );
      if (!mounted) return;
      setState(() {
        _loading        = false;
        _withdrawStatus = res['status'] as String? ?? 'processing';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading  = false;
        _errorMsg = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color,
          behavior: SnackBarBehavior.floating),
    );
  }

  String _fmt(int v) {
    if (v >= 1000) return '${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}';
    return v.toString();
  }

  String _operatorLabel() {
    switch (_operator) {
      case 'orange': return 'Orange Money';
      case 'mtn':    return 'MTN MoMo';
      case 'moov':   return 'Moov Money';
      default:       return 'Wave';
    }
  }

  String _phoneHint() {
    switch (_operator) {
      case 'orange': return 'Ex: 07 00 00 00 00';
      case 'mtn':    return 'Ex: 05 00 00 00 00';
      case 'moov':   return 'Ex: 01 00 00 00 00';
      default:       return 'Ex: 07 00 00 00 00';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),

            if (_withdrawStatus != null)
              _resultView()
            else
              _formView(),
          ],
        ),
      ),
    );
  }

  Widget _formView() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _kBlue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.arrow_circle_up_outlined,
              color: _kBlue, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Retirer de l\'argent',
                style: GoogleFonts.urbanist(
                    fontSize: 17, fontWeight: FontWeight.bold)),
            Text('Solde : ${_fmt(widget.currentBalance)} FCFA',
                style: GoogleFonts.urbanist(
                    fontSize: 12, color: Colors.grey.shade600)),
          ]),
        ),
      ]),

      const SizedBox(height: 24),

      // Montants
      _label('Montant'),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8, runSpacing: 8,
        children: [
          ..._presets.map((p) => _chip(p)),
          _otherChip(),
        ],
      ),
      if (_useCustom) ...[
        const SizedBox(height: 10),
        _input(_customCtrl, 'Montant personnalisé', Icons.edit,
            type: TextInputType.number,
            onChange: (_) => setState(() {})),
      ],

      const SizedBox(height: 20),

      // Opérateur
      _label('Opérateur'),
      const SizedBox(height: 10),
      Row(children: [
        _opBtn('wave',   'Wave',   const Color(0xFF00B9F1)),
        const SizedBox(width: 8),
        _opBtn('orange', 'Orange', const Color(0xFFFF6600)),
        const SizedBox(width: 8),
        _opBtn('mtn',    'MTN',    const Color(0xFFFFBB00)),
        const SizedBox(width: 8),
        _opBtn('moov',   'Moov',   const Color(0xFF005EB8)),
      ]),

      const SizedBox(height: 20),

      _label('Numéro de réception'),
      const SizedBox(height: 8),
      _input(_phoneCtrl, _phoneHint(), Icons.phone_rounded,
          type: TextInputType.phone),
      const SizedBox(height: 8),
      _info('L\'argent sera envoyé sur ce numéro après validation.', _kBlue),

      if (_amount > widget.currentBalance && _amount > 0) ...[
        const SizedBox(height: 8),
        _warning('Montant supérieur à votre solde (${_fmt(widget.currentBalance)} FCFA)'),
      ],
      if (_errorMsg != null) ...[
        const SizedBox(height: 12),
        _warning(_errorMsg!),
      ],

      const SizedBox(height: 24),
      SizedBox(
        width: double.infinity, height: 54,
        child: ScaleButton(
          onPressed: _loading || _amount < 500 ? null : _startWithdrawal,
          style: ElevatedButton.styleFrom(
            backgroundColor: _kBlue,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
          child: _loading
              ? const SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : Text('Retirer  ${_fmt(_amount)} FCFA  →',
                  style: GoogleFonts.urbanist(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15)),
        ),
      ),
    ],
  );

  Widget _resultView() {
    final isSent = _withdrawStatus == 'sent';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(children: [
        Icon(
          isSent ? Icons.check_circle_rounded : Icons.hourglass_top_rounded,
          color: isSent ? const Color(0xFF2E7D32) : _kBlue,
          size: 72,
        ),
        const SizedBox(height: 20),
        Text(
          isSent ? 'Retrait envoyé  ✓' : 'Demande enregistrée',
          style: GoogleFonts.urbanist(
              fontSize: 20, fontWeight: FontWeight.bold,
              color: isSent ? const Color(0xFF2E7D32) : _kBlue),
        ),
        const SizedBox(height: 8),
        Text(
          isSent
              ? '${_fmt(_amount)} FCFA envoyés vers ${_operatorLabel()} (${_phoneCtrl.text.trim()}).'
              : 'Votre retrait de ${_fmt(_amount)} FCFA est en traitement.\nDélai : sous 24h.',
          textAlign: TextAlign.center,
          style: GoogleFonts.urbanist(fontSize: 13, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ScaleButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: isSent ? const Color(0xFF2E7D32) : _kBlue,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: Text('Fermer',
                style: GoogleFonts.urbanist(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ),
      ]),
    );
  }

  // ── Helpers UI ────────────────────────────────────────────────────────────
  Widget _label(String t) => Text(t,
      style: GoogleFonts.urbanist(
          fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black54));

  Widget _chip(int amount) {
    final selected = !_useCustom && _selectedPreset == amount;
    return GestureDetector(
      onTap: () => setState(() { _selectedPreset = amount; _useCustom = false; }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? _kBlue : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected ? _kBlue : Colors.grey.shade300),
        ),
        child: Text('${_fmt(amount)} FCFA',
            style: GoogleFonts.urbanist(
                fontWeight: FontWeight.bold, fontSize: 13,
                color: selected ? Colors.white : Colors.black87)),
      ),
    );
  }

  Widget _otherChip() => GestureDetector(
    onTap: () => setState(() => _useCustom = true),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: _useCustom ? _kBlue : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: _useCustom ? _kBlue : Colors.grey.shade300),
      ),
      child: Text('Autre',
          style: GoogleFonts.urbanist(
              fontWeight: FontWeight.bold, fontSize: 13,
              color: _useCustom ? Colors.white : Colors.black87)),
    ),
  );

  String _opLogo(String value) {
    switch (value) {
      case 'mtn':    return 'assets/payment/mtn.png';
      case 'orange': return 'assets/payment/orange.png';
      case 'moov':   return 'assets/payment/moov.png';
      default:       return 'assets/payment/wave.png';
    }
  }

  Widget _opBtn(String value, String label, Color color) {
    final selected = _operator == value;
    return Expanded(
      child: TapEffect(
        onTap: () => setState(() => _operator = value),
        scaleDown: 0.93,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.12) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: selected ? color : Colors.grey.shade300,
                width: selected ? 2 : 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(_opLogo(value),
                width: 32, height: 32,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Text(label[0],
                    style: TextStyle(color: color,
                        fontWeight: FontWeight.w900, fontSize: 16)),
              ),
              const SizedBox(height: 4),
              Text(label,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.urbanist(
                      fontSize: 10,
                      fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                      color: selected ? color : Colors.black87)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _input(TextEditingController ctrl, String hint, IconData icon,
      {TextInputType? type, ValueChanged<String>? onChange}) =>
      TextField(
        controller: ctrl,
        keyboardType: type,
        onChanged: onChange,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.urbanist(fontSize: 13),
          prefixIcon: Icon(icon, size: 18),
          filled: true,
          fillColor: Colors.grey.shade50,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _kBlue, width: 1.5)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      );

  Widget _info(String text, Color color) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.2)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.info_outline, color: color, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text(text,
          style: GoogleFonts.urbanist(
              fontSize: 12, color: Colors.grey.shade700))),
    ]),
  );

  Widget _warning(String text) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.red.shade50,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.red.shade200),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.warning_amber, color: Colors.red.shade700, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text(text,
          style: GoogleFonts.urbanist(
              fontSize: 12, color: Colors.red.shade700))),
    ]),
  );
}

