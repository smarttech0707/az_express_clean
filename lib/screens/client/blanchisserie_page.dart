import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import '../../services/wallet_payment_compatibility.dart';
import '../../theme/app_theme.dart';

class BlanchisseriePage extends StatefulWidget {
  const BlanchisseriePage({super.key});

  @override
  State<BlanchisseriePage> createState() => _BlancheriePageState();
}

class _BlancheriePageState extends State<BlanchisseriePage> {
  final _addressCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  String _serviceType = "Lavage + Repassage";
  int _quantity = 1;
  bool _loading = false;
  String _paymentMethod = 'cash';
  int _walletBalance = 0;
  StreamSubscription? _walletSub;

  List<String> _services = const [
    "Lavage + Repassage",
    "Lavage uniquement",
    "Repassage uniquement",
    "Pressing",
  ];
  int _pricePerKg = 1000;

  int get _totalPrice => _quantity * _pricePerKg;

  @override
  void initState() {
    super.initState();
    _listenWallet();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('blanchisserie')
          .get();
      if (!doc.exists || !mounted) return;
      final data = doc.data()!;
      setState(() {
        if (data['services'] is List) {
          _services = List<String>.from(data['services'] as List);
          if (_services.isNotEmpty) _serviceType = _services.first;
        }
        if (data['pricePerKg'] is num) {
          _pricePerKg = (data['pricePerKg'] as num).toInt();
        }
      });
    } catch (_) {}
  }

  void _listenWallet() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _walletSub = FirebaseFirestore.instance
        .collection('clients')
        .doc(uid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(
          () => _walletBalance = (snap.data()?['wallet'] as num? ?? 0).toInt());
    });
  }

  Future<void> _submit() async {
    if (_addressCtrl.text.trim().isEmpty) {
      _snack("Veuillez entrer votre adresse", Colors.red);
      return;
    }
    if (_paymentMethod == 'wallet' && _walletBalance < _totalPrice) {
      _snack(
          "Solde insuffisant. Vous avez $_walletBalance FCFA, il faut $_totalPrice FCFA",
          Colors.red);
      return;
    }

    setState(() => _loading = true);
    try {
      var user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        await FirebaseAuth.instance.signInAnonymously();
        user = FirebaseAuth.instance.currentUser;
      }
      final uid = user!.uid;
      final id = const Uuid().v4();

      final orderData = {
        "id": id,
        "description":
            "Blanchisserie : $_serviceType — $_quantity kg\nAdresse : ${_addressCtrl.text.trim()}"
                "${_notesCtrl.text.trim().isNotEmpty ? '\nNotes : ${_notesCtrl.text.trim()}' : ''}",
        "budget": _totalPrice,
        "shoppingBudget": 0,
        "status": "pending",
        "type": "blanchisserie",
        "serviceType": _serviceType,
        "quantity": _quantity,
        "address": _addressCtrl.text.trim(),
        "notes": _notesCtrl.text.trim(),
        "latitude": 0,
        "longitude": 0,
        "clientId": uid,
        "paymentMethod": _paymentMethod,
        "isPaid": _paymentMethod == 'wallet',
        "createdAt": FieldValue.serverTimestamp(),
      };

      if (_paymentMethod == 'wallet') {
        // LOT 6.3 SECURITY : voir WalletPaymentCompatibilityService.
        if (!mounted) return;
        final compatible =
            await WalletPaymentCompatibilityService.ensureCompatible(context);
        if (!compatible) {
          setState(() => _loading = false);
          return;
        }
        final clientRef =
            FirebaseFirestore.instance.collection('clients').doc(uid);
        final orderRef =
            FirebaseFirestore.instance.collection('orders').doc(id);

        await FirebaseFirestore.instance.runTransaction((tx) async {
          final snap = await tx.get(clientRef);
          final wallet = (snap.data()?['wallet'] as num? ?? 0).toInt();
          if (wallet < _totalPrice) throw Exception('SOLDE_INSUFFISANT');
          // LOT 6 SECURITY : lie ce débit précis à CETTE commande (règle
          // Firestore walletDebitMatchesPaidOrder) — empêche qu'un même
          // débit ne soit réutilisé pour valider plusieurs commandes.
          tx.update(clientRef, {
            'wallet': wallet - _totalPrice,
            'lastPaidOrderId': id,
          });
          tx.set(orderRef, orderData);
        });

        await FirebaseFirestore.instance
            .collection('clients')
            .doc(uid)
            .collection('wallet_transactions')
            .add({
          'type': 'purchase',
          'amount': _totalPrice,
          'description': 'Blanchisserie — $_serviceType × $_quantity kg',
          'orderId': id,
          'createdAt': Timestamp.now(),
        });
      } else {
        await FirebaseFirestore.instance
            .collection("orders")
            .doc(id)
            .set(orderData);
      }

      if (mounted) {
        _snack("Demande envoyée ! Un livreur va vous contacter.", Colors.green);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
      }
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('SOLDE_INSUFFISANT')) {
        _snack("Solde wallet insuffisant", Colors.red);
      } else {
        _snack("Erreur : $e", Colors.red);
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  @override
  void dispose() {
    _walletSub?.cancel();
    _addressCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Widget _paymentSelector() {
    final brightness = Theme.of(context).brightness;
    final muted = AppColors.premiumTextSecondary(brightness);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.premiumSurfaceElevated(brightness),
        borderRadius: AppRadius.lgR,
        border: Border.all(color: AppColors.premiumBorder(brightness)),
        boxShadow: AppShadow.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Mode de paiement",
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold, color: muted)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _paymentMethod = 'cash'),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: _paymentMethod == 'cash'
                        ? AppColors.primary
                        : AppColors.premiumSurface(brightness),
                    border: Border.all(
                      color: _paymentMethod == 'cash'
                          ? AppColors.primary
                          : AppColors.premiumBorder(brightness),
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.money,
                            color:
                                _paymentMethod == 'cash' ? Colors.white : muted,
                            size: 18),
                        const SizedBox(width: 6),
                        Text("Espèces",
                            style: TextStyle(
                                color: _paymentMethod == 'cash'
                                    ? Colors.white
                                    : muted,
                                fontWeight: FontWeight.bold)),
                      ]),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _paymentMethod = 'wallet'),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: _paymentMethod == 'wallet'
                        ? AppColors.primary
                        : AppColors.premiumSurface(brightness),
                    border: Border.all(
                      color: _paymentMethod == 'wallet'
                          ? AppColors.primary
                          : AppColors.premiumBorder(brightness),
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.account_balance_wallet,
                          color:
                              _paymentMethod == 'wallet' ? Colors.white : muted,
                          size: 18),
                      const SizedBox(width: 6),
                      Text("Wallet",
                          style: TextStyle(
                              color: _paymentMethod == 'wallet'
                                  ? Colors.white
                                  : muted,
                              fontWeight: FontWeight.bold)),
                    ]),
                    Text("$_walletBalance FCFA",
                        style: TextStyle(
                            color: _paymentMethod == 'wallet'
                                ? Colors.white70
                                : muted,
                            fontSize: 11)),
                  ]),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: AppColors.premiumBg(brightness),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 150,
            pinned: true,
            backgroundColor: AppColors.premiumSurface(brightness),
            foregroundColor: AppColors.premiumTextPrimary(brightness),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  color: AppColors.premiumSurface(brightness),
                  border: Border(
                    bottom:
                        BorderSide(color: Colors.blue.withValues(alpha: .3)),
                  ),
                ),
                child: SafeArea(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 40),
                      Icon(Icons.local_laundry_service,
                          color: Colors.blue.shade700, size: 42),
                      const SizedBox(height: 8),
                      Text("Blanchisserie",
                          style: AppTypography.titleLargeStyle(context,
                              color: AppColors.premiumTextPrimary(brightness))),
                      Text("Dépôt et retrait de linge",
                          style: AppTypography.bodySmallStyle(context,
                              color:
                                  AppColors.premiumTextSecondary(brightness))),
                    ],
                  ),
                ),
              ),
            ),
            title: const Text("Blanchisserie"),
            centerTitle: false,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── TYPE DE SERVICE ──────────────────────────
                  _sectionTitle("Type de service"),
                  const SizedBox(height: 10),
                  Material(
                    color: AppColors.premiumSurfaceElevated(brightness),
                    elevation: 1,
                    shadowColor: AppColors.black10,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: AppColors.premiumBorder(brightness),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: RadioGroup<String>(
                      groupValue: _serviceType,
                      onChanged: (v) {
                        if (v != null) setState(() => _serviceType = v);
                      },
                      child: Column(
                        children: _services.map((s) {
                          final selected = s == _serviceType;
                          return RadioListTile<String>(
                            value: s,
                            selected: selected,
                            title: Text(s,
                                style: TextStyle(
                                    color: selected
                                        ? Colors.blue.shade800
                                        : AppColors.premiumTextPrimary(
                                            brightness),
                                    fontWeight: selected
                                        ? FontWeight.bold
                                        : FontWeight.normal)),
                            activeColor: Colors.blue.shade700,
                          );
                        }).toList(),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── QUANTITÉ ────────────────────────────────
                  _sectionTitle("Quantité (kg approximatif)"),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.premiumSurfaceElevated(brightness),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 8)
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          onPressed: _quantity > 1
                              ? () => setState(() => _quantity--)
                              : null,
                          icon: const Icon(Icons.remove_circle_outline),
                          color: Colors.blue.shade700,
                          iconSize: 32,
                        ),
                        const SizedBox(width: 20),
                        Column(
                          children: [
                            Text("$_quantity",
                                style: TextStyle(
                                    fontSize: 36,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue.shade700)),
                            const Text("kg",
                                style: TextStyle(
                                    color: Colors.grey, fontSize: 14)),
                          ],
                        ),
                        const SizedBox(width: 20),
                        IconButton(
                          onPressed: () => setState(() => _quantity++),
                          icon: const Icon(Icons.add_circle_outline),
                          color: Colors.blue.shade700,
                          iconSize: 32,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.blue.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 16, color: Colors.blue.shade700),
                        const SizedBox(width: 8),
                        Text(
                          "Prix estimé : $_totalPrice FCFA",
                          style: TextStyle(
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── ADRESSE ─────────────────────────────────
                  _sectionTitle("Votre adresse"),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.premiumSurfaceElevated(brightness),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 8)
                      ],
                    ),
                    child: TextField(
                      controller: _addressCtrl,
                      decoration: InputDecoration(
                        hintText: "Ex : Quartier Commerce, rue principale...",
                        prefixIcon: Icon(Icons.location_on,
                            color: Colors.blue.shade700),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none),
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surface,
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── NOTES ───────────────────────────────────
                  _sectionTitle("Instructions spéciales (optionnel)"),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.premiumSurfaceElevated(brightness),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 8)
                      ],
                    ),
                    child: TextField(
                      controller: _notesCtrl,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: "Ex : linge fragile, couleurs séparées...",
                        prefixIcon: Icon(Icons.note_alt_outlined,
                            color: Colors.grey.shade400),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none),
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surface,
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── PAIEMENT ────────────────────────────────
                  _sectionTitle("Mode de paiement"),
                  const SizedBox(height: 10),
                  _paymentSelector(),

                  const SizedBox(height: 30),

                  // ── SUBMIT ──────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton.icon(
                      onPressed: _loading ? null : _submit,
                      icon: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : Icon(
                              _paymentMethod == 'wallet'
                                  ? Icons.account_balance_wallet
                                  : Icons.send,
                              color: Colors.white),
                      label: Text(
                        _loading
                            ? "Envoi en cours..."
                            : _paymentMethod == 'wallet'
                                ? "Payer $_totalPrice FCFA par Wallet"
                                : "Envoyer la demande",
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),

                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) => Text(
        title,
        style: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey),
      );
}
