import 'dart:async';
import 'dart:math' as math;
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';

import '../../l10n/app_text.dart';
import 'livraison_screen.dart';
import 'courses_screen.dart';
import '../restaurant/restaurant_list.dart';
import 'pharmacie_garde.dart';
import 'blanchisserie_page.dart';
import 'colis_page.dart';
import 'eau_boissons_page.dart';
import 'boutique_page.dart';
import 'services_hub_page.dart';
import 'simple_service_page.dart';
import 'client_wallet_page.dart';
import 'boulangeries_list.dart';
import '../immobilier/immobilier_home_screen.dart';
import '../../theme/app_theme.dart';
import '../../widgets/live_marker_cache.dart';
import '../../event/screens/event_home_screen.dart';
import '../../ekbine/screens/ek_home_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES
// ─────────────────────────────────────────────────────────────────────────────
const LatLng _abengourou = LatLng(6.7273, -3.4961);
const Color _primary = AppColors.primary;

// Habillage de l'écran selon le thème : la carte Google reste claire, mais le
// panneau, les pastilles et les cartes de services suivent le mode clair/sombre.
Brightness _bright(BuildContext c) => Theme.of(c).brightness;
Color _mapSurface(BuildContext c) => AppColors.premiumSurface(_bright(c));
Color _mapBorder(BuildContext c) => AppColors.premiumBorder(_bright(c));
Color _mapText(BuildContext c) => AppColors.premiumTextPrimary(_bright(c));
Color _mapTextSecondary(BuildContext c) =>
    AppColors.premiumTextSecondary(_bright(c));

// ─────────────────────────────────────────────────────────────────────────────
// ÉTAT PERMISSION
// ─────────────────────────────────────────────────────────────────────────────
enum _PermState { checking, granted, denied, serviceOff }

// ─────────────────────────────────────────────────────────────────────────────
// POSITIONS DU PANNEAU DE SERVICES (fractions de la hauteur de l'écran)
// ─────────────────────────────────────────────────────────────────────────────
typedef ClientPanelSizes = ({double collapsed, double mid, double expanded});

/// Hauteurs du panneau déplaçable, calculées en pixels puis converties en
/// fractions : le même code sert un 360×640 et un 430×932.
/// - réduit : poignée + salutation/portefeuille, au-dessus de la barre flottante ;
/// - moyen : en plus, la carte reste visible sur près de 40 % de l'écran ;
/// - agrandi : s'arrête sous la barre de recherche (jamais par-dessus).
@visibleForTesting
ClientPanelSizes clientPanelSizes({
  required double height,
  required double topInset,
  required double bottomInset,
}) {
  final h = height <= 0 ? 1.0 : height;
  final collapsed = ((100 + bottomInset) / h).clamp(0.12, 0.34).toDouble();
  // Barre de recherche : décalage 12 + badge 36 + espace 10 + champ 52 + marge.
  final headerBottom = topInset + 12 + 36 + 10 + 52 + 10;
  final expanded =
      (1 - headerBottom / h).clamp(collapsed + 0.2, 0.92).toDouble();
  final mid = ((360 + bottomInset) / h)
      .clamp(collapsed + 0.1, math.min(0.62, expanded - 0.08))
      .toDouble();
  return (collapsed: collapsed, mid: mid, expanded: expanded);
}

// ─────────────────────────────────────────────────────────────────────────────
// MAP SCREEN
// ─────────────────────────────────────────────────────────────────────────────
class ClientMap extends StatefulWidget {
  const ClientMap({super.key, this.driversFeed});

  /// Injection de test uniquement. `null` en production → vraie requête
  /// Firestore `livreurs` en ligne (voir [onlineDriversFeed]).
  final LiveDriverFeed? driversFeed;

  @override
  State<ClientMap> createState() => _ClientMapState();
}

class _ClientMapState extends State<ClientMap> {
  GoogleMapController? _mapController;
  LatLng? _clientPosition;
  _PermState _permState = _PermState.checking;
  Set<Marker> _markers = {};
  Map<String, Marker> _driverMarkers = {};
  StreamSubscription<LiveDriverSnapshot>? _driversSub;
  int _onlineDrivers = 0;

  // Icônes cachées pour éviter de les recréer à chaque update
  BitmapDescriptor? _driverIcon;
  BitmapDescriptor? _clientIcon;

  // Panneau de services déplaçable (3 positions : réduit / moyen / agrandi).
  final DraggableScrollableController _sheetCtrl =
      DraggableScrollableController();
  ClientPanelSizes? _panelSizes;
  double _sheetHeight = 0;

  // ── Initialisation ──────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _loadIcons();
    _checkPermissionAndLocate();
  }

  Future<void> _loadIcons() async {
    // Essaie de charger l'icône moto depuis les assets
    try {
      _driverIcon = await BitmapDescriptor.asset(
        const ImageConfiguration(size: Size(48, 48)),
        'assets/motorbike.png',
      );
    } catch (_) {
      _driverIcon =
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    }
    _clientIcon =
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
  }

  @override
  void dispose() {
    _driversSub?.cancel();
    _mapController?.dispose();
    _sheetCtrl.dispose();
    super.dispose();
  }

  // ── Gestion permissions & géolocalisation ───────────────────────────────────
  Future<void> _checkPermissionAndLocate() async {
    // 1. Service GPS activé ?
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) setState(() => _permState = _PermState.serviceOff);
      _showEnableGpsDialog();
      _listenDrivers(); // afficher quand même les livreurs
      return;
    }

    // 2. Permission accordée ?
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    if (perm == LocationPermission.deniedForever ||
        perm == LocationPermission.denied) {
      if (mounted) setState(() => _permState = _PermState.denied);
      _listenDrivers();
      return;
    }

    if (mounted) setState(() => _permState = _PermState.granted);

    // 3. Obtenir la position
    await _fetchPosition();
    _listenDrivers();
  }

  Future<void> _fetchPosition() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (!mounted) return;
      final latlng = LatLng(pos.latitude, pos.longitude);
      setState(() => _clientPosition = latlng);
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(latlng, 15));
      _updateClientMarker(latlng);
    } on LocationServiceDisabledException {
      if (mounted) setState(() => _permState = _PermState.serviceOff);
    } catch (_) {
      // Position indisponible — on reste centré sur Abengourou
    }
  }

  void _updateClientMarker(LatLng pos) {
    final newMarkers = Set<Marker>.from(_markers);
    newMarkers.removeWhere((m) => m.markerId.value == 'client');
    newMarkers.add(Marker(
      markerId: const MarkerId('client'),
      position: pos,
      infoWindow: const InfoWindow(title: 'Vous'),
      icon: _clientIcon ??
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      zIndexInt: 2,
    ));
    if (mounted) setState(() => _markers = newMarkers);
  }

  // ── Écoute des livreurs en temps réel ──────────────────────────────────────
  void _listenDrivers() {
    _driversSub?.cancel();
    final feed = widget.driversFeed ?? onlineDriversFeed;
    _driversSub = feed().listen(_onDriversSnapshot, onError: (_) {
      // Erreur Firestore silencieuse — on garde l'UI stable
    });
  }

  void _onDriversSnapshot(LiveDriverSnapshot snapshot) {
    if (!mounted) return;
    final changes = <LiveMarkerChange>[];
    for (final change in snapshot.docChanges) {
      final doc = change.doc;
      if (change.type == LiveMarkerChangeType.removed) {
        changes.add(LiveMarkerChange(doc.id, LiveMarkerChangeType.removed));
        continue;
      }
      final data = doc.data;
      final lat = (data['lat'] as num?)?.toDouble() ?? 0;
      final lng = (data['lng'] as num?)?.toDouble() ?? 0;
      if (lat == 0 || lng == 0) {
        changes.add(LiveMarkerChange(doc.id, LiveMarkerChangeType.modified));
        continue;
      }
      changes.add(LiveMarkerChange(
        doc.id,
        change.type == LiveMarkerChangeType.added
            ? LiveMarkerChangeType.added
            : LiveMarkerChangeType.modified,
        marker: Marker(
          markerId: MarkerId(doc.id),
          position: LatLng(lat, lng),
          infoWindow: InfoWindow(
            title: data['name'] as String? ?? 'Livreur',
            snippet: data['vehicle'] as String? ?? '',
          ),
          icon: _driverIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          zIndexInt: 1,
        ),
      ));
    }

    _driverMarkers = applyLiveMarkerChanges(_driverMarkers, changes);

    setState(() {
      _markers = {
        if (_clientPosition != null)
          Marker(
            markerId: const MarkerId('client'),
            position: _clientPosition!,
            infoWindow: const InfoWindow(title: 'Vous'),
            icon: _clientIcon ??
                BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueAzure),
            zIndexInt: 2,
          ),
        ..._driverMarkers.values,
      };
      _onlineDrivers = snapshot.docs.length;
    });
  }

  // ── Dialogs ─────────────────────────────────────────────────────────────────
  void _showEnableGpsDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('GPS désactivé',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text(
            'Activez le GPS pour voir votre position et les livreurs proches.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Plus tard'),
          ),
          ScaleButton(
            onPressed: () async {
              Navigator.pop(context);
              await Geolocator.openLocationSettings();
              await _checkPermissionAndLocate();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text('Activer', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _recenter() {
    if (_clientPosition != null) {
      _mapController
          ?.animateCamera(CameraUpdate.newLatLngZoom(_clientPosition!, 15));
    } else {
      _checkPermissionAndLocate();
    }
  }

  void _cycleSheet() {
    final sizes = _panelSizes;
    if (sizes == null || !_sheetCtrl.isAttached) return;
    final current = _sheetCtrl.size;
    final target = current < sizes.mid - 0.02
        ? sizes.mid
        : current < sizes.expanded - 0.02
            ? sizes.expanded
            : sizes.collapsed;
    _sheetCtrl.animateTo(target,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  /// Glissement sur la poignée (fixe, hors du contenu défilant, donc hors de la
  /// portée du défilement natif du panneau) : suit le doigt.
  void _dragSheet(double dy) {
    final sizes = _panelSizes;
    if (sizes == null || !_sheetCtrl.isAttached || _sheetHeight <= 0) return;
    _sheetCtrl.jumpTo(
      (_sheetCtrl.size - dy / _sheetHeight)
          .clamp(sizes.collapsed, sizes.expanded)
          .toDouble(),
    );
  }

  /// Relâché : se cale sur la position la plus proche, en tenant compte de
  /// l'élan (vitesse vers le bas > 0).
  void _settleSheet(double velocityY) {
    final sizes = _panelSizes;
    if (sizes == null || !_sheetCtrl.isAttached || _sheetHeight <= 0) return;
    final projected = _sheetCtrl.size - velocityY * 0.12 / _sheetHeight;
    final stops = [sizes.collapsed, sizes.mid, sizes.expanded];
    var target = stops.first;
    for (final stop in stops) {
      if ((stop - projected).abs() < (target - projected).abs()) target = stop;
    }
    _sheetCtrl.animateTo(target,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  Widget _buildServicesSheet() {
    return LayoutBuilder(builder: (context, c) {
      final pad = MediaQuery.of(context).padding;
      final sizes = clientPanelSizes(
        height: c.maxHeight,
        topInset: pad.top,
        bottomInset: pad.bottom,
      );
      _panelSizes = sizes;
      _sheetHeight = c.maxHeight;
      return DraggableScrollableSheet(
        controller: _sheetCtrl,
        initialChildSize: sizes.mid,
        minChildSize: sizes.collapsed,
        maxChildSize: sizes.expanded,
        snap: true,
        snapSizes: [sizes.mid],
        builder: (_, scrollController) => _BottomPanel(
          onlineDrivers: _onlineDrivers,
          scrollController: scrollController,
          onHandleTap: _cycleSheet,
          onHandleDrag: _dragSheet,
          onHandleDragEnd: _settleSheet,
        ),
      );
    });
  }

  // ── BUILD ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        body: Stack(
          fit: StackFit.expand, // ← FIX CRITIQUE : map remplit l'écran
          children: [
            // ── CARTE GOOGLE MAPS ─────────────────────────────────────────
            GoogleMap(
              initialCameraPosition: CameraPosition(
                target: _clientPosition ?? _abengourou,
                zoom: _clientPosition != null ? 15 : 13,
              ),
              myLocationEnabled: _permState == _PermState.granted,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              compassEnabled: false,
              markers: _markers,
              onMapCreated: (ctrl) {
                _mapController = ctrl;
                if (_clientPosition != null) {
                  ctrl.animateCamera(
                      CameraUpdate.newLatLngZoom(_clientPosition!, 15));
                }
              },
            ),

            // ── OVERLAY PERMISSION REFUSÉE ────────────────────────────────
            if (_permState == _PermState.denied)
              Positioned(
                top: MediaQuery.of(context).padding.top + 60,
                left: 20,
                right: 20,
                child: _PermissionBanner(
                  onTap: () => Geolocator.openAppSettings(),
                ),
              ),

            // ── PANNEAU DÉPLAÇABLE ────────────────────────────────────────
            // Placé sous l'en-tête : agrandi, il ne recouvre jamais la barre de
            // recherche. Hors du panneau, les gestes atteignent la carte.
            Positioned.fill(child: _buildServicesSheet()),

            // ── BARRE DE RECHERCHE + BADGE LIVREURS ──────────────────────
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Ligne 1 : badge livreurs + recentrage
                  Row(children: [
                    _DriversBadge(
                      count: _onlineDrivers,
                      permState: _permState,
                    ),
                    const Spacer(),
                    _RecenterButton(onTap: _recenter),
                  ]),
                  const SizedBox(height: 10),
                  // Ligne 2 : barre de recherche
                  _SearchBar(
                      onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const LivraisonScreen()),
                          )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BADGE LIVREURS
// ─────────────────────────────────────────────────────────────────────────────
class _DriversBadge extends StatelessWidget {
  final int count;
  final _PermState permState;
  const _DriversBadge({required this.count, required this.permState});

  @override
  Widget build(BuildContext context) {
    final isAvailable = count > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: _mapSurface(context),
        borderRadius: AppRadius.pillR,
        border: Border.all(color: _mapBorder(context)),
        boxShadow: AppShadow.sm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: isAvailable
                  ? AppColors.successStrong
                  : AppColors.premiumTextMutedLight,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            permState == _PermState.checking
                ? '...'
                : isAvailable
                    ? '$count ${context.tr('drivers_available')}'
                    : context.tr('no_driver'),
            style: GoogleFonts.urbanist(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: _mapText(context),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BOUTON RECENTRAGE
// ─────────────────────────────────────────────────────────────────────────────
class _RecenterButton extends StatelessWidget {
  final VoidCallback onTap;
  const _RecenterButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Recentrer la carte sur ma position',
      button: true,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: _mapSurface(context),
            shape: BoxShape.circle,
            border: Border.all(color: _mapBorder(context)),
            boxShadow: AppShadow.sm,
          ),
          child: const Icon(Icons.my_location_rounded,
              color: AppColors.primaryAction, size: 22),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BANNER PERMISSION REFUSÉE
// ─────────────────────────────────────────────────────────────────────────────
class _PermissionBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _PermissionBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.orange.shade300),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(Icons.location_off_rounded,
                color: Colors.orange.shade700, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'GPS désactivé — Appuyez pour activer la localisation',
                style: GoogleFonts.urbanist(
                  fontSize: 12,
                  color: Colors.orange.shade800,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: Colors.orange.shade600, size: 18),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BARRE DE RECHERCHE
// ─────────────────────────────────────────────────────────────────────────────
class _SearchBar extends StatelessWidget {
  final VoidCallback onTap;
  const _SearchBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: _mapSurface(context),
          borderRadius: AppRadius.pillR,
          border: Border.all(color: _mapBorder(context)),
          boxShadow: AppShadow.md,
        ),
        child: Row(children: [
          const Icon(Icons.search_rounded,
              color: AppColors.primaryAction, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Où allez-vous ?',
              style: GoogleFonts.urbanist(
                fontSize: 16,
                color: _mapTextSecondary(context),
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primaryAction.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mic_rounded,
                color: AppColors.primaryAction, size: 20),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PANNEAU INFÉRIEUR
// ─────────────────────────────────────────────────────────────────────────────
class _BottomPanel extends StatefulWidget {
  final int onlineDrivers;

  /// Fourni par `DraggableScrollableSheet` : c'est lui qui relie le défilement
  /// du contenu au déplacement du panneau.
  final ScrollController scrollController;
  final VoidCallback onHandleTap;
  final ValueChanged<double> onHandleDrag;
  final ValueChanged<double> onHandleDragEnd;
  const _BottomPanel({
    required this.onlineDrivers,
    required this.scrollController,
    required this.onHandleTap,
    required this.onHandleDrag,
    required this.onHandleDragEnd,
  });

  @override
  State<_BottomPanel> createState() => _BottomPanelState();
}

class _BottomPanelState extends State<_BottomPanel> {
  int _walletBalance = 0;
  String _clientName = '';
  StreamSubscription<DocumentSnapshot>? _clientSub;

  @override
  void initState() {
    super.initState();
    _listenClient();
  }

  void _listenClient() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _clientSub = FirebaseFirestore.instance
        .collection('clients')
        .doc(uid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final d = snap.data();
      setState(() {
        _walletBalance = (d?['wallet'] as num?)?.toInt() ?? 0;
        _clientName = (d?['name'] as String?) ?? '';
      });
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _clientSub?.cancel();
    super.dispose();
  }

  String get _firstName =>
      _clientName.isNotEmpty ? _clientName.split(' ').first : '';

  static String _fmtWallet(int v) {
    if (v >= 1000) {
      return '${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}';
    }
    return v.toString();
  }

  void _showPlusMenu(BuildContext context) => showPlusServicesMenu(context);

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: BoxDecoration(
        color: _mapSurface(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: _mapBorder(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Poignée FIXE (reste visible quand les services défilent) : glisser
          // déplace le panneau, un appui le fait passer à la position suivante
          // (alternative au geste pour l'accessibilité).
          Semantics(
            label: 'Panneau des services. Appuyer pour agrandir ou réduire',
            button: true,
            excludeSemantics: true,
            onTap: widget.onHandleTap,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onHandleTap,
              onVerticalDragUpdate: (d) => widget.onHandleDrag(d.delta.dy),
              onVerticalDragEnd: (d) =>
                  widget.onHandleDragEnd(d.velocity.pixelsPerSecond.dy),
              child: SizedBox(
                height: 32,
                width: double.infinity,
                child: Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: AppColors.premiumTextMutedLight
                          .withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: widget.scrollController,
              physics: const ClampingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── GREETING + WALLET ──────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _firstName.isNotEmpty
                                    ? '${context.tr('hello')} $_firstName 👋'
                                    : context.tr('hello'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.urbanist(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: _mapText(context),
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                context.tr('where_send'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.urbanist(
                                  fontSize: 13,
                                  color: _mapTextSecondary(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),

                        // ── Wallet chip ──────────────────────────────────────
                        // Orange d'action (texte blanc ≥ 4,5:1) et zone d'appui de
                        // 48 px ; mêmes données et même destination qu'avant.
                        Semantics(
                          label:
                              'Portefeuille, solde ${_fmtWallet(_walletBalance)} '
                              'francs CFA. Ouvrir',
                          button: true,
                          excludeSemantics: true,
                          child: GestureDetector(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const ClientWalletPage()),
                            ),
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 48),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    AppColors.primaryActionLight,
                                    AppColors.primaryAction,
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: AppRadius.btnR,
                                boxShadow: AppShadow.colored(
                                    AppColors.primaryAction,
                                    opacity: 0.25),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                      Icons.account_balance_wallet_rounded,
                                      color: Colors.white,
                                      size: 16),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${_fmtWallet(_walletBalance)} F',
                                    style: GoogleFonts.urbanist(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  const Icon(Icons.chevron_right_rounded,
                                      color: Colors.white, size: 18),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  SizedBox(height: screenH < 700 ? 14 : 18),

                  // ── SERVICES ──────────────────────────────────────────────
                  // Livraison en tête (carte principale), puis deux colonnes
                  // équilibrées, puis « Plus de services » pleine largeur.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        _ServiceCard(
                          variant: _ServiceVariant.featured,
                          icon: Icons.delivery_dining_rounded,
                          label: 'Livraison',
                          description: 'Envoyer un colis rapidement',
                          accent: AppColors.primary,
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const LivraisonScreen())),
                        ),
                        const SizedBox(height: 12),
                        _ServiceRow(
                          left: _ServiceCard(
                            icon: Icons.shopping_basket_rounded,
                            label: 'Courses',
                            description: 'Vos achats du quotidien',
                            accent: _kAccentCourses,
                            onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const CoursesScreen())),
                          ),
                          right: _ServiceCard(
                            icon: Icons.restaurant_rounded,
                            label: 'Food',
                            description: 'Commandez vos repas',
                            accent: _kAccentFood,
                            onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const RestaurantList())),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _ServiceRow(
                          left: _ServiceCard(
                            icon: Icons.phone_android_rounded,
                            label: 'E-Kbine',
                            description: context.tr('ekbine_sub'),
                            accent: _kAccentEkbine,
                            onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const EkHomeScreen())),
                          ),
                          right: _ServiceCard(
                            icon: Icons.celebration_rounded,
                            label: 'Événementiel',
                            description: 'Location, déco, traiteur & personnel',
                            accent: _kAccentEvent,
                            onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const EventHomeScreen())),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _ServiceCard(
                          variant: _ServiceVariant.wide,
                          icon: Icons.grid_view_rounded,
                          label: context.tr('more_services'),
                          description: 'Découvrir tous les services',
                          accent: _kAccentMore,
                          onTap: () => _showPlusMenu(context),
                        ),
                      ],
                    ),
                  ),

                  SizedBox(height: bottomPad + 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SERVICE CARD
// ─────────────────────────────────────────────────────────────────────────────
// Accents par service (et par catégorie du menu « Plus de services »).
const Color _kAccentCourses = AppColors.successStrong;
const Color _kAccentFood = AppColors.primaryAction;
const Color _kAccentEkbine = AppColors.blueAction;
const Color _kAccentEvent = AppColors.eventAccent;
const Color _kAccentMore = AppColors.premiumTextSecondaryLight;

/// Version de l'accent lisible sur le fond sombre (le clair y est trop profond).
Color _accentFor(Color accent, Brightness b) {
  if (b == Brightness.light) return accent;
  if (accent == _kAccentCourses) return const Color(0xFF4ADE80);
  if (accent == _kAccentFood) return AppColors.primary;
  if (accent == _kAccentEkbine) return AppColors.bluePremiumDark;
  if (accent == _kAccentEvent) return AppColors.eventAccentDark;
  return AppColors.premiumTextSecondaryDark;
}

enum _ServiceVariant { featured, tile, wide }

/// Deux cartes côte à côte, de même hauteur.
class _ServiceRow extends StatelessWidget {
  final Widget left;
  final Widget right;
  const _ServiceRow({required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: left),
          const SizedBox(width: 12),
          Expanded(child: right),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatefulWidget {
  final _ServiceVariant variant;
  final IconData icon;
  final String label;
  final String description;
  final Color accent;
  final VoidCallback onTap;

  const _ServiceCard({
    this.variant = _ServiceVariant.tile,
    required this.icon,
    required this.label,
    required this.description,
    required this.accent,
    required this.onTap,
  });

  @override
  State<_ServiceCard> createState() => _ServiceCardState();
}

class _ServiceCardState extends State<_ServiceCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final b = _bright(context);
    final featured = widget.variant == _ServiceVariant.featured;
    final wide = widget.variant == _ServiceVariant.wide;
    final accent = _accentFor(widget.accent, b);

    // Principale : orange d'action plein (texte blanc ≥ 4,5:1), sans dégradé.
    // Autres : fond de carte discret + bordure, accent porté par l'icône.
    final Color fill = featured
        ? (_pressed ? AppColors.primaryActionPressed : AppColors.primaryAction)
        : (b == Brightness.dark
            ? AppColors.premiumSurfaceElevatedDark
            : AppColors.premiumBgLight);
    final Color titleColor = featured ? Colors.white : _mapText(context);
    final Color descColor =
        featured ? Colors.white : _mapTextSecondary(context);
    final Color iconBg = featured
        ? Colors.white.withValues(alpha: 0.2)
        : accent.withValues(alpha: b == Brightness.dark ? 0.2 : 0.12);
    final Color iconFg = featured ? Colors.white : accent;

    final iconBox = Container(
      width: featured ? 52 : 44,
      height: featured ? 52 : 44,
      decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
      child: Icon(widget.icon, color: iconFg, size: featured ? 28 : 24),
    );

    final title = Text(
      widget.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.urbanist(
        fontSize: featured ? 20 : 15,
        fontWeight: featured ? FontWeight.w800 : FontWeight.w700,
        color: titleColor,
        height: 1.2,
      ),
    );
    final desc = Text(
      widget.description,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.urbanist(
        fontSize: featured ? 13.5 : 12,
        fontWeight: FontWeight.w500,
        color: descColor,
        height: 1.25,
      ),
    );

    final Widget content;
    if (featured || wide) {
      content = Row(
        children: [
          iconBox,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, const SizedBox(height: 2), desc],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right_rounded,
              color: featured ? Colors.white : _mapTextSecondary(context),
              size: 24),
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          iconBox,
          const SizedBox(height: 12),
          title,
          const SizedBox(height: 2),
          desc,
        ],
      );
    }

    return Semantics(
      label: '${widget.label}. ${widget.description}',
      button: true,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: Container(
            constraints: BoxConstraints(
              minHeight: featured ? 132 : (wide ? 68 : 0),
            ),
            padding: EdgeInsets.all(featured ? 18 : 14),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: AppRadius.cardR,
              border: featured ? null : Border.all(color: _mapBorder(context)),
              boxShadow: featured
                  ? AppShadow.colored(AppColors.primaryAction, opacity: 0.22)
                  : null,
            ),
            alignment: Alignment.centerLeft,
            child: content,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MENU « PLUS DE SERVICES »
// ─────────────────────────────────────────────────────────────────────────────
class _PlusEntry {
  final IconData icon;
  final String routeKey;

  /// Couleur historique transmise telle quelle aux pages `SimpleServicePage`
  /// (elle ne sert plus à l'affichage du menu, qui suit la catégorie).
  final Color color;

  /// Libellé littéral pour l'entrée sans clé de traduction.
  final String? label;

  const _PlusEntry(this.icon, this.routeKey, this.color, {this.label});
}

class _PlusCategory {
  final String titleKey;
  final Color accent;
  final List<_PlusEntry> entries;
  const _PlusCategory(this.titleKey, this.accent, this.entries);
}

/// 13 services d'origine + le raccourci E-Kbine (route déjà existante).
const List<_PlusCategory> _plusCategories = [
  _PlusCategory('plus_cat_commerce', _kAccentFood, [
    _PlusEntry(Icons.bakery_dining_rounded, 'boulangerie', Color(0xFF5D4037)),
    _PlusEntry(Icons.storefront_rounded, 'boutique', Colors.deepOrange),
    _PlusEntry(Icons.local_pharmacy_rounded, 'pharmacy', Colors.red),
    _PlusEntry(Icons.wine_bar_rounded, 'cave', Color(0xFF880E4F)),
    _PlusEntry(Icons.water_drop_rounded, 'water', Colors.teal),
  ]),
  _PlusCategory('plus_cat_home', _kAccentEkbine, [
    _PlusEntry(Icons.home_rounded, 'houses', Color(0xFF00695C)),
    _PlusEntry(Icons.apartment_rounded, 'furnished', Color(0xFF4A148C)),
    _PlusEntry(Icons.villa_rounded, 'real_estate', Color(0xFF00838F)),
  ]),
  _PlusCategory('plus_cat_daily', _kAccentCourses, [
    _PlusEntry(Icons.local_laundry_service_rounded, 'laundry', Colors.blue),
    _PlusEntry(Icons.card_giftcard_rounded, 'parcel', Colors.orange),
    _PlusEntry(Icons.construction_rounded, 'local_services', Color(0xFF1565C0)),
  ]),
  _PlusCategory('plus_cat_transport', _kAccentEvent, [
    _PlusEntry(Icons.electric_rickshaw_rounded, 'tricycle', Color(0xFF6D4C41)),
    _PlusEntry(Icons.local_taxi_rounded, 'night_taxi', Color(0xFF37474F)),
    _PlusEntry(Icons.phone_android_rounded, 'ekbine', Color(0xFF00695C),
        label: 'E-Kbine'),
  ]),
];

/// Menu des services secondaires, groupé par catégorie. Se ferme par la
/// croix, le retour Android, un glissement vers le bas ou un appui à côté.
void showPlusServicesMenu(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => const _PlusMenuSheet(),
  );
}

class _PlusMenuSheet extends StatelessWidget {
  const _PlusMenuSheet();

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      decoration: BoxDecoration(
        color: _mapSurface(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: _mapBorder(context)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 44,
              height: 5,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                color: AppColors.premiumTextMutedLight.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      context.tr('more_services'),
                      style: GoogleFonts.urbanist(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: _mapText(context),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Fermer',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.close_rounded,
                      color: _mapTextSecondary(context)),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + bottom),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final cat in _plusCategories) _PlusSection(cat),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlusSection extends StatelessWidget {
  final _PlusCategory category;
  const _PlusSection(this.category);

  @override
  Widget build(BuildContext context) {
    final accent = _accentFor(category.accent, _bright(context));
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 16,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.tr(category.titleKey),
                    style: GoogleFonts.urbanist(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _mapText(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(builder: (context, c) {
            // 3 colonnes, largeur plafonnée pour rester lisible sur tablette.
            final w = (math.min(c.maxWidth, 560.0) - 24) / 3;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final e in category.entries)
                  _PlusCard(entry: e, accent: category.accent, width: w),
              ],
            );
          }),
        ],
      ),
    );
  }
}

class _PlusCard extends StatefulWidget {
  final _PlusEntry entry;
  final Color accent;
  final double width;

  const _PlusCard({
    required this.entry,
    required this.accent,
    required this.width,
  });

  @override
  State<_PlusCard> createState() => _PlusCardState();
}

class _PlusCardState extends State<_PlusCard> {
  bool _pressed = false;

  String get _title => widget.entry.label ?? context.tr(widget.entry.routeKey);

  void _navigate(BuildContext context) {
    final nav = Navigator.of(context);
    final key = widget.entry.routeKey;
    final title = _title;
    final subtitle =
        key == 'ekbine' ? context.tr('ekbine_sub') : context.tr('${key}_sub');
    final color = widget.entry.color;
    nav.pop();
    Widget? page;
    switch (key) {
      case 'boulangerie':
        page = const BoulangeriesList();
        break;
      case 'boutique':
        page = const BoutiquePage();
        break;
      case 'pharmacy':
        page = const PharmacieGardePage();
        break;
      case 'laundry':
        page = const BlanchisseriePage();
        break;
      case 'parcel':
        page = const ColisPage();
        break;
      case 'water':
        page = const EauBoissonsPage();
        break;
      case 'houses':
        page = const ImmobilierHomeScreen(
          initialPriceType: 'rent',
          initialPropertyType: 'Maison',
        );
        break;
      case 'furnished':
        page = const ImmobilierHomeScreen(
          initialPriceType: 'rent',
          initialPropertyType: 'Résidence meublée',
          initialFurnished: true,
        );
        break;
      case 'real_estate':
        page = const ImmobilierHomeScreen();
        break;
      case 'local_services':
        page = const ServicesHubPage();
        break;
      case 'ekbine':
        page = const EkHomeScreen();
        break;
      case 'cave':
        page = SimpleServicePage(
          serviceType: 'cave',
          title: title,
          subtitle: subtitle,
          icon: Icons.wine_bar_rounded,
          gradient: const [Color(0xFF880E4F), Color(0xFFAD1457)],
          color: color,
        );
        break;
      case 'tricycle':
        page = SimpleServicePage(
          serviceType: 'tricycle',
          title: title,
          subtitle: subtitle,
          icon: Icons.electric_rickshaw_rounded,
          gradient: const [Color(0xFF4E342E), Color(0xFF8D6E63)],
          color: color,
        );
        break;
      case 'night_taxi':
        page = SimpleServicePage(
          serviceType: 'taxi_nuit',
          title: title,
          subtitle: subtitle,
          icon: Icons.local_taxi_rounded,
          gradient: const [Color(0xFF263238), Color(0xFF546E7A)],
          color: color,
        );
        break;
    }
    if (page != null) {
      nav.push(MaterialPageRoute(builder: (_) => page!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _bright(context);
    final accent = _accentFor(widget.accent, b);
    final dark = b == Brightness.dark;
    final fill =
        dark ? AppColors.premiumSurfaceElevatedDark : AppColors.premiumBgLight;
    final title = _title;

    return Semantics(
      label: title,
      button: true,
      excludeSemantics: true,
      onTap: () => _navigate(context),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          _navigate(context);
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: Container(
            width: widget.width,
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
            decoration: BoxDecoration(
              color: _pressed
                  ? Color.alphaBlend(accent.withValues(alpha: 0.12), fill)
                  : fill,
              borderRadius: AppRadius.cardR,
              border: Border.all(color: _mapBorder(context)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: dark ? 0.2 : 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(widget.entry.icon, color: accent, size: 24),
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.urbanist(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _mapText(context),
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
