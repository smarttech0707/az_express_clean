import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../models/order_model.dart';
import '../services/firestore_service.dart';
import '../services/realtime_tracking_service.dart';
import '../services/places_service.dart';
import '../theme/app_theme.dart';
import '../widgets/driver_marker.dart';
import '../widgets/route_polyline.dart';
import '../widgets/eta_card.dart';

/// Écran de suivi professionnel côté client — style Google Maps / Yango.
class CustomerTrackingScreen extends StatefulWidget {
  final OrderModel order;
  const CustomerTrackingScreen({super.key, required this.order});

  @override
  State<CustomerTrackingScreen> createState() => _CustomerTrackingScreenState();
}

class _CustomerTrackingScreenState extends State<CustomerTrackingScreen>
    with SingleTickerProviderStateMixin {

  late RealtimeTrackingService _tracking;

  // ── Carte ──────────────────────────────────────────────────────────────────
  GoogleMapController?  _mapCtrl;
  Set<Marker>           _markers   = {};
  Set<Polyline>         _polylines = {};
  BitmapDescriptor?     _motoIcon;
  BitmapDescriptor?     _clientIcon;
  BitmapDescriptor?     _destIcon;

  // ── Pulsation indicateur livreur ───────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late Animation<double>   _pulse;

  // ── Recherche destination ──────────────────────────────────────────────────
  final _searchCtrl   = TextEditingController();
  final _searchFocus  = FocusNode();
  List<PlaceSuggestion> _suggestions = [];
  Timer?                _debounce;

  // ── Données ────────────────────────────────────────────────────────────────
  late LatLng  _clientPos;
  LatLng?      _destPos;
  String?      _driverName;
  String?      _driverPhoto;
  String?      _driverPhone;
  double?      _driverRating;
  String       _orderStatus = '';
  bool         _isDelivered = false;
  StreamSubscription<DocumentSnapshot>? _orderSub;
  String       _currentDriverId = '';
  Timer?       _staleCheckTimer;

  // ── C6 — Connexion faible ──────────────────────────────────────────────────
  bool _isConnected = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  // ── P6 — Expansion radius automatique ─────────────────────────────────────
  Timer? _searchTimer30;
  Timer? _searchTimer60;

  @override
  void initState() {
    super.initState();
    final o = widget.order;
    _clientPos        = LatLng(o.latitude, o.longitude);
    _destPos          = (o.destLat != null && o.destLng != null)
        ? LatLng(o.destLat!, o.destLng!)
        : null;
    _currentDriverId  = o.driverId ?? '';

    _tracking = RealtimeTrackingService(
      driverId:       _currentDriverId,
      clientPosition: _clientPos,
      destination:    _destPos,
    );
    _tracking.addListener(_onTrackingUpdate);

    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.3, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _loadIcons();
    _loadDriverInfo();
    _searchCtrl.addListener(_onSearchChanged);
    _listenOrder();
    _startRadiusExpansion();

    // Rafraîchit le UI toutes les 30s pour détecter le GPS stale
    _staleCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) { if (mounted && _tracking.hasDriver) setState(() {}); },
    );

    // C6 — Surveillance de la connexion réseau
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final connected = results.any((r) => r != ConnectivityResult.none);
      if (mounted && connected != _isConnected) {
        setState(() => _isConnected = connected);
      }
    });
  }

  /// Écoute l'ordre pour détecter l'assignation d'un livreur ET les changements
  /// de statut (accepted → picked_up → delivered) en continu.
  void _listenOrder() {
    _orderSub = FirebaseFirestore.instance
        .collection('orders')
        .doc(widget.order.id)
        .snapshots()
        .listen((snap) {
      if (!snap.exists || !mounted) return;
      final data     = snap.data() ?? {};
      final driverId = data['driverId'] as String? ?? '';
      final status   = data['status']   as String? ?? '';

      // Nouveau livreur assigné (ou premier assignement)
      if (driverId.isNotEmpty && driverId != _currentDriverId) {
        _currentDriverId = driverId;
        // Arrêter l'expansion radius — un livreur a accepté
        _searchTimer30?.cancel();
        _searchTimer60?.cancel();
        _tracking.removeListener(_onTrackingUpdate);
        _tracking.dispose();
        _tracking = RealtimeTrackingService(
          driverId:       driverId,
          clientPosition: _clientPos,
          destination:    _destPos,
        );
        _tracking.addListener(_onTrackingUpdate);
        _loadDriverInfoById(driverId);
        if (mounted) setState(() {});
      }

      // Changement de statut commande
      if (status != _orderStatus) {
        setState(() => _orderStatus = status);
        if (status == 'picked_up' && _destPos != null) {
          _tracking.switchToDelivery(_destPos!);
        }
        if (status == 'delivered') {
          setState(() => _isDelivered = true);
        }
        if (status == 'cancelled') {
          _searchTimer30?.cancel();
          _searchTimer60?.cancel();
          if (mounted) _showNoCancelledDialog();
        }
      }
    }, onError: (_) {});
  }

  void _showNoCancelledDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        contentPadding:
            const EdgeInsets.fromLTRB(24, 28, 24, 8),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('😔', style: TextStyle(fontSize: 48)),
            SizedBox(height: 16),
            Text(
              'Aucun livreur disponible',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 10),
            Text(
              'Nous n\'avons trouvé aucun livreur disponible pour le moment. Vous pouvez réessayer dans quelques minutes.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Color(0xFF757575)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop();
            },
            child: const Text('Réessayer'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary),
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context)
                  .popUntil((route) => route.isFirst);
            },
            child: const Text('Retour accueil'),
          ),
        ],
      ),
    );
  }

  // P6 — Lance les timers d'expansion du rayon de recherche.
  // 0–30s : 2 km (initial) → 30–60s : 5 km → 60s+ : 30 km (tout Abengourou)
  void _startRadiusExpansion() {
    // Pas besoin si un livreur est déjà assigné
    if (_currentDriverId.isNotEmpty) return;

    _searchTimer30 = Timer(const Duration(seconds: 30), () async {
      if (!mounted || _currentDriverId.isNotEmpty) return;
      try {
        await FirestoreService().findNearestDriver(
          _clientPos.latitude, _clientPos.longitude,
          widget.order.id,
          budget:   widget.order.budget,
          radiusKm: 5.0,
        );
      } catch (_) {}
    });

    _searchTimer60 = Timer(const Duration(seconds: 60), () async {
      if (!mounted || _currentDriverId.isNotEmpty) return;
      try {
        await FirestoreService().findNearestDriver(
          _clientPos.latitude, _clientPos.longitude,
          widget.order.id,
          budget:   widget.order.budget,
          radiusKm: 30.0,
        );
      } catch (_) {}
    });
  }

  // ── Icônes et infos ────────────────────────────────────────────────────────

  Future<void> _loadIcons() async {
    _motoIcon   = await DriverMarkerIcon.getMotoIcon();
    _clientIcon = DriverMarkerIcon.getClientIcon();
    _destIcon   = DriverMarkerIcon.getDestIcon();
    if (mounted) _rebuildMarkers();
  }

  Future<void> _loadDriverInfo() async {
    final driverId = widget.order.driverId;
    if (driverId == null || driverId.isEmpty) return;
    await _loadDriverInfoById(driverId);
  }

  Future<void> _loadDriverInfoById(String driverId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('livreurs').doc(driverId).get();
      if (!mounted || !doc.exists) return;
      final d = doc.data()!;
      setState(() {
        _driverName   = d['name']     as String?;
        _driverPhoto  = d['photoUrl'] as String?;
        _driverPhone  = d['phone']    as String?;
        _driverRating = (d['avgRating'] as num?)?.toDouble();
      });
    } catch (_) {}
  }

  // ── Mises à jour du service ────────────────────────────────────────────────

  void _onTrackingUpdate() {
    if (!mounted) return;
    _rebuildMarkers();
    _rebuildPolylines();
    if (_tracking.followDriver) _followWithBearing();
  }

  // Caméra Uber-style : suit le livreur avec son cap et un léger tilt
  void _followWithBearing() {
    final driverPos = _tracking.animatedDriverPos;
    if (_mapCtrl == null || driverPos == null) return;
    _mapCtrl!.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(
      target:  driverPos,
      zoom:    16,
      bearing: _tracking.animatedHeading,
      tilt:    25,
    )));
  }

  void _rebuildMarkers() {
    setState(() {
      _markers = MapMarkersBuilder.buildForClient(
        clientPos:     _clientPos,
        driverPos:     _tracking.animatedDriverPos,
        destination:   _destPos,
        driverIcon:    _motoIcon,
        clientIcon:    _clientIcon ?? DriverMarkerIcon.getClientIcon(),
        destIcon:      _destIcon   ?? DriverMarkerIcon.getDestIcon(),
        driverName:    _driverName,
        driverHeading: _tracking.animatedHeading,
      );
    });
  }

  void _rebuildPolylines() {
    setState(() {
      _polylines = RoutePolylineBuilder.buildForClient(
        routeToClient: _tracking.routeToClient,
        routeToDest:   _tracking.routeToDest,
      );
    });
  }

  void _fitAllVisible() {
    if (_mapCtrl == null) return;
    final pts = <LatLng>[_clientPos];
    if (_tracking.animatedDriverPos != null) pts.add(_tracking.animatedDriverPos!);
    if (_destPos != null) pts.add(_destPos!);
    final bounds = RoutePolylineBuilder.boundsFor(pts);
    if (bounds != null) {
      _mapCtrl!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
    }
  }

  // ── Recherche Places ───────────────────────────────────────────────────────

  void _onSearchChanged() {
    _debounce?.cancel();
    final input = _searchCtrl.text.trim();
    if (input.length < 2) { setState(() => _suggestions = []); return; }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final results = await PlacesService.autocomplete(input);
      if (mounted) setState(() => _suggestions = results);
    });
  }

  Future<void> _selectSuggestion(PlaceSuggestion s) async {
    _searchFocus.unfocus();
    setState(() => _suggestions = []);
    _searchCtrl.text = s.mainText;

    final coords = await PlacesService.getCoordinates(s.placeId);
    if (coords == null || !mounted) return;

    setState(() => _destPos = coords);
    _tracking.forceRecalculate();
    _rebuildMarkers();
    _mapCtrl?.animateCamera(CameraUpdate.newLatLngZoom(coords, 15));
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        body: Stack(children: [

          // ── Carte plein écran ────────────────────────────────────────────
          GoogleMap(
            initialCameraPosition: CameraPosition(target: _clientPos, zoom: 14),
            markers:             _markers,
            polylines:           _polylines,
            myLocationEnabled:   false,
            zoomControlsEnabled: false,
            compassEnabled:      false,
            mapToolbarEnabled:   false,
            onMapCreated: (ctrl) {
              _mapCtrl = ctrl;
              Future.delayed(const Duration(milliseconds: 600), _fitAllVisible);
            },
            onCameraMoveStarted: () {
              if (_tracking.followDriver) _tracking.setFollowDriver(false);
            },
          ),

          // ── Barre de recherche ───────────────────────────────────────────
          Positioned(
            top: topPad + 10, left: 16, right: 16,
            child: _buildSearchBar(),
          ),

          // ── Bouton retour ────────────────────────────────────────────────
          Positioned(
            top: topPad + 62, left: 16,
            child: _FloatingBtn(
              icon:    Icons.arrow_back_rounded,
              onTap:   () => Navigator.pop(context),
            ),
          ),

          // ── Suggestions autocomplete ─────────────────────────────────────
          if (_suggestions.isNotEmpty)
            Positioned(
              top: topPad + 108, left: 16, right: 16,
              child: _buildSuggestions(),
            ),

          // ── Indicateur "en attente de livreur" ───────────────────────────
          if (!_tracking.hasDriver)
            Positioned(
              top: topPad + 62, left: 60, right: 60,
              child: _WaitBanner(pulse: _pulse),
            ),

          // ── Indicateur GPS stale (>45s sans mise à jour) ─────────────────
          if (_tracking.hasDriver &&
              _tracking.lastUpdateTime.year > 2000 &&
              DateTime.now().difference(_tracking.lastUpdateTime).inSeconds > 45)
            Positioned(
              top: topPad + 62, left: 60, right: 60,
              child: const _StaleBanner(),
            ),

          // ── C6 — Bannière connexion faible ───────────────────────────────
          if (!_isConnected)
            Positioned(
              top: topPad + 62, left: 16, right: 16,
              child: _WeakConnectionBanner(
                lastUpdate: _tracking.hasDriver &&
                    _tracking.lastUpdateTime.year > 2000
                        ? _tracking.lastUpdateTime
                        : null,
              ),
            ),

          // ── Overlay livraison terminée ────────────────────────────────────
          if (_isDelivered)
            Positioned.fill(
              child: _DeliveredOverlay(
                onClose: () => Navigator.of(context).pop(),
              ),
            ),

          // ── FABs droite ──────────────────────────────────────────────────
          ListenableBuilder(
            listenable: _tracking,
            builder: (_, __) => Positioned(
              right: 16,
              bottom: 280 + MediaQuery.of(context).padding.bottom,
              child: Column(children: [
                _FloatingBtn(
                  icon:      _tracking.followDriver
                      ? Icons.navigation_rounded
                      : Icons.navigation_outlined,
                  bgColor:   _tracking.followDriver
                      ? AppColors.primary : Colors.white,
                  iconColor: _tracking.followDriver ? Colors.white : Colors.black87,
                  onTap: () {
                    _tracking.setFollowDriver(!_tracking.followDriver);
                    if (_tracking.followDriver) {
                      _followWithBearing();
                    } else {
                      _fitAllVisible();
                    }
                  },
                ),
                const SizedBox(height: 10),
                _FloatingBtn(
                  icon:  Icons.zoom_out_map_rounded,
                  onTap: _fitAllVisible,
                ),
              ]),
            ),
          ),

          // ── Carte ETA bas ────────────────────────────────────────────────
          if (!_isDelivered)
            ListenableBuilder(
              listenable: _tracking,
              builder: (_, __) => Positioned(
                bottom: 0, left: 0, right: 0,
                child: EtaCard(
                  tracking:       _tracking,
                  driverName:     _driverName,
                  driverPhotoUrl: _driverPhoto,
                  driverPhone:    _driverPhone,
                  driverRating:   _driverRating,
                  orderStatus:    _orderStatus,
                  orderId:        widget.order.id,
                  onRecenter:     _fitAllVisible,
                  onFollowToggle: () {
                    _tracking.setFollowDriver(!_tracking.followDriver);
                    if (_tracking.followDriver) {
                      _followWithBearing();
                    } else {
                      _fitAllVisible();
                    }
                  },
                ),
              ),
            ),
        ]),
      ),
    );
  }

  // ── Barre de recherche ─────────────────────────────────────────────────────
  Widget _buildSearchBar() => Container(
    height: 52,
    decoration: BoxDecoration(
      color:        Colors.white,
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [
        BoxShadow(color: Color(0x22000000), blurRadius: 12, offset: Offset(0, 4)),
      ],
    ),
    child: Row(children: [
      const SizedBox(width: 14),
      const Icon(Icons.search_rounded, color: AppColors.primary, size: 20),
      const SizedBox(width: 10),
      Expanded(child: TextField(
        controller:  _searchCtrl,
        focusNode:   _searchFocus,
        style:       GoogleFonts.urbanist(fontSize: 14),
        decoration:  InputDecoration(
          hintText:       'Rechercher une destination…',
          hintStyle:      GoogleFonts.urbanist(fontSize: 13, color: Colors.grey.shade400),
          border:         InputBorder.none,
          isDense:        true,
          contentPadding: EdgeInsets.zero,
        ),
        onTap: () {},
      )),
      if (_searchCtrl.text.isNotEmpty)
        GestureDetector(
          onTap: () {
            _searchCtrl.clear();
            setState(() => _suggestions = []);
            _searchFocus.unfocus();
          },
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Icon(Icons.close_rounded, size: 18, color: Colors.grey),
          ),
        )
      else const SizedBox(width: 14),
    ]),
  );

  // ── Suggestions ────────────────────────────────────────────────────────────
  Widget _buildSuggestions() => Material(
    borderRadius: BorderRadius.circular(16),
    elevation:    6,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: _suggestions.map((s) => InkWell(
          onTap: () => _selectSuggestion(s),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              const Icon(Icons.place_rounded, color: AppColors.primary, size: 18),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.mainText, style: GoogleFonts.urbanist(
                    fontSize: 13, fontWeight: FontWeight.w600)),
                if (s.secondaryText.isNotEmpty)
                  Text(s.secondaryText, style: GoogleFonts.urbanist(
                      fontSize: 11, color: Colors.grey.shade500)),
              ])),
            ]),
          ),
        )).toList(),
      ),
    ),
  );

  @override
  void dispose() {
    _orderSub?.cancel();
    _staleCheckTimer?.cancel();
    _connectivitySub?.cancel();
    _searchTimer30?.cancel();
    _searchTimer60?.cancel();
    _tracking.removeListener(_onTrackingUpdate);
    _tracking.dispose();
    _pulseCtrl.dispose();
    _mapCtrl?.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    super.dispose();
  }
}

// ── Widgets helpers ───────────────────────────────────────────────────────────

class _FloatingBtn extends StatelessWidget {
  final IconData     icon;
  final Color        bgColor;
  final Color        iconColor;
  final VoidCallback onTap;

  const _FloatingBtn({
    required this.icon,
    required this.onTap,
    this.bgColor   = Colors.white,
    this.iconColor = Colors.black87,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 44, height: 44,
      decoration: BoxDecoration(
        color: bgColor, shape: BoxShape.circle,
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 12, offset: Offset(0, 3)),
        ],
      ),
      child: Icon(icon, color: iconColor, size: 20),
    ),
  );
}

class _WaitBanner extends StatelessWidget {
  final Animation<double> pulse;
  const _WaitBanner({required this.pulse});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 12, offset: Offset(0, 3))],
    ),
    child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
      FadeTransition(
        opacity: pulse,
        child: Container(
          width: 8, height: 8,
          decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
        ),
      ),
      const SizedBox(width: 8),
      Text('Recherche d\'un livreur…',
          style: GoogleFonts.urbanist(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.text)),
    ]),
  );
}

class _StaleBanner extends StatelessWidget {
  const _StaleBanner();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF3E0),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      boxShadow: const [BoxShadow(color: Color(0x18000000), blurRadius: 8)],
    ),
    child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.gps_off_rounded, size: 14, color: AppColors.primary),
      const SizedBox(width: 6),
      Text('GPS livreur indisponible',
          style: GoogleFonts.urbanist(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.primary)),
    ]),
  );
}

class _WeakConnectionBanner extends StatelessWidget {
  final DateTime? lastUpdate;
  const _WeakConnectionBanner({this.lastUpdate});

  @override
  Widget build(BuildContext context) {
    final timeStr = lastUpdate != null
        ? DateFormat('HH:mm').format(lastUpdate!)
        : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color:        const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(20),
        border:       Border.all(color: Colors.orange.shade300),
        boxShadow: const [BoxShadow(color: Color(0x18000000), blurRadius: 8)],
      ),
      child: Row(mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.signal_wifi_statusbar_null_rounded,
            size: 14, color: Colors.orange),
        const SizedBox(width: 6),
        Text(
          timeStr != null
              ? 'Connexion faible — Dernière position à $timeStr'
              : 'Connexion faible',
          style: GoogleFonts.urbanist(
              fontSize: 12, fontWeight: FontWeight.w500,
              color: Colors.orange.shade800),
        ),
      ]),
    );
  }
}

class _DeliveredOverlay extends StatelessWidget {
  final VoidCallback onClose;
  const _DeliveredOverlay({required this.onClose});

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.black54,
    child: Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 32, offset: Offset(0, 8))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64, height: 64,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.success, Color(0xFF16A34A)],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_rounded, color: Colors.white, size: 36),
          ),
          const SizedBox(height: 20),
          Text('Livraison terminée !',
            style: GoogleFonts.urbanist(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.text)),
          const SizedBox(height: 8),
          Text('Votre colis a été livré avec succès.',
            textAlign: TextAlign.center,
            style: GoogleFonts.urbanist(fontSize: 14, color: AppColors.textMuted)),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: onClose,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFE65100), AppColors.primary, Color(0xFFFF8C42)],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.all(Radius.circular(20)),
                boxShadow: [BoxShadow(color: AppColors.primary35, blurRadius: 12, offset: Offset(0, 4))],
              ),
              child: Text('Retour', textAlign: TextAlign.center,
                style: GoogleFonts.urbanist(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
            ),
          ),
        ]),
      ),
    ),
  );
}
