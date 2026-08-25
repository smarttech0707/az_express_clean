import 'dart:async';
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
import '../../event/screens/event_home_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTES
// ─────────────────────────────────────────────────────────────────────────────
const LatLng _abengourou = LatLng(6.7273, -3.4961);
const Color _primary = AppColors.primary;

// ─────────────────────────────────────────────────────────────────────────────
// ÉTAT PERMISSION
// ─────────────────────────────────────────────────────────────────────────────
enum _PermState { checking, granted, denied, serviceOff }

// ─────────────────────────────────────────────────────────────────────────────
// MAP SCREEN
// ─────────────────────────────────────────────────────────────────────────────
class ClientMap extends StatefulWidget {
  const ClientMap({super.key});

  @override
  State<ClientMap> createState() => _ClientMapState();
}

class _ClientMapState extends State<ClientMap>
    with SingleTickerProviderStateMixin {
  GoogleMapController? _mapController;
  LatLng? _clientPosition;
  _PermState _permState = _PermState.checking;
  Set<Marker> _markers = {};
  StreamSubscription<QuerySnapshot>? _driversSub;
  int _onlineDrivers = 0;

  // Icônes cachées pour éviter de les recréer à chaque update
  BitmapDescriptor? _driverIcon;
  BitmapDescriptor? _clientIcon;

  // Animation du panneau inférieur
  late AnimationController _panelCtrl;
  late Animation<Offset> _panelSlide;
  late Animation<double> _panelFade;

  // ── Initialisation ──────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _initPanelAnimation();
    _loadIcons();
    _checkPermissionAndLocate();
  }

  void _initPanelAnimation() {
    _panelCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _panelSlide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _panelCtrl, curve: Curves.easeOutCubic));
    _panelFade = CurvedAnimation(parent: _panelCtrl, curve: Curves.easeOut);
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) _panelCtrl.forward();
    });
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
    _panelCtrl.dispose();
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
    _driversSub = FirebaseFirestore.instance
        .collection('livreurs')
        .where('isOnline', isEqualTo: true)
        .snapshots()
        .listen(_onDriversSnapshot, onError: (_) {
      // Erreur Firestore silencieuse — on garde l'UI stable
    });
  }

  void _onDriversSnapshot(QuerySnapshot snapshot) {
    if (!mounted) return;

    final Set<Marker> newMarkers = {};

    // Marqueur client
    if (_clientPosition != null) {
      newMarkers.add(Marker(
        markerId: const MarkerId('client'),
        position: _clientPosition!,
        infoWindow: const InfoWindow(title: 'Vous'),
        icon: _clientIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        zIndexInt: 2,
      ));
    }

    // Marqueurs livreurs
    for (final doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>;
      final lat = (data['lat'] as num?)?.toDouble() ?? 0;
      final lng = (data['lng'] as num?)?.toDouble() ?? 0;
      if (lat == 0 || lng == 0) continue;

      newMarkers.add(Marker(
        markerId: MarkerId(doc.id),
        position: LatLng(lat, lng),
        infoWindow: InfoWindow(
          title: data['name'] as String? ?? 'Livreur',
          snippet: data['vehicle'] as String? ?? '',
        ),
        icon: _driverIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        zIndexInt: 1,
      ));
    }

    setState(() {
      _markers = newMarkers;
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

            // ── PANNEAU INFÉRIEUR ─────────────────────────────────────────
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SlideTransition(
                position: _panelSlide,
                child: FadeTransition(
                  opacity: _panelFade,
                  child: _BottomPanel(onlineDrivers: _onlineDrivers),
                ),
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color:
                  isAvailable ? const Color(0xFF22C55E) : Colors.grey.shade400,
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
              color: Colors.black87,
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Icon(Icons.my_location_rounded, color: _primary, size: 20),
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
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(children: [
          const Icon(Icons.search_rounded, color: AppColors.primary, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Où allez-vous ?',
              style: GoogleFonts.urbanist(
                fontSize: 16,
                color: Colors.grey.shade500,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mic_rounded,
                color: AppColors.primary, size: 20),
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
  const _BottomPanel({required this.onlineDrivers});

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

  void _showPlusMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final bottom = MediaQuery.of(ctx).padding.bottom;
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.82,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    ctx.tr('more_services'),
                    style: GoogleFonts.urbanist(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + bottom),
                  child: const Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _PlusCard(
                          icon: Icons.bakery_dining_rounded,
                          routeKey: 'boulangerie',
                          color: Color(0xFF5D4037)),
                      _PlusCard(
                          icon: Icons.storefront_rounded,
                          routeKey: 'boutique',
                          color: Colors.deepOrange),
                      _PlusCard(
                          icon: Icons.local_pharmacy_rounded,
                          routeKey: 'pharmacy',
                          color: Colors.red),
                      _PlusCard(
                          icon: Icons.local_laundry_service_rounded,
                          routeKey: 'laundry',
                          color: Colors.blue),
                      _PlusCard(
                          icon: Icons.card_giftcard_rounded,
                          routeKey: 'parcel',
                          color: Colors.orange),
                      _PlusCard(
                          icon: Icons.water_drop_rounded,
                          routeKey: 'water',
                          color: Colors.teal),
                      _PlusCard(
                          icon: Icons.home_rounded,
                          routeKey: 'houses',
                          color: Color(0xFF00695C)),
                      _PlusCard(
                          icon: Icons.apartment_rounded,
                          routeKey: 'furnished',
                          color: Color(0xFF4A148C)),
                      _PlusCard(
                          icon: Icons.villa_rounded,
                          routeKey: 'real_estate',
                          color: Color(0xFF00838F)),
                      _PlusCard(
                          icon: Icons.construction_rounded,
                          routeKey: 'local_services',
                          color: Color(0xFF1565C0)),
                      _PlusCard(
                          icon: Icons.wine_bar_rounded,
                          routeKey: 'cave',
                          color: Color(0xFF880E4F)),
                      _PlusCard(
                          icon: Icons.electric_rickshaw_rounded,
                          routeKey: 'tricycle',
                          color: Color(0xFF6D4C41)),
                      _PlusCard(
                          icon: Icons.local_taxi_rounded,
                          routeKey: 'night_taxi',
                          color: Color(0xFF37474F)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 24,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 16),
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),

          // ── GREETING + WALLET ──────────────────────────────────────────
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
                        style: GoogleFonts.urbanist(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        context.tr('where_send'),
                        style: GoogleFonts.urbanist(
                          fontSize: 12.5,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),

                // ── Wallet chip ────────────────────────────────────────
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ClientWalletPage()),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [_primary, Color(0xFFFF8F00)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: _primary.withValues(alpha: 0.35),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.account_balance_wallet_rounded,
                            color: Colors.white, size: 14),
                        const SizedBox(width: 6),
                        Text(
                          '${_fmtWallet(_walletBalance)} F',
                          style: GoogleFonts.urbanist(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 3),
                        const Icon(Icons.chevron_right_rounded,
                            color: Colors.white70, size: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: screenH < 700 ? 14 : 18),

          // ── GRILLE SERVICES 2×2 ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                Row(children: [
                  // ── Livraison ──────────────────────────────────────────
                  _ServiceCard(
                    icon: Icons.delivery_dining_rounded,
                    label: 'Livraison',
                    description: 'Envoyer un colis rapidement',
                    color: _primary,
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const LivraisonScreen())),
                  ),
                  const SizedBox(width: 12),
                  // ── Courses ────────────────────────────────────────────
                  _ServiceCard(
                    icon: Icons.shopping_basket_rounded,
                    label: 'Courses',
                    description: 'Vos achats du quotidien',
                    color: const Color(0xFF2E7D32),
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const CoursesScreen())),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  // ── Food ───────────────────────────────────────────────
                  _ServiceCard(
                    icon: Icons.restaurant_rounded,
                    label: 'Food',
                    description: 'Commandez vos repas',
                    color: const Color(0xFF1565C0),
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const RestaurantList())),
                  ),
                  const SizedBox(width: 12),
                  // ── Plus de services ───────────────────────────────────
                  _ServiceCard(
                    icon: Icons.grid_view_rounded,
                    label: context.tr('more_services'),
                    description: 'Découvrir tous les services',
                    color: const Color(0xFF6A1B9A),
                    onTap: () => _showPlusMenu(context),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  _ServiceCard(
                    icon: Icons.celebration_rounded,
                    label: 'Événementiel',
                    description: 'Location, déco, traiteur & personnel',
                    color: const Color(0xFF8E24AA),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const EventHomeScreen()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Spacer(),
                ]),
              ],
            ),
          ),

          SizedBox(height: bottomPad + 20),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SERVICE CARD
// ─────────────────────────────────────────────────────────────────────────────
class _ServiceCard extends StatefulWidget {
  final IconData icon;
  final String label;
  final String description;
  final Color color;
  final VoidCallback onTap;

  const _ServiceCard({
    required this.icon,
    required this.label,
    required this.description,
    required this.color,
    required this.onTap,
  });

  @override
  State<_ServiceCard> createState() => _ServiceCardState();
}

class _ServiceCardState extends State<_ServiceCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.94 : 1.0,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            height: 88,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: _pressed ? 0.15 : 0.08),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: widget.color.withValues(alpha: 0.25),
                width: 1.5,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(widget.icon, color: widget.color, size: 20),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.urbanist(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        widget.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.urbanist(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w400,
                          color: Colors.black54,
                          height: 1.2,
                        ),
                      ),
                    ],
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

// ─────────────────────────────────────────────────────────────────────────────
// PLUS CARD
// ─────────────────────────────────────────────────────────────────────────────
class _PlusCard extends StatefulWidget {
  final IconData icon;
  final String routeKey;
  final Color color;

  const _PlusCard({
    required this.icon,
    required this.routeKey,
    required this.color,
  });

  @override
  State<_PlusCard> createState() => _PlusCardState();
}

class _PlusCardState extends State<_PlusCard> {
  bool _pressed = false;

  void _navigate(BuildContext context) {
    Navigator.pop(context);
    final title = context.tr(widget.routeKey);
    final subtitle = context.tr('${widget.routeKey}_sub');
    Widget? page;
    switch (widget.routeKey) {
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
      case 'cave':
        page = SimpleServicePage(
          serviceType: 'cave',
          title: title,
          subtitle: subtitle,
          icon: Icons.wine_bar_rounded,
          gradient: const [Color(0xFF880E4F), Color(0xFFAD1457)],
          color: widget.color,
        );
        break;
      case 'tricycle':
        page = SimpleServicePage(
          serviceType: 'tricycle',
          title: title,
          subtitle: subtitle,
          icon: Icons.electric_rickshaw_rounded,
          gradient: const [Color(0xFF4E342E), Color(0xFF8D6E63)],
          color: widget.color,
        );
        break;
      case 'night_taxi':
        page = SimpleServicePage(
          serviceType: 'taxi_nuit',
          title: title,
          subtitle: subtitle,
          icon: Icons.local_taxi_rounded,
          gradient: const [Color(0xFF263238), Color(0xFF546E7A)],
          color: widget.color,
        );
        break;
    }
    if (page != null) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => page!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cardWidth = (MediaQuery.of(context).size.width - 40 - 24) / 3;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        _navigate(context);
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: SizedBox(
          width: cardWidth,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: _pressed ? 0.15 : 0.07),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: widget.color.withValues(alpha: 0.22), width: 1.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(widget.icon, color: widget.color, size: 22),
                ),
                const SizedBox(height: 8),
                Text(
                  context.tr(widget.routeKey),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.urbanist(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                    height: 1.3,
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
