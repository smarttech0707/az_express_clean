import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import '../ek_constants.dart';
import '../providers/ek_provider.dart';
import 'ek_order_tracking.dart';

class EkOrderForm extends StatefulWidget {
  final String? preselectedOperator;
  final String? serviceHint;

  const EkOrderForm({
    super.key,
    this.preselectedOperator,
    this.serviceHint,
  });

  @override
  State<EkOrderForm> createState() => _EkOrderFormState();
}

class _EkOrderFormState extends State<EkOrderForm> {
  final PageController _pageCtrl = PageController();
  int _step = 0;

  // Selections
  String? _operator;
  Map<String, dynamic>? _service;
  String _beneficiary = '';
  int _amount = 0;
  String _paymentMethod = 'wallet';

  final _numberCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  bool _submitting  = false;

  @override
  void initState() {
    super.initState();
    if (widget.preselectedOperator != null) {
      _operator = widget.preselectedOperator;
    }
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _numberCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  void _goNext() {
    _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    setState(() => _step++);
  }

  void _goBack() {
    if (_step == 0) { Navigator.pop(context); return; }
    _pageCtrl.previousPage(
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    setState(() => _step--);
  }

  List<Map<String, dynamic>> get _currentServices {
    if (_operator == null) return [];
    return List<Map<String, dynamic>>.from(
        ekServices[_operator] as List? ?? []);
  }

  int get _fee => _service == null ? 0 : ekCalculateFee(_service!['id'] as String, _amount);
  int get _total => _amount + _fee;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kEkBg,
      appBar: AppBar(
        backgroundColor: kEkDark,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded),
          onPressed: _goBack,
        ),
        title: Text(
          _stepTitle(),
          style: GoogleFonts.inter(
              fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: (_step + 1) / 5,
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation<Color>(kEkGreen),
          ),
        ),
      ),
      body: PageView(
        controller: _pageCtrl,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _StepOperator(
            selected: _operator,
            onSelect: (op) { setState(() { _operator = op; _service = null; }); _goNext(); },
          ),
          _StepService(
            operator: _operator,
            services: _currentServices,
            selected: _service,
            onSelect: (svc) { setState(() => _service = svc); _goNext(); },
          ),
          _StepBeneficiary(
            operator: _operator,
            service: _service,
            numberCtrl: _numberCtrl,
            amountCtrl: _amountCtrl,
            onAmountPreset: (v) {
              setState(() => _amount = v);
              _amountCtrl.text = v.toString();
            },
            onChanged: () {
              setState(() {
                _beneficiary = _numberCtrl.text;
                _amount = int.tryParse(_amountCtrl.text) ?? 0;
              });
            },
            onNext: () {
              if (_numberCtrl.text.length < 8) {
                _showErr('Numéro invalide (minimum 8 chiffres)'); return;
              }
              if (_amount < ((_service?['minAmount'] as int?) ?? 100)) {
                _showErr('Montant minimum : ${_service?['minAmount']} F'); return;
              }
              _beneficiary = _numberCtrl.text;
              _amount = int.tryParse(_amountCtrl.text) ?? 0;
              _goNext();
            },
          ),
          _StepPayment(
            selected: _paymentMethod,
            totalPaid: _total,
            fee: _fee,
            onSelect: (m) { setState(() => _paymentMethod = m); _goNext(); },
          ),
          _StepConfirm(
            operator: _operator,
            service: _service,
            beneficiary: _beneficiary,
            amount: _amount,
            fee: _fee,
            total: _total,
            paymentMethod: _paymentMethod,
            submitting: _submitting,
            onConfirm: _submit,
          ),
        ],
      ),
    );
  }

  String _stepTitle() {
    switch (_step) {
      case 0: return 'Choisir l\'opérateur';
      case 1: return 'Choisir le service';
      case 2: return 'Détails de la commande';
      case 3: return 'Mode de paiement';
      case 4: return 'Confirmation';
      default: return 'Nouvelle commande';
    }
  }

  void _showErr(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) { setState(() => _submitting = false); return; }

    // Fetch client info
    String clientName = 'Client', clientPhone = '';
    try {
      final doc = await FirebaseFirestore.instance
          .collection('clients').doc(user.uid).get();
      clientName  = doc.data()?['name']  ?? 'Client';
      clientPhone = doc.data()?['phone'] ?? '';
    } catch (_) {}

    if (!mounted) return;
    final result = await context.read<EkProvider>().placeOrder(
      clientId:          user.uid,
      clientName:        clientName,
      clientPhone:       clientPhone,
      operator:          _operator!,
      serviceId:         _service!['id'] as String,
      serviceLabel:      _service!['label'] as String,
      beneficiaryNumber: _beneficiary,
      amount:            _amount,
      paymentMethod:     _paymentMethod,
    );

    if (!mounted) return;
    setState(() => _submitting = false);

    // Firestore auto-IDs are exactly 20 alphanumeric chars — anything else is an error message
    final isOrderId = result != null && RegExp(r'^[A-Za-z0-9]{20}$').hasMatch(result);
    if (!isOrderId) {
      _showErr(result ?? 'Erreur inconnue');
      return;
    }

    // Success — navigate to tracking
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => EkOrderTracking(orderId: result),
      ),
    );
  }
}

// ── Step 1: Operator ───────────────────────────────────────────────────────────
class _StepOperator extends StatelessWidget {
  final String? selected;
  final void Function(String) onSelect;

  const _StepOperator({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 8),
        Text('Quel opérateur ?',
            style: GoogleFonts.inter(
                fontSize: 22, fontWeight: FontWeight.w800, color: kEkText)),
        const SizedBox(height: 6),
        Text('Choisissez le réseau du bénéficiaire',
            style: GoogleFonts.inter(fontSize: 14, color: kEkMuted)),
        const SizedBox(height: 28),
        ...ekOperators.map((op) {
          final color = Color(op['color'] as int);
          final bg    = Color(op['bg'] as int);
          final sel   = selected == op['id'];
          return GestureDetector(
            onTap: () => onSelect(op['id'] as String),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: sel ? color.withValues(alpha: 0.1) : bg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: sel ? color : color.withValues(alpha: 0.2),
                  width: sel ? 2 : 1,
                ),
                boxShadow: sel
                    ? [BoxShadow(color: color.withValues(alpha: 0.2),
                          blurRadius: 10, offset: const Offset(0, 4))]
                    : [],
              ),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    op['logo'] as String,
                    width: 48, height: 48, fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Text(
                      op['emoji'] as String,
                      style: const TextStyle(fontSize: 34),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(op['label'] as String,
                        style: GoogleFonts.inter(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: color)),
                    Text('${(ekServices[op['id']] as List?)?.length ?? 0} services disponibles',
                        style: GoogleFonts.inter(
                            fontSize: 12, color: kEkMuted)),
                  ]),
                ),
                if (sel)
                  Icon(Icons.check_circle_rounded, color: color, size: 26),
              ]),
            ),
          );
        }),
      ],
    );
  }
}

// ── Step 2: Service ────────────────────────────────────────────────────────────
class _StepService extends StatelessWidget {
  final String? operator;
  final List<Map<String, dynamic>> services;
  final Map<String, dynamic>? selected;
  final void Function(Map<String, dynamic>) onSelect;

  const _StepService({
    required this.operator,
    required this.services,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (operator == null) return const SizedBox.shrink();
    final opData = ekOperators.firstWhere(
        (o) => o['id'] == operator, orElse: () => {});
    final opColor = Color((opData['color'] as int?) ?? 0xFF00C853);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 8),
        Text('Quel service ?',
            style: GoogleFonts.inter(
                fontSize: 22, fontWeight: FontWeight.w800, color: kEkText)),
        const SizedBox(height: 24),
        ...services.map((svc) {
          final sel = selected?['id'] == svc['id'];
          return GestureDetector(
            onTap: () => onSelect(svc),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                color: sel
                    ? opColor.withValues(alpha: 0.08)
                    : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: sel ? opColor : kEkDivider,
                  width: sel ? 2 : 1,
                ),
              ),
              child: Row(children: [
                Text(svc['icon'] as String,
                    style: const TextStyle(fontSize: 26)),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(svc['label'] as String,
                      style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                          color: sel ? opColor : kEkText)),
                ),
                if (sel)
                  Icon(Icons.check_circle_rounded, color: opColor, size: 22),
              ]),
            ),
          );
        }),
      ],
    );
  }
}

// ── Step 3: Beneficiary & amount ──────────────────────────────────────────────
class _StepBeneficiary extends StatelessWidget {
  final String? operator;
  final Map<String, dynamic>? service;
  final TextEditingController numberCtrl;
  final TextEditingController amountCtrl;
  final void Function(int) onAmountPreset;
  final VoidCallback onChanged;
  final VoidCallback onNext;

  const _StepBeneficiary({
    required this.operator,
    required this.service,
    required this.numberCtrl,
    required this.amountCtrl,
    required this.onAmountPreset,
    required this.onChanged,
    required this.onNext,
  });

  String get _phoneHint {
    switch (operator) {
      case 'orange': return '07 XX XX XX XX';
      case 'mtn':    return '05 XX XX XX XX';
      case 'moov':   return '01 XX XX XX XX';
      default:       return '07 XX XX XX XX';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 8),
        Text('Détails',
            style: GoogleFonts.inter(
                fontSize: 22, fontWeight: FontWeight.w800, color: kEkText)),
        const SizedBox(height: 24),
        // Number
        Text('Numéro bénéficiaire',
            style: GoogleFonts.inter(
                fontSize: 13, fontWeight: FontWeight.w600, color: kEkText)),
        const SizedBox(height: 8),
        TextField(
          controller: numberCtrl,
          onChanged: (_) => onChanged(),
          keyboardType: TextInputType.phone,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700),
          decoration: InputDecoration(
            hintText: _phoneHint,
            hintStyle: GoogleFonts.inter(color: kEkMuted),
            prefixIcon: const Icon(Icons.phone_rounded, color: kEkGreen),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: kEkDivider)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: kEkDivider)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: kEkGreen, width: 2)),
          ),
        ),
        const SizedBox(height: 20),
        // Amount
        Text('Montant (FCFA)',
            style: GoogleFonts.inter(
                fontSize: 13, fontWeight: FontWeight.w600, color: kEkText)),
        const SizedBox(height: 8),
        TextField(
          controller: amountCtrl,
          onChanged: (_) => onChanged(),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700),
          decoration: InputDecoration(
            hintText: 'Ex: 1000',
            hintStyle: GoogleFonts.inter(color: kEkMuted),
            prefixIcon: const Icon(Icons.payments_rounded, color: kEkGreen),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: kEkDivider)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: kEkDivider)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: kEkGreen, width: 2)),
          ),
        ),
        const SizedBox(height: 14),
        // Presets
        Wrap(
          spacing: 8, runSpacing: 8,
          children: ekAmountPresets.map((v) {
            return GestureDetector(
              onTap: () => onAmountPreset(v),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: kEkGreen.withValues(alpha: 0.4)),
                ),
                child: Text(_fmt(v),
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: kEkGreen)),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ScaleButton(
            onPressed: onNext,
            style: ElevatedButton.styleFrom(
              backgroundColor: kEkGreen,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              elevation: 0,
            ),
            child: Text('Continuer',
                style: GoogleFonts.inter(
                    fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 20),
      ]),
    );
  }
}

// ── Step 4: Payment method ─────────────────────────────────────────────────────
class _StepPayment extends StatelessWidget {
  final String selected;
  final int totalPaid;
  final int fee;
  final void Function(String) onSelect;

  const _StepPayment({
    required this.selected,
    required this.totalPaid,
    required this.fee,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final methods = [
      {'id': 'wallet',       'label': 'Wallet AZ Express',
       'sub': 'Paiement instantané depuis votre solde',
       'icon': Icons.account_balance_wallet_rounded, 'color': 0xFF00C853},
      {'id': 'orange_money', 'label': 'Orange Money',
       'sub': 'Vous payez l\'agent directement en OM',
       'icon': Icons.phone_android_rounded, 'color': 0xFFFF6600},
      {'id': 'mtn_momo',    'label': 'MTN MoMo',
       'sub': 'Vous payez l\'agent directement en MoMo',
       'icon': Icons.phone_android_rounded, 'color': 0xFFFFBB00},
      {'id': 'wave',         'label': 'Wave',
       'sub': 'Vous payez l\'agent directement via Wave',
       'icon': Icons.waves_rounded, 'color': 0xFF00B9F1},
      {'id': 'cash',         'label': 'Espèces à l\'agent',
       'sub': 'Vous remettez le montant en liquide à l\'agent',
       'icon': Icons.money_rounded, 'color': 0xFF4CAF50},
    ];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 8),
        Text('Mode de paiement',
            style: GoogleFonts.inter(
                fontSize: 22, fontWeight: FontWeight.w800, color: kEkText)),
        const SizedBox(height: 6),
        Container(
          margin: const EdgeInsets.only(bottom: 24),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: kEkGreen.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kEkGreen.withValues(alpha: 0.2)),
          ),
          child: Row(children: [
            const Icon(Icons.info_outline_rounded, color: kEkGreen, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Total à payer : ${_fmt(totalPaid)}',
                  style: GoogleFonts.inter(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      color: kEkGreen)),
            ),
          ]),
        ),
        ...methods.map((m) {
          final sel   = selected == m['id'];
          final color = Color(m['color'] as int);
          return GestureDetector(
            onTap: () => onSelect(m['id'] as String),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: sel ? color.withValues(alpha: 0.06) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: sel ? color : kEkDivider,
                    width: sel ? 2 : 1),
              ),
              child: Row(children: [
                Container(
                  width: 42, height: 42,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(m['icon'] as IconData, color: color, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(m['label'] as String,
                        style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: kEkText)),
                    Text(m['sub'] as String,
                        style: GoogleFonts.inter(
                            fontSize: 11, color: kEkMuted)),
                  ]),
                ),
                if (sel)
                  Icon(Icons.check_circle_rounded, color: color, size: 22),
              ]),
            ),
          );
        }),
      ],
    );
  }
}

// ── Step 5: Confirm ────────────────────────────────────────────────────────────
class _StepConfirm extends StatelessWidget {
  final String? operator;
  final Map<String, dynamic>? service;
  final String beneficiary;
  final int amount;
  final int fee;
  final int total;
  final String paymentMethod;
  final bool submitting;
  final VoidCallback onConfirm;

  const _StepConfirm({
    required this.operator,
    required this.service,
    required this.beneficiary,
    required this.amount,
    required this.fee,
    required this.total,
    required this.paymentMethod,
    required this.submitting,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final opData = ekOperators.firstWhere(
        (o) => o['id'] == operator, orElse: () => {});

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 8),
        Text('Résumé',
            style: GoogleFonts.inter(
                fontSize: 22, fontWeight: FontWeight.w800, color: kEkText)),
        const SizedBox(height: 20),
        _SummaryCard(
          operator: opData,
          service: service,
          beneficiary: beneficiary,
          amount: amount,
          fee: fee,
          total: total,
          paymentMethod: paymentMethod,
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF8E1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFFFCC02)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.warning_amber_rounded,
                color: Color(0xFFFF8F00), size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Un agent de votre communauté va exécuter cette opération. '
                'Vous pourrez confirmer ou contester après réception de la preuve.',
                style: GoogleFonts.inter(fontSize: 12, height: 1.5,
                    color: const Color(0xFF5D4037)),
              ),
            ),
          ]),
        ),
        if (paymentMethod != 'wallet') ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFE3F2FD),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF90CAF9)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_rounded, color: Color(0xFF1565C0), size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Paiement direct à l\'agent : vous devrez lui envoyer le montant total '
                  '(${_fmt(total)}) via ${_payLabelShort(paymentMethod)} avant ou après l\'opération.',
                  style: GoogleFonts.inter(fontSize: 12, height: 1.5,
                      color: const Color(0xFF0D47A1)),
                ),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ScaleButton(
            onPressed: submitting ? null : onConfirm,
            style: ElevatedButton.styleFrom(
              backgroundColor: kEkGreen,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            child: submitting
                ? const SizedBox(
                    width: 24, height: 24,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5))
                : Text('Confirmer & Commander',
                    style: GoogleFonts.inter(
                        fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 20),
      ]),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final Map<String, dynamic> operator;
  final Map<String, dynamic>? service;
  final String beneficiary;
  final int amount;
  final int fee;
  final int total;
  final String paymentMethod;

  const _SummaryCard({
    required this.operator,
    required this.service,
    required this.beneficiary,
    required this.amount,
    required this.fee,
    required this.total,
    required this.paymentMethod,
  });

  @override
  Widget build(BuildContext context) {
    final opColor = Color((operator['color'] as int?) ?? 0xFF00C853);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: kEkDivider),
        boxShadow: const [
          BoxShadow(color: Color(0x08000000), blurRadius: 8,
              offset: Offset(0, 3))
        ],
      ),
      child: Column(children: [
        _Row('Opérateur',  '${operator['emoji'] ?? ''} ${operator['label'] ?? ''}'),
        _Row('Service',    service?['label'] ?? ''),
        _Row('Bénéficiaire', beneficiary),
        _Row('Montant',    _fmt(amount)),
        const Divider(height: 20),
        _Row('Total',      _fmt(total), isTotal: true, opColor: opColor),
        _Row('Paiement',   _payLabel(paymentMethod)),
      ]),
    );
  }

  String _payLabel(String m) {
    switch (m) {
      case 'wallet':       return 'Wallet AZ Express';
      case 'orange_money': return 'Orange Money';
      case 'mtn_momo':    return 'MTN MoMo';
      case 'wave':         return 'Wave';
      case 'cash':         return 'Espèces à l\'agent';
      default:             return m;
    }
  }
}

String _payLabelShort(String m) {
  switch (m) {
    case 'orange_money': return 'Orange Money';
    case 'mtn_momo':    return 'MTN MoMo';
    case 'wave':         return 'Wave';
    case 'cash':         return 'espèces';
    default:             return m;
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool isTotal;
  final Color? opColor;

  const _Row(this.label, this.value,
      {this.isTotal = false, this.opColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: GoogleFonts.inter(
            fontSize: isTotal ? 14 : 13,
            color: isTotal ? kEkText : kEkMuted,
            fontWeight: isTotal ? FontWeight.w700 : FontWeight.normal)),
        Text(value, style: GoogleFonts.inter(
            fontSize: isTotal ? 16 : 13,
            color: isTotal ? (opColor ?? kEkGreen) : kEkText,
            fontWeight: isTotal ? FontWeight.w800 : FontWeight.w600)),
      ]),
    );
  }
}

String _fmt(int price) {
  final s = price.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return '${buf.toString()} F';
}

