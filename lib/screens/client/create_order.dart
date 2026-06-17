import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_sound/flutter_sound.dart' hide PlayerState;
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:geolocator/geolocator.dart';

import '../../services/firestore_service.dart';
import '../../services/delivery_service.dart';
import '../../models/order_model.dart';
import '../../widgets/scale_button.dart';
import '../../widgets/address_picker_widget.dart';

// Centre d'Abengourou — point de référence pour les calculs de distance
const double _abgLat = 6.7273;
const double _abgLng = -3.4961;

class CreateOrderScreen extends StatefulWidget {
  const CreateOrderScreen({super.key});

  @override
  State<CreateOrderScreen> createState() => _CreateOrderScreenState();
}

class _CreateOrderScreenState extends State<CreateOrderScreen> {

  // ── Infos client ─────────────────────────────────────────────────────────
  final _nameCtrl           = TextEditingController();
  final _phoneCtrl          = TextEditingController();

  // ── Commande ──────────────────────────────────────────────────────────────
  final _listCtrl           = TextEditingController();
  final _shoppingBudgetCtrl = TextEditingController();

  // ── Pour qui ──────────────────────────────────────────────────────────────
  bool _forSelf    = true;
  bool _forBusiness = false; // Pour un commerce

  // ── Adresses ──────────────────────────────────────────────────────────────
  AddressResult? _deliveryResult;
  AddressResult? _pickupResult;
  final _pickupDescCtrl = TextEditingController();

  // Méthode de sélection adresse : 'gps' | 'zone' | 'maps'
  String _pickupMethod   = 'maps';
  String _deliveryMethod = 'maps';
  bool   _pickupGpsLoading   = false;
  bool   _deliveryGpsLoading = false;

  // Zones sélectionnées
  String? _pickupZone;
  String? _deliveryZone;

  // Contacts
  final _pickupContactNameCtrl  = TextEditingController();
  final _pickupContactPhoneCtrl = TextEditingController();
  final _recipientNameCtrl      = TextEditingController();
  final _recipientPhoneCtrl     = TextEditingController();

  // ── Paiement ──────────────────────────────────────────────────────────────
  String              _paymentMethod = 'cash';
  int                 _walletBalance = 0;
  bool                _codEnabled    = true;
  StreamSubscription? _walletSub;

  // ── Prix ──────────────────────────────────────────────────────────────────
  PriceBreakdown? _breakdown;

  // ── Audio ─────────────────────────────────────────────────────────────────
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final AudioPlayer          _player   = AudioPlayer();
  bool    _isRecording        = false;
  String? _audioPath;
  Timer?  _recordingTimer;
  int     _recordingSeconds   = 0;
  int     _audioDurationSeconds = 0;
  bool    _isPlaying          = false;
  int     _playPosition       = 0;

  // ── État envoi ────────────────────────────────────────────────────────────
  bool _sending = false;

  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initRecorder();
    _listenWallet();
  }

  void _listenWallet() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _walletSub = FirebaseFirestore.instance
        .collection('clients').doc(uid).snapshots().listen((snap) {
      if (!mounted) return;
      final data  = snap.data();
      final codOk = data?['cashOnDeliveryEnabled'] ?? true;
      setState(() {
        _walletBalance = (data?['wallet'] as num?)?.toInt() ?? 0;
        _codEnabled    = codOk as bool;
        if (!_codEnabled && _paymentMethod == 'cash') _paymentMethod = 'wallet';
      });
    });
  }

  Future<void> _initRecorder() async {
    await Permission.microphone.request();
    await _recorder.openRecorder();
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _isPlaying = s == PlayerState.playing);
    });
    _player.onPositionChanged.listen((pos) {
      if (mounted) setState(() => _playPosition = pos.inSeconds);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _isPlaying = false; _playPosition = 0; });
    });
  }

  @override
  void dispose() {
    _walletSub?.cancel();
    _recordingTimer?.cancel();
    _recorder.closeRecorder();
    _player.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _listCtrl.dispose();
    _shoppingBudgetCtrl.dispose();
    _pickupDescCtrl.dispose();
    _pickupContactNameCtrl.dispose();
    _pickupContactPhoneCtrl.dispose();
    _recipientNameCtrl.dispose();
    _recipientPhoneCtrl.dispose();
    super.dispose();
  }

  // ── Enregistrement vocal ──────────────────────────────────────────────────

  Future<void> _startRecording() async {
    final dir  = await getTemporaryDirectory();
    _audioPath = '${dir.path}/az_order_${DateTime.now().millisecondsSinceEpoch}.aac';
    await _recorder.startRecorder(toFile: _audioPath);
    _recordingSeconds = 0;
    _recordingTimer   = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordingSeconds++);
    });
    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    final path = await _recorder.stopRecorder();
    if (path != null) _audioPath = path;
    _audioDurationSeconds = _recordingSeconds;
    _playPosition = 0;
    setState(() => _isRecording = false);
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _player.pause();
    } else {
      await _player.play(DeviceFileSource(_audioPath!));
    }
  }

  void _deleteVoice() {
    _player.stop();
    setState(() {
      _audioPath            = null;
      _isPlaying            = false;
      _playPosition         = 0;
      _audioDurationSeconds = 0;
      _recordingSeconds     = 0;
    });
  }

  String _fmtTime(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  Future<String?> _uploadVoice(String orderId) async {
    if (_audioPath == null) return null;
    try {
      final ref = FirebaseStorage.instance
          .ref().child('voice_messages/$orderId/voice.aac');
      await ref.putFile(File(_audioPath!), SettableMetadata(contentType: 'audio/aac'));
      return await ref.getDownloadURL();
    } catch (_) {
      return null;
    }
  }

  // ── Calcul prix ───────────────────────────────────────────────────────────

  Future<void> _calculatePrice() async {
    if (_deliveryResult == null) {
      _snack('Choisissez d\'abord l\'adresse de livraison');
      return;
    }
    final startLat = _pickupResult?.latitude  ?? _abgLat;
    final startLng = _pickupResult?.longitude ?? _abgLng;
    final dist = DeliveryService.calculateDistance(
      startLat, startLng,
      _deliveryResult!.latitude, _deliveryResult!.longitude,
    );
    setState(() => _breakdown = DeliveryService.priceBreakdown(dist));
  }

  // ── Envoi commande ────────────────────────────────────────────────────────

  // ── GPS helper ─────────────────────────────────────────────────────────────
  Future<AddressResult?> _getGpsPosition() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      _snack('Permission GPS refusée', color: Colors.red);
      return null;
    }
    final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high));
    return AddressResult(
      latitude:  pos.latitude,
      longitude: pos.longitude,
      address:   'Ma position actuelle',
    );
  }

  Future<void> _sendOrder() async {
    final name   = _nameCtrl.text.trim();
    final phone  = _phoneCtrl.text.trim();
    final list   = _listCtrl.text.trim();

    if (name.isEmpty || phone.isEmpty || list.isEmpty) {
      _snack('Remplissez tous les champs obligatoires'); return;
    }
    if (_deliveryResult == null && _deliveryZone == null) {
      _snack('Choisissez l\'adresse ou la zone de livraison'); return;
    }
    if (_deliveryResult == null) {
      _snack('Choisissez l\'adresse de livraison'); return;
    }
    if (_breakdown == null) {
      _snack('Calculez le prix de livraison d\'abord'); return;
    }

    final deliveryFee = _breakdown!.total;

    if (deliveryFee < 500) {
      _snack('Frais de livraison minimum : 500 FCFA'); return;
    }
    if (deliveryFee > 10000) {
      _snack('Frais trop élevés. Vérifiez la distance.'); return;
    }
    if (_paymentMethod == 'wallet' && _walletBalance < deliveryFee) {
      _snack(
        'Solde insuffisant (${_fmtW(_walletBalance)} FCFA). Frais : $deliveryFee FCFA',
        color: Colors.red,
      );
      return;
    }

    final shoppingBudget = (int.tryParse(_shoppingBudgetCtrl.text.trim()) ?? 0)
        .clamp(0, 9999999);

    setState(() => _sending = true);

    // Auth
    User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      try { final c = await FirebaseAuth.instance.signInAnonymously(); user = c.user; }
      catch (_) {}
    }
    final uid = user?.uid;

    // Débit wallet si nécessaire
    if (_paymentMethod == 'wallet' && uid != null) {
      try {
        final clientRef = FirebaseFirestore.instance.collection('clients').doc(uid);
        await FirebaseFirestore.instance.runTransaction((tx) async {
          final snap    = await tx.get(clientRef);
          final current = (snap.data()?['wallet'] as num?)?.toInt() ?? 0;
          if (current < deliveryFee) throw Exception('SOLDE_INSUFFISANT');
          tx.update(clientRef, {'wallet': current - deliveryFee});
        });
        await FirebaseFirestore.instance
            .collection('clients').doc(uid).collection('wallet_transactions')
            .add({
          'type': 'payment', 'amount': deliveryFee,
          'description': 'Frais de livraison', 'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _sending = false);
        _snack(
          e.toString().contains('SOLDE_INSUFFISANT')
              ? 'Solde insuffisant'
              : 'Erreur paiement : $e',
          color: Colors.red,
        );
        return;
      }
    }

    try {
      final orderId  = const Uuid().v4();
      final audioUrl = await _uploadVoice(orderId);

      // Description du lieu de collecte
      final pickupAddr = _pickupDescCtrl.text.trim().isNotEmpty
          ? _pickupDescCtrl.text.trim()
          : _pickupResult?.address;

      // Destinataire : pour moi = moi-même, sinon champs séparés
      final recipientName = _forSelf
          ? name
          : _recipientNameCtrl.text.trim().isNotEmpty
              ? _recipientNameCtrl.text.trim()
              : null;
      final recipientPhone = _forSelf
          ? phone
          : _recipientPhoneCtrl.text.trim().isNotEmpty
              ? _recipientPhoneCtrl.text.trim()
              : null;

      final order = OrderModel(
        id:             orderId,
        description:    list,
        budget:         deliveryFee,
        shoppingBudget: shoppingBudget,
        status:         'pending',
        // Adresse de livraison
        latitude:        _deliveryResult!.latitude,
        longitude:       _deliveryResult!.longitude,
        deliveryAddress: _deliveryResult!.address,
        deliveryZone:    _deliveryZone,
        // Adresse de collecte
        pickupAddress:   pickupAddr,
        pickupLat:       _pickupResult?.latitude,
        pickupLng:       _pickupResult?.longitude,
        pickupZone:      _pickupZone,
        // Contacts
        recipientName:     recipientName,
        recipientPhone:    recipientPhone,
        pickupContactName: _pickupContactNameCtrl.text.trim().isNotEmpty
            ? _pickupContactNameCtrl.text.trim()
            : null,
        pickupContactPhone: _pickupContactPhoneCtrl.text.trim().isNotEmpty
            ? _pickupContactPhoneCtrl.text.trim()
            : null,
        // Compatibilité tracking
        destLat:         _deliveryResult!.latitude,
        destLng:         _deliveryResult!.longitude,
        // Méta
        type:            'shopping',
        clientId:        uid,
        clientName:      name,
        clientPhone:     phone,
        voiceMessage:    audioUrl,
        paymentMethod:   _paymentMethod,
        isPaid:          _paymentMethod == 'wallet',
        forSelf:         _forSelf,
      );

      await FirestoreService().createOrder(order);

    } catch (e) {
      // Si le wallet a été débité, rembourser automatiquement
      if (_paymentMethod == 'wallet' && uid != null) {
        try {
          final clientRef = FirebaseFirestore.instance.collection('clients').doc(uid);
          await FirebaseFirestore.instance.runTransaction((tx) async {
            final snap = await tx.get(clientRef);
            final current = (snap.data()?['wallet'] as num?)?.toInt() ?? 0;
            tx.update(clientRef, {'wallet': current + deliveryFee});
          });
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _sending = false);
      _snack('Erreur envoi commande : ${e.toString()}', color: Colors.red);
      return;
    }

    if (!mounted) return;
    setState(() {
      _sending         = false;
      _breakdown       = null;
      _deliveryResult  = null;
      _pickupResult    = null;
      _audioPath       = null;
      _pickupZone      = null;
      _deliveryZone    = null;
      _pickupMethod    = 'maps';
      _deliveryMethod  = 'maps';
    });
    _nameCtrl.clear();
    _phoneCtrl.clear();
    _listCtrl.clear();
    _shoppingBudgetCtrl.clear();
    _pickupDescCtrl.clear();
    _pickupContactNameCtrl.clear();
    _pickupContactPhoneCtrl.clear();
    _recipientNameCtrl.clear();
    _recipientPhoneCtrl.clear();

    _snack(
      _paymentMethod == 'wallet'
          ? 'Commande payée ! Recherche d\'un livreur…'
          : 'Commande envoyée ! Recherche d\'un livreur…',
      color: Colors.green,
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmtW(int v) =>
      v >= 1000 ? '${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}' : v.toString();

  void _snack(String msg, {Color? color}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Nouvelle commande'),
        backgroundColor: const Color(0xFFFF6D00),
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [

          // ── 1. POUR QUI ? ──────────────────────────────────────────────────
          const _SectionHeader(icon: Icons.people_rounded, title: 'Pour qui commandez-vous ?'),
          const SizedBox(height: 10),
          _buildForWhoSelector(),

          const SizedBox(height: 24),

          // ── 2. ADRESSE DE LIVRAISON ────────────────────────────────────────
          const _SectionHeader(icon: Icons.delivery_dining_rounded, title: 'Adresse de livraison'),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color:        Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)],
            ),
            child: Column(children: [
              _buildMethodTabs(
                selected:  _deliveryMethod,
                onChanged: (m) => setState(() {
                  _deliveryMethod = m;
                  _deliveryResult = null;
                  _deliveryZone   = null;
                  _breakdown      = null;
                }),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(children: [
                  if (_deliveryMethod == 'gps') ...[
                    _GpsCaptureTile(
                      loading: _deliveryGpsLoading,
                      result:  _deliveryResult,
                      onCapture: () async {
                        setState(() => _deliveryGpsLoading = true);
                        final r = await _getGpsPosition();
                        setState(() {
                          _deliveryGpsLoading = false;
                          if (r != null) {
                            _deliveryResult = r;
                            _breakdown = null;
                          }
                        });
                      },
                    ),
                  ],
                  if (_deliveryMethod == 'zone') ...[
                    _ZoneDropdown(
                      selected: _deliveryZone,
                      onChanged: (z, lat, lng) => setState(() {
                        _deliveryZone = z;
                        _breakdown    = null;
                        if (lat != null && lng != null) {
                          _deliveryResult = AddressResult(
                              latitude: lat, longitude: lng, address: z);
                        }
                      }),
                    ),
                  ],
                  if (_deliveryMethod == 'maps') ...[
                    AddressPickerWidget(
                      title:          'Livraison',
                      hint:           'Tapez un quartier, une rue, un lieu…',
                      initialMode:    _forSelf ? AddressMode.gps : AddressMode.manual,
                      showModeToggle: !_forSelf,
                      onChanged: (result) => setState(() {
                        _deliveryResult = result;
                        _breakdown = null;
                      }),
                    ),
                  ],
                ]),
              ),
            ]),
          ),

          const SizedBox(height: 24),

          // ── 3. VOS INFORMATIONS ────────────────────────────────────────────
          const _SectionHeader(icon: Icons.person_rounded, title: 'Vos informations'),
          const SizedBox(height: 10),
          _field(_nameCtrl,  'Votre nom',       Icons.person_outline),
          const SizedBox(height: 10),
          _field(_phoneCtrl, 'Votre téléphone', Icons.phone,
              type: TextInputType.phone),

          const SizedBox(height: 24),

          // ── 4. LISTE DE COURSES ────────────────────────────────────────────
          const _SectionHeader(icon: Icons.shopping_basket_rounded, title: 'Liste de courses'),
          const SizedBox(height: 8),
          _buildShoppingCard(),

          const SizedBox(height: 16),

          // Budget articles
          _buildBudgetField(),

          const SizedBox(height: 24),

          // ── 5. LIEU DE COLLECTE ────────────────────────────────────────────
          const _SectionHeader(icon: Icons.store_rounded, title: 'Lieu de collecte'),
          const SizedBox(height: 6),
          Text(
            'Où le livreur doit-il récupérer la commande ?',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 10),
          _buildPickupSection(),

          const SizedBox(height: 24),

          // ── 6. CALCULER ────────────────────────────────────────────────────
          ElevatedButton.icon(
            onPressed: _calculatePrice,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.black87,
              minimumSize: const Size(double.infinity, 52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            icon: const Icon(Icons.calculate_rounded, color: Colors.white),
            label: const Text('Calculer le prix de livraison',
                style: TextStyle(color: Colors.white, fontSize: 16)),
          ),

          const SizedBox(height: 16),

          // ── 7. RECAP + PAIEMENT + ENVOYER ─────────────────────────────────
          if (_breakdown != null) ...[
            _TotalCard(
              breakdown:      _breakdown!,
              shoppingBudget: int.tryParse(_shoppingBudgetCtrl.text.trim()) ?? 0,
            ),
            const SizedBox(height: 14),
            _PaymentMethodCard(
              selected:      _paymentMethod,
              walletBalance: _walletBalance,
              deliveryFee:   _breakdown!.total,
              codEnabled:    _codEnabled,
              onChanged:     (v) => setState(() => _paymentMethod = v),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 58,
              child: ScaleButton(
                onPressed: _sending ? null : _sendOrder,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _paymentMethod == 'wallet'
                      ? const Color(0xFF1565C0)
                      : const Color(0xFFFF6D00),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                child: _sending
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _paymentMethod == 'wallet'
                                ? Icons.account_balance_wallet_rounded
                                : Icons.send_rounded,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _paymentMethod == 'wallet'
                                ? 'Payer & confirmer'
                                : 'Confirmer la commande',
                            style: const TextStyle(
                                fontSize: 18,
                                color: Colors.white,
                                fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
              ),
            ),
          ],

          const SizedBox(height: 30),
        ],
      ),
    );
  }

  // ── Sélecteur "Pour qui" ───────────────────────────────────────────────────
  Widget _buildForWhoSelector() {
    return Column(children: [
      Row(children: [
        Expanded(child: _forWhoOption(
          icon:     Icons.person_rounded,
          label:    'Pour moi',
          subtitle: 'Livraison à moi-même',
          selected: _forSelf && !_forBusiness,
          onTap:    () => setState(() {
            _forSelf        = true;
            _forBusiness    = false;
            _deliveryResult = null;
            _breakdown      = null;
            _recipientNameCtrl.clear();
            _recipientPhoneCtrl.clear();
          }),
        )),
        const SizedBox(width: 10),
        Expanded(child: _forWhoOption(
          icon:     Icons.people_alt_rounded,
          label:    'Pour un proche',
          subtitle: 'Livraison à quelqu\'un',
          selected: !_forSelf && !_forBusiness,
          onTap:    () => setState(() {
            _forSelf        = false;
            _forBusiness    = false;
            _deliveryResult = null;
            _breakdown      = null;
          }),
        )),
        const SizedBox(width: 10),
        Expanded(child: _forWhoOption(
          icon:     Icons.storefront_rounded,
          label:    'Pour un commerce',
          subtitle: 'Livraison pro',
          selected: _forBusiness,
          onTap:    () => setState(() {
            _forSelf        = false;
            _forBusiness    = true;
            _deliveryResult = null;
            _breakdown      = null;
          }),
        )),
      ]),
      // Champs destinataire si pas "pour moi"
      if (!_forSelf) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF3E0),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFFF6D00).withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.person_pin_rounded,
                    color: Color(0xFFFF6D00), size: 18),
                const SizedBox(width: 6),
                Text(_forBusiness ? 'Contact destinataire' : 'Informations du destinataire',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFE65100),
                        fontSize: 13)),
              ]),
              const SizedBox(height: 10),
              _field(_recipientNameCtrl,
                  _forBusiness ? 'Nom du responsable *' : 'Nom du destinataire *',
                  Icons.person_outline),
              const SizedBox(height: 8),
              _field(_recipientPhoneCtrl, 'Téléphone du destinataire *', Icons.phone,
                  type: TextInputType.phone),
            ],
          ),
        ),
      ],
    ]);
  }

  Widget _forWhoOption({
    required IconData    icon,
    required String      label,
    required String      subtitle,
    required bool        selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color:        selected ? const Color(0xFFFF6D00).withValues(alpha: 0.08) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(
            color: selected ? const Color(0xFFFF6D00) : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6)],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon,
                  color: selected ? const Color(0xFFFF6D00) : Colors.grey.shade500, size: 20),
              const Spacer(),
              if (selected)
                const Icon(Icons.check_circle_rounded,
                    color: Color(0xFFFF6D00), size: 14),
            ]),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                  fontSize:   12,
                  fontWeight: FontWeight.bold,
                  color:      selected ? const Color(0xFFFF6D00) : Colors.black87,
                )),
            Text(subtitle,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
          ],
        ),
      ),
    );
  }

  // ── Section lieu de collecte ───────────────────────────────────────────────
  Widget _buildPickupSection() {
    return Container(
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)],
      ),
      child: Column(children: [
        // Sélecteur de méthode
        _buildMethodTabs(
          selected:  _pickupMethod,
          onChanged: (m) => setState(() {
            _pickupMethod  = m;
            _pickupResult  = null;
            _pickupZone    = null;
            _breakdown     = null;
          }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Column(children: [

            // Méthode GPS
            if (_pickupMethod == 'gps') ...[
              _GpsCaptureTile(
                loading: _pickupGpsLoading,
                result:  _pickupResult,
                onCapture: () async {
                  setState(() => _pickupGpsLoading = true);
                  final r = await _getGpsPosition();
                  setState(() {
                    _pickupGpsLoading = false;
                    if (r != null) { _pickupResult = r; _breakdown = null; }
                  });
                },
              ),
            ],

            // Méthode Zone
            if (_pickupMethod == 'zone') ...[
              _ZoneDropdown(
                selected: _pickupZone,
                onChanged: (z, lat, lng) => setState(() {
                  _pickupZone   = z;
                  _breakdown    = null;
                  if (lat != null && lng != null) {
                    _pickupResult = AddressResult(
                        latitude: lat, longitude: lng, address: z);
                  }
                }),
              ),
            ],

            // Méthode Maps
            if (_pickupMethod == 'maps') ...[
              TextField(
                controller: _pickupDescCtrl,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText:  'Marché, boutique, restaurant…',
                  hintText:   'ex : Marché central, boutique Awa…',
                  hintStyle:  TextStyle(color: Colors.grey.shade400, fontSize: 13),
                  prefixIcon: const Icon(Icons.store_rounded, color: Color(0xFFFF6D00)),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                  filled: true, fillColor: const Color(0xFFF5F5F5),
                ),
              ),
              const SizedBox(height: 8),
              AddressPickerWidget(
                title:          'Collecte',
                hint:           'Épingler le lieu de collecte sur la carte',
                initialMode:    AddressMode.manual,
                showModeToggle: false,
                onChanged: (result) =>
                    setState(() { _pickupResult = result; _breakdown = null; }),
              ),
            ],

          ]),
        ),

        // Contact récupérateur
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(children: [
            Divider(height: 20, color: Colors.grey.shade100),
            Row(children: [
              const Icon(Icons.contact_phone_rounded,
                  size: 15, color: Color(0xFFFF6D00)),
              const SizedBox(width: 6),
              Text('Contact récupérateur (optionnel)',
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w500)),
            ]),
            const SizedBox(height: 8),
            _field(_pickupContactNameCtrl,  'Nom du récupérateur',
                Icons.person_outline, required: false),
            const SizedBox(height: 8),
            _field(_pickupContactPhoneCtrl, 'Téléphone du récupérateur',
                Icons.phone, type: TextInputType.phone, required: false),
          ]),
        ),
      ]),
    );
  }

  // ── Onglets de méthode (GPS / Zone / Maps) ─────────────────────────────────
  Widget _buildMethodTabs({
    required String   selected,
    required void Function(String) onChanged,
  }) {
    final methods = [
      ('gps',  Icons.my_location_rounded,  'Ma position'),
      ('zone', Icons.map_outlined,          'Zone'),
      ('maps', Icons.place_rounded,         'Sur la carte'),
    ];
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF5F5F5),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: methods.map((m) {
          final isSelected = selected == m.$1;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(m.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white : Colors.transparent,
                  borderRadius: isSelected
                      ? const BorderRadius.vertical(top: Radius.circular(16))
                      : null,
                  border: isSelected
                      ? const Border(
                          bottom: BorderSide(
                              color: Color(0xFFFF6D00), width: 2))
                      : null,
                ),
                child: Column(children: [
                  Icon(m.$2,
                      size: 18,
                      color: isSelected
                          ? const Color(0xFFFF6D00)
                          : Colors.grey.shade500),
                  const SizedBox(height: 2),
                  Text(m.$3,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: isSelected
                              ? const Color(0xFFFF6D00)
                              : Colors.grey.shade500)),
                ]),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Carte shopping ─────────────────────────────────────────────────────────
  Widget _buildShoppingCard() {
    return Container(
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)],
      ),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            color: Color(0xFFFF6D00),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: const Row(children: [
            Icon(Icons.list_alt, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text('Écrivez vos articles (un par ligne)',
                style: TextStyle(color: Colors.white, fontSize: 13)),
          ]),
        ),
        TextField(
          controller: _listCtrl,
          maxLines:   6,
          style:      const TextStyle(fontSize: 15, height: 1.8, fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText:     'Tomates 200 FCFA\nHuile 1L 1 000 FCFA\nCube Maggi…',
            hintStyle:    TextStyle(color: Colors.grey.shade400, fontSize: 14),
            border:       InputBorder.none,
            contentPadding: const EdgeInsets.all(14),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: _buildVoiceZone(),
        ),
      ]),
    );
  }

  Widget _buildBudgetField() {
    return Container(
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)],
      ),
      child: TextField(
        controller:   _shoppingBudgetCtrl,
        keyboardType: TextInputType.number,
        style:        const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        decoration: InputDecoration(
          labelText:    'Budget total des articles (FCFA)',
          labelStyle:   const TextStyle(fontSize: 14),
          hintText:     'ex : 1 500',
          prefixIcon:   const Icon(Icons.account_balance_wallet_rounded,
              color: Color(0xFFFF6D00)),
          suffixText:   'FCFA',
          suffixStyle:  TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.bold),
          border:       OutlineInputBorder(
              borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          filled:       true,
          fillColor:    Colors.white,
        ),
      ),
    );
  }

  // ── Zone vocale ────────────────────────────────────────────────────────────
  Widget _buildVoiceZone() {
    if (_audioPath != null && !_isRecording) {
      final total    = _audioDurationSeconds;
      final position = _playPosition.clamp(0, total > 0 ? total : 1);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color:        const Color(0xFFDCF8C6),
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(color: Colors.green.shade200),
        ),
        child: Row(children: [
          GestureDetector(
            onTap: _togglePlayback,
            child: Container(
              width: 44, height: 44,
              decoration: const BoxDecoration(color: Color(0xFF25D366), shape: BoxShape.circle),
              child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white, size: 26),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight:  3,
                  thumbShape:   const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor:   const Color(0xFF25D366),
                  inactiveTrackColor: Colors.green.shade100,
                  thumbColor:         const Color(0xFF25D366),
                ),
                child: Slider(
                  value: position.toDouble(),
                  min:   0,
                  max:   total > 0 ? total.toDouble() : 1,
                  onChanged: (v) async {
                    await _player.seek(Duration(seconds: v.toInt()));
                    setState(() => _playPosition = v.toInt());
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  _isPlaying
                      ? '${_fmtTime(position)} / ${_fmtTime(total)}'
                      : _fmtTime(total),
                  style: TextStyle(fontSize: 11, color: Colors.green.shade700,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ]),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _deleteVoice,
            child: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color:  Colors.red.shade50, shape: BoxShape.circle,
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Icon(Icons.delete_outline, color: Colors.red.shade400, size: 20),
            ),
          ),
        ]),
      );
    }

    if (_isRecording) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color:        Colors.red.shade50,
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(color: Colors.red.shade200),
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: Colors.red.shade400, shape: BoxShape.circle),
            child: const Icon(Icons.mic, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(child: Row(children: [
            Text('Enregistrement…',
                style: TextStyle(color: Colors.red.shade700,
                    fontWeight: FontWeight.w600, fontSize: 14)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  color: Colors.red.shade400, borderRadius: BorderRadius.circular(20)),
              child: Text(_fmtTime(_recordingSeconds),
                  style: const TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 14)),
            ),
          ])),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _stopRecording,
            child: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                  color: Colors.red.shade400, shape: BoxShape.circle),
              child: const Icon(Icons.stop, color: Colors.white, size: 24),
            ),
          ),
        ]),
      );
    }

    return GestureDetector(
      onTap: _startRecording,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color:        const Color(0xFFFF6D00).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(color: const Color(0xFFFF6D00).withValues(alpha: 0.3)),
        ),
        child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.mic_rounded, color: Color(0xFFFF6D00), size: 22),
          SizedBox(width: 10),
          Text('Enregistrer un message vocal',
              style: TextStyle(color: Color(0xFFFF6D00),
                  fontWeight: FontWeight.w600, fontSize: 14)),
        ]),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType? type, bool required = true}) {
    return TextField(
      controller:   ctrl,
      keyboardType: type,
      decoration: InputDecoration(
        labelText:  label,
        prefixIcon: Icon(icon),
        border:     OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled:     true,
        fillColor:  Colors.white,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// WIDGETS STATELESS RÉUTILISABLES
// ═══════════════════════════════════════════════════════════════════════════

// ── Tuile GPS ───────────────────────────────────────────────────────────────
class _GpsCaptureTile extends StatelessWidget {
  final bool          loading;
  final AddressResult? result;
  final VoidCallback  onCapture;
  const _GpsCaptureTile({
    required this.loading,
    required this.result,
    required this.onCapture,
  });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          icon: loading
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.my_location_rounded,
                  color: Color(0xFF1565C0)),
          label: Text(
            loading ? 'Localisation en cours…' : 'Utiliser ma position actuelle',
            style: const TextStyle(color: Color(0xFF1565C0)),
          ),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF1565C0)),
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: loading ? null : onCapture,
        ),
      ),
      if (result != null) ...[
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.green.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.green.shade200),
          ),
          child: Row(children: [
            const Icon(Icons.check_circle_rounded,
                color: Colors.green, size: 16),
            const SizedBox(width: 8),
            Expanded(child: Text(
              result!.address.isNotEmpty
                  ? result!.address
                  : '${result!.latitude.toStringAsFixed(4)}, '
                    '${result!.longitude.toStringAsFixed(4)}',
              style: const TextStyle(fontSize: 12, color: Colors.green),
            )),
          ]),
        ),
      ],
    ]);
  }
}

// ── Sélecteur de zone (Firestore) ───────────────────────────────────────────
class _ZoneDropdown extends StatefulWidget {
  final String?  selected;
  final void Function(String name, double? lat, double? lng) onChanged;
  const _ZoneDropdown({required this.selected, required this.onChanged});
  @override
  State<_ZoneDropdown> createState() => _ZoneDropdownState();
}

class _ZoneDropdownState extends State<_ZoneDropdown> {
  List<Map<String, dynamic>> _zones = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('zones_livraison')
          .where('isActive', isEqualTo: true)
          .orderBy('order')
          .get();
      if (mounted) {
        setState(() {
          _zones = snap.docs.map((d) {
            final data = d.data();
            return {
              'name': data['name'] as String,
              'type': data['type'] as String? ?? '',
              'lat':  (data['lat']  as num?)?.toDouble(),
              'lng':  (data['lng']  as num?)?.toDouble(),
              'parent': data['parentName'] as String? ?? '',
            };
          }).toList();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_zones.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.orange.shade200),
        ),
        child: const Text(
          'Aucune zone disponible. L\'administrateur doit configurer les zones.',
          style: TextStyle(fontSize: 12, color: Colors.deepOrange),
        ),
      );
    }

    // Regrouper par type
    final villes    = _zones.where((z) => z['type'] == 'ville').toList();
    final quartiers = _zones.where((z) => z['type'] == 'quartier').toList();
    final villages  = _zones.where((z) => z['type'] == 'village').toList();
    final secteurs  = _zones.where((z) => z['type'] == 'secteur').toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (villes.isNotEmpty)    _group('Villes',    villes),
        if (quartiers.isNotEmpty) _group('Quartiers', quartiers),
        if (villages.isNotEmpty)  _group('Villages',  villages),
        if (secteurs.isNotEmpty)  _group('Secteurs',  secteurs),
      ],
    );
  }

  Widget _group(String title, List<Map<String, dynamic>> zones) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(title,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade600)),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: zones.map((z) {
            final name     = z['name'] as String;
            final isSelect = widget.selected == name;
            return GestureDetector(
              onTap: () => widget.onChanged(
                  name,
                  z['lat'] as double?,
                  z['lng'] as double?),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelect
                      ? const Color(0xFFFF6D00)
                      : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelect
                        ? const Color(0xFFFF6D00)
                        : Colors.grey.shade300,
                  ),
                ),
                child: Text(name,
                    style: TextStyle(
                        fontSize: 13,
                        color: isSelect ? Colors.white : Colors.black87,
                        fontWeight: isSelect
                            ? FontWeight.bold
                            : FontWeight.normal)),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String   title;
  const _SectionHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) => Row(children: [
    Container(
      padding:    const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color:        const Color(0xFFFF6D00).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: const Color(0xFFFF6D00), size: 18),
    ),
    const SizedBox(width: 10),
    Text(title,
        style: const TextStyle(
            fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87)),
  ]);
}

// ── Récapitulatif prix ──────────────────────────────────────────────────────

class _TotalCard extends StatelessWidget {
  final PriceBreakdown breakdown;
  final int            shoppingBudget;
  const _TotalCard({required this.breakdown, required this.shoppingBudget});

  @override
  Widget build(BuildContext context) {
    final deliveryFee = breakdown.total;
    final total       = deliveryFee + shoppingBudget;
    final isNight     = breakdown.isNight;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isNight
              ? [const Color(0xFF1A237E), const Color(0xFF283593)]
              : [const Color(0xFFFF6D00), const Color(0xFFFFB300)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(
          color:  (isNight ? Colors.indigo : const Color(0xFFFF6D00)).withValues(alpha: 0.4),
          blurRadius: 16, offset: const Offset(0, 6),
        )],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(isNight ? Icons.nights_stay : Icons.wb_sunny,
              color: isNight ? Colors.lightBlueAccent : Colors.yellow, size: 18),
          const SizedBox(width: 8),
          Text(
            isNight ? 'Tarif nuit — Récapitulatif' : 'Tarif jour — Récapitulatif',
            style: const TextStyle(color: Colors.white70, fontSize: 13, letterSpacing: 0.5),
          ),
        ]),
        const SizedBox(height: 16),
        _line(Icons.shopping_basket_rounded, 'Montant courses', '$shoppingBudget FCFA', shoppingBudget == 0),
        const SizedBox(height: 10),
        _line(Icons.delivery_dining_rounded, 'Frais de livraison', '$deliveryFee FCFA', false),
        const SizedBox(height: 10),
        Text(
          '${breakdown.distanceKm.toStringAsFixed(1)} km · ~${breakdown.etaMinutes} min · ${breakdown.detail}',
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Divider(color: Colors.white.withValues(alpha: 0.25)),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('TOTAL À PAYER',
                  style: TextStyle(color: Colors.white70, fontSize: 12,
                      fontWeight: FontWeight.w600, letterSpacing: 1.2)),
              SizedBox(height: 4),
              Text('Courses + Livraison',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
            ]),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(_fmt(total),
                  style: const TextStyle(color: Colors.white, fontSize: 42,
                      fontWeight: FontWeight.w900, height: 1)),
              const Padding(
                padding: EdgeInsets.only(bottom: 6, left: 6),
                child: Text('FCFA',
                    style: TextStyle(color: Colors.white70, fontSize: 15,
                        fontWeight: FontWeight.bold)),
              ),
            ]),
          ],
        ),
      ]),
    );
  }

  Widget _line(IconData icon, String label, String value, bool isZero) {
    return Row(children: [
      Icon(icon, color: Colors.white60, size: 16),
      const SizedBox(width: 10),
      Expanded(child: Text(label,
          style: const TextStyle(color: Colors.white70, fontSize: 14))),
      Text(
        isZero ? 'non renseigné' : value,
        style: TextStyle(
          color:      isZero ? Colors.white38 : Colors.white,
          fontSize:   14,
          fontWeight: isZero ? FontWeight.normal : FontWeight.bold,
        ),
      ),
    ]);
  }

  String _fmt(int v) {
    if (v >= 1000) {
      return v.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]} ',
      );
    }
    return v.toString();
  }
}

// ── Sélecteur mode de paiement ──────────────────────────────────────────────

class _PaymentMethodCard extends StatelessWidget {
  final String   selected;
  final int      walletBalance;
  final int      deliveryFee;
  final bool     codEnabled;
  final ValueChanged<String> onChanged;

  const _PaymentMethodCard({
    required this.selected,
    required this.walletBalance,
    required this.deliveryFee,
    required this.onChanged,
    this.codEnabled = true,
  });

  String _fmt(int v) =>
      v >= 1000 ? '${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}' : v.toString();

  @override
  Widget build(BuildContext context) {
    final hasFunds = walletBalance >= deliveryFee;
    return Container(
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color:        const Color(0xFFFF6D00).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.payments_rounded, color: Color(0xFFFF6D00), size: 18),
            ),
            const SizedBox(width: 10),
            const Text('Mode de paiement',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87)),
          ]),
        ),
        const Divider(height: 1),
        _Option(
          icon:     Icons.money_rounded,
          title:    'Espèces à la livraison',
          subtitle: codEnabled
              ? 'Payer le livreur à la livraison'
              : 'Désactivé — 3 fausses commandes détectées',
          color:    codEnabled ? const Color(0xFF2E7D32) : Colors.grey,
          selected: selected == 'cash',
          onTap:    codEnabled ? () => onChanged('cash') : null,
          badge:    codEnabled ? null : Icons.block_rounded,
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        _Option(
          icon:     Icons.account_balance_wallet_rounded,
          title:    'Payer par wallet',
          subtitle: hasFunds
              ? 'Solde : ${_fmt(walletBalance)} FCFA'
              : 'Solde insuffisant (${_fmt(walletBalance)} FCFA)',
          color:    hasFunds ? const Color(0xFF1565C0) : Colors.red,
          selected: selected == 'wallet',
          onTap:    hasFunds ? () => onChanged('wallet') : null,
          badge:    hasFunds ? null : Icons.warning_amber_rounded,
        ),
        const SizedBox(height: 4),
      ]),
    );
  }
}

class _Option extends StatelessWidget {
  final IconData   icon;
  final String     title, subtitle;
  final Color      color;
  final bool       selected;
  final VoidCallback? onTap;
  final IconData?  badge;

  const _Option({
    required this.icon, required this.title, required this.subtitle,
    required this.color, required this.selected, this.onTap, this.badge,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap:        onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color:        color.withValues(alpha: selected ? 0.18 : 0.08),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14,
                  color: onTap == null ? Colors.grey : Colors.black87)),
          const SizedBox(height: 2),
          Row(children: [
            if (badge != null) ...[
              Icon(badge, color: Colors.red, size: 13),
              const SizedBox(width: 3),
            ],
            Text(subtitle,
                style: TextStyle(fontSize: 12,
                    color: badge != null ? Colors.red : Colors.grey.shade600)),
          ]),
        ])),
        if (selected)
          Icon(Icons.check_circle_rounded, color: color, size: 22)
        else
          Icon(Icons.radio_button_unchecked_rounded,
              color: Colors.grey.shade400, size: 22),
      ]),
    ),
  );
}
