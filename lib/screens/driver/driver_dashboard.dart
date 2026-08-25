import 'dart:async';
import '../../widgets/scale_button.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';
import '../../widgets/glass_kit.dart';
import '../../services/firestore_service.dart';
import '../../services/driver_location_service.dart';
import '../../services/location_service.dart';
import '../../models/order_model.dart';
import '../../services/notification_service.dart';
import '../driver_tracking_screen.dart';
import 'driver_wallet.dart';
import 'driver_profil.dart';

class DriverDashboard extends StatefulWidget {
  final String driverId;
  final String driverName;

  const DriverDashboard({
    super.key,
    required this.driverId,
    required this.driverName,
  });

  @override
  State<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends State<DriverDashboard>
    with WidgetsBindingObserver {
  final FirestoreService _firestore = FirestoreService();
  final AudioPlayer _player = AudioPlayer();

  double? _driverLat;
  double? _driverLng;
  bool _isOnline = true;
  bool _requestDialogShowing = false;

  int _wallet = 0;
  int _deliveredCount = 0;
  double _avgRating = 0.0;
  bool _sosSent = false;
  StreamSubscription<DocumentSnapshot>? _driverSub;
  StreamSubscription<OrderModel?>? _pendingSub;
  StreamSubscription<DocumentSnapshot>? _broadcastOrderSub;
  String? _watchedPendingOrderId;
  OrderModel? _pendingRequest;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _getLocation();
    _setOnline(true);
    DriverLocationService.instance.startTracking(widget.driverId);
    _listenDriverDoc();
    // Quand le livreur tape une notification FCM, le listener Firestore
    // _listenPendingRequest() affiche automatiquement le dialog d'acceptation.
    // On n'a rien de plus à faire ici, mais on enregistre le callback pour
    // éviter que le handler vide par défaut soit utilisé.
    NotificationService.registerTapHandler((type, orderId, status) {
      // Pour new_order : le dialog apparaît automatiquement via _listenPendingRequest
      // Pour les autres types, rien à faire depuis le dashboard livreur
    });
    _listenPendingRequest();
    _loadDeliveredCount();
  }

  void _listenPendingRequest() {
    _pendingSub =
        _firestore.driverPendingRequest(widget.driverId).listen((order) {
      if (mounted) setState(() => _pendingRequest = order);
      if (order != null && !_requestDialogShowing && mounted) {
        _showRequestDialog(order);
      }
    });
  }

  void _listenDriverDoc() {
    _driverSub = FirebaseFirestore.instance
        .collection('livreurs')
        .doc(widget.driverId)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final data = snap.data() ?? {};
      setState(() {
        _wallet = (data['wallet'] as num? ?? 0).toInt();
        _avgRating = (data['avgRating'] as num? ?? 0).toDouble();
      });
      // Détection des commandes broadcast via pendingOrderId
      _handleBroadcastOrder(data['pendingOrderId'] as String?);
    });
  }

  void _handleBroadcastOrder(String? pendingId) {
    if (pendingId == _watchedPendingOrderId) return;
    _watchedPendingOrderId = pendingId;
    _broadcastOrderSub?.cancel();
    _broadcastOrderSub = null;

    if (pendingId == null) {
      // La commande broadcast a été prise par un autre ou annulée
      if (_pendingRequest?.status == 'broadcast') {
        if (mounted) setState(() => _pendingRequest = null);
      }
      return;
    }

    // Surveiller la commande broadcast en temps réel
    _broadcastOrderSub = FirebaseFirestore.instance
        .collection('orders')
        .doc(pendingId)
        .snapshots()
        .listen((snap) {
      if (!snap.exists || !mounted) return;
      final order = OrderModel.fromMap(snap.id, snap.data()!);
      if (order.status == 'broadcast') {
        if (mounted) setState(() => _pendingRequest = order);
        if (!_requestDialogShowing) _showRequestDialog(order);
      } else {
        // Acceptée par un autre livreur → annuler silencieusement
        if (mounted) setState(() => _pendingRequest = null);
      }
    });
  }

  void _showFeedbackSheet(String orderId, String clientId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _FeedbackSheet(
        orderId: orderId,
        driverId: widget.driverId,
        clientId: clientId,
      ),
    );
  }

  Future<bool?> _showCashConfirmDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.money_rounded, color: Color(0xFF2E7D32), size: 26),
            SizedBox(width: 10),
            Text('Paiement espèces'),
          ],
        ),
        content: const Text(
          'Le client vous a-t-il remis les espèces pour cette commande ?',
          style: TextStyle(fontSize: 15),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Non payé',
                style:
                    TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
          ScaleButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Oui, payé',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _loadDeliveredCount() async {
    final count = await _firestore.driverDeliveredCountOnce(widget.driverId);
    if (!mounted) return;
    setState(() => _deliveredCount = count);
  }

  void _showSOSConfirm() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.sos_rounded, color: Colors.red, size: 28),
            SizedBox(width: 8),
            Text('Alerte SOS', style: TextStyle(color: Colors.red)),
          ],
        ),
        content: const Text(
          'Envoyer une alerte d\'urgence à l\'administrateur avec votre position GPS actuelle ?',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          ScaleButton(
            onPressed: () {
              Navigator.pop(context);
              _sendSOS();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Envoyer'),
          ),
        ],
      ),
    );
  }

  Future<void> _sendSOS() async {
    setState(() => _sosSent = true);
    await FirebaseFirestore.instance.collection('sos_alerts').add({
      'driverId': widget.driverId,
      'driverName': widget.driverName,
      'lat': _driverLat ?? 0,
      'lng': _driverLng ?? 0,
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'active',
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Alerte SOS envoyée à l\'administrateur !'),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 5),
      ),
    );
    Future.delayed(const Duration(minutes: 5), () {
      if (mounted) setState(() => _sosSent = false);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.unregisterTapHandler();
    _driverSub?.cancel();
    _pendingSub?.cancel();
    _broadcastOrderSub?.cancel();
    _player.dispose();
    DriverLocationService.instance.stopTracking();
    super.dispose();
  }

  // Master Prompt 129 — cause racine confirmée : `DriverLocationService`
  // exposait déjà `resumeIfNeeded()` (pensé explicitement pour ce retour
  // depuis l'arrière-plan), mais aucun code ne l'appelait nulle part dans
  // l'app — un flux GPS tué par l'OS pendant que l'app est en arrière-plan
  // (mise en veille écran, gestion agressive de la batterie de certains
  // fabricants) ne reprenait donc jamais tout seul, laissant le livreur
  // "En ligne" dans l'UI mais invisible au dispatch (GPS non rafraîchi).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isOnline) {
      DriverLocationService.instance.resumeIfNeeded();
    }
  }

  Future<void> _getLocation() async {
    try {
      await Geolocator.requestPermission();
      final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ));
      if (!mounted) return;
      setState(() {
        _driverLat = pos.latitude;
        _driverLng = pos.longitude;
      });
    } catch (_) {
      // GPS refusé ou indisponible — le livreur peut continuer sans position initiale
    }
  }

  Future<void> _setOnline(bool value) async {
    if (!value) {
      // stopTracking seul n'écrit pas isOnline:false. Sans cet appel, le
      // stream GPS continuait et sa prochaine position remettait le livreur
      // en ligne automatiquement.
      await DriverLocationService.instance.goOffline(widget.driverId);
      if (mounted) setState(() => _isOnline = false);
      return;
    }

    // Réactiver le GPS avant de rendre le livreur disponible, notamment après
    // une coupure réseau ou un précédent passage hors ligne.
    await DriverLocationService.instance.startTracking(widget.driverId);
    await FirebaseFirestore.instance
        .collection("livreurs")
        .doc(widget.driverId)
        .set({"isOnline": value}, SetOptions(merge: true));
    if (mounted) setState(() => _isOnline = value);
  }

  Future<void> _callClient(String phone) async {
    final url = Uri.parse("tel:$phone");
    if (await canLaunchUrl(url)) launchUrl(url);
  }

  // ── Flux de livraison avec preuve obligatoire ────────────────────────────
  Future<void> _showDeliveryProofSheet(
      OrderModel order, bool clientPaid) async {
    String? photoUrl;
    double? gpsLat;
    double? gpsLng;
    bool photoUploading = false;
    bool confirming = false;
    // Référence partagée entre l'IIFE GPS et le StatefulBuilder
    void Function(VoidCallback)? sheetRefresh;

    // Capturer GPS en arrière-plan dès l'ouverture
    () async {
      try {
        final pos = await Geolocator.getCurrentPosition(
            locationSettings:
                const LocationSettings(accuracy: LocationAccuracy.high));
        gpsLat = pos.latitude;
        gpsLng = pos.longitude;
        sheetRefresh?.call(() {}); // rafraîchit l'UI du bottom sheet
      } catch (_) {}
    }();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          sheetRefresh = setS; // expose setS à l'IIFE GPS
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Poignée
                Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2))),

                const Text('Preuve de livraison',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(
                    'Une photo est obligatoire avant de confirmer la livraison.',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 13, color: Colors.grey.shade600)),

                const SizedBox(height: 20),

                // Photo
                if (photoUrl == null)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      icon: photoUploading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.camera_alt, color: Colors.white),
                      label: Text(
                        photoUploading
                            ? 'Upload en cours…'
                            : 'Prendre la photo de livraison',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15),
                      ),
                      onPressed: photoUploading
                          ? null
                          : () async {
                              final picker = ImagePicker();
                              final file = await picker.pickImage(
                                  source: ImageSource.camera, imageQuality: 75);
                              if (file == null) return;
                              setS(() => photoUploading = true);
                              try {
                                final ref = FirebaseStorage.instance.ref().child(
                                    'delivery_photos/${widget.driverId}/${order.id}.jpg');
                                await ref.putFile(File(file.path));
                                photoUrl = await ref.getDownloadURL();
                              } catch (_) {
                                setS(() => photoUploading = false);
                                if (ctx.mounted) {
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                          'Échec de l\'envoi — Vérifiez votre connexion et réessayez.'),
                                      backgroundColor: Colors.red,
                                      duration: Duration(seconds: 4),
                                    ),
                                  );
                                }
                                return;
                              }
                              setS(() => photoUploading = false);
                            },
                    ),
                  )
                else
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.shade300),
                    ),
                    child: Row(children: [
                      const Icon(Icons.check_circle_rounded,
                          color: Colors.green, size: 24),
                      const SizedBox(width: 10),
                      const Expanded(
                          child: Text('Photo prise avec succès',
                              style: TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold))),
                      TextButton(
                        onPressed: () => setS(() => photoUrl = null),
                        child: const Text('Reprendre',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ]),
                  ),

                const SizedBox(height: 12),

                // Statut GPS
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: gpsLat != null
                        ? Colors.blue.shade50
                        : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: gpsLat != null
                            ? Colors.blue.shade200
                            : Colors.grey.shade200),
                  ),
                  child: Row(children: [
                    Icon(Icons.my_location_rounded,
                        size: 16,
                        color: gpsLat != null ? Colors.blue : Colors.grey),
                    const SizedBox(width: 8),
                    Text(
                      gpsLat != null
                          ? 'GPS capturé (${gpsLat!.toStringAsFixed(4)}, ${gpsLng!.toStringAsFixed(4)})'
                          : 'Capture GPS en cours…',
                      style: TextStyle(
                          fontSize: 12,
                          color: gpsLat != null
                              ? Colors.blue.shade700
                              : Colors.grey),
                    ),
                  ]),
                ),

                const SizedBox(height: 20),

                // Bouton confirmer
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          photoUrl != null ? Colors.green : Colors.grey,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: (photoUrl == null || confirming)
                        ? null
                        : () async {
                            setS(() => confirming = true);
                            try {
                              await _firestore.deliverOrder(
                                order.id,
                                widget.driverId,
                                order.budget,
                                markCashPaid:
                                    order.paymentMethod == 'cash' && clientPaid,
                                deliveredLat: gpsLat,
                                deliveredLng: gpsLng,
                                deliveryPhotoUrl: photoUrl,
                              );
                              if ((order.clientId?.isNotEmpty ?? false) &&
                                  !clientPaid) {
                                await _firestore
                                    .reportFakeOrder(order.clientId!);
                              }
                              if (ctx.mounted) Navigator.pop(ctx);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(clientPaid
                                      ? 'Livraison confirmée !'
                                      : 'Livraison confirmée. Non-paiement signalé.'),
                                  backgroundColor:
                                      clientPaid ? Colors.green : Colors.orange,
                                ),
                              );
                              _showFeedbackSheet(
                                  order.id, order.clientId ?? '');
                            } catch (e) {
                              setS(() => confirming = false);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      "Échec de la confirmation. Vérifiez votre connexion et réessayez."),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          },
                    child: confirming
                        ? const CircularProgressIndicator(color: Colors.white)
                        : Text(
                            photoUrl != null
                                ? 'Confirmer la livraison'
                                : 'Prenez d\'abord une photo',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold),
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showRequestDialog(OrderModel order) {
    if (_requestDialogShowing) return;
    _requestDialogShowing = true;

    // Vibration triple pour alerter le livreur (en foreground)
    HapticFeedback.heavyImpact();
    Future.delayed(
        const Duration(milliseconds: 200), HapticFeedback.heavyImpact);
    Future.delayed(
        const Duration(milliseconds: 400), HapticFeedback.heavyImpact);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _OrderRequestDialog(
        order: order,
        driverId: widget.driverId,
        driverLat: _driverLat,
        driverLng: _driverLng,
        firestore: _firestore,
        onDone: () {
          _requestDialogShowing = false;
        },
      ),
    ).then((_) {
      _requestDialogShowing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasActiveWork = _pendingRequest != null;
    return PopScope(
      canPop: !hasActiveWork,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Terminez la commande en cours avant de quitter.'),
          duration: Duration(seconds: 2),
        ));
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        floatingActionButton: _buildSOSButton(),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        appBar: AppBar(
          title: Text("Bonjour, ${widget.driverName}"),
          backgroundColor: AppColors.primary,
          centerTitle: true,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.person_outline_rounded, color: Colors.white),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DriverProfil(
                  driverId: widget.driverId,
                  driverName: widget.driverName,
                ),
              ),
            ),
          ),
          actions: [
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DriverWallet(
                    driverId: widget.driverId,
                    driverName: widget.driverName,
                  ),
                ),
              ),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: AppRadius.pillR,
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.3), width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.account_balance_wallet_rounded,
                        size: 14, color: Colors.white),
                    const SizedBox(width: 5),
                    Text(
                      '$_wallet FCFA',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        body: StreamBuilder<OrderModel?>(
          stream: _firestore.driverActiveOrder(widget.driverId),
          builder: (context, activeSnap) {
            final activeOrder = activeSnap.data;
            final pendingRequest = _pendingRequest;

            return Column(
              children: [
                // Alerte solde bas (< 200 FCFA)
                if (_wallet < 200)
                  GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DriverWallet(
                          driverId: widget.driverId,
                          driverName: widget.driverName,
                        ),
                      ),
                    ),
                    child: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(15, 10, 15, 0),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: AppRadius.lgR,
                        border:
                            Border.all(color: Colors.red.shade200, width: 0.8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.red.withValues(alpha: 0.08),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Colors.red.shade100,
                              borderRadius: AppRadius.smR,
                            ),
                            child: Icon(Icons.warning_amber_rounded,
                                color: Colors.red.shade700, size: 18),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              "Crédit bas ($_wallet FCFA) — Contactez l'admin",
                              style: TextStyle(
                                  color: Colors.red.shade700,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                          Icon(Icons.arrow_forward_ios_rounded,
                              size: 12, color: Colors.red.shade400),
                        ],
                      ),
                    ),
                  ),

                // Online toggle
                _buildOnlineToggle(),

                // Stats row
                _buildStatsRow(),

                // Active order card (if any)
                if (activeOrder != null) _buildActiveOrderCard(activeOrder),

                // Status when idle
                if (activeOrder == null && pendingRequest == null)
                  _buildIdleState(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSOSButton() {
    return AnimatedScale(
      scale: _sosSent ? 0.92 : 1.0,
      duration: const Duration(milliseconds: 150),
      child: GestureDetector(
        onTap: _sosSent ? null : _showSOSConfirm,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _sosSent ? Colors.grey : Colors.red.shade700,
            boxShadow: [
              BoxShadow(
                color: (_sosSent ? Colors.grey : Colors.red)
                    .withValues(alpha: 0.45),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Center(
            child: Text(
              'SOS',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: _sosSent ? 13 : 15,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOnlineToggle() {
    const accent = AppColors.primary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      margin: const EdgeInsets.fromLTRB(15, 12, 15, 0),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      decoration: BoxDecoration(
        gradient: _isOnline
            ? const LinearGradient(
                colors: [Color(0xFFE65100), accent, Color(0xFFFF8C42)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                stops: [0.0, 0.55, 1.0],
              )
            : null,
        color: _isOnline ? null : Colors.white,
        borderRadius: AppRadius.xlR,
        border:
            _isOnline ? null : Border.all(color: AppColors.divider, width: 0.8),
        boxShadow: [
          BoxShadow(
            color: _isOnline
                ? accent.withValues(alpha: 0.35)
                : const Color(0x08000000),
            blurRadius: 16,
            offset: const Offset(0, 5),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _isOnline
                  ? Colors.white.withValues(alpha: 0.22)
                  : Colors.grey.shade100,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isOnline
                  ? Icons.delivery_dining_rounded
                  : Icons.delivery_dining_outlined,
              color: _isOnline ? Colors.white : Colors.grey,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isOnline ? "En ligne" : "Hors ligne",
                  style: GoogleFonts.urbanist(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: _isOnline ? Colors.white : Colors.black87,
                  ),
                ),
                Text(
                  _isOnline
                      ? "Disponible pour des courses"
                      : "Activez pour recevoir des commandes",
                  style: GoogleFonts.urbanist(
                    fontSize: 11,
                    color: _isOnline ? Colors.white70 : Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: _isOnline,
            activeThumbColor: Colors.white,
            activeTrackColor: Colors.white.withValues(alpha: 0.4),
            inactiveThumbColor: const Color(0xFFFF5A3C),
            inactiveTrackColor: const Color(0xFFFF5A3C).withValues(alpha: 0.2),
            onChanged: _setOnline,
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    final ratingLabel =
        _avgRating > 0 ? '${_avgRating.toStringAsFixed(1)} / 5' : '—';
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 4, 15, 0),
      child: Row(
        children: [
          Expanded(
            child:
                _statCard("Livraisons", "$_deliveredCount", Icons.check_circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _statCard(
                "Portefeuille", "$_wallet FCFA", Icons.account_balance_wallet),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _statCard("Ma note", ratingLabel, Icons.star_rounded),
          ),
        ],
      ),
    );
  }

  Widget _statCard(String title, String value, IconData icon) {
    const accent = AppColors.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: PremiumCard(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        borderRadius: AppRadius.lgR,
        child: Column(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: AppRadius.mdR,
              ),
              child: Icon(icon, size: 20, color: accent),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: GoogleFonts.urbanist(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: AppColors.text),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 1),
            Text(
              title,
              style: GoogleFonts.urbanist(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIdleState() {
    const accent = AppColors.primary;
    return Expanded(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  gradient: _isOnline
                      ? LinearGradient(
                          colors: [
                            accent.withValues(alpha: 0.12),
                            accent.withValues(alpha: 0.05),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        )
                      : null,
                  color: _isOnline ? null : Colors.grey.shade100,
                  shape: BoxShape.circle,
                  boxShadow: _isOnline
                      ? [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.15),
                            blurRadius: 24,
                            spreadRadius: 4,
                          ),
                        ]
                      : null,
                ),
                child: Icon(
                  Icons.delivery_dining_rounded,
                  size: 54,
                  color: _isOnline
                      ? accent.withValues(alpha: 0.55)
                      : Colors.grey.shade300,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _isOnline
                    ? "En attente d'une commande..."
                    : "Vous êtes hors ligne",
                style: GoogleFonts.urbanist(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _isOnline
                    ? "Restez connecté, une course arrive bientôt"
                    : "Activez le toggle pour recevoir des commandes",
                style: GoogleFonts.urbanist(
                  fontSize: 13,
                  color: AppColors.textMuted,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveOrderCard(OrderModel order) {
    final bool isPickedUp = order.status == "picked_up";
    const accent = AppColors.primary;

    return Expanded(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(15),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: AppRadius.xlR,
            boxShadow: [
              BoxShadow(
                  color: Color(0x0D000000),
                  blurRadius: 20,
                  offset: Offset(0, 4)),
              BoxShadow(
                  color: Color(0x08000000),
                  blurRadius: 6,
                  offset: Offset(0, 1)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header premium
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isPickedUp
                        ? const [Color(0xFF1B5E20), Color(0xFF2E7D32)]
                        : const [Color(0xFFE65100), accent],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(AppRadius.xl)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: AppRadius.smR,
                      ),
                      child: Icon(
                        isPickedUp
                            ? Icons.local_shipping_rounded
                            : Icons.inventory_2_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isPickedUp
                            ? 'Colis récupéré — En route'
                            : 'Commande acceptée — Aller chercher',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15),
                      ),
                    ),
                  ],
                ),
              ),

              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      order.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    _buildModeBadge(order.deliveryMode),
                    const SizedBox(height: 8),
                    _infoRow(
                        Icons.person, "Client : ${order.clientName ?? '—'}"),
                    if (order.clientPhone != null)
                      _infoRow(Icons.phone, "Tél : ${order.clientPhone!}"),
                    _infoRow(
                        Icons.attach_money,
                        "Budget : ${order.budget} FCFA"
                        " (Gain : ${_firestore.calculateDriverGain(order.budget)} FCFA)"),
                    if (_driverLat != null)
                      _infoRow(Icons.straighten,
                          "Distance : ${LocationService.calculateDistance(_driverLat!, _driverLng!, order.latitude, order.longitude).toStringAsFixed(1)} km"),
                    const SizedBox(height: 16),

                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.map, color: Colors.white),
                            label: const Text("Carte",
                                style: TextStyle(color: Colors.white)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF167DB7),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () {
                              Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => DriverTrackingScreen(
                                            order: order,
                                            driverId: widget.driverId,
                                          )));
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        if ((order.clientPhone ?? '').isNotEmpty)
                          Expanded(
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.call, color: Colors.white),
                              label: const Text("Appeler",
                                  style: TextStyle(color: Colors.white)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () => _callClient(order.clientPhone!),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Main action button
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ScaleButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isPickedUp
                              ? const Color(0xFF2E7D32)
                              : AppColors.primary,
                          shape: const RoundedRectangleBorder(
                              borderRadius: AppRadius.lgR),
                          elevation: 0,
                        ),
                        onPressed: () async {
                          if (isPickedUp) {
                            bool clientPaid = true;
                            if (order.paymentMethod == 'cash' &&
                                order.clientId != null) {
                              final result = await _showCashConfirmDialog();
                              if (result == null) return;
                              clientPaid = result;
                            }
                            await _showDeliveryProofSheet(order, clientPaid);
                          } else {
                            await _firestore.pickUpOrder(order.id);
                          }
                        },
                        child: Text(
                          isPickedUp
                              ? "Confirmer la livraison"
                              : "Colis récupéré",
                          style: const TextStyle(
                              fontSize: 16,
                              color: Colors.white,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),

                    if (order.voiceMessage != null) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        icon: const Icon(Icons.play_circle_fill,
                            color: AppColors.primary),
                        label: const Text("Message vocal du client"),
                        onPressed: () =>
                            _player.play(UrlSource(order.voiceMessage!)),
                      ),
                    ],

                    // Info : la photo est demandée lors de la confirmation
                    if (isPickedUp) ...[
                      const SizedBox(height: 6),
                      Text(
                        '📷 Une photo sera requise pour confirmer la livraison',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }
}

// ============================================================
// HELPERS PARTAGÉS
// ============================================================

Widget _buildModeBadge(String deliveryMode) {
  final isExpress = deliveryMode == 'express';
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    decoration: BoxDecoration(
      color: isExpress
          ? AppColors.primary.withValues(alpha: 0.12)
          : Colors.green.shade50,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
        color: isExpress ? AppColors.primary : Colors.green.shade400,
        width: 1.2,
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          isExpress ? '🚀' : '🏍️',
          style: const TextStyle(fontSize: 14),
        ),
        const SizedBox(width: 6),
        Text(
          isExpress ? 'EXPRESS — Mission dédiée' : 'STANDARD — Groupable',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: isExpress ? AppColors.primary : Colors.green.shade700,
          ),
        ),
      ],
    ),
  );
}

// ============================================================
// DIALOG STYLE YANGO — POPUP DE DEMANDE DE COURSE
// ============================================================

class _OrderRequestDialog extends StatefulWidget {
  final OrderModel order;
  final String driverId;
  final double? driverLat;
  final double? driverLng;
  final FirestoreService firestore;
  final VoidCallback onDone;

  const _OrderRequestDialog({
    required this.order,
    required this.driverId,
    required this.driverLat,
    required this.driverLng,
    required this.firestore,
    required this.onDone,
  });

  @override
  State<_OrderRequestDialog> createState() => _OrderRequestDialogState();
}

class _OrderRequestDialogState extends State<_OrderRequestDialog> {
  late int _secondsLeft;
  Timer? _timer;
  final AudioPlayer _dialogPlayer = AudioPlayer();
  bool _playingVoice = false;
  bool _acceptingWithSelfie = false;
  double? _resolvedLat;
  double? _resolvedLng;
  StreamSubscription<DocumentSnapshot>? _orderStatusSub;

  @override
  void initState() {
    super.initState();
    _secondsLeft = 30;
    _startTimer();
    _resolveDriverPosition();
    _watchOrderStatusForBroadcast();
  }

  // Ferme le dialog automatiquement si un autre livreur accepte en mode broadcast
  void _watchOrderStatusForBroadcast() {
    if (widget.order.status != 'broadcast') return;
    _orderStatusSub = FirebaseFirestore.instance
        .collection('orders')
        .doc(widget.order.id)
        .snapshots()
        .listen((snap) {
      if (!snap.exists || !mounted) return;
      final status = snap.data()?['status'] as String? ?? '';
      if (status != 'broadcast') {
        _timer?.cancel();
        widget.onDone();
        if (mounted) Navigator.of(context).pop();
      }
    });
  }

  // Résoudre la position du livreur : GPS local d'abord, sinon Firestore
  Future<void> _resolveDriverPosition() async {
    if (widget.driverLat != null && widget.driverLat != 0) {
      setState(() {
        _resolvedLat = widget.driverLat;
        _resolvedLng = widget.driverLng;
      });
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance
          .collection('livreurs')
          .doc(widget.driverId)
          .get();
      final data = doc.data();
      final lat = (data?['lat'] as num?)?.toDouble() ?? 0;
      final lng = (data?['lng'] as num?)?.toDouble() ?? 0;
      if (lat != 0 && mounted) {
        setState(() {
          _resolvedLat = lat;
          _resolvedLng = lng;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    _orderStatusSub?.cancel();
    _dialogPlayer.dispose();
    super.dispose();
  }

  Future<void> _playVoice() async {
    if (_playingVoice) {
      await _dialogPlayer.stop();
      setState(() => _playingVoice = false);
    } else {
      setState(() => _playingVoice = true);
      await _dialogPlayer.play(UrlSource(widget.order.voiceMessage!));
      _dialogPlayer.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _playingVoice = false);
      });
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        timer.cancel();
        _decline();
      }
    });
  }

  Future<void> _accept() async {
    _timer?.cancel();
    setState(() => _acceptingWithSelfie = true);

    try {
      // 1. Prendre selfie de confirmation
      final picker = ImagePicker();
      final img = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 70,
      );

      if (img == null) {
        // Annulé — relancer le timer
        setState(() {
          _acceptingWithSelfie = false;
          _secondsLeft = 30;
        });
        _startTimer();
        return;
      }

      // 2. Upload selfie
      final selfieRef = FirebaseStorage.instance.ref().child(
          "acceptance_selfies/${widget.order.id}/${widget.driverId}.jpg");
      await selfieRef.putFile(File(img.path));
      final selfieUrl = await selfieRef.getDownloadURL();

      // 3. Récupérer photo de profil du livreur
      String? driverPhotoUrl;
      final driverDoc = await FirebaseFirestore.instance
          .collection("livreurs")
          .doc(widget.driverId)
          .get();
      if (driverDoc.exists) {
        driverPhotoUrl = driverDoc["photoUrl"];
      }

      // 4. Accepter la course
      await widget.firestore.acceptOrder(
        widget.order.id,
        widget.driverId,
        acceptanceSelfieUrl: selfieUrl,
        driverPhotoUrl: driverPhotoUrl,
      );

      widget.onDone();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _acceptingWithSelfie = false);
      if (mounted) {
        final msg = e.toString();
        if (msg.contains("CREDIT_INSUFFISANT")) {
          final parts = msg.split(":");
          final wallet = parts.length > 1 ? parts[1] : "0";
          final needed = parts.length > 2 ? parts[2] : "100";
          _showCreditDialog(wallet, needed);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text("Erreur : $msg"), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  void _showCreditDialog(String wallet, String needed) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.account_balance_wallet, color: Colors.red),
            SizedBox(width: 8),
            Text("Crédit insuffisant"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Vous n'avez pas assez de crédit pour accepter cette course.",
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Column(
                children: [
                  _creditRow("Votre crédit", "$wallet FCFA", Colors.red),
                  const SizedBox(height: 4),
                  _creditRow(
                      "Commission requise", "$needed FCFA", Colors.orange),
                ],
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              "Contactez l'administrateur pour recharger votre crédit.",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Fermer"),
          ),
        ],
      ),
    );
  }

  Widget _creditRow(String label, String value, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 13, color: Colors.black87)),
        Text(value,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }

  Future<void> _decline() async {
    _timer?.cancel();
    await widget.firestore.declineOrder(widget.order.id, widget.driverId);
    widget.onDone();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final double distance = (_resolvedLat != null && _resolvedLat != 0)
        ? LocationService.calculateDistance(
            _resolvedLat!,
            _resolvedLng!,
            widget.order.latitude,
            widget.order.longitude,
          )
        : 0;

    final int gain = widget.firestore.calculateDriverGain(widget.order.budget);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      // Réduire les marges pour avoir plus d'espace sur petits écrans
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Timer circle
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 70,
                  height: 70,
                  child: CircularProgressIndicator(
                    value: _secondsLeft / 30,
                    strokeWidth: 6,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _secondsLeft > 10 ? AppColors.primary : Colors.red,
                    ),
                  ),
                ),
                Text(
                  "$_secondsLeft",
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: _secondsLeft > 10 ? AppColors.primary : Colors.red,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            const Text(
              "Nouvelle course !",
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primary),
            ),

            const SizedBox(height: 10),

            // Badge mode STANDARD / EXPRESS
            _buildModeBadge(widget.order.deliveryMode),

            const SizedBox(height: 10),

            // Order info
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.order.description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  _row(Icons.person,
                      "Client : ${widget.order.clientName ?? '—'}"),
                  if ((widget.order.clientPhone ?? '').isNotEmpty)
                    _row(Icons.phone_rounded,
                        "Tél client : ${widget.order.clientPhone!}"),
                  if ((widget.order.pickupAddress ?? '').isNotEmpty)
                    _row(Icons.location_on_rounded,
                        "Prise en charge : ${widget.order.pickupAddress!}"),
                  if ((widget.order.deliveryAddress ?? '').isNotEmpty)
                    _row(Icons.place_rounded,
                        "Destination : ${widget.order.deliveryAddress!}"),
                  _row(Icons.straighten,
                      "Distance : ${distance.toStringAsFixed(1)} km"),
                  _row(Icons.attach_money,
                      "Budget : ${widget.order.budget} FCFA"),
                  _row(Icons.wallet, "Votre gain estimé : $gain FCFA",
                      bold: true, color: Colors.green),
                  if (widget.order.recipientPhone != null)
                    _row(Icons.phone_forwarded_rounded,
                        "Destinataire : ${widget.order.recipientPhone!}"),
                ],
              ),
            ),

            // Bouton vocal (si disponible)
            if (widget.order.voiceMessage != null) ...[
              const SizedBox(height: 12),
              GestureDetector(
                onTap: _playVoice,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: _playingVoice
                        ? Colors.orange.shade50
                        : Colors.green.shade50,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _playingVoice
                          ? Colors.orange.shade300
                          : Colors.green.shade300,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _playingVoice
                            ? Icons.stop_circle
                            : Icons.play_circle_fill,
                        color: _playingVoice
                            ? Colors.orange.shade700
                            : Colors.green.shade700,
                        size: 28,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _playingVoice
                              ? "Arrêter le message"
                              : "Écouter le message vocal",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _playingVoice
                                ? Colors.orange.shade700
                                : Colors.green.shade700,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            const SizedBox(height: 20),

            // Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      foregroundColor: Colors.red,
                      minimumSize: const Size(0, 52),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: _decline,
                    child:
                        const Text("Refuser", style: TextStyle(fontSize: 16)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ScaleButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      minimumSize: const Size(0, 52),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: _acceptingWithSelfie ? null : _accept,
                    child: _acceptingWithSelfie
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2),
                          )
                        : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.camera_alt,
                                  color: Colors.white, size: 16),
                              SizedBox(width: 4),
                              Text("Accepter",
                                  style: TextStyle(
                                      fontSize: 15,
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(IconData icon, String text, {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color ?? Colors.grey),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                color: color,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RAPPORT DE LIVRAISON
// ─────────────────────────────────────────────────────────────────────────────

class _FeedbackSheet extends StatefulWidget {
  final String orderId;
  final String driverId;
  final String clientId;

  const _FeedbackSheet({
    required this.orderId,
    required this.driverId,
    required this.clientId,
  });

  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  String _difficulty = 'facile';
  final Set<String> _issues = {};
  final _noteCtrl = TextEditingController();
  bool _submitting = false;

  static const _difficulties = [
    {'id': 'facile', 'label': 'Facile', 'color': 0xFF4CAF50},
    {'id': 'moyen', 'label': 'Moyen', 'color': 0xFFFF9800},
    {'id': 'difficile', 'label': 'Difficile', 'color': 0xFFF44336},
  ];

  static const _issueOptions = [
    'Mauvaise adresse',
    'Client absent',
    'Paiement refusé',
    'Client impoli',
    'Retard de trafic',
    'Autre problème',
  ];

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      await FirebaseFirestore.instance.collection('delivery_reports').add({
        'orderId': widget.orderId,
        'driverId': widget.driverId,
        'clientId': widget.clientId,
        'difficulty': _difficulty,
        'issues': _issues.toList(),
        'note': _noteCtrl.text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 28),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 20),
            Text('Rapport de livraison',
                style: GoogleFonts.urbanist(
                    fontSize: 18, fontWeight: FontWeight.w700)),
            Text('Aidez-nous à améliorer l\'expérience client',
                style: GoogleFonts.urbanist(
                    fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 20),
            Text('Comment s\'est passée la livraison ?',
                style: GoogleFonts.urbanist(
                    fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Row(
              children: _difficulties.map((opt) {
                final id = opt['id'] as String;
                final label = opt['label'] as String;
                final color = Color(opt['color'] as int);
                final sel = _difficulty == id;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _difficulty = id),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: sel
                            ? color.withValues(alpha: 0.1)
                            : Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: sel ? color : Colors.grey.shade200,
                            width: sel ? 2 : 1),
                      ),
                      child: Text(label,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.urbanist(
                              fontSize: 12,
                              fontWeight:
                                  sel ? FontWeight.w700 : FontWeight.normal,
                              color: sel ? color : Colors.grey.shade600)),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            Text('Problèmes rencontrés (optionnel)',
                style: GoogleFonts.urbanist(
                    fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _issueOptions.map((issue) {
                final sel = _issues.contains(issue);
                return GestureDetector(
                  onTap: () => setState(() {
                    if (sel) {
                      _issues.remove(issue);
                    } else {
                      _issues.add(issue);
                    }
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: sel
                          ? AppColors.primary.withValues(alpha: 0.1)
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: sel ? AppColors.primary : Colors.grey.shade300,
                          width: sel ? 1.5 : 1),
                    ),
                    child: Text(issue,
                        style: GoogleFonts.urbanist(
                            fontSize: 12,
                            fontWeight:
                                sel ? FontWeight.w700 : FontWeight.normal,
                            color: sel
                                ? AppColors.primary
                                : Colors.grey.shade700)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            Text('Commentaire (optionnel)',
                style: GoogleFonts.urbanist(
                    fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _noteCtrl,
              maxLines: 3,
              style: GoogleFonts.urbanist(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Décrivez le problème ou laissez un commentaire...',
                hintStyle: GoogleFonts.urbanist(
                    fontSize: 12, color: Colors.grey.shade400),
                filled: true,
                fillColor: Colors.grey.shade50,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade200)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade200)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: AppColors.primary, width: 1.5)),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.grey.shade300),
                    minimumSize: const Size(0, 48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text('Passer',
                      style: GoogleFonts.urbanist(color: Colors.grey)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ScaleButton(
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : Text('Envoyer le rapport',
                          style: GoogleFonts.urbanist(
                              fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
