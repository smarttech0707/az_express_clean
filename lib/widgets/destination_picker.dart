import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

import '../services/places_service.dart';
import '../services/route_service.dart';
import '../theme/app_theme.dart';

const String _mapsKey = 'AIzaSyCjWt989YSIBblhRE9WNVOWXvOsXHIQ1DE';

class DestinationResult {
  final LatLng position;
  final String address;
  const DestinationResult({required this.position, required this.address});
}

/// Écran de sélection de destination :
/// - Champ de recherche d'adresse avec autocomplétion Google Places
/// - Carte avec marqueur destination + marqueur livreur le plus proche
/// - Trajet et ETA affichés
class DestinationPickerScreen extends StatefulWidget {
  final LatLng clientPosition;

  const DestinationPickerScreen({super.key, required this.clientPosition});

  @override
  State<DestinationPickerScreen> createState() =>
      _DestinationPickerScreenState();
}

class _DestinationPickerScreenState
    extends State<DestinationPickerScreen> {
  final _searchCtrl = TextEditingController();
  final _focus      = FocusNode();

  List<PlaceSuggestion> _suggestions = [];
  bool _searching = false;
  Timer? _debounce;

  LatLng? _destination;
  String  _destinationAddress = '';

  // Livreur le plus proche
  LatLng?  _driverPos;
  String   _driverName = 'Livreur';

  // Carte
  GoogleMapController? _mapCtrl;
  Set<Marker>    _markers   = {};
  Set<Polyline>  _polylines = {};
  double         _distanceKm = 0;
  int            _etaMin     = 0;
  bool           _loadingRoute = false;

  @override
  void initState() {
    super.initState();
    _loadNearestDriver();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _focus.dispose();
    _mapCtrl?.dispose();
    super.dispose();
  }

  // ── Charger le livreur en ligne le plus proche ──────────────────────────
  Future<void> _loadNearestDriver() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('livreurs')
          .where('isOnline', isEqualTo: true)
          .limit(20)
          .get();

      if (snap.docs.isEmpty) return;

      double minDist = double.infinity;
      DocumentSnapshot? nearest;

      for (final doc in snap.docs) {
        final d   = doc.data();
        final lat = (d['lat'] as num?)?.toDouble() ?? 0;
        final lng = (d['lng'] as num?)?.toDouble() ?? 0;
        if (lat == 0 || lng == 0) continue;

        final dist = Geolocator.distanceBetween(
          widget.clientPosition.latitude,
          widget.clientPosition.longitude,
          lat, lng,
        );
        if (dist < minDist) {
          minDist  = dist;
          nearest  = doc;
        }
      }

      if (nearest == null) return;
      final d = nearest.data() as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _driverPos  = LatLng(
          (d['lat'] as num).toDouble(),
          (d['lng'] as num).toDouble(),
        );
        _driverName = d['name'] as String? ?? 'Livreur';
      });
    } catch (_) {}
  }

  // ── Autocomplétion ────────────────────────────────────────────────────────
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      setState(() => _searching = true);
      final results = await PlacesService.autocomplete(value);
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _searching   = false;
      });
    });
  }

  // ── Sélection d'une suggestion ───────────────────────────────────────────
  Future<void> _selectSuggestion(PlaceSuggestion s) async {
    _focus.unfocus();
    setState(() {
      _searchCtrl.text = s.description;
      _suggestions     = [];
      _loadingRoute    = true;
    });

    final coords = await PlacesService.getCoordinates(s.placeId);
    if (coords == null) {
      if (!mounted) return;
      setState(() => _loadingRoute = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Position introuvable. Essaie autrement.')),
      );
      return;
    }

    await _setDestination(coords, s.description);
  }

  // ── Définir la destination et calculer le trajet ─────────────────────────
  Future<void> _setDestination(LatLng pos, String address) async {
    setState(() {
      _destination        = pos;
      _destinationAddress = address;
      _loadingRoute       = true;
    });

    // Centrer la carte
    _mapCtrl?.animateCamera(CameraUpdate.newLatLngZoom(pos, 14));

    // Marqueurs
    final newMarkers = <Marker>{
      Marker(
        markerId: const MarkerId('destination'),
        position: pos,
        infoWindow: InfoWindow(title: address),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        zIndexInt: 2,
      ),
      Marker(
        markerId: const MarkerId('client'),
        position: widget.clientPosition,
        infoWindow: const InfoWindow(title: 'Vous'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        zIndexInt: 3,
      ),
    };

    // Ajouter le livreur si disponible
    if (_driverPos != null) {
      newMarkers.add(Marker(
        markerId: const MarkerId('driver'),
        position: _driverPos!,
        infoWindow: InfoWindow(title: _driverName),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        zIndexInt: 4,
      ));
    }

    setState(() => _markers = newMarkers);

    // Trajet livreur → client → destination
    final polylines = <Polyline>{};
    double totalDist = 0;

    if (_driverPos != null) {
      // Segment 1 : livreur → client
      final route1 = await RouteService.getRoute(
        _driverPos!.latitude, _driverPos!.longitude,
        widget.clientPosition.latitude, widget.clientPosition.longitude,
        _mapsKey,
      );
      if (route1.isNotEmpty) {
        polylines.add(Polyline(
          polylineId: const PolylineId('driver_to_client'),
          points: route1,
          color: AppColors.primary,
          width: 5,
        ));
        totalDist += Geolocator.distanceBetween(
          _driverPos!.latitude, _driverPos!.longitude,
          widget.clientPosition.latitude, widget.clientPosition.longitude,
        ) / 1000;
      }
    }

    // Segment 2 : client → destination
    final route2 = await RouteService.getRoute(
      widget.clientPosition.latitude, widget.clientPosition.longitude,
      pos.latitude, pos.longitude,
      _mapsKey,
    );
    if (route2.isNotEmpty) {
      polylines.add(Polyline(
        polylineId: const PolylineId('client_to_dest'),
        points: route2,
        color: AppColors.blue,
        width: 5,
        patterns: [PatternItem.dash(20), PatternItem.gap(10)],
      ));
      totalDist += Geolocator.distanceBetween(
        widget.clientPosition.latitude, widget.clientPosition.longitude,
        pos.latitude, pos.longitude,
      ) / 1000;
    }

    // ETA (30 km/h en ville)
    final etaMin = ((totalDist / 30) * 60).round().clamp(2, 120);

    // Ajuster le zoom pour voir tout le trajet
    if (_driverPos != null || route2.isNotEmpty) {
      final allPoints = [
        if (_driverPos != null) _driverPos!,
        widget.clientPosition,
        pos,
      ];
      final bounds = _boundsFromLatLng(allPoints);
      _mapCtrl?.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, 60));
    }

    if (!mounted) return;
    setState(() {
      _polylines    = polylines;
      _distanceKm   = totalDist;
      _etaMin       = etaMin;
      _loadingRoute = false;
    });
  }

  LatLngBounds _boundsFromLatLng(List<LatLng> points) {
    double minLat = points.first.latitude,  maxLat = points.first.latitude;
    double minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude  < minLat) minLat = p.latitude;
      if (p.latitude  > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── CARTE ──────────────────────────────────────────────────────────
          GoogleMap(
            onMapCreated: (c) {
              _mapCtrl = c;
              if (_destination == null) {
                c.animateCamera(CameraUpdate.newLatLngZoom(
                    widget.clientPosition, 14));
              }
            },
            initialCameraPosition: CameraPosition(
              target: widget.clientPosition,
              zoom:   14,
            ),
            markers:   _markers,
            polylines: _polylines,
            myLocationEnabled:       true,
            myLocationButtonEnabled: false,
            zoomControlsEnabled:     false,
            mapType:                 MapType.normal,
          ),

          // ── BARRE DE RECHERCHE ──────────────────────────────────────────
          SafeArea(
            child: Column(
              children: [
                // Back + search bar
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: const BoxDecoration(
                            color:  Colors.white,
                            shape:  BoxShape.circle,
                            boxShadow: AppShadow.md,
                          ),
                          child: const Icon(Icons.arrow_back_rounded, size: 20),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Container(
                          decoration: const BoxDecoration(
                            color:        Colors.white,
                            borderRadius: AppRadius.lgR,
                            boxShadow:    AppShadow.md,
                          ),
                          child: TextField(
                            controller:  _searchCtrl,
                            focusNode:   _focus,
                            onChanged:   _onSearchChanged,
                            autofocus:   true,
                            style: GoogleFonts.inter(fontSize: 15),
                            decoration: InputDecoration(
                              hintText: 'Où livrer ? (quartier, rue…)',
                              hintStyle: GoogleFonts.inter(
                                  color: AppColors.textLight, fontSize: 14),
                              prefixIcon: const Icon(
                                  Icons.search_rounded,
                                  color: AppColors.primary),
                              suffixIcon: _searching
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: SizedBox(
                                        width: 18, height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: AppColors.primary),
                                      ))
                                  : _searchCtrl.text.isNotEmpty
                                      ? IconButton(
                                          icon: const Icon(Icons.close,
                                              color: AppColors.textLight),
                                          onPressed: () {
                                            _searchCtrl.clear();
                                            setState(() => _suggestions = []);
                                          })
                                      : null,
                              border:        InputBorder.none,
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Suggestions
                if (_suggestions.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                    decoration: const BoxDecoration(
                      color:        Colors.white,
                      borderRadius: AppRadius.lgR,
                      boxShadow:    AppShadow.md,
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _suggestions.length.clamp(0, 5),
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final s = _suggestions[i];
                        return ListTile(
                          leading: const Icon(Icons.place_rounded,
                              color: AppColors.primary, size: 22),
                          title: Text(s.mainText,
                              style: GoogleFonts.inter(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                          subtitle: s.secondaryText.isNotEmpty
                              ? Text(s.secondaryText,
                                  style: GoogleFonts.inter(
                                      fontSize: 12,
                                      color: AppColors.textLight))
                              : null,
                          onTap: () => _selectSuggestion(s),
                          dense: true,
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

          // ── PANNEAU INFO TRAJET ──────────────────────────────────────────
          if (_destination != null)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                    20, 20, 20,
                    MediaQuery.of(context).padding.bottom + 20),
                decoration: const BoxDecoration(
                  color:        Colors.white,
                  borderRadius: AppRadius.topXxl,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Handle
                    Center(
                      child: Container(
                        width: 36, height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: const BoxDecoration(
                          color:        AppColors.border,
                          borderRadius: AppRadius.pillR,
                        ),
                      ),
                    ),

                    // Destination
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(
                            color:        AppColors.primary10,
                            borderRadius: AppRadius.mdR,
                          ),
                          child: const Icon(Icons.place_rounded,
                              color: AppColors.primary, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _destinationAddress,
                            style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Stats trajet
                    if (_loadingRoute)
                      const Center(child: CircularProgressIndicator(
                          color: AppColors.primary))
                    else
                      Row(
                        children: [
                          _StatPill(
                            icon:  Icons.straighten_rounded,
                            label: '${_distanceKm.toStringAsFixed(1)} km',
                            color: AppColors.blue,
                          ),
                          const SizedBox(width: 10),
                          _StatPill(
                            icon:  Icons.access_time_rounded,
                            label: '$_etaMin min',
                            color: AppColors.primary,
                          ),
                          if (_driverPos != null) ...[
                            const SizedBox(width: 10),
                            const _StatPill(
                              icon:  Icons.delivery_dining_rounded,
                              label: 'Livreur proche',
                              color: AppColors.green,
                            ),
                          ],
                        ],
                      ),

                    const SizedBox(height: 16),

                    // Bouton confirmer
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: _loadingRoute
                            ? null
                            : () => Navigator.pop(
                                context,
                                DestinationResult(
                                  position: _destination!,
                                  address:  _destinationAddress,
                                )),
                        icon:  const Icon(Icons.check_rounded),
                        label: const Text('Confirmer cette destination'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          shape: const RoundedRectangleBorder(
                              borderRadius: AppRadius.lgR),
                          textStyle: GoogleFonts.inter(
                              fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Loading overlay
          if (_loadingRoute && _destination != null)
            const Positioned(
              top: 100, left: 0, right: 0,
              child: Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.primary)),
                        SizedBox(width: 12),
                        Text('Calcul du trajet…'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;

  const _StatPill({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.1),
        borderRadius: AppRadius.pillR,
        border:       Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(label, style: GoogleFonts.inter(
              color: color, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
