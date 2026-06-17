import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:uuid/uuid.dart';

import '../../models/order_model.dart';
import '../../services/firestore_service.dart';
import '../../services/tarif_service.dart';
import '../../widgets/address_picker_widget.dart';
import '../../widgets/scale_button.dart';
import 'order_wait_screen.dart';

class CoursesScreen extends StatefulWidget {
  const CoursesScreen({super.key});

  @override
  State<CoursesScreen> createState() => _CoursesScreenState();
}

class _CoursesScreenState extends State<CoursesScreen> {

  // ── Contrôleurs
  final _listCtrl        = TextEditingController();
  final _budgetCtrl      = TextEditingController();
  final _notesCtrl       = TextEditingController();
  final _mobilePhoneCtrl = TextEditingController();

  // ── Articles avec quantités et prix
  final List<String> _items      = [];
  final List<int>    _quantities = [];
  final List<int?>   _prices     = []; // null = pas de prix renseigné
  final _itemCtrl    = TextEditingController();

  // ── Adresse de livraison
  AddressResult? _deliveryAddress;

  // ── Mode de livraison
  String _deliveryMode = 'standard';

  // ── Paiement
  String _payment = 'cash';
  int    _wallet  = 0;
  StreamSubscription? _walletSub;

  // ── Voice
  final SpeechToText _speech       = SpeechToText();
  bool               _speechAvailable = false;
  bool               _listening    = false;
  String             _liveWords    = '';

  // ── État
  bool _sending = false;

  // ── Getters calculés ────────────────────────────────────────────────────────

  bool get _isPriceMode => _prices.any((p) => p != null);

  int get _articleTotal {
    int total = 0;
    for (int i = 0; i < _prices.length; i++) {
      if (_prices[i] != null) total += _prices[i]! * _quantities[i];
    }
    return total;
  }

  TarifResult get _tarifResult => TarifService.compute(
        clientLat: _deliveryAddress?.latitude  ?? TarifService.centerLat,
        clientLng: _deliveryAddress?.longitude ?? TarifService.centerLng,
      );

  int get _standardFee => _tarifResult.standardPrice;
  int get _expressFee  => _tarifResult.expressPrice;
  int get _deliveryFee => _deliveryMode == 'express' ? _expressFee : _standardFee;

  int get _budgetValue => int.tryParse(_budgetCtrl.text.trim()) ?? 0;

  int get _orderTotal {
    if (_isPriceMode) return _articleTotal + _deliveryFee;
    return _budgetValue + _deliveryFee;
  }

  String _fmt(int amount) {
    if (amount <= 0) return '—';
    final s = amount.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return '${buf.toString()} FCFA';
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _listenWallet();
    _budgetCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _speech.stop();
    _walletSub?.cancel();
    _listCtrl.dispose();
    _budgetCtrl.dispose();
    _notesCtrl.dispose();
    _itemCtrl.dispose();
    _mobilePhoneCtrl.dispose();
    super.dispose();
  }

  // ── Speech ──────────────────────────────────────────────────────────────────

  Future<void> _initSpeech() async {
    _speechAvailable = await _speech.initialize(
      onError: (e) => setState(() => _listening = false),
      onStatus: (s) {
        if (s == 'done' || s == 'notListening') {
          setState(() => _listening = false);
          if (_liveWords.trim().isNotEmpty) _addVoiceItem(_liveWords.trim());
          _liveWords = '';
        }
      },
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggleListening() async {
    if (!_speechAvailable) {
      _snack('Micro non disponible sur cet appareil', Colors.orange);
      return;
    }
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
    } else {
      setState(() { _listening = true; _liveWords = ''; });
      await _speech.listen(
        onResult: _onSpeechResult,
        listenOptions: SpeechListenOptions(
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 3),
          localeId: 'fr_FR',
          partialResults: true,
        ),
      );
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    setState(() => _liveWords = result.recognizedWords);
    if (result.finalResult && result.recognizedWords.trim().isNotEmpty) {
      _addVoiceItem(result.recognizedWords.trim());
      _liveWords = '';
    }
  }

  // ── Articles ─────────────────────────────────────────────────────────────────

  // Extrait le nom et le prix d'une saisie type "Huile 500 FCFA"
  ({String name, int? price}) _parseItem(String text) {
    final cleaned = text.trim();
    final match = RegExp(
      r'^(.+?)\s+(\d+)\s*(?:fcfa|f\.cfa|f)$',
      caseSensitive: false,
    ).firstMatch(cleaned);
    if (match != null) {
      final price = int.tryParse(match.group(2)!);
      if (price != null && price > 0) {
        return (name: _capitalize(match.group(1)!.trim()), price: price);
      }
    }
    return (name: _capitalize(cleaned), price: null);
  }

  void _addVoiceItem(String text) {
    final separators = RegExp(r'[,\.;]|\bet\b|\bpuis\b|\baussi\b', caseSensitive: false);
    final parts = text.split(separators)
        .map((s) => s.trim())
        .where((s) => s.length >= 2)
        .toList();
    setState(() {
      for (final part in parts) {
        final parsed = _parseItem(part);
        if (!_items.contains(parsed.name)) {
          _items.add(parsed.name);
          _quantities.add(1);
          _prices.add(parsed.price);
        }
      }
    });
  }

  void _addManualItem() {
    final text = _itemCtrl.text.trim();
    if (text.isEmpty) return;
    final parsed = _parseItem(text);
    setState(() {
      if (!_items.contains(parsed.name)) {
        _items.add(parsed.name);
        _quantities.add(1);
        _prices.add(parsed.price);
      }
      _itemCtrl.clear();
    });
  }

  void _removeItem(int index) {
    setState(() {
      _items.removeAt(index);
      _quantities.removeAt(index);
      _prices.removeAt(index);
    });
  }

  void _editItem(int index) {
    final nameCtrl  = TextEditingController(text: _items[index]);
    final priceCtrl = TextEditingController(text: _prices[index]?.toString() ?? '');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Modifier l\'article',
            style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: nameCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            style: GoogleFonts.inter(fontSize: 15),
            decoration: InputDecoration(
              labelText: 'Article',
              hintText: 'Ex : Huile, Tomates…',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: priceCtrl,
            keyboardType: TextInputType.number,
            style: GoogleFonts.inter(fontSize: 15),
            decoration: InputDecoration(
              labelText: 'Prix unitaire (optionnel)',
              hintText: 'Ex : 500',
              suffixText: 'FCFA',
              suffixStyle: TextStyle(
                  color: Colors.grey.shade500, fontWeight: FontWeight.w600),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Annuler',
                style: GoogleFonts.inter(color: Colors.grey.shade600)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2E7D32),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              final name  = nameCtrl.text.trim();
              final price = int.tryParse(
                  priceCtrl.text.trim().replaceAll(' ', '').replaceAll(' ', ''));
              if (name.isNotEmpty) {
                setState(() {
                  _items[index]  = _capitalize(name);
                  _prices[index] = (price != null && price > 0) ? price : null;
                });
              }
              Navigator.pop(context);
            },
            child: Text('Valider', style: GoogleFonts.inter(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _changeQty(int index, int delta) {
    setState(() {
      final newQty = _quantities[index] + delta;
      if (newQty <= 0) {
        _items.removeAt(index);
        _quantities.removeAt(index);
        _prices.removeAt(index);
      } else {
        _quantities[index] = newQty;
      }
    });
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

  // ── Wallet ───────────────────────────────────────────────────────────────────

  void _listenWallet() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _walletSub = FirebaseFirestore.instance
        .collection('clients')
        .doc(uid)
        .snapshots()
        .listen((s) {
      if (mounted) {
        setState(
            () => _wallet = (s.data()?['wallet'] as num?)?.toInt() ?? 0);
      }
    });
  }

  // ── Validation ───────────────────────────────────────────────────────────────

  void _showValidationError(List<String> missing) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Icon(Icons.warning_amber_rounded,
              color: Color(0xFFFF6D00), size: 22),
          const SizedBox(width: 8),
          Text('Informations manquantes',
              style: GoogleFonts.inter(
                  fontSize: 15, fontWeight: FontWeight.w700)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Veuillez renseigner :',
                style: GoogleFonts.inter(
                    fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 10),
            ...missing.map((m) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                const Icon(Icons.cancel_rounded, color: Colors.red, size: 16),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(m,
                        style: GoogleFonts.inter(
                            fontSize: 13, fontWeight: FontWeight.w600))),
              ]),
            )),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2E7D32),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(context),
            child: Text('OK', style: GoogleFonts.inter(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ── Envoi commande ───────────────────────────────────────────────────────────

  Future<void> _sendOrder() async {
    final tarif = _tarifResult;
    if (!tarif.canOrder) {
      _snack(tarif.rejectionMessage ?? 'Livraison non disponible', Colors.red);
      return;
    }

    final int shoppingBudget =
        _isPriceMode ? _articleTotal : _budgetValue;
    final int totalBudget = shoppingBudget + _deliveryFee;
    final needsMobilePhone = _payment != 'cash' && _payment != 'wallet';

    final missing = <String>[];
    if (_items.isEmpty && _listCtrl.text.trim().isEmpty) {
      missing.add('Articles à acheter');
    }
    if (!_isPriceMode && _budgetValue < 500) {
      missing.add('Budget minimum 500 FCFA');
    }
    if (_deliveryAddress == null) missing.add('Adresse de livraison');
    if (needsMobilePhone && _mobilePhoneCtrl.text.trim().isEmpty) {
      missing.add('Numéro de paiement mobile');
    }

    if (missing.isNotEmpty) {
      _showValidationError(missing);
      return;
    }

    if (_payment == 'wallet' && _wallet < totalBudget) {
      _snack('Solde insuffisant ($_wallet FCFA)', Colors.red);
      return;
    }

    setState(() => _sending = true);

    try {
      var user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        final c = await FirebaseAuth.instance.signInAnonymously();
        user = c.user;
      }

      String? clientName;
      String? clientPhone;
      if (user?.uid != null) {
        try {
          final profile = await FirebaseFirestore.instance
              .collection('clients')
              .doc(user!.uid)
              .get();
          clientName  = profile.data()?['name']  as String?;
          clientPhone = profile.data()?['phone'] as String?;
        } catch (_) {}
      }

      final itemList = _items.isNotEmpty
          ? _items.asMap().entries.map((e) {
              final qty      = _quantities[e.key];
              final price    = _prices[e.key];
              final priceStr = price != null
                  ? ' — ${_fmt(price * qty)}'
                  : '';
              return '${e.key + 1}. ${e.value}'
                  '${qty > 1 ? " (x$qty)" : ""}$priceStr';
            }).join('\n')
          : _listCtrl.text.trim();

      final notes       = _notesCtrl.text.trim();
      final mobilePhone = _mobilePhoneCtrl.text.trim();
      var desc = itemList + (notes.isNotEmpty ? '\n\nNotes : $notes' : '');
      if (mobilePhone.isNotEmpty) desc += '\nPaiement : $mobilePhone';

      if (_payment == 'wallet') {
        await FirebaseFirestore.instance.runTransaction((tx) async {
          final ref  = FirebaseFirestore.instance
              .collection('clients')
              .doc(user!.uid);
          final snap = await tx.get(ref);
          final bal  = (snap.data()?['wallet'] as num?)?.toInt() ?? 0;
          if (bal < totalBudget) throw Exception('SOLDE_INSUFFISANT');
          tx.update(ref, {'wallet': bal - totalBudget});
        });
      }

      final orderId = const Uuid().v4();
      final order = OrderModel(
        id:              orderId,
        description:     desc,
        budget:          _deliveryFee,
        shoppingBudget:  shoppingBudget,
        status:          'pending',
        latitude:        _deliveryAddress!.latitude,
        longitude:       _deliveryAddress!.longitude,
        deliveryAddress: _deliveryAddress!.address,
        type:            'shopping',
        clientId:        user?.uid,
        clientName:      clientName,
        clientPhone:     clientPhone,
        paymentMethod:   _payment,
        isPaid:          _payment == 'wallet',
        forSelf:         true,
        deliveryMode:    _deliveryMode,
      );

      await FirestoreService().createOrder(order);
      if (!mounted) return;

      // Réinitialiser le formulaire
      setState(() {
        _items.clear();
        _quantities.clear();
        _prices.clear();
        _listCtrl.clear();
        _budgetCtrl.clear();
        _notesCtrl.clear();
        _mobilePhoneCtrl.clear();
        _deliveryAddress = null;
        _sending = false;
      });

      // Naviguer vers l'écran d'attente / suivi
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OrderWaitScreen(order: order),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _snack('Erreur : $e', Colors.red);
    }
  }

  void _snack(String msg, Color color) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));

  // ══════════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Mes Courses'),
        backgroundColor: const Color(0xFF2E7D32),
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPad + 24),
        physics: const BouncingScrollPhysics(),
        children: [

          // ── Articles ─────────────────────────────────────────────────────────
          const _Section(
            icon: Icons.shopping_basket_rounded,
            title: 'Articles à acheter',
            color: Color(0xFF2E7D32),
          ),
          const SizedBox(height: 6),
          Text(
            'Ajoutez le prix pour un calcul auto · ex : "Huile 500 FCFA"',
            style: GoogleFonts.inter(
                fontSize: 11, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 10),

          // Barre saisie + micro
          Container(
            decoration: _cardDec,
            padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
            child: Row(children: [
              const Icon(Icons.add_shopping_cart_rounded,
                  size: 20, color: Color(0xFF2E7D32)),
              const SizedBox(width: 10),
              Expanded(child: TextField(
                controller: _itemCtrl,
                style: GoogleFonts.inter(fontSize: 15),
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Huile 500 FCFA, Tomates, Pain…',
                  hintStyle: GoogleFonts.inter(
                      fontSize: 14, color: Colors.grey.shade400),
                  border: InputBorder.none,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 14),
                ),
                onSubmitted: (_) => _addManualItem(),
              )),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: _addManualItem,
                  child: Container(
                    width: 40, height: 40,
                    alignment: Alignment.center,
                    child: const Icon(Icons.add_circle_rounded,
                        color: Color(0xFF2E7D32), size: 28),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: _toggleListening,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: _listening
                        ? Colors.red.shade500
                        : const Color(0xFF2E7D32),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _listening
                        ? Icons.stop_rounded
                        : Icons.mic_rounded,
                    color: Colors.white, size: 22,
                  ),
                ),
              ),
            ]),
          ),

          // Transcription en direct
          if (_listening && _liveWords.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(children: [
                Icon(Icons.mic_rounded, color: Colors.red.shade400, size: 14),
                const SizedBox(width: 8),
                Expanded(child: Text(_liveWords,
                    style: GoogleFonts.inter(
                        fontSize: 13, fontStyle: FontStyle.italic))),
              ]),
            ),
          ],

          if (!_listening && _speechAvailable) ...[
            const SizedBox(height: 6),
            Text('🎙 Dictez vos articles séparés par des virgules',
                style: GoogleFonts.inter(
                    fontSize: 11, color: Colors.grey.shade500)),
          ],

          const SizedBox(height: 12),

          // Liste des articles
          if (_items.isNotEmpty)
            Container(
              decoration: _cardDec,
              child: Column(
                children: _items.asMap().entries.map((e) {
                  final i     = e.key;
                  final item  = e.value;
                  final qty   = _quantities[i];
                  final price = _prices[i];
                  return Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      child: Row(children: [
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item, style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87)),
                            if (price != null)
                              Text(
                                qty > 1
                                    ? '${_fmt(price)} × $qty = ${_fmt(price * qty)}'
                                    : _fmt(price),
                                style: GoogleFonts.inter(
                                    fontSize: 11,
                                    color: const Color(0xFF2E7D32),
                                    fontWeight: FontWeight.w600),
                              )
                            else
                              Text('Quantité : $qty',
                                  style: GoogleFonts.inter(
                                      fontSize: 11,
                                      color: Colors.grey.shade500)),
                          ],
                        )),
                        _QtyBtn(
                          icon: Icons.remove,
                          color: const Color(0xFF2E7D32),
                          onTap: () => _changeQty(i, -1),
                        ),
                        Container(
                          width: 32, alignment: Alignment.center,
                          child: Text('$qty', style: GoogleFonts.inter(
                              fontSize: 14, fontWeight: FontWeight.w700)),
                        ),
                        _QtyBtn(
                          icon: Icons.add,
                          color: const Color(0xFF2E7D32),
                          onTap: () => _changeQty(i, 1),
                        ),
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: () => _editItem(i),
                          child: Icon(Icons.edit_outlined,
                              size: 19, color: Colors.blue.shade300),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _removeItem(i),
                          child: Icon(Icons.delete_outline_rounded,
                              size: 19, color: Colors.red.shade300),
                        ),
                      ]),
                    ),
                    if (i < _items.length - 1)
                      Divider(
                          height: 1,
                          indent: 14,
                          endIndent: 14,
                          color: Colors.grey.shade100),
                  ]);
                }).toList(),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(20),
              decoration: _cardDec,
              child: Center(
                child: Column(children: [
                  Icon(Icons.shopping_basket_outlined,
                      size: 40, color: Colors.grey.shade300),
                  const SizedBox(height: 8),
                  Text('Aucun article pour l\'instant',
                      style: GoogleFonts.inter(
                          color: Colors.grey.shade400, fontSize: 13)),
                  Text('Tapez ou dictez vos courses',
                      style: GoogleFonts.inter(
                          color: Colors.grey.shade400, fontSize: 11)),
                ]),
              ),
            ),

          const SizedBox(height: 20),

          // ── Budget (mode budget seulement) ───────────────────────────────────
          if (!_isPriceMode) ...[
            const _Section(
              icon: Icons.account_balance_wallet_rounded,
              title: 'Budget maximum pour les courses',
              color: Color(0xFFFF6D00),
            ),
            const SizedBox(height: 6),
            Text(
              'Indiquez combien dépenser pour les articles (hors frais de livraison)',
              style: GoogleFonts.inter(
                  fontSize: 11, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 10),
            Container(
              decoration: _cardDec,
              child: TextField(
                controller:   _budgetCtrl,
                keyboardType: TextInputType.number,
                style: GoogleFonts.inter(
                    fontSize: 18, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  hintText: 'ex : 2 500',
                  hintStyle: GoogleFonts.inter(
                      fontSize: 16, color: Colors.grey.shade400),
                  prefixIcon: const Icon(
                      Icons.account_balance_wallet_rounded,
                      color: Color(0xFFFF6D00)),
                  suffixText: 'FCFA',
                  suffixStyle: TextStyle(
                      color: Colors.grey.shade500,
                      fontWeight: FontWeight.w600),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  filled:    true,
                  fillColor: Colors.white,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // ── Adresse de livraison ─────────────────────────────────────────────
          const _Section(
            icon: Icons.place_rounded,
            title: 'Adresse de livraison',
            color: Color(0xFF1565C0),
          ),
          const SizedBox(height: 10),
          AddressPickerWidget(
            title:       'Livraison',
            hint:        'Où livrer ? Tapez quartier, rue, lieu-dit…',
            initialMode: AddressMode.gps,
            onChanged:   (r) => setState(() => _deliveryAddress = r),
          ),
          if (_deliveryAddress != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: const Color(0xFF1565C0).withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFF1565C0).withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.location_on_rounded,
                    color: Color(0xFF1565C0), size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(_deliveryAddress!.address,
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF1565C0)))),
                const Icon(Icons.check_circle_rounded,
                    color: Color(0xFF1565C0), size: 16),
              ]),
            ),
          ],

          const SizedBox(height: 20),

          // ── Mode de livraison ────────────────────────────────────────────────
          const _Section(
            icon: Icons.electric_bike_rounded,
            title: 'Mode de livraison',
            color: Color(0xFFFF7A1A),
          ),
          const SizedBox(height: 10),
          _CourseModeCard(
            mode:       'standard',
            icon:       Icons.electric_bike_rounded,
            title:      'STANDARD',
            subtitle:   'Le livreur peut combiner plusieurs courses',
            etaText:    '45 – 90 min',
            priceText:  _fmt(_standardFee),
            iconColor:  const Color(0xFF2E7D32),
            isSelected: _deliveryMode == 'standard',
            onTap:      () => setState(() => _deliveryMode = 'standard'),
          ),
          const SizedBox(height: 8),
          _CourseModeCard(
            mode:       'express',
            icon:       Icons.rocket_launch_rounded,
            title:      'EXPRESS',
            subtitle:   'Mission dédiée uniquement pour vous',
            etaText:    '15 – 30 min',
            priceText:  _fmt(_expressFee),
            iconColor:  const Color(0xFFFF7A1A),
            isSelected: _deliveryMode == 'express',
            onTap:      () => setState(() => _deliveryMode = 'express'),
            badge:      'Prioritaire',
          ),

          const SizedBox(height: 20),

          // ── Récapitulatif dynamique ──────────────────────────────────────────
          _buildRecap(),

          const SizedBox(height: 20),

          // ── Notes ────────────────────────────────────────────────────────────
          _Section(
            icon: Icons.notes_rounded,
            title: 'Notes complémentaires',
            color: Colors.grey.shade600,
          ),
          const SizedBox(height: 10),
          Container(
            decoration: _cardDec,
            child: TextField(
              controller: _notesCtrl,
              maxLines:   4,
              style:      GoogleFonts.inter(fontSize: 14),
              decoration: InputDecoration(
                hintText:
                    'Ne pas sonner, appeler avant d\'arriver,\nmonter au 2e étage, laisser au gardien…',
                hintStyle: GoogleFonts.inter(
                    fontSize: 13, color: Colors.grey.shade400),
                prefixIcon: const Padding(
                  padding: EdgeInsets.only(
                      left: 14, right: 10, top: 14, bottom: 100),
                  child: Icon(Icons.sticky_note_2_rounded,
                      size: 20, color: Color(0xFF607D8B)),
                ),
                prefixIconConstraints: const BoxConstraints(),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(16),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // ── Paiement ─────────────────────────────────────────────────────────
          const _Section(
            icon: Icons.credit_card_rounded,
            title: 'Mode de paiement',
            color: Color(0xFF2E7D32),
          ),
          const SizedBox(height: 10),
          ...[
            _PayRow(
              icon: Icons.money_rounded,
              iconColor: const Color(0xFF2E7D32),
              label: 'Espèces',
              subtitle: 'Paiement au livreur',
              selected: _payment == 'cash',
              onTap: () => setState(() => _payment = 'cash'),
            ),
            _PayRow(
              imagePath: 'assets/orange_money.png',
              iconColor: const Color(0xFFFF6600),
              label: 'Orange Money',
              subtitle: 'Paiement mobile',
              selected: _payment == 'orange_money',
              onTap: () => setState(() => _payment = 'orange_money'),
            ),
            _PayRow(
              imagePath: 'assets/mtn_money.png',
              iconColor: const Color(0xFFFFCC00),
              label: 'MTN Mobile Money',
              subtitle: 'Paiement mobile',
              selected: _payment == 'mtn_money',
              onTap: () => setState(() => _payment = 'mtn_money'),
            ),
            _PayRow(
              imagePath: 'assets/wave.png',
              iconColor: const Color(0xFF1ABCFE),
              label: 'Wave',
              subtitle: 'Paiement mobile',
              selected: _payment == 'wave',
              onTap: () => setState(() => _payment = 'wave'),
            ),
            if (_wallet > 0)
              _PayRow(
                icon:      Icons.account_balance_wallet_rounded,
                iconColor: const Color(0xFF6A1B9A),
                label:     'Wallet · ${_fmt(_wallet)}',
                subtitle:  _wallet >= _orderTotal && _orderTotal > 0
                    ? 'Solde suffisant — paiement immédiat'
                    : 'Solde disponible',
                selected:  _payment == 'wallet',
                onTap:     () => setState(() => _payment = 'wallet'),
              ),
          ],
          if (_payment != 'cash' && _payment != 'wallet') ...[
            const SizedBox(height: 10),
            Container(
              decoration: _cardDec,
              child: TextField(
                controller:   _mobilePhoneCtrl,
                keyboardType: TextInputType.phone,
                style: GoogleFonts.inter(
                    fontSize: 15, fontWeight: FontWeight.w500),
                decoration: InputDecoration(
                  hintText: _payment == 'orange_money'
                      ? 'Numéro Orange Money (ex : 07 XX XX XX XX)'
                      : _payment == 'mtn_money'
                          ? 'Numéro MTN MoMo (ex : 05 XX XX XX XX)'
                          : 'Numéro Wave (ex : 01 XX XX XX XX)',
                  hintStyle: GoogleFonts.inter(
                      fontSize: 13, color: Colors.grey.shade400),
                  prefixIcon: Icon(
                    Icons.phone_rounded,
                    color: _payment == 'orange_money'
                        ? const Color(0xFFFF6600)
                        : _payment == 'mtn_money'
                            ? const Color(0xFFFFCC00)
                            : const Color(0xFF1ABCFE),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  filled:    true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 16),
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),

          // ── Bouton commander ─────────────────────────────────────────────────
          _buildCommanderButton(),
        ],
      ),
    );
  }

  // ── Récapitulatif dynamique ──────────────────────────────────────────────────

  Widget _buildRecap() {
    final modeName = _deliveryMode == 'express' ? 'Express' : 'Standard';
    final fee      = _deliveryFee;

    if (_isPriceMode) {
      // Mode prix : affiche articles + livraison + total
      final artTotal = _articleTotal;
      final total    = artTotal + fee;
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFF2E7D32).withValues(alpha: 0.08),
              const Color(0xFF1B5E20).withValues(alpha: 0.03),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: const Color(0xFF2E7D32).withValues(alpha: 0.2)),
        ),
        child: Column(children: [
          // En-tête
          Row(children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF2E7D32).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.receipt_long_rounded,
                  color: Color(0xFF2E7D32), size: 16),
            ),
            const SizedBox(width: 10),
            Text('Récapitulatif de commande',
                style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87)),
          ]),
          const SizedBox(height: 14),
          _recapLine(
            label: 'Articles (${_items.length})',
            value: _items.isNotEmpty ? _fmt(artTotal) : '—',
          ),
          const SizedBox(height: 8),
          _recapLine(
            label: 'Livraison $modeName${_tarifResult.isNight ? " 🌙" : ""}',
            value: _fmt(fee),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(
                height: 1,
                color: const Color(0xFF2E7D32).withValues(alpha: 0.3)),
          ),
          Row(children: [
            Expanded(child: Text('TOTAL',
                style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Colors.black87))),
            Text(
              _items.isNotEmpty ? _fmt(total) : '—',
              style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF2E7D32)),
            ),
          ]),
        ]),
      );
    }

    // Mode budget : affiche budget + livraison Standard + livraison Express
    final budget   = _budgetValue;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFFF6D00).withValues(alpha: 0.08),
            const Color(0xFFFF6D00).withValues(alpha: 0.03),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: const Color(0xFFFF6D00).withValues(alpha: 0.25)),
      ),
      child: Column(children: [
        // En-tête
        Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFFFF6D00).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.calculate_rounded,
                color: Color(0xFFFF6D00), size: 16),
          ),
          const SizedBox(width: 10),
          Text(
            'Estimation du coût total${_tarifResult.isNight ? " 🌙" : ""}',
            style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.black87),
          ),
        ]),
        const SizedBox(height: 14),
        _recapLine(
          label: 'Budget courses',
          value: budget > 0 ? _fmt(budget) : '—',
        ),
        const SizedBox(height: 12),
        // Ligne Standard
        _recapModeRow(
          label:      'Standard',
          icon:       Icons.electric_bike_rounded,
          total:      budget > 0 ? budget + _standardFee : 0,
          isSelected: _deliveryMode == 'standard',
          color:      const Color(0xFF2E7D32),
        ),
        const SizedBox(height: 8),
        // Ligne Express
        _recapModeRow(
          label:      'Express',
          icon:       Icons.rocket_launch_rounded,
          total:      budget > 0 ? budget + _expressFee : 0,
          isSelected: _deliveryMode == 'express',
          color:      const Color(0xFFFF7A1A),
        ),
      ]),
    );
  }

  Widget _recapLine({required String label, required String value}) {
    return Row(children: [
      Expanded(child: Text(label,
          style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade700))),
      Text(value,
          style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Colors.black87)),
    ]);
  }

  Widget _recapModeRow({
    required String   label,
    required IconData icon,
    required int      total,
    required bool     isSelected,
    required Color    color,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isSelected
            ? color.withValues(alpha: 0.10)
            : Colors.white.withValues(alpha: 0.70),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected ? color : Colors.grey.shade200,
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: Row(children: [
        Icon(icon,
            size: 16,
            color: isSelected ? color : Colors.grey.shade400),
        const SizedBox(width: 8),
        Expanded(child: Text(label,
            style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight:
                    isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? color : Colors.grey.shade600))),
        Text(
          total > 0 ? _fmt(total) : '—',
          style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: isSelected ? color : Colors.grey.shade500),
        ),
        if (isSelected) ...[
          const SizedBox(width: 6),
          Icon(Icons.check_circle_rounded, size: 16, color: color),
        ],
      ]),
    );
  }

  Widget _buildCommanderButton() {
    final showTotal = (_isPriceMode && _items.isNotEmpty) ||
        (!_isPriceMode && _budgetValue > 0);
    return SizedBox(
      height: showTotal ? 70 : 56,
      child: ScaleButton(
        onPressed: _sending ? null : _sendOrder,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF2E7D32),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
        child: _sending
            ? const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5),
                  ),
                  SizedBox(width: 12),
                  Text('Recherche en cours…',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600)),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.shopping_cart_checkout_rounded,
                          color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                      Text('Commander maintenant',
                          style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ],
                  ),
                  if (showTotal) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Total estimé : ${_fmt(_orderTotal)}',
                      style: GoogleFonts.inter(
                          fontSize: 11, color: Colors.white70),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  BoxDecoration get _cardDec => BoxDecoration(
    color:        Colors.white,
    borderRadius: BorderRadius.circular(14),
    boxShadow: [
      BoxShadow(
          color: Colors.black.withValues(alpha: 0.05), blurRadius: 6)
    ],
  );
}

// ── Widgets locaux ─────────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final IconData icon;
  final String   title;
  final Color    color;
  const _Section(
      {required this.icon, required this.title, required this.color});

  @override
  Widget build(BuildContext context) => Row(children: [
    Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8)),
      child: Icon(icon, color: color, size: 16),
    ),
    const SizedBox(width: 10),
    Text(title,
        style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Colors.black87)),
  ]);
}

class _QtyBtn extends StatelessWidget {
  final IconData      icon;
  final Color         color;
  final VoidCallback  onTap;
  const _QtyBtn(
      {required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 30, height: 30,
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
      child: Icon(icon, color: color, size: 16),
    ),
  );
}

class _PayRow extends StatelessWidget {
  final IconData? icon;
  final String?   imagePath;
  final Color     iconColor;
  final String    label, subtitle;
  final bool      selected;
  final VoidCallback? onTap;

  const _PayRow({
    this.icon,
    this.imagePath,
    required this.iconColor,
    required this.label,
    required this.subtitle,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF2E7D32).withValues(alpha: 0.06)
              : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? const Color(0xFF2E7D32)
                : Colors.grey.shade200,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: imagePath != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      imagePath!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Icon(
                          Icons.payment_rounded,
                          color: iconColor,
                          size: 20),
                    ),
                  )
                : Icon(icon ?? Icons.payment_rounded,
                    color: iconColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.black87)),
              Text(subtitle,
                  style: GoogleFonts.inter(
                      fontSize: 11, color: Colors.grey.shade500)),
            ],
          )),
          if (selected)
            const Icon(Icons.check_circle_rounded,
                color: Color(0xFF2E7D32), size: 20)
          else
            Icon(Icons.radio_button_unchecked_rounded,
                color: Colors.grey.shade300, size: 20),
        ]),
      ),
    );
  }
}

class _CourseModeCard extends StatelessWidget {
  final String     mode;
  final IconData   icon;
  final String     title;
  final String     subtitle;
  final String     etaText;
  final String?    priceText;
  final Color      iconColor;
  final bool       isSelected;
  final VoidCallback onTap;
  final String?    badge;

  const _CourseModeCard({
    required this.mode,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.etaText,
    required this.iconColor,
    required this.isSelected,
    required this.onTap,
    this.priceText,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected
              ? iconColor.withValues(alpha: 0.06)
              : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? iconColor : Colors.grey.shade200,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [BoxShadow(
                  color: iconColor.withValues(alpha: 0.12),
                  blurRadius: 8)]
              : [BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 4)],
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: isSelected
                  ? iconColor.withValues(alpha: 0.14)
                  : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon,
                color: isSelected ? iconColor : Colors.grey.shade500,
                size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(title,
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: isSelected
                            ? iconColor
                            : Colors.black87)),
                if (badge != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(badge!,
                        style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: iconColor)),
                  ),
                ],
              ]),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: GoogleFonts.inter(
                      fontSize: 11, color: Colors.grey.shade600)),
              const SizedBox(height: 2),
              Row(children: [
                const Icon(Icons.access_time_rounded,
                    size: 12, color: Colors.grey),
                const SizedBox(width: 3),
                Text(etaText,
                    style: GoogleFonts.inter(
                        fontSize: 11,
                        color: Colors.grey.shade500,
                        fontWeight: FontWeight.w600)),
                if (priceText != null) ...[
                  const SizedBox(width: 10),
                  const Icon(Icons.payments_outlined,
                      size: 12, color: Colors.grey),
                  const SizedBox(width: 3),
                  Text(priceText!,
                      style: GoogleFonts.inter(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                          fontWeight: FontWeight.w600)),
                ],
              ]),
            ],
          )),
          Icon(
            isSelected
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            color: isSelected ? iconColor : Colors.grey.shade400,
            size: 22,
          ),
        ]),
      ),
    );
  }
}
