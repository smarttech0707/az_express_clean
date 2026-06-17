import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/order_model.dart';
import '../../services/route_service.dart';
import '../../theme/app_theme.dart';

const String _mapsKey = 'AIzaSyCjWt989YSIBblhRE9WNVOWXvOsXHIQ1DE';

/// Carte du livreur — suivi GPS temps réel, itinéraire, ETA.
class DriverMap extends StatefulWidget {
  final OrderModel order;
  final String     driverId;

  const DriverMap({
    super.key,
    required this.order,
    required this.driverId,
  });

  // Constructeur de compatibilité avec l'ancien appel par lat/lng
  factory DriverMap.fromLatLng({
    required double clientLat,
    required double clientLng,
    required String driverId,
  }) => DriverMap(
    driverId: driverId,
    order: OrderModel(
      id: '', description: '', budget: 0,
      status: 'accepted', latitude: clientLat, longitude: clientLng,
      type: 'shopping',
    ),
  );

  @override
  State<DriverMap> createState() => _DriverMapState();
}

class _DriverMapState extends State<DriverMap>
    with SingleTickerProviderStateMixin {
  GoogleMapController? _mapCtrl;
  LatLng?  _driverPos;
  LatLng   get _clientPos => LatLng(widget.order.latitude, widget.order.longitude);
  LatLng?  get _destPos   => (widget.order.destLat != null)
      ? LatLng(widget.order.destLat!, widget.order.destLng!)
      : null;

  List<LatLng> _routeToClient = [];
  List<LatLng> _routeToDest   = [];

  double _distToClient = 0;
  double _distToDest   = 0;
  int    _etaToClient  = 0;
  int    _etaToDest    = 0;
  double _heading      = 0;
  bool   _loadingRoute = false;
  bool   _followDriver = true;
  bool   _firstFit     = false;

  BitmapDescriptor?             _motoIcon;
  StreamSubscription<Position>? _gpsSub;
  LatLng?                       _lastRoutePos;
  bool                          _bgGranted = true;

  late AnimationController _pulseCtrl;
  late Animation<double>   _pulse;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.4, end: 1.0)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _loadMotoIcon();
    _startGPS();
  }

  Future<void> _loadMotoIcon() async {
    try {
      final icon = await BitmapDescriptor.asset(
          const ImageConfiguration(size: Size(52, 52)), 'assets/motorbike.png');
      if (mounted) setState(() => _motoIcon = icon);
    } catch (_) {}
  }

  Future<void> _startGPS() async {
    final perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return;
    }

    // Sur Android 10+ vérifier la permission "Tout le temps"
    if (Platform.isAndroid) {
      final bg = await Permission.locationAlways.status;
      if (mounted) setState(() => _bgGranted = bg.isGranted);
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high));
      _onNewPos(pos);
    } catch (_) {}
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, distanceFilter: 5),
    ).listen(_onNewPos, onError: (_) {});
  }

  Future<void> _requestBgLocation() async {
    // Demander la permission background — Android 11+ nécessite les paramètres système
    final status = await Permission.locationAlways.request();
    if (status.isGranted) {
      if (mounted) setState(() => _bgGranted = true);
    } else {
      // Android 11+ redirige vers les paramètres système
      await openAppSettings();
    }
  }

  void _onNewPos(Position pos) {
    if (!mounted) return;
    final latlng = LatLng(pos.latitude, pos.longitude);

    // Envoie position + cap + vitesse à Firestore
    FirebaseFirestore.instance
        .collection('livreurs')
        .doc(widget.driverId)
        .set({
          'lat':       pos.latitude,
          'lng':       pos.longitude,
          'heading':   pos.heading,
          'speed':     pos.speed,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

    setState(() {
      _driverPos    = latlng;
      _heading      = pos.heading;
      _distToClient = Geolocator.distanceBetween(
        pos.latitude, pos.longitude,
        _clientPos.latitude, _clientPos.longitude) / 1000;
      _etaToClient = _eta(_distToClient, pos.speed);
      if (_destPos != null) {
        _distToDest = Geolocator.distanceBetween(
          _clientPos.latitude, _clientPos.longitude,
          _destPos!.latitude, _destPos!.longitude) / 1000;
        _etaToDest  = _eta(_distToDest, pos.speed);
      }
    });

    if (_followDriver && _mapCtrl != null) {
      _mapCtrl!.animateCamera(CameraUpdate.newLatLng(latlng));
    }

    final shouldRefresh = _lastRoutePos == null ||
        Geolocator.distanceBetween(
          _lastRoutePos!.latitude, _lastRoutePos!.longitude,
          latlng.latitude, latlng.longitude) >= 30;

    if (shouldRefresh && !_loadingRoute) {
      _lastRoutePos = latlng;
      _calcRoutes(latlng);
    }
  }

  Future<void> _calcRoutes(LatLng from) async {
    setState(() => _loadingRoute = true);
    final r1 = await RouteService.getRoute(
      from.latitude, from.longitude,
      _clientPos.latitude, _clientPos.longitude, _mapsKey);
    _routeToClient = r1.isNotEmpty ? r1 : [from, _clientPos];

    if (_destPos != null) {
      final r2 = await RouteService.getRoute(
        _clientPos.latitude, _clientPos.longitude,
        _destPos!.latitude, _destPos!.longitude, _mapsKey);
      _routeToDest = r2;
    }
    if (mounted) {
      setState(() => _loadingRoute = false);
      if (!_firstFit) { _firstFit = true; _fitAll(); }
    }
  }

  void _fitAll() {
    if (_mapCtrl == null) return;
    final pts = <LatLng>[
      _clientPos,
      if (_driverPos != null) _driverPos!,
      if (_destPos   != null) _destPos!,
    ];
    if (pts.length < 2) return;
    double minLat = pts.first.latitude,  maxLat = pts.first.latitude;
    double minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final p in pts) {
      if (p.latitude  < minLat) minLat = p.latitude;
      if (p.latitude  > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    _mapCtrl!.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: LatLng(minLat, minLng),
                     northeast: LatLng(maxLat, maxLng)), 70));
  }

  // speedMs : vitesse GPS en m/s — utilise la vraie vitesse si > 3 km/h, sinon 25 km/h
  static int _eta(double km, double speedMs) {
    final kmh = speedMs > 0.8 ? speedMs * 3.6 : 25.0;
    return km <= 0 ? 1 : ((km / kmh) * 60).round().clamp(1, 180);
  }

  Future<void> _navigateTo(LatLng dest) async {
    final url = Uri.parse(
        'https://www.google.com/maps/dir/?api=1'
        '&destination=${dest.latitude},${dest.longitude}'
        '&travelmode=driving');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _pulseCtrl.dispose();
    _mapCtrl?.dispose();
    super.dispose();
  }

  Set<Marker> get _markers => {
    Marker(
      markerId: const MarkerId('client'),
      position: _clientPos,
      infoWindow: InfoWindow(
          title: 'Client', snippet: widget.order.clientName ?? ''),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      zIndexInt: 2,
    ),
    if (_destPos != null)
      Marker(
        markerId: const MarkerId('dest'),
        position: _destPos!,
        infoWindow: const InfoWindow(title: 'Destination finale'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        zIndexInt: 1,
      ),
    if (_driverPos != null)
      Marker(
        markerId:   const MarkerId('driver'),
        position:   _driverPos!,
        flat:       true,
        rotation:   _heading,
        anchor:     const Offset(0.5, 0.5),
        infoWindow: const InfoWindow(title: 'Vous'),
        icon:       _motoIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        zIndexInt:  3,
      ),
  };

  Set<Polyline> get _polylines => {
    if (_routeToClient.isNotEmpty)
      Polyline(
        polylineId: const PolylineId('to_client'),
        points: _routeToClient, color: AppColors.primary, width: 6,
        startCap: Cap.roundCap, endCap: Cap.roundCap,
        jointType: JointType.round,
      ),
    if (_routeToDest.isNotEmpty)
      Polyline(
        polylineId: const PolylineId('to_dest'),
        points: _routeToDest, color: AppColors.blue, width: 4,
        patterns: [PatternItem.dash(15), PatternItem.gap(8)],
        startCap: Cap.roundCap, endCap: Cap.roundCap,
      ),
  };

  @override
  Widget build(BuildContext context) {
    final hasDest = _destPos != null;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent, elevation: 0,
          leading: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: const BoxDecoration(color: Colors.white,
                  shape: BoxShape.circle, boxShadow: AppShadow.md),
              child: const Icon(Icons.arrow_back_rounded,
                  color: AppColors.text, size: 20),
            ),
          ),
          title: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(color: Colors.white,
                borderRadius: AppRadius.pillR, boxShadow: AppShadow.md),
            child: Text('Carte livraison',
                style: GoogleFonts.inter(color: AppColors.text,
                    fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          centerTitle: true,
          actions: [
            GestureDetector(
              onTap: () {
                setState(() => _followDriver = true);
                if (_driverPos != null) {
                  _mapCtrl?.animateCamera(
                    CameraUpdate.newLatLngZoom(_driverPos!, 15));
                }
              },
              child: Container(
                margin: const EdgeInsets.all(8), padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: _followDriver ? AppColors.primary : Colors.white,
                    shape: BoxShape.circle, boxShadow: AppShadow.md),
                child: Icon(Icons.my_location_rounded,
                    color: _followDriver ? Colors.white : AppColors.textMuted,
                    size: 20),
              ),
            ),
            GestureDetector(
              onTap: () { setState(() => _followDriver = false); _fitAll(); },
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(color: Colors.white,
                    shape: BoxShape.circle, boxShadow: AppShadow.md),
                child: const Icon(Icons.zoom_out_map_rounded,
                    color: AppColors.textMuted, size: 20),
              ),
            ),
          ],
        ),

        body: _driverPos == null
            ? const Center(child: CircularProgressIndicator(
                color: AppColors.primary))
            : Stack(children: [
                GoogleMap(
                  initialCameraPosition:
                      CameraPosition(target: _driverPos!, zoom: 15),
                  markers:             _markers,
                  polylines:           _polylines,
                  myLocationEnabled:   false,
                  zoomControlsEnabled: false,
                  compassEnabled:      true,
                  mapToolbarEnabled:   false,
                  onMapCreated: (c) {
                    _mapCtrl = c;
                    Future.delayed(const Duration(milliseconds: 600), _fitAll);
                  },
                  onCameraMoveStarted: () {
                    if (_followDriver) setState(() => _followDriver = false);
                  },
                ),

                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: Container(
                    decoration: const BoxDecoration(
                        color: Colors.white, borderRadius: AppRadius.topXxl,
                        boxShadow: [BoxShadow(color: Color(0x22000000),
                            blurRadius: 20, offset: Offset(0, -4))]),
                    padding: EdgeInsets.fromLTRB(20, 16, 20,
                        MediaQuery.of(context).padding.bottom + 16),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Center(child: Container(
                          width: 36, height: 4,
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: const BoxDecoration(
                              color: AppColors.border,
                              borderRadius: AppRadius.pillR))),

                      // Bannière GPS arrière-plan (Android 10+)
                      if (!_bgGranted) ...[
                        GestureDetector(
                          onTap: _requestBgLocation,
                          child: Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade50,
                              borderRadius: AppRadius.mdR,
                              border: Border.all(color: Colors.orange.shade300),
                            ),
                            child: Row(children: [
                              Icon(Icons.warning_amber_rounded,
                                  color: Colors.orange.shade700, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('GPS arrière-plan désactivé',
                                        style: GoogleFonts.inter(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.orange.shade800)),
                                    Text(
                                        'Votre position ne sera plus transmise '
                                        'si vous fermez l\'appli. Appuyez pour corriger.',
                                        style: GoogleFonts.inter(
                                            fontSize: 11,
                                            color: Colors.orange.shade700)),
                                  ],
                                ),
                              ),
                              Icon(Icons.arrow_forward_ios_rounded,
                                  color: Colors.orange.shade400, size: 14),
                            ]),
                          ),
                        ),
                      ],

                      Row(children: [
                        FadeTransition(opacity: _pulse,
                          child: Container(width: 12, height: 12,
                              decoration: BoxDecoration(
                                  color: _bgGranted
                                      ? AppColors.green
                                      : Colors.orange.shade400,
                                  shape: BoxShape.circle))),
                        const SizedBox(width: 10),
                        Expanded(child: Text(
                            _bgGranted
                                ? 'GPS actif · Position transmise en temps réel'
                                : 'GPS actif · arrière-plan limité',
                            style: GoogleFonts.inter(fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _bgGranted
                                    ? AppColors.green
                                    : Colors.orange.shade700))),
                        if (_loadingRoute)
                          const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppColors.primary)),
                      ]),

                      const SizedBox(height: 14),

                      Row(children: [
                        _DStat(
                          icon: Icons.person_pin_circle_rounded,
                          label: 'Vers client',
                          value: '${_distToClient.toStringAsFixed(1)} km',
                          sub: '~$_etaToClient min',
                          color: AppColors.primary,
                        ),
                        if (hasDest) ...[
                          const SizedBox(width: 12),
                          _DStat(
                            icon: Icons.place_rounded,
                            label: 'Total trajet',
                            value:
                                '${(_distToClient + _distToDest).toStringAsFixed(1)} km',
                            sub: '~${_etaToClient + _etaToDest} min',
                            color: AppColors.blue,
                          ),
                        ],
                      ]),

                      const SizedBox(height: 14),

                      Row(children: [
                        Expanded(child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: const RoundedRectangleBorder(
                                  borderRadius: AppRadius.lgR)),
                          onPressed: () => _navigateTo(_clientPos),
                          icon: const Icon(Icons.navigation_rounded, size: 18),
                          label: Text(
                              hasDest ? 'Vers le client' : 'Naviguer',
                              style: GoogleFonts.inter(
                                  fontWeight: FontWeight.w700)),
                        )),
                        if (hasDest) ...[
                          const SizedBox(width: 10),
                          Expanded(child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.blue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: const RoundedRectangleBorder(
                                    borderRadius: AppRadius.lgR)),
                            onPressed: () => _navigateTo(_destPos!),
                            icon: const Icon(Icons.place_rounded, size: 18),
                            label: Text('Destination',
                                style: GoogleFonts.inter(
                                    fontWeight: FontWeight.w700)),
                          )),
                        ],
                      ]),
                    ]),
                  ),
                ),
              ]),
      ),
    );
  }
}

class _DStat extends StatelessWidget {
  final IconData icon;
  final String   label, value, sub;
  final Color    color;
  const _DStat({required this.icon, required this.label,
      required this.value, required this.sub, required this.color});
  @override
  Widget build(BuildContext context) => Expanded(child: Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08), borderRadius: AppRadius.mdR,
        border: Border.all(color: color.withValues(alpha: 0.25))),
    child: Row(children: [
      Icon(icon, color: color, size: 22),
      const SizedBox(width: 10),
      Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: GoogleFonts.inter(
            fontSize: 11, color: AppColors.textMuted)),
        Text(value, style: GoogleFonts.inter(
            fontSize: 15, fontWeight: FontWeight.w800, color: color)),
        Text(sub, style: GoogleFonts.inter(
            fontSize: 11, color: AppColors.textMuted)),
      ])),
    ]),
  ));
}
