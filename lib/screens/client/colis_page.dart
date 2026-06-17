import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

class ColisPage extends StatefulWidget {
  const ColisPage({super.key});

  @override
  State<ColisPage> createState() => _ColisPageState();
}

class _ColisPageState extends State<ColisPage> {
  final _senderNameCtrl = TextEditingController();
  final _senderPhoneCtrl = TextEditingController();
  final _recipientNameCtrl = TextEditingController();
  final _recipientPhoneCtrl = TextEditingController();
  final _recipientAddressCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  String _colisType = "Colis standard";
  bool _fragile = false;
  bool _loading = false;
  String _paymentMethod = 'cash';
  int _walletBalance = 0;
  StreamSubscription? _walletSub;

  List<Map<String, dynamic>> _types = [];
  int _fragileSurcharge = 200;

  static final _typeAssets = <String, List<dynamic>>{
    'Colis standard':       [Icons.inventory_2,   Colors.orange],
    'Cadeau emballé':       [Icons.card_giftcard, Colors.pink],
    'Document / Enveloppe': [Icons.description,   Colors.blue],
    'Gros colis':           [Icons.all_inbox,     Colors.deepPurple],
  };

  static const _fallbackTypes = <Map<String, dynamic>>[
    {"label": "Colis standard",       "price": 500},
    {"label": "Cadeau emballé",       "price": 700},
    {"label": "Document / Enveloppe", "price": 300},
    {"label": "Gros colis",           "price": 1000},
  ];

  Map<String, dynamic> _enrich(Map<String, dynamic> t) {
    final label = t['label'] as String? ?? '';
    final assets = _typeAssets[label] ?? [Icons.inventory_2, Colors.grey];
    return {...t, 'icon': assets[0] as IconData, 'color': assets[1] as Color};
  }

  int get _price {
    final t = _types.firstWhere((t) => t["label"] == _colisType,
        orElse: () => {"price": 500});
    return (t["price"] as num? ?? 500).toInt() + (_fragile ? _fragileSurcharge : 0);
  }

  @override
  void initState() {
    super.initState();
    _types = _fallbackTypes.map(_enrich).toList();
    _listenWallet();
    _loadConfig();
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
      setState(() =>
          _walletBalance = (snap.data()?['wallet'] as num? ?? 0).toInt());
    });
  }

  Future<void> _loadConfig() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('colis')
          .get();
      if (!doc.exists || !mounted) return;
      final data = doc.data()!;
      setState(() {
        if (data['types'] is List) {
          _types = (data['types'] as List)
              .map((e) => _enrich(Map<String, dynamic>.from(e as Map)))
              .toList();
          if (_types.isNotEmpty) {
            _colisType = (_types.first['label'] as String?) ?? _colisType;
          }
        }
        if (data['fragileSurcharge'] is num) {
          _fragileSurcharge = (data['fragileSurcharge'] as num).toInt();
        }
      });
    } catch (_) {}
  }

  Future<void> _submit() async {
    if (_recipientNameCtrl.text.trim().isEmpty ||
        _recipientAddressCtrl.text.trim().isEmpty) {
      _snack("Veuillez remplir le nom et l'adresse du destinataire", Colors.red);
      return;
    }
    if (_paymentMethod == 'wallet' && _walletBalance < _price) {
      _snack(
          "Solde insuffisant. Vous avez $_walletBalance FCFA, il faut $_price FCFA",
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
      final desc = StringBuffer("Colis : $_colisType");
      if (_fragile) desc.write(" (Fragile)");
      if (_senderNameCtrl.text.trim().isNotEmpty) {
        desc.write("\nExpéditeur : ${_senderNameCtrl.text.trim()}");
      }
      if (_senderPhoneCtrl.text.trim().isNotEmpty) {
        desc.write(" — ${_senderPhoneCtrl.text.trim()}");
      }
      desc.write(
          "\nDestinataire : ${_recipientNameCtrl.text.trim()} — ${_recipientPhoneCtrl.text.trim()}");
      desc.write("\nAdresse : ${_recipientAddressCtrl.text.trim()}");
      if (_descriptionCtrl.text.trim().isNotEmpty) {
        desc.write("\nContenu : ${_descriptionCtrl.text.trim()}");
      }

      final orderData = {
        "id": id,
        "description": desc.toString(),
        "budget": _price,
        "shoppingBudget": 0,
        "status": "pending",
        "type": "colis",
        "colisType": _colisType,
        "fragile": _fragile,
        "senderName": _senderNameCtrl.text.trim(),
        "senderPhone": _senderPhoneCtrl.text.trim(),
        "recipientName": _recipientNameCtrl.text.trim(),
        "recipientPhone": _recipientPhoneCtrl.text.trim(),
        "recipientAddress": _recipientAddressCtrl.text.trim(),
        "contentDescription": _descriptionCtrl.text.trim(),
        "latitude": 0,
        "longitude": 0,
        "clientId":      uid,
        "paymentMethod": _paymentMethod,
        "isPaid":        false,
        "createdAt":     FieldValue.serverTimestamp(),
      };

      if (_paymentMethod == 'wallet') {
        final clientRef =
            FirebaseFirestore.instance.collection('clients').doc(uid);
        final orderRef =
            FirebaseFirestore.instance.collection('orders').doc(id);

        await FirebaseFirestore.instance.runTransaction((tx) async {
          final snap = await tx.get(clientRef);
          final wallet = (snap.data()?['wallet'] as num? ?? 0).toInt();
          if (wallet < _price) throw Exception('SOLDE_INSUFFISANT');
          tx.update(clientRef, {'wallet': wallet - _price});
          tx.set(orderRef, orderData);
        });

        await FirebaseFirestore.instance
            .collection('clients')
            .doc(uid)
            .collection('wallet_transactions')
            .add({
          'type': 'purchase',
          'amount': _price,
          'description': 'Colis — $_colisType${_fragile ? ' (Fragile)' : ''}',
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
        _snack("Demande d'envoi créée ! Un livreur va récupérer votre colis.",
            Colors.green);
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
    _senderNameCtrl.dispose();
    _senderPhoneCtrl.dispose();
    _recipientNameCtrl.dispose();
    _recipientPhoneCtrl.dispose();
    _recipientAddressCtrl.dispose();
    _descriptionCtrl.dispose();
    super.dispose();
  }

  Widget _paymentSelector() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Mode de paiement",
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _paymentMethod = 'cash'),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: _paymentMethod == 'cash'
                        ? Colors.orange.shade700
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.money,
                            color: _paymentMethod == 'cash'
                                ? Colors.white
                                : Colors.grey,
                            size: 18),
                        const SizedBox(width: 6),
                        Text("Espèces",
                            style: TextStyle(
                                color: _paymentMethod == 'cash'
                                    ? Colors.white
                                    : Colors.grey,
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
                        ? Colors.orange.shade700
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(children: [
                    Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.account_balance_wallet,
                              color: _paymentMethod == 'wallet'
                                  ? Colors.white
                                  : Colors.grey,
                              size: 18),
                          const SizedBox(width: 6),
                          Text("Wallet",
                              style: TextStyle(
                                  color: _paymentMethod == 'wallet'
                                      ? Colors.white
                                      : Colors.grey,
                                  fontWeight: FontWeight.bold)),
                        ]),
                    Text("$_walletBalance FCFA",
                        style: TextStyle(
                            color: _paymentMethod == 'wallet'
                                ? Colors.white70
                                : Colors.grey.shade400,
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
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 150,
            pinned: true,
            backgroundColor: Colors.orange.shade700,
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.orange.shade800, Colors.orange.shade500],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const SafeArea(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(height: 40),
                      Icon(Icons.card_giftcard,
                          color: Colors.white, size: 48),
                      SizedBox(height: 8),
                      Text("Colis & Cadeaux",
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                      Text("Envoi entre particuliers",
                          style: TextStyle(color: Colors.white70, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            ),
            title: const Text("Colis & Cadeaux"),
            centerTitle: true,
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── TYPE DE COLIS ────────────────────────────
                  _sectionTitle("Type d'envoi"),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 90,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _types.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (context, i) {
                        final t = _types[i];
                        final selected = t["label"] == _colisType;
                        final color = t["color"] as Color;
                        return GestureDetector(
                          onTap: () =>
                              setState(() => _colisType = t["label"]),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 110,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: selected ? color : Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: selected
                                    ? color
                                    : Colors.grey.shade200,
                                width: selected ? 2 : 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.05),
                                    blurRadius: 6)
                              ],
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(t["icon"] as IconData,
                                    color: selected ? Colors.white : color,
                                    size: 26),
                                const SizedBox(height: 6),
                                Text(
                                  t["label"],
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: selected
                                        ? Colors.white
                                        : Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Fragile switch
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 8)
                      ],
                    ),
                    child: SwitchListTile(
                      value: _fragile,
                      onChanged: (v) => setState(() => _fragile = v),
                      title: const Text("Colis fragile",
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text("+$_fragileSurcharge FCFA — manipulation avec soin",
                          style: const TextStyle(fontSize: 11)),
                      secondary: const Icon(Icons.warning_amber_rounded,
                          color: Colors.orange),
                      activeThumbColor: Colors.orange.shade700,
                    ),
                  ),

                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.payments_outlined,
                            size: 16,
                            color: Colors.orange.shade700),
                        const SizedBox(width: 8),
                        Text(
                          "Prix estimé : $_price FCFA",
                          style: TextStyle(
                              color: Colors.orange.shade700,
                              fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── EXPÉDITEUR ──────────────────────────────
                  _sectionTitle("Expéditeur (optionnel)"),
                  const SizedBox(height: 10),
                  _card([
                    _field(_senderNameCtrl, "Votre nom", Icons.person_outline),
                    const Divider(height: 1),
                    _field(_senderPhoneCtrl, "Votre téléphone",
                        Icons.phone_outlined,
                        type: TextInputType.phone),
                  ]),

                  const SizedBox(height: 20),

                  // ── DESTINATAIRE ────────────────────────────
                  _sectionTitle("Destinataire"),
                  const SizedBox(height: 10),
                  _card([
                    _field(_recipientNameCtrl, "Nom du destinataire *",
                        Icons.person),
                    const Divider(height: 1),
                    _field(_recipientPhoneCtrl, "Téléphone du destinataire",
                        Icons.phone,
                        type: TextInputType.phone),
                    const Divider(height: 1),
                    _field(_recipientAddressCtrl, "Adresse de livraison *",
                        Icons.location_on),
                  ]),

                  const SizedBox(height: 20),

                  // ── CONTENU ─────────────────────────────────
                  _sectionTitle("Description du contenu"),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 8)
                      ],
                    ),
                    child: TextField(
                      controller: _descriptionCtrl,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText:
                            "Ex : vêtements, documents importants...",
                        prefixIcon: Icon(Icons.inventory_outlined,
                            color: Colors.grey.shade400),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none),
                        filled: true,
                        fillColor: Colors.white,
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
                                  : Icons.local_shipping,
                              color: Colors.white),
                      label: Text(
                        _loading
                            ? "Envoi en cours..."
                            : _paymentMethod == 'wallet'
                                ? "Payer $_price FCFA par Wallet"
                                : "Envoyer le colis",
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange.shade700,
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
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.grey),
      );

  Widget _card(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
          ],
        ),
        child: Column(children: children),
      );

  Widget _field(
      TextEditingController ctrl, String hint, IconData icon,
      {TextInputType? type}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: TextField(
        controller: ctrl,
        keyboardType: type,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: Icon(icon, color: Colors.grey.shade400, size: 20),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none),
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        ),
      ),
    );
  }
}
