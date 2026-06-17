import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import 'package:url_launcher/url_launcher.dart';

import '../models/order_model.dart';
import '../models/route_model.dart';
import '../services/driver_location_service.dart';
import '../services/google_routes_service.dart';
import '../widgets/driver_marker.dart';
import '../widgets/route_polyline.dart';

/// Écran carte professionnel côté livreur — style Bolt/Yango driver.
///
/// GPS et Firestore gérés exclusivement par [DriverLocationService] (singleton).
/// Cet écran s'abonne au stream de positions pour l'affichage uniquement.
class DriverTrackingScreen extends StatefulWidget {
  final OrderModel order;
  final String     driverId;

  const DriverTrackingScreen({
    super.key,
    required this.order,
    required this.driverId,
  });

  @override
  State<DriverTrackingScreen> createState() => _DriverTrackingScreenState();
}

class _DriverTrackingScreenState extends State<DriverTrackingScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {

  // ── Carte ──────────────────────────────────────────────────────────────────
  GoogleMapController?  _mapCtrl;
  Set<Marker>           _markers   = {};
  Set<Polyline>         _polylines = {};
  BitmapDescriptor?     _motoIcon;
  BitmapDescriptor?     _clientIcon;
  BitmapDescriptor?     _destIcon;

  // ── Position driver ────────────────────────────────────────────────────────
  LatLng?  _driverPos;
  bool     _followDriver   = true;
  bool     _firstFitDone   = false;

  // ── Abonnement au stream DLS (lecture seule — plus d'écriture Firestore ici)
  StreamSubscription<Position>? _posSub;

  // ── Routes ─────────────────────────────────────────────────────────────────
  RouteModel _routeToClient = RouteModel.empty();
  RouteModel _routeToDest   = RouteModel.empty();
  bool       _routeLoading  = false;
  LatLng?    _lastRouteCalcPos;
  static const _recalcThresholdM = 80.0;

  // ── Points de référence ────────────────────────────────────────────────────
  late LatLng _clientPos;
  LatLng?     _destPos;

  // ── Indicateur GPS ─────────────────────────────────────────────────────────
  bool _gpsActive = false;

  // ── Animation pulsation GPS ────────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late Animation<double>   _pulse;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final o = widget.order;
    _clientPos = LatLng(o.latitude, o.longitude);
    _destPos   = (o.destLat != null && o.destLng != null)
        ? LatLng(o.destLat!, o.destLng!)
        : null;

    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.3, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _loadIcons();
    _subscribeToPositionStream();
  }

  // ── WidgetsBindingObserver ─────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // C4 — Reprise automatique si le stream GPS a été tué en arrière-plan
      DriverLocationService.instance.resumeIfNeeded().then((_) {
        if (mounted) _checkGpsState();
      });
    }
  }

  void _checkGpsState() {
    final gpsState = DriverLocationService.instance.gpsState;
    if (gpsState != GpsTrackingState.active) {
      _showGpsDialog(gpsState);
    }
  }

  // ── Chargement icônes ──────────────────────────────────────────────────────

  Future<void> _loadIcons() async {
    _motoIcon   = await DriverMarkerIcon.getMotoIcon(size: 56);
    _clientIcon = DriverMarkerIcon.getClientIcon();
    _destIcon   = DriverMarkerIcon.getDestIcon();
    if (mounted) _rebuildMap();
  }

  // ── Abonnement au stream DLS ───────────────────────────────────────────────

  void _subscribeToPositionStream() {
    _posSub?.cancel();
    final dls = DriverLocationService.instance;
    if (dls.gpsState != GpsTrackingState.active) {
      dls.startTracking(widget.driverId).then((state) {
        if (mounted && state != GpsTrackingState.active) {
          _showGpsDialog(state);
        }
      });
    }
    _posSub = dls.positionStream.listen(_onNewPosition);
  }

  void _onNewPosition(Position pos) {
    if (!mounted) return;

    final latlng = LatLng(pos.latitude, pos.longitude);

    setState(() {
      _driverPos = latlng;
      _gpsActive = true;
    });

    // Caméra
    if (_followDriver && _mapCtrl != null) {
      _mapCtrl!.animateCamera(CameraUpdate.newLatLng(latlng));
    }

    // Recalcul route (affichage driver uniquement)
    final shouldRecalc = _lastRouteCalcPos == null || _isOffRoute(latlng);
    if (shouldRecalc && !_routeLoading) {
      _lastRouteCalcPos = latlng;
      _calcRoutes(latlng);
    } else {
      _rebuildMap();
    }
  }

  // ── Calcul routes ──────────────────────────────────────────────────────────

  bool _isOffRoute(LatLng pos) {
    if (_routeToClient.isEmpty) return true;
    double minDist = double.infinity;
    for (final p in _routeToClient.points) {
      final d = Geolocator.distanceBetween(
          pos.latitude, pos.longitude, p.latitude, p.longitude);
      if (d < minDist) minDist = d;
    }
    return minDist > _recalcThresholdM;
  }

  Future<void> _calcRoutes(LatLng from) async {
    if (_routeLoading) return;
    setState(() => _routeLoading = true);

    _routeToClient = await GoogleRoutesService.getRouteModel(
      origin:      from,
      destination: _clientPos,
    );

    if (_destPos != null) {
      _routeToDest = await GoogleRoutesService.getRouteModel(
        origin:      _clientPos,
        destination: _destPos!,
      );
    }

    if (!mounted) return;
    setState(() => _routeLoading = false);

    _rebuildMap();

    if (!_firstFitDone) {
      _firstFitDone = true;
      _fitAllVisible();
    }
  }

  // ── Reconstruction des éléments carte ─────────────────────────────────────

  void _rebuildMap() {
    if (!mounted) return;
    setState(() {
      _markers   = _buildMarkers();
      _polylines = RoutePolylineBuilder.buildForDriver(
        routeToClient: _routeToClient,
        routeToDest:   _routeToDest,
      );
    });
  }

  Set<Marker> _buildMarkers() {
    if (_driverPos == null) return {};
    return MapMarkersBuilder.buildForDriver(
      driverPos:   _driverPos!,
      clientPos:   _clientPos,
      destination: _destPos,
      driverIcon:  _motoIcon,
      clientIcon:  _clientIcon ?? DriverMarkerIcon.getClientIcon(),
      destIcon:    _destIcon   ?? DriverMarkerIcon.getDestIcon(),
      clientName:  widget.order.clientName,
      clientPhone: widget.order.clientPhone,
    );
  }

  // ── Caméra ────────────────────────────────────────────────────────────────

  void _fitAllVisible() {
    if (_mapCtrl == null) return;
    final pts = [
      if (_driverPos != null) _driverPos!,
      _clientPos,
      if (_destPos != null) _destPos!,
    ];
    final bounds = RoutePolylineBuilder.boundsFor(pts);
    if (bounds != null) {
      _mapCtrl!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
    }
  }

  void _centerOnDriver() {
    if (_driverPos == null || _mapCtrl == null) return;
    _mapCtrl!.animateCamera(CameraUpdate.newLatLngZoom(_driverPos!, 16));
  }

  // ── Navigation externe ────────────────────────────────────────────────────

  Future<void> _navigateTo(LatLng dest) async {
    final url = Uri.parse(
        'https://www.google.com/maps/dir/?api=1'
        '&destination=${dest.latitude},${dest.longitude}'
        '&travelmode=driving');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  // ── C3 — Dialog GPS requis ─────────────────────────────────────────────────

  void _showGpsDialog(GpsTrackingState state) {
    if (!mounted) return;
    final permanent = state == GpsTrackingState.permanentlyDenied;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.location_off_rounded,
                color: Colors.orange, size: 24),
          ),
          const SizedBox(width: 12),
          const Text('GPS requis',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        ]),
        content: const Text(
          'Le GPS est nécessaire pour effectuer vos livraisons.\n\n'
          'Vos clients ne pourront pas suivre votre position sans le GPS.',
          style: TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Annuler',
                style: TextStyle(color: Colors.grey.shade600)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B00),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              if (permanent) {
                await openAppSettings();
              } else {
                await DriverLocationService.instance.startTracking(widget.driverId);
                if (mounted) _subscribeToPositionStream();
              }
            },
            child: Text(permanent ? 'Ouvrir les paramètres' : 'Réessayer'),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final hasDest    = _destPos != null;
    final topPad     = MediaQuery.of(context).padding.top;
    final bottomPad  = MediaQuery.of(context).padding.bottom;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        body: _driverPos == null
            ? _buildLoadingScreen()
            : Stack(children: [

                // ── Carte ──────────────────────────────────────────────────
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                      target: _clientPos, zoom: 14),
                  markers:             _markers,
                  polylines:           _polylines,
                  myLocationEnabled:   false,
                  zoomControlsEnabled: false,
                  compassEnabled:      true,
                  mapToolbarEnabled:   false,
                  onMapCreated: (ctrl) {
                    _mapCtrl = ctrl;
                    Future.delayed(const Duration(milliseconds: 600), _fitAllVisible);
                  },
                  onCameraMoveStarted: () {
                    if (_followDriver) setState(() => _followDriver = false);
                  },
                ),

                // ── Header transparent ──────────────────────────────────────
                Positioned(
                  top: topPad + 10, left: 16, right: 16,
                  child: Row(children: [
                    _FloatingBtn(
                      icon:  Icons.arrow_back_rounded,
                      onTap: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    // C3 — Indicateur GPS réel (plus jamais "actif" quand indisponible)
                    _GpsStatusChip(
                      isActive: _gpsActive &&
                          DriverLocationService.instance.gpsState == GpsTrackingState.active,
                      pulse: _pulse,
                    ),
                  ]),
                ),

                // ── FABs droite ──────────────────────────────────────────────
                Positioned(
                  right: 16,
                  bottom: 300 + bottomPad,
                  child: Column(children: [
                    _FloatingBtn(
                      icon:    _followDriver
                          ? Icons.navigation_rounded
                          : Icons.navigation_outlined,
                      bgColor: _followDriver
                          ? const Color(0xFFFF6D00) : Colors.white,
                      iconColor: _followDriver ? Colors.white : Colors.black87,
                      onTap: () {
                        setState(() => _followDriver = !_followDriver);
                        if (_followDriver) _centerOnDriver();
                      },
                    ),
                    const SizedBox(height: 10),
                    _FloatingBtn(
                      icon:  Icons.zoom_out_map_rounded,
                      onTap: _fitAllVisible,
                    ),
                    if (_routeLoading) ...[
                      const SizedBox(height: 10),
                      const SizedBox(
                        width: 44, height: 44,
                        child: CircularProgressIndicator(
                            color: Color(0xFFFF6D00), strokeWidth: 3),
                      ),
                    ],
                  ]),
                ),

                // ── Panneau bas ──────────────────────────────────────────────
                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: _buildBottomPanel(hasDest, bottomPad),
                ),
              ]),
      ),
    );
  }

  // ── Panneau inférieur ──────────────────────────────────────────────────────

  Widget _buildBottomPanel(bool hasDest, double bottomPad) {
    return Container(
      decoration: const BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(color: Color(0x22000000), blurRadius: 20, offset: Offset(0, -4)),
        ],
      ),
      padding: EdgeInsets.fromLTRB(20, 16, 20, bottomPad + 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [

        // Poignée
        Center(child: Container(
          width: 36, height: 4,
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: Colors.grey.shade300, borderRadius: BorderRadius.circular(4)),
        )),

        // ── GPS actif ────────────────────────────────────────────────────────
        Row(children: [
          FadeTransition(
            opacity: _pulse,
            child: Container(
              width: 12, height: 12,
              decoration: BoxDecoration(
                color: _gpsActive
                    ? const Color(0xFF22C55E)
                    : Colors.orange,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _gpsActive
                  ? 'Position transmise en temps réel'
                  : 'Acquisition GPS en cours…',
              style: GoogleFonts.inter(
                fontSize: 12, fontWeight: FontWeight.w600,
                color: _gpsActive
                    ? const Color(0xFF22C55E)
                    : Colors.orange,
              ),
            ),
          ),
        ]),

        const SizedBox(height: 14),

        // ── Stats ────────────────────────────────────────────────────────────
        Row(children: [
          _StatTile(
            label:    'Vers le client',
            distance: _routeToClient.distanceText,
            eta:      _routeToClient.etaText,
            color:    const Color(0xFFFF6D00),
            icon:     Icons.person_pin_circle_rounded,
          ),
          if (hasDest) ...[
            const SizedBox(width: 12),
            _StatTile(
              label:    'Total trajet',
              distance: RouteModel.formatDistance(
                  _routeToClient.distanceKm + _routeToDest.distanceKm),
              eta:      RouteModel.formatEta(
                  _routeToClient.etaMinutes + _routeToDest.etaMinutes),
              color:    const Color(0xFF1565C0),
              icon:     Icons.place_rounded,
            ),
          ],
        ]),

        const SizedBox(height: 14),

        // ── Boutons navigation ───────────────────────────────────────────────
        Row(children: [
          Expanded(child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6D00),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            onPressed: () => _navigateTo(_clientPos),
            icon:  const Icon(Icons.navigation_rounded, size: 18),
            label: Text(
              hasDest ? 'Vers le client' : 'Naviguer',
              style: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 14),
            ),
          )),
          if (hasDest && _destPos != null) ...[
            const SizedBox(width: 10),
            Expanded(child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              onPressed: () => _navigateTo(_destPos!),
              icon:  const Icon(Icons.place_rounded, size: 18),
              label: Text('Destination',
                  style: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 14)),
            )),
          ],
        ]),
      ]),
    );
  }

  // ── Écran chargement GPS ──────────────────────────────────────────────────

  Widget _buildLoadingScreen() => Scaffold(
    backgroundColor: Colors.white,
    body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const CircularProgressIndicator(color: Color(0xFFFF6D00), strokeWidth: 3),
      const SizedBox(height: 20),
      Text('Localisation GPS…',
          style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Text('Veuillez patienter',
          style: GoogleFonts.inter(fontSize: 13, color: Colors.grey.shade500)),
    ])),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _pulseCtrl.dispose();
    _mapCtrl?.dispose();
    super.dispose();
  }
}

// ── Chip GPS status ───────────────────────────────────────────────────────────

class _GpsStatusChip extends StatelessWidget {
  final bool              isActive;
  final Animation<double> pulse;
  const _GpsStatusChip({required this.isActive, required this.pulse});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color:        Colors.white,
      borderRadius: BorderRadius.circular(20),
      boxShadow: const [
        BoxShadow(color: Color(0x22000000), blurRadius: 8),
      ],
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      FadeTransition(
        opacity: isActive ? pulse : const AlwaysStoppedAnimation(1.0),
        child: Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF22C55E) : Colors.orange,
            shape: BoxShape.circle,
          ),
        ),
      ),
      const SizedBox(width: 6),
      Text(
        isActive ? 'GPS actif' : 'GPS…',
        style: GoogleFonts.inter(
          fontSize: 12, fontWeight: FontWeight.w600,
          color: isActive ? const Color(0xFF22C55E) : Colors.orange,
        ),
      ),
    ]),
  );
}

// ── Widgets helpers ───────────────────────────────────────────────────────────

class _FloatingBtn extends StatelessWidget {
  final IconData  icon;
  final Color     bgColor, iconColor;
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
          BoxShadow(color: Color(0x22000000), blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Icon(icon, color: iconColor, size: 20),
    ),
  );
}

class _StatTile extends StatelessWidget {
  final String   label, distance, eta;
  final Color    color;
  final IconData icon;
  const _StatTile({
    required this.label, required this.distance, required this.eta,
    required this.color, required this.icon,
  });

  @override
  Widget build(BuildContext context) => Expanded(child: Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color:  color.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: color.withValues(alpha: 0.2)),
    ),
    child: Row(children: [
      Icon(icon, color: color, size: 22),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: GoogleFonts.inter(
            fontSize: 11, color: Colors.grey.shade500)),
        Text(distance, style: GoogleFonts.inter(
            fontSize: 15, fontWeight: FontWeight.w800, color: color)),
        Text(eta, style: GoogleFonts.inter(
            fontSize: 11, color: Colors.grey.shade500)),
      ])),
    ]),
  ));
}
