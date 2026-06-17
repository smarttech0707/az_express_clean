import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../../widgets/driver_marker.dart';

/// Page admin — suivi en temps réel de tous les livreurs en ligne.
///
/// Affiche une carte avec la position de chaque livreur actif,
/// et une liste avec statut GPS, dernière mise à jour, vitesse.
class AdminLiveTrackingPage extends StatefulWidget {
  const AdminLiveTrackingPage({super.key});

  @override
  State<AdminLiveTrackingPage> createState() => _AdminLiveTrackingPageState();
}

class _AdminLiveTrackingPageState extends State<AdminLiveTrackingPage> {

  // ── Carte ──────────────────────────────────────────────────────────────────
  GoogleMapController? _mapCtrl;
  Set<Marker>          _markers = {};
  BitmapDescriptor?    _motoIcon;

  // ── Données livreurs ───────────────────────────────────────────────────────
  final List<_DriverStatus> _drivers = [];
  StreamSubscription<QuerySnapshot>? _sub;

  // ── Abengourou centre (position par défaut) ────────────────────────────────
  static const _abengourou = LatLng(6.7294, -3.4966);

  @override
  void initState() {
    super.initState();
    _loadIcon();
    _subscribeToDrivers();
  }

  Future<void> _loadIcon() async {
    _motoIcon = await DriverMarkerIcon.getMotoIcon(size: 44);
    if (mounted) _rebuildMarkers();
  }

  void _subscribeToDrivers() {
    _sub = FirebaseFirestore.instance
        .collection('livreurs')
        .where('isOnline', isEqualTo: true)
        .snapshots()
        .listen(_onDriversUpdate, onError: (_) {});
  }

  void _onDriversUpdate(QuerySnapshot snap) {
    if (!mounted) return;
    final list = snap.docs.map((doc) {
      final d = doc.data() as Map<String, dynamic>;
      final lat = (d['lat'] as num?)?.toDouble();
      final lng = (d['lng'] as num?)?.toDouble();
      final updatedAt = d['updatedAt'] != null
          ? (d['updatedAt'] as Timestamp).toDate()
          : null;
      final secsSince = updatedAt != null
          ? DateTime.now().difference(updatedAt).inSeconds
          : 9999;
      return _DriverStatus(
        id:        doc.id,
        name:      d['name']  as String? ?? 'Livreur',
        phone:     d['phone'] as String? ?? '',
        lat:       lat,
        lng:       lng,
        heading:   (d['heading'] as num?)?.toDouble() ?? 0,
        speed:     (d['speed']  as num?)?.toDouble() ?? 0,
        updatedAt: updatedAt,
        secsSince: secsSince,
        gpsOk:     lat != null && lng != null && secsSince < 60,
      );
    }).toList();

    list.sort((a, b) => a.name.compareTo(b.name));

    setState(() {
      _drivers
        ..clear()
        ..addAll(list);
    });
    _rebuildMarkers();
  }

  void _rebuildMarkers() {
    if (!mounted) return;
    final markers = <Marker>{};
    for (final d in _drivers) {
      if (d.lat == null || d.lng == null) continue;
      markers.add(Marker(
        markerId:   MarkerId(d.id),
        position:   LatLng(d.lat!, d.lng!),
        icon:       _motoIcon ?? BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(
          title:   d.name,
          snippet: d.gpsOk
              ? '${d.speedKmh.toStringAsFixed(0)} km/h'
              : 'GPS inactif',
        ),
        rotation:   d.heading,
        flat:       true,
        anchor:     const Offset(0.5, 0.5),
        zIndexInt:  d.gpsOk ? 2 : 1,
      ));
    }
    setState(() => _markers = markers);
  }

  void _centerOn(_DriverStatus d) {
    if (d.lat == null || d.lng == null || _mapCtrl == null) return;
    _mapCtrl!.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(d.lat!, d.lng!), 16));
  }

  @override
  Widget build(BuildContext context) {
    final online = _drivers.where((d) => d.gpsOk).length;
    final total  = _drivers.length;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('Tracking Live',
            style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color:        Colors.white24,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$online / $total en ligne',
                  style: GoogleFonts.inter(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(children: [

        // ── Carte ──────────────────────────────────────────────────────────
        SizedBox(
          height: 280,
          child: GoogleMap(
            initialCameraPosition: const CameraPosition(
                target: _abengourou, zoom: 13),
            markers:             _markers,
            zoomControlsEnabled: false,
            compassEnabled:      true,
            mapToolbarEnabled:   false,
            myLocationEnabled:   false,
            onMapCreated:        (ctrl) => _mapCtrl = ctrl,
          ),
        ),

        // ── Liste livreurs ──────────────────────────────────────────────────
        Expanded(
          child: total == 0
              ? _buildEmpty()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  itemCount: _drivers.length,
                  itemBuilder: (_, i) => _DriverTile(
                    driver: _drivers[i],
                    onTap:  () => _centerOn(_drivers[i]),
                  ),
                ),
        ),
      ]),
    );
  }

  Widget _buildEmpty() => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    Icon(Icons.delivery_dining_rounded,
        size: 56, color: Colors.grey.shade300),
    const SizedBox(height: 12),
    Text('Aucun livreur en ligne',
        style: GoogleFonts.poppins(
            fontSize: 15, fontWeight: FontWeight.w600,
            color: Colors.grey.shade400)),
  ]));

  @override
  void dispose() {
    _sub?.cancel();
    _mapCtrl?.dispose();
    super.dispose();
  }
}

// ── Modèle interne ────────────────────────────────────────────────────────────

class _DriverStatus {
  final String   id, name, phone;
  final double?  lat, lng;
  final double   heading, speed;
  final DateTime? updatedAt;
  final int      secsSince;
  final bool     gpsOk;

  const _DriverStatus({
    required this.id,
    required this.name,
    required this.phone,
    required this.lat,
    required this.lng,
    required this.heading,
    required this.speed,
    required this.updatedAt,
    required this.secsSince,
    required this.gpsOk,
  });

  double get speedKmh => speed * 3.6;

  String get lastUpdateStr {
    if (updatedAt == null) return 'jamais';
    if (secsSince < 60)  return 'il y a ${secsSince}s';
    if (secsSince < 3600) return 'il y a ${secsSince ~/ 60} min';
    return DateFormat('HH:mm').format(updatedAt!);
  }
}

// ── Tuile livreur ─────────────────────────────────────────────────────────────

class _DriverTile extends StatelessWidget {
  final _DriverStatus driver;
  final VoidCallback  onTap;
  const _DriverTile({required this.driver, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ok    = driver.gpsOk;
    final color = ok ? const Color(0xFF22C55E) : Colors.orange;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(color: Color(0x10000000), blurRadius: 6, offset: Offset(0, 2)),
          ],
          border: Border.all(
            color: ok ? const Color(0xFFDCFCE7) : const Color(0xFFFFF3E0)),
        ),
        child: Row(children: [

          // Indicateur GPS
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),

          // Nom + téléphone
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(driver.name, style: GoogleFonts.inter(
                fontSize: 14, fontWeight: FontWeight.w700)),
            if (driver.phone.isNotEmpty)
              Text(driver.phone, style: GoogleFonts.inter(
                  fontSize: 11, color: Colors.grey.shade500)),
          ])),

          // Stats
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(
              ok ? '${driver.speedKmh.toStringAsFixed(0)} km/h' : 'GPS inactif',
              style: GoogleFonts.inter(
                  fontSize: 13, fontWeight: FontWeight.w700, color: color),
            ),
            Text(
              driver.lastUpdateStr,
              style: GoogleFonts.inter(
                  fontSize: 11, color: Colors.grey.shade400),
            ),
          ]),

          const SizedBox(width: 8),
          Icon(Icons.chevron_right_rounded,
              color: Colors.grey.shade300, size: 20),
        ]),
      ),
    );
  }
}
