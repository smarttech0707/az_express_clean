import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/order_model.dart';
import '../../services/notification_service.dart';
import '../../services/tracking_service.dart';
import '../../theme/app_theme.dart';

class OrderTrackingMap extends StatefulWidget {
  final OrderModel order;

  const OrderTrackingMap({super.key, required this.order});

  // Ancien constructeur pour compatibilité avec les appels existants
  static Widget fromIds({
    required String driverId,
    required double clientLat,
    required double clientLng,
  }) {
    return _LegacyTrackingMap(
      driverId: driverId, clientLat: clientLat, clientLng: clientLng);
  }

  @override
  State<OrderTrackingMap> createState() => _OrderTrackingMapState();
}

class _OrderTrackingMapState extends State<OrderTrackingMap>
    with SingleTickerProviderStateMixin {
  late TrackingService _tracking;
  GoogleMapController? _mapCtrl;
  BitmapDescriptor? _motoIcon;

  late AnimationController _pulseCtrl;
  late Animation<double>   _pulse;

  bool _followDriver = true;
  final Set<int> _etaMilestonesNotified = {};

  @override
  void initState() {
    super.initState();
    final o = widget.order;
    _tracking = TrackingService(
      driverId:       o.driverId ?? '',
      clientPosition: LatLng(o.latitude, o.longitude),
      destination:    (o.destLat != null && o.destLng != null)
          ? LatLng(o.destLat!, o.destLng!)
          : null,
    );
    _tracking.addListener(_onUpdate);

    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.4, end: 1.0)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _loadMotoIcon();
  }

  Future<void> _loadMotoIcon() async {
    try {
      final icon = await BitmapDescriptor.asset(
          const ImageConfiguration(size: Size(48, 48)), 'assets/motorbike.png');
      if (mounted) setState(() => _motoIcon = icon);
    } catch (_) {}
  }

  void _onUpdate() {
    if (!mounted) return;
    setState(() {});
    if (_followDriver && _tracking.state.driverPosition != null) {
      _fitBounds();
    }
    _checkEtaMilestones();
  }

  void _checkEtaMilestones() {
    final s = _tracking.state;
    if (s.driverPosition == null) return;

    final bool hasDestination = s.destination != null && s.etaToDest > 0;
    final bool inDeliveryPhase = hasDestination && s.etaToClient == 0;
    final int eta = inDeliveryPhase
        ? s.etaToDest
        : (hasDestination ? s.etaTotal : s.etaToClient);
    if (eta <= 0) return;

    for (final threshold in [10, 5, 2]) {
      if (eta <= threshold && !_etaMilestonesNotified.contains(threshold)) {
        _etaMilestonesNotified.add(threshold);
        final body = inDeliveryPhase
            ? '🛵 Votre commande sera livrée dans environ $eta minute${eta > 1 ? 's' : ''}.'
            : '🛵 Votre livreur arrive dans environ $eta minute${eta > 1 ? 's' : ''}.';
        NotificationService.showLocalBanner(
          title: 'Arrivée imminente',
          body: body,
          type: 'driver_found',
        );
        break;
      }
    }
  }

  void _fitBounds() {
    final s = _tracking.state;
    final pts = <LatLng>[
      s.clientPosition,
      if (s.driverPosition != null) s.driverPosition!,
      if (s.destination != null) s.destination!,
    ];
    if (pts.length < 2 || _mapCtrl == null) return;

    double minLat = pts.first.latitude,  maxLat = pts.first.latitude;
    double minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final p in pts) {
      if (p.latitude  < minLat) minLat = p.latitude;
      if (p.latitude  > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    _mapCtrl!.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(
            southwest: LatLng(minLat, minLng),
            northeast: LatLng(maxLat, maxLng)),
        70));
  }

  @override
  void dispose() {
    _tracking.removeListener(_onUpdate);
    _tracking.dispose();
    _pulseCtrl.dispose();
    _mapCtrl?.dispose();
    super.dispose();
  }

  Set<Marker> get _markers {
    final s = _tracking.state;
    return {
      Marker(
        markerId: const MarkerId('client'),
        position: s.clientPosition,
        infoWindow: const InfoWindow(title: 'Votre position'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        zIndexInt: 2,
      ),
      if (s.destination != null)
        Marker(
          markerId: const MarkerId('dest'),
          position: s.destination!,
          infoWindow: const InfoWindow(title: 'Destination'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          zIndexInt: 1,
        ),
      if (s.driverPosition != null)
        Marker(
          markerId: const MarkerId('driver'),
          position: s.driverPosition!,
          infoWindow: const InfoWindow(title: 'Livreur en route'),
          icon: _motoIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
          zIndexInt: 3,
        ),
    };
  }

  Set<Polyline> get _polylines {
    final s = _tracking.state;
    return {
      if (s.routeToClient.isNotEmpty)
        Polyline(
          polylineId: const PolylineId('to_client'),
          points:    s.routeToClient,
          color:     AppColors.primary,
          width:     5,
          startCap:  Cap.roundCap,
          endCap:    Cap.roundCap,
          jointType: JointType.round,
        ),
      if (s.routeToDestination.isNotEmpty)
        Polyline(
          polylineId: const PolylineId('to_dest'),
          points:    s.routeToDestination,
          color:     AppColors.blue,
          width:     4,
          patterns:  [PatternItem.dash(15), PatternItem.gap(8)],
          startCap:  Cap.roundCap,
          endCap:    Cap.roundCap,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = _tracking.state;
    final hasDriver = s.driverPosition != null;
    final hasDest   = s.destination   != null;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: const BoxDecoration(
                  color: Colors.white, shape: BoxShape.circle,
                  boxShadow: AppShadow.md),
              child: const Icon(Icons.arrow_back_rounded,
                  color: AppColors.text, size: 20),
            ),
          ),
          title: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
                color: Colors.white, borderRadius: AppRadius.pillR,
                boxShadow: AppShadow.md),
            child: Text('Suivi livraison',
                style: GoogleFonts.urbanist(
                    color: AppColors.text, fontSize: 15,
                    fontWeight: FontWeight.w700)),
          ),
          centerTitle: true,
          actions: [
            GestureDetector(
              onTap: () {
                setState(() => _followDriver = !_followDriver);
                if (_followDriver) _fitBounds();
              },
              child: Container(
                margin: const EdgeInsets.all(8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: _followDriver ? AppColors.primary : Colors.white,
                    shape: BoxShape.circle, boxShadow: AppShadow.md),
                child: Icon(Icons.my_location_rounded,
                    color: _followDriver ? Colors.white : AppColors.textMuted,
                    size: 20),
              ),
            ),
          ],
        ),

        body: Stack(children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
                target: s.clientPosition, zoom: 14),
            markers:             _markers,
            polylines:           _polylines,
            myLocationEnabled:   false,
            zoomControlsEnabled: false,
            compassEnabled:      false,
            mapToolbarEnabled:   false,
            onMapCreated: (c) {
              _mapCtrl = c;
              Future.delayed(const Duration(milliseconds: 500), _fitBounds);
            },
            onCameraMoveStarted: () {
              if (_followDriver) setState(() => _followDriver = false);
            },
          ),

          // Panneau info bas
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              decoration: const BoxDecoration(
                  color: Colors.white, borderRadius: AppRadius.topXxl,
                  boxShadow: [BoxShadow(
                      color: Color(0x22000000), blurRadius: 20,
                      offset: Offset(0, -4))]),
              padding: EdgeInsets.fromLTRB(
                  20, 16, 20,
                  MediaQuery.of(context).padding.bottom + 16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Handle
                Center(child: Container(
                    width: 36, height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: const BoxDecoration(
                        color: AppColors.border,
                        borderRadius: AppRadius.pillR))),

                // Statut en temps réel
                Row(children: [
                  FadeTransition(
                    opacity: _pulse,
                    child: Container(
                        width: 12, height: 12,
                        decoration: BoxDecoration(
                            color: hasDriver ? AppColors.green : Colors.grey,
                            shape: BoxShape.circle)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(
                    hasDriver
                        ? 'Livreur en route · mise à jour en temps réel'
                        : 'Localisation du livreur…',
                    style: GoogleFonts.urbanist(
                        fontSize: 13, fontWeight: FontWeight.w600,
                        color: hasDriver ? AppColors.green : AppColors.textMuted),
                  )),
                  if (s.routeLoading)
                    const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.primary)),
                ]),

                const SizedBox(height: 16),

                // Stats
                Row(children: [
                  _Stat(
                    icon:  Icons.access_time_rounded,
                    label: 'ETA',
                    value: hasDriver
                        ? '~${hasDest ? s.etaTotal : s.etaToClient} min'
                        : '—',
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 12),
                  _Stat(
                    icon:  Icons.straighten_rounded,
                    label: 'Distance',
                    value: hasDriver
                        ? '${s.distanceToClient.toStringAsFixed(1)} km'
                        : '—',
                    color: AppColors.blue,
                  ),
                  if (hasDest) ...[
                    const SizedBox(width: 12),
                    _Stat(
                      icon:  Icons.place_rounded,
                      label: 'Total trajet',
                      value: '${s.distanceTotal.toStringAsFixed(1)} km',
                      color: AppColors.green,
                    ),
                  ],
                ]),

                // Légende
                if (hasDest) ...[
                  const SizedBox(height: 12),
                  const Row(children: [
                    _LegendLine(color: AppColors.primary,
                        label: 'Livreur → vous'),
                    SizedBox(width: 12),
                    _LegendLine(color: AppColors.blue,
                        label: 'Vous → destination', dashed: true),
                  ]),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String   label, value;
  final Color    color;
  const _Stat({required this.icon, required this.label,
      required this.value, required this.color});
  @override
  Widget build(BuildContext context) => Expanded(child: Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08), borderRadius: AppRadius.mdR,
        border: Border.all(color: color.withValues(alpha: 0.2))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 4),
        Text(label, style: GoogleFonts.urbanist(
            fontSize: 10, color: AppColors.textMuted)),
      ]),
      const SizedBox(height: 4),
      Text(value, style: GoogleFonts.urbanist(
          fontSize: 16, fontWeight: FontWeight.w800, color: color)),
    ]),
  ));
}

class _LegendLine extends StatelessWidget {
  final Color color; final String label; final bool dashed;
  const _LegendLine({required this.color, required this.label,
      this.dashed = false});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 20, height: 4,
            decoration: BoxDecoration(
                color: dashed ? Colors.transparent : color,
                borderRadius: AppRadius.pillR,
                border: dashed ? Border.all(color: color) : null)),
        const SizedBox(width: 6),
        Text(label, style: GoogleFonts.urbanist(
            fontSize: 11, color: AppColors.textMuted)),
      ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Wrapper pour compatibilité avec les appels existants via driverId/lat/lng
// ─────────────────────────────────────────────────────────────────────────────
class _LegacyTrackingMap extends StatefulWidget {
  final String driverId;
  final double clientLat, clientLng;
  const _LegacyTrackingMap({required this.driverId,
      required this.clientLat, required this.clientLng});
  @override
  State<_LegacyTrackingMap> createState() => _LegacyTrackingMapState();
}

class _LegacyTrackingMapState extends State<_LegacyTrackingMap>
    with SingleTickerProviderStateMixin {
  late TrackingService _tracking;
  GoogleMapController? _mapCtrl;
  BitmapDescriptor?    _motoIcon;

  late AnimationController _pulseCtrl;
  late Animation<double>   _pulse;

  void _onTrackingUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _tracking = TrackingService(
      driverId:       widget.driverId,
      clientPosition: LatLng(widget.clientLat, widget.clientLng),
    );
    _tracking.addListener(_onTrackingUpdate);
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.4, end: 1.0)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _loadMotoIcon();
  }

  Future<void> _loadMotoIcon() async {
    try {
      final icon = await BitmapDescriptor.asset(
          const ImageConfiguration(size: Size(48, 48)), 'assets/motorbike.png');
      if (mounted) setState(() => _motoIcon = icon);
    } catch (_) {}
  }

  @override
  void dispose() {
    _tracking.removeListener(_onTrackingUpdate);
    _tracking.dispose();
    _pulseCtrl.dispose();
    _mapCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _tracking.state;
    return Scaffold(
      appBar: AppBar(
          title: const Text('Suivi de livraison'),
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          centerTitle: true, elevation: 0),
      body: Stack(children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(
              target: s.clientPosition, zoom: 14),
          markers: {
            Marker(markerId: const MarkerId('client'),
                position: s.clientPosition,
                infoWindow: const InfoWindow(title: 'Votre position'),
                icon: BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueAzure)),
            if (s.driverPosition != null)
              Marker(markerId: const MarkerId('driver'),
                  position: s.driverPosition!,
                  infoWindow: const InfoWindow(title: 'Livreur en route'),
                  icon: _motoIcon ?? BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueOrange)),
          },
          polylines: {
            if (s.routeToClient.isNotEmpty)
              Polyline(polylineId: const PolylineId('route'),
                  points: s.routeToClient, color: AppColors.primary, width: 5),
          },
          myLocationEnabled: false, zoomControlsEnabled: false,
          onMapCreated: (c) => _mapCtrl = c,
        ),
        Positioned(
          bottom: 16, left: 16, right: 16,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(color: Colors.white,
                borderRadius: AppRadius.lgR, boxShadow: AppShadow.md),
            child: Row(children: [
              FadeTransition(opacity: _pulse,
                  child: Container(width: 12, height: 12,
                      decoration: BoxDecoration(
                          color: s.driverPosition != null
                              ? AppColors.green : Colors.grey,
                          shape: BoxShape.circle))),
              const SizedBox(width: 12),
              Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(s.driverPosition != null
                        ? 'Livreur en route'
                        : 'Localisation…',
                        style: GoogleFonts.urbanist(fontWeight: FontWeight.w700,
                            fontSize: 14)),
                    if (s.driverPosition != null)
                      Text('ETA: ~${s.etaToClient} min · '
                          '${s.distanceToClient.toStringAsFixed(1)} km',
                          style: GoogleFonts.urbanist(
                              fontSize: 12, color: AppColors.textMuted)),
                  ])),
            ]),
          ),
        ),
      ]),
    );
  }
}
