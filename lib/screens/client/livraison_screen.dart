import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../models/local_place.dart';
import '../../models/order_model.dart';
import '../../models/route_model.dart';
import '../../providers/active_city_provider.dart';
import '../../services/firestore_service.dart';
import '../../services/google_routes_service.dart';
import '../../services/places_search_service.dart';
import '../../services/places_service.dart';
import '../../services/tarif_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/driver_marker.dart';
import '../../widgets/glass_kit.dart';
import '../../widgets/route_polyline.dart';
import '../customer_tracking_screen.dart';

const LatLng _abengourou = LatLng(6.7273, -3.4961);

enum _ActiveField { none, departure, destination }

@visibleForTesting
bool livraisonCashOnDeliveryEnabled(dynamic value) => value as bool? ?? true;

@visibleForTesting
String livraisonPaymentAfterCodUpdate({
  required String currentPayment,
  required bool cashOnDeliveryEnabled,
}) =>
    !cashOnDeliveryEnabled && currentPayment == 'cash'
        ? 'wallet'
        : currentPayment;

@visibleForTesting
int parseLivraisonShoppingBudget(String value) =>
    (int.tryParse(value.trim()) ?? 0).clamp(0, 9999999);

@visibleForTesting
bool shouldShowLivraisonSearchExpansion({
  required String query,
  required bool searched,
  required bool searching,
  required bool hasResults,
  required PlacesSearchState searchState,
}) =>
    searched &&
    !searching &&
    !hasResults &&
    query.trim().length >= 5 &&
    searchState == PlacesSearchState.awaitingExpansion;

typedef LivraisonReverseGeocoder = Future<String?> Function(
  double latitude,
  double longitude,
);

@visibleForTesting
Future<LocalPlace> buildLivraisonGpsPlace({
  required double latitude,
  required double longitude,
  required String district,
  required bool resolveAddress,
  LivraisonReverseGeocoder reverseGeocoder = PlacesService.reverseGeocode,
}) async {
  final address =
      resolveAddress ? await reverseGeocoder(latitude, longitude) : null;
  return LocalPlace.fromExternal(
    name: address?.split(',').first ?? 'Ma position actuelle',
    address: address ?? 'Position GPS',
    latitude: latitude,
    longitude: longitude,
    category: 'quartier',
    district: district,
    source: 'gps',
  );
}

@visibleForTesting
String activeLivraisonCityName(ActiveCityProvider provider) {
  final cityId = provider.activeCityId;
  if (cityId == null) return '';
  for (final city in provider.activeCities) {
    if (city.cityId == cityId) return city.name ?? '';
  }
  return '';
}

@visibleForTesting
String? livraisonOrderCoordinateSource(String source) => switch (source) {
      'gps' => 'gps',
      'map' => 'map_pin',
      'firestore' => 'local_place',
      'osm' || 'nominatim' => 'nominatim',
      'google' || 'google_poi' => 'google',
      _ => null,
    };

const _catItems = <(String, String, Color)>[
  ('documents', '📄 Documents', Color(0xFF1565C0)),
  ('colis', '📦 Colis', AppColors.primary),
  ('medicaments', '💊 Médicaments', Color(0xFF2E7D32)),
  ('repas', '🍔 Repas', Color(0xFFE53935)),
  ('autre', '🎁 Autre', Color(0xFF607D8B)),
];

class LivraisonScreen extends StatefulWidget {
  final bool startStartupServices;

  const LivraisonScreen({
    super.key,
    this.startStartupServices = true,
  });
  @override
  State<LivraisonScreen> createState() => _LivraisonScreenState();
}

class _LivraisonScreenState extends State<LivraisonScreen>
    with TickerProviderStateMixin {
  // ── Animations ─────────────────────────────────────────────────────────────
  late final AnimationController _routeAnim;
  late final AnimationController _pulseCtrl;

  // ── Carte ──────────────────────────────────────────────────────────────────
  GoogleMapController? _mapCtrl;
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  BitmapDescriptor? _clientIcon;
  BitmapDescriptor? _destIcon;

  // ── Lieux sélectionnés ─────────────────────────────────────────────────────
  LocalPlace? _departure;
  LocalPlace? _destination;

  // ── Recherche ──────────────────────────────────────────────────────────────
  _ActiveField _activeField = _ActiveField.none;
  final _depCtrl = TextEditingController();
  final _destCtrl = TextEditingController();
  final _depFocus = FocusNode();
  final _destFocus = FocusNode();
  // Cibles explicites du bouton clavier "Suivant" (Nom → Téléphone) — un
  // FocusScope.nextFocus() générique ne traverse pas correctement jusqu'à
  // ces champs à travers les Padding/SizedBox intermédiaires de la Column.
  final _pickupContactPhoneFocus = FocusNode();
  final _recipientPhoneFocus = FocusNode();
  List<LocalPlace> _suggestions = [];
  bool _searching = false;
  bool _searched = false;
  bool _awaitingExpansion = false;
  bool _expandingSearch = false;
  Timer? _debounce;
  List<LocalPlace> _popularPlaces = const [];
  String? _popularPlacesCityId;

  // ── Route ──────────────────────────────────────────────────────────────────
  RouteModel _route = RouteModel.empty();
  bool _routeLoading = false;

  // ── Commande ───────────────────────────────────────────────────────────────
  final _colisCtrl = TextEditingController();
  final _recipientCtrl = TextEditingController(); // téléphone destinataire
  final _pickupContactNameCtrl = TextEditingController();
  final _pickupContactPhoneCtrl = TextEditingController();
  final _recipientNameCtrl = TextEditingController();
  final _poidsCtrl = TextEditingController();
  final _shoppingBudgetCtrl = TextEditingController();
  String _deliveryMode = 'standard';
  String _category = 'colis';
  String _payment = 'cash';
  int _wallet = 0;
  bool _codEnabled = true;
  StreamSubscription? _walletSub;
  bool _sending = false;
  bool _gpsLoading = false;
  bool _selectingDestinationOnMap = false;
  LatLng _mapCenter = _abengourou;

  // ── Phases du parcours ─────────────────────────────────────────────────────
  // 1 = sélection point récupération
  // 2 = contact expéditeur (qui remet le colis)
  // 3 = sélection point livraison
  // 4 = contact destinataire + type colis
  // 5 = confirmation + paiement + commande
  int _phase = 1;

  // ── Getters calculés ──────────────────────────────────────────────────────

  TarifResult? get _tarifResult {
    if (_destination == null) return null;
    return TarifService.compute(
      clientLat: _destination!.latitude,
      clientLng: _destination!.longitude,
      routeDistanceKm: _route.distanceKm > 0 ? _route.distanceKm : null,
    );
  }

  int get _selectedPrice {
    final t = _tarifResult;
    if (t == null) return 0;
    return _deliveryMode == 'express' ? t.expressPrice : t.standardPrice;
  }

  String get _etaRange {
    if (_route.etaMinutes == 0) return '—';
    if (_deliveryMode == 'express') {
      return '${(_route.etaMinutes * 0.8).ceil()}–${_route.etaMinutes + 5} min';
    }
    return '${_route.etaMinutes + 15}–${_route.etaMinutes + 40} min';
  }

  int get _expressPrice => _tarifResult?.expressPrice ?? 0;
  int get _standardPrice => _tarifResult?.standardPrice ?? 0;

  String get _categoryLabel {
    for (final c in _catItems) {
      if (c.$1 == _category) return c.$2;
    }
    return '📦 Colis';
  }

  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    _routeAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _loadIcons();
    if (widget.startStartupServices) {
      _getGPS(_ActiveField.departure, false);
      _listenWallet();
    }
    _depFocus.addListener(_onDepFocusChange);
    _destFocus.addListener(_onDestFocusChange);
  }

  void _loadIcons() {
    _clientIcon = DriverMarkerIcon.getClientIcon();
    _destIcon = DriverMarkerIcon.getDestIcon();
  }

  Future<void> _getGPS([
    _ActiveField target = _ActiveField.departure,
    bool resolveAddress = true,
  ]) async {
    if (_gpsLoading) return;
    final cityProvider = context.read<ActiveCityProvider>();
    _gpsLoading = true;
    try {
      final perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      await cityProvider.resolveGps(
        latitude: pos.latitude,
        longitude: pos.longitude,
      );
      final place = await buildLivraisonGpsPlace(
        latitude: pos.latitude,
        longitude: pos.longitude,
        district: activeLivraisonCityName(cityProvider),
        resolveAddress: resolveAddress,
      );
      if (!mounted) return;
      setState(() {
        if (target == _ActiveField.destination) {
          _destination = place;
          _destCtrl.text = place.name;
          _selectingDestinationOnMap = false;
        } else {
          _departure = place;
          _depCtrl.text = place.name;
        }
      });
      _updateMarkers();
      await _loadPopularPlaces(cityProvider);
      if (_departure != null && _destination != null) _calcRoute();
      _mapCtrl?.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 15));
    } catch (_) {
    } finally {
      if (mounted) setState(() => _gpsLoading = false);
    }
  }

  Future<void> _loadPopularPlaces(ActiveCityProvider cityProvider) async {
    final cityId = cityProvider.activeCityId;
    if (cityId == null) {
      if (mounted) {
        setState(() {
          _popularPlaces = const [];
          _popularPlacesCityId = null;
        });
      }
      return;
    }
    final places = await PlacesSearchService.popularPlaces(
      cityService: cityProvider.service,
    );
    if (!mounted || cityProvider.activeCityId != cityId) return;
    setState(() {
      _popularPlaces = places;
      _popularPlacesCityId = cityId;
    });
  }

  void _listenWallet() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _walletSub = FirebaseFirestore.instance
        .collection('clients')
        .doc(uid)
        .snapshots()
        .listen((s) {
      if (mounted) {
        final data = s.data();
        final codEnabled =
            livraisonCashOnDeliveryEnabled(data?['cashOnDeliveryEnabled']);
        setState(() {
          _wallet = (data?['wallet'] as num?)?.toInt() ?? 0;
          _codEnabled = codEnabled;
          _payment = livraisonPaymentAfterCodUpdate(
            currentPayment: _payment,
            cashOnDeliveryEnabled: codEnabled,
          );
        });
      }
    });
  }

  void _onDepFocusChange() {
    if (_depFocus.hasFocus) {
      setState(() {
        _activeField = _ActiveField.departure;
        _searched = false;
      });
    }
  }

  void _onDestFocusChange() {
    if (_destFocus.hasFocus) {
      setState(() {
        _activeField = _ActiveField.destination;
        _searched = false;
      });
    }
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < PlacesSearchService.minQueryLength) {
      setState(() {
        _suggestions = [];
        _searching = false;
        _searched = false;
        _awaitingExpansion = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(
        const Duration(milliseconds: 300), () => _runSearch(query.trim()));
  }

  Future<void> _runSearch(String query) async {
    final results = await PlacesSearchService.search(
      query,
      cityService: context.read<ActiveCityProvider>().service,
    );
    if (!mounted) return;
    setState(() {
      _suggestions = results;
      _searching = false;
      _searched = true;
      _awaitingExpansion = PlacesSearchService.lastSearchState ==
          PlacesSearchState.awaitingExpansion;
    });
  }

  Future<void> _expandSearch() async {
    final query = (_activeField == _ActiveField.departure
            ? _depCtrl.text
            : _destCtrl.text)
        .trim();
    if (!shouldShowLivraisonSearchExpansion(
      query: query,
      searched: _searched,
      searching: _searching,
      hasResults: _suggestions.isNotEmpty,
      searchState: _awaitingExpansion
          ? PlacesSearchState.awaitingExpansion
          : PlacesSearchState.idle,
    )) {
      return;
    }

    setState(() {
      _expandingSearch = true;
      _searching = true;
    });
    final suggestions = await PlacesSearchService.expandSearch(
      query,
      cityService: context.read<ActiveCityProvider>().service,
    );
    if (!mounted) return;
    setState(() {
      _suggestions = suggestions
          .map((suggestion) => LocalPlace(
                id: suggestion.placeId,
                name: suggestion.mainText,
                category: 'other',
                district: suggestion.secondaryText,
                address: suggestion.description,
                latitude: suggestion.latitude ?? 0,
                longitude: suggestion.longitude ?? 0,
                source: suggestion.source,
              ))
          .toList(growable: false);
      _searching = false;
      _expandingSearch = false;
      _awaitingExpansion = false;
      _searched = true;
    });
  }

  Future<void> _selectPlace(LocalPlace place) async {
    LocalPlace resolved = place;
    if (!place.hasCoords) {
      setState(() => _searching = true);
      final r = await PlacesSearchService.resolve(place);
      if (!mounted) return;
      if (r == null) {
        setState(() => _searching = false);
        _snack('Impossible de localiser ce lieu', Colors.red);
        return;
      }
      resolved = r;
    }
    if (place.source == 'firestore' && place.id.isNotEmpty) {
      PlacesSearchService.incrementSearchCount(place.id);
    }

    if (_activeField == _ActiveField.departure) {
      setState(() {
        _departure = resolved;
        _depCtrl.text = resolved.name;
        _activeField = _ActiveField.none;
        _suggestions = [];
        _searching = false;
      });
      _depFocus.unfocus();
      _mapCtrl?.animateCamera(CameraUpdate.newLatLngZoom(resolved.latLng, 16));
    } else {
      setState(() {
        _destination = resolved;
        _destCtrl.text = resolved.name;
        _selectingDestinationOnMap = false;
        _activeField = _ActiveField.none;
        _suggestions = [];
        _searching = false;
        if (_phase == 3) _phase = 4;
      });
      _destFocus.unfocus();
      _mapCtrl?.animateCamera(CameraUpdate.newLatLngZoom(resolved.latLng, 16));
    }

    _updateMarkers();
    if (resolved.source != 'firestore') {
      await PlacesSearchService.autoLearn(
        resolved,
        cityService: context.read<ActiveCityProvider>().service,
      );
    }
    if (_departure != null && _destination != null) _calcRoute();
  }

  Future<void> _resolveMapCenter() async {
    if ((_phase != 1 && _phase != 3) ||
        (_phase == 3 && !_selectingDestinationOnMap) ||
        _activeField != _ActiveField.none) {
      return;
    }

    final center = _mapCenter;
    final proposedName = (_phase == 3 ? _destCtrl.text : _depCtrl.text).trim();
    final place = LocalPlace.fromExternal(
      name: proposedName.isEmpty
          ? 'Point sélectionné sur la carte'
          : proposedName,
      address: 'Position sélectionnée sur la carte',
      latitude: center.latitude,
      longitude: center.longitude,
      category: 'quartier',
      district: '',
      source: 'map',
    );
    setState(() {
      if (_phase == 3) {
        _destination = place;
        _destCtrl.text = place.name;
      } else {
        _departure = place;
        _depCtrl.text = place.name;
      }
    });
    _updateMarkers();
    if (_departure != null && _destination != null) _calcRoute();
  }

  Future<void> _calcRoute() async {
    if (_departure == null || _destination == null) return;
    if (!_departure!.hasCoords || !_destination!.hasCoords) return;
    setState(() => _routeLoading = true);
    final route = await GoogleRoutesService.getRouteModel(
      origin: _departure!.latLng,
      destination: _destination!.latLng,
    );
    if (!mounted) return;
    setState(() {
      _route = route;
      _routeLoading = false;
      _polylines = RoutePolylineBuilder.buildForClient(
          routeToClient: route, routeToDest: RouteModel.empty());
    });
    _routeAnim.forward(from: 0);
    _pulseCtrl
      ..reset()
      ..repeat(reverse: true);
    final pts = [
      _departure!.latLng,
      _destination!.latLng,
      ...route.points.take(3),
      ...route.points
          .skip(route.points.length > 3 ? route.points.length - 3 : 0)
    ];
    final bounds = RoutePolylineBuilder.boundsFor(pts);
    if (bounds != null) {
      _mapCtrl?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
    }
  }

  void _updateMarkers() {
    final m = <Marker>{};
    if (_departure != null && _departure!.hasCoords) {
      m.add(Marker(
        markerId: const MarkerId('dep'),
        position: _departure!.latLng,
        icon: _clientIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: InfoWindow(title: _departure!.name),
        zIndexInt: 2,
        anchor: const Offset(0.5, 1),
      ));
    }
    if (_destination != null && _destination!.hasCoords) {
      m.add(Marker(
        markerId: const MarkerId('dest'),
        position: _destination!.latLng,
        icon: _destIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: _destination!.name),
        zIndexInt: 1,
        anchor: const Offset(0.5, 1),
      ));
    }
    setState(() => _markers = m);
  }

  // ── Navigation entre phases ───────────────────────────────────────────────

  void _goBack() {
    // Confirmé sur appareil réel : `_activeField` (qui pilote l'overlay de
    // recherche plein écran) n'est remis à `none` que par une sélection de
    // lieu réussie — jamais par un retour arrière. Sans ce reset, revenir en
    // arrière depuis une phase où le focus était resté actif sur le champ de
    // recherche laisse l'overlay de suggestions s'afficher par-dessus une
    // phase qui n'a pourtant aucun champ de recherche (ex. phase 2),
    // masquant entièrement son contenu réel.
    if (_activeField != _ActiveField.none) {
      _activeField = _ActiveField.none;
      _depFocus.unfocus();
      _destFocus.unfocus();
    }
    if (_phase == 1) {
      Navigator.pop(context);
      return;
    }
    if (_phase == 2) {
      setState(() => _phase = 1);
      return;
    }
    if (_phase == 3) {
      setState(() => _phase = 2);
      return;
    }
    if (_phase == 4) {
      setState(() {
        _phase = 3;
        _destination = null;
        _destCtrl.clear();
        _route = RouteModel.empty();
        _polylines = {};
      });
      _updateMarkers();
      return;
    }
    if (_phase == 5) {
      setState(() => _phase = 4);
      return;
    }
    if (_phase == 6) {
      setState(() => _phase = 5);
      return;
    }
  }

  void _goToDeliverySearch() {
    if (_pickupContactNameCtrl.text.trim().isEmpty) {
      _snack('Veuillez saisir le nom de la personne qui remet le colis',
          Colors.orange);
      return;
    }
    if (_pickupContactPhoneCtrl.text.trim().isEmpty) {
      _snack('Veuillez saisir le numéro de téléphone de l\'expéditeur',
          Colors.orange);
      return;
    }
    setState(() {
      _phase = 3;
      _activeField = _ActiveField.none;
      _selectingDestinationOnMap = false;
    });
    if (_departure != null) {
      _mapCtrl
          ?.animateCamera(CameraUpdate.newLatLngZoom(_departure!.latLng, 14));
    }
  }

  void _goToColisDetails() {
    if (_recipientNameCtrl.text.trim().isEmpty) {
      _snack('Veuillez saisir le nom du destinataire', Colors.orange);
      return;
    }
    if (_recipientCtrl.text.trim().isEmpty) {
      _snack('Veuillez saisir le numéro de téléphone du destinataire',
          Colors.orange);
      return;
    }
    setState(() => _phase = 5);
  }

  void _goToConfirm() {
    final tarif = _tarifResult;
    if (tarif != null && !tarif.canOrder) {
      _snack(tarif.rejectionMessage ?? 'Livraison non disponible', Colors.red);
      return;
    }
    setState(() => _phase = 6);
    _pulseCtrl.repeat(reverse: true);
    if (_departure != null && _destination != null) {
      final pts = [
        _departure!.latLng,
        _destination!.latLng,
        ..._route.points.take(3)
      ];
      final bounds = RoutePolylineBuilder.boundsFor(pts);
      if (bounds != null) {
        _mapCtrl?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 120));
      }
    }
  }

  // ── Envoi commande — LOGIQUE MÉTIER INCHANGÉE ─────────────────────────────

  Future<void> _sendOrder() async {
    if (_departure == null || _destination == null) return;
    setState(() => _sending = true);
    final cityService = context.read<ActiveCityProvider>().service;

    try {
      var user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        final c = await FirebaseAuth.instance.signInAnonymously();
        user = c.user;
      }

      final price = _selectedPrice;
      final shoppingBudget =
          parseLivraisonShoppingBudget(_shoppingBudgetCtrl.text);
      final totalAmount = price + shoppingBudget;
      if (_payment == 'wallet' && _wallet < totalAmount) {
        _snack('Solde insuffisant ($_wallet FCFA)', Colors.red);
        setState(() => _sending = false);
        return;
      }

      String? clientName;
      String? clientPhone;
      if (user?.uid != null) {
        try {
          final profile = await FirebaseFirestore.instance
              .collection('clients')
              .doc(user!.uid)
              .get();
          clientName = profile.data()?['name'] as String?;
          clientPhone = profile.data()?['phone'] as String?;
        } catch (_) {}
      }

      final modeLabel = _deliveryMode == 'express' ? 'EXPRESS' : 'STANDARD';
      final catLabel = _categoryLabel;
      final colisDesc = _colisCtrl.text.trim();
      final poids = _poidsCtrl.text.trim();
      final descFull = [
        if (colisDesc.isNotEmpty) colisDesc,
        if (poids.isNotEmpty) 'Poids: $poids kg',
      ].join(' · ');
      final orderId = const Uuid().v4();
      final pkName = _pickupContactNameCtrl.text.trim();
      final pkPhone = _pickupContactPhoneCtrl.text.trim();
      final rcpName = _recipientNameCtrl.text.trim();
      final rcpPhone = _recipientCtrl.text.trim();
      final activeCityId = cityService.activeCityId;
      final zones = await Future.wait([
        cityService.resolveZone(
          latitude: _departure!.latitude,
          longitude: _departure!.longitude,
        ),
        cityService.resolveZone(
          latitude: _destination!.latitude,
          longitude: _destination!.longitude,
        ),
      ]);

      final order = OrderModel(
        id: orderId,
        description: descFull.isNotEmpty
            ? '[$modeLabel][$catLabel] $descFull'
            : '[$modeLabel][$catLabel] Livraison — ${_destination!.name}',
        budget: price,
        shoppingBudget: shoppingBudget,
        status: 'pending',
        latitude: _departure!.latitude,
        longitude: _departure!.longitude,
        deliveryAddress: _destination!.address,
        destLat: _destination!.latitude,
        destLng: _destination!.longitude,
        type: 'livraison',
        clientId: user?.uid,
        clientName: clientName,
        clientPhone: clientPhone,
        paymentMethod: _payment,
        isPaid: _payment == 'wallet',
        forSelf: true,
        deliveryMode: _deliveryMode,
        pickupContactName: pkName.isNotEmpty ? pkName : null,
        pickupContactPhone: pkPhone.isNotEmpty ? pkPhone : null,
        recipientName: rcpName.isNotEmpty ? rcpName : null,
        recipientPhone: rcpPhone.isNotEmpty ? rcpPhone : null,
        pickupCityId: activeCityId,
        deliveryCityId: activeCityId,
        pickupZoneId: zones[0]?.id,
        deliveryZoneId: zones[1]?.id,
        pickupCoordinateSource:
            livraisonOrderCoordinateSource(_departure!.source),
        deliveryCoordinateSource:
            livraisonOrderCoordinateSource(_destination!.source),
        gpsDetectedCityId: cityService.gpsDetectedCityId,
        activeCityId: activeCityId,
        citySelectionSource: cityService.citySelectionSource,
        cityResolutionStatus: cityService.cityResolutionStatus,
      );

      if (_payment == 'wallet') {
        final clientRef =
            FirebaseFirestore.instance.collection('clients').doc(user!.uid);
        final orderRef =
            FirebaseFirestore.instance.collection('orders').doc(order.id);
        await FirebaseFirestore.instance.runTransaction((tx) async {
          final snap = await tx.get(clientRef);
          final balance = (snap.data()?['wallet'] as num?)?.toInt() ?? 0;
          if (balance < totalAmount) throw Exception('SOLDE_INSUFFISANT');
          tx.update(clientRef, {'wallet': balance - totalAmount});
          tx.set(orderRef, order.toMap());
        });
        await FirestoreService().createOrder(order, alreadyCreated: true);
      } else {
        await FirestoreService().createOrder(order);
      }
      if (!mounted) return;
      Navigator.pushReplacement(
          context,
          MaterialPageRoute(
              builder: (_) => CustomerTrackingScreen(order: order)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _snack('Erreur : $e', Colors.red);
    }
  }

  void _snack(String msg, Color color) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));

  void _dismissKeyboard() {
    _depFocus.unfocus();
    _destFocus.unfocus();
    setState(() {
      _activeField = _ActiveField.none;
      _suggestions = [];
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark,
        child: Scaffold(
          backgroundColor: Colors.black,
          resizeToAvoidBottomInset: false,
          body: Stack(children: [
            // ── Carte plein écran ────────────────────────────────────────────
            Positioned.fill(
              child: GoogleMap(
                initialCameraPosition:
                    const CameraPosition(target: _abengourou, zoom: 13),
                markers: _markers,
                polylines: _polylines,
                myLocationEnabled: false,
                zoomControlsEnabled: false,
                mapToolbarEnabled: false,
                compassEnabled: false,
                onMapCreated: (c) => _mapCtrl = c,
                onCameraMove: (position) => _mapCenter = position.target,
                onCameraIdle: _resolveMapCenter,
                onTap: (_) => _dismissKeyboard(),
              ),
            ),

            if ((_phase == 1 || (_phase == 3 && _selectingDestinationOnMap)) &&
                _activeField == _ActiveField.none)
              const IgnorePointer(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 112),
                    child: _PickupMapPin(),
                  ),
                ),
              ),

            // ── Top bar flottante ────────────────────────────────────────────
            Positioned(
              top: topPad + 8,
              left: 16,
              right: 16,
              child: _buildTopBar(),
            ),

            // ── Bouton GPS ───────────────────────────────────────────────────
            // Phase 1 uniquement : _getGPS() écrase _departure (le point de
            // récupération) sans aucun retour visuel dans les phases 2-6 —
            // affiché partout, il permettait de modifier silencieusement le
            // point déjà confirmé depuis n'importe quelle étape ultérieure.
            if (_activeField == _ActiveField.none &&
                (_phase == 1 || _phase == 3))
              Positioned(
                right: 16,
                bottom: _panelMinHeight(bottomPad) + 12,
                child: _CircleBtn(
                  icon: Icons.my_location_rounded,
                  onTap: () => _getGPS(_phase == 3
                      ? _ActiveField.destination
                      : _ActiveField.departure),
                ),
              ),

            // ── Panel bas flottant ───────────────────────────────────────────
            Positioned(
              bottom: keyboardHeight,
              left: 0,
              right: 0,
              child: _buildBottomPanel(bottomPad),
            ),

            // ── Overlay suggestions (par-dessus tout) ───────────────────────
            if (_activeField != _ActiveField.none)
              Positioned.fill(
                child: _buildSuggestionsOverlay(topPad, keyboardHeight),
              ),
          ]),
        ),
      ),
    );
  }

  double _panelMinHeight(double bottomPad) {
    const base = <int, double>{1: 220, 2: 320, 3: 200, 4: 300, 5: 360, 6: 380};
    return (base[_phase] ?? 220) + bottomPad;
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    const titles = [
      '📍 Où récupérons-nous ?',
      '👤 Qui remet le colis ?',
      '📍 Où livrons-nous ?',
      '👤 Qui reçoit le colis ?',
      '📦 Détails du colis',
      '🚚 Récapitulatif',
    ];

    return Row(children: [
      GestureDetector(
        onTap: _goBack,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: AppShadow.md,
          ),
          child: const Icon(Icons.arrow_back_rounded,
              size: 20, color: AppColors.text),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: AppShadow.sm,
          ),
          child: Row(children: [
            Expanded(
              child: Text(titles[_phase - 1],
                  style: GoogleFonts.urbanist(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text),
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            // Progress dots
            Row(
              children: List.generate(
                  6,
                  (i) => AnimatedContainer(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        margin: const EdgeInsets.only(left: 3),
                        width: i < _phase ? 14 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: i < _phase
                              ? AppColors.primary
                              : AppColors.divider,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      )),
            ),
          ]),
        ),
      ),
    ]);
  }

  // ── Panel bas ─────────────────────────────────────────────────────────────

  Widget _buildBottomPanel(double bottomPad) {
    final screenH = MediaQuery.of(context).size.height;
    final topPad = MediaQuery.of(context).padding.top;
    final keyboardH = MediaQuery.of(context).viewInsets.bottom;
    final maxPanelH = screenH - topPad - 72 - keyboardH;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) => SlideTransition(
        position:
            Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(anim),
        child: FadeTransition(opacity: anim, child: child),
      ),
      child: KeyedSubtree(
        key: ValueKey(_phase),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxPanelH),
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              boxShadow: [
                BoxShadow(
                    color: Color(0x1A000000),
                    blurRadius: 32,
                    offset: Offset(0, -8)),
                BoxShadow(
                    color: Color(0x08000000),
                    blurRadius: 8,
                    offset: Offset(0, -2)),
              ],
            ),
            child: _buildPanelContent(bottomPad),
          ),
        ),
      ),
    );
  }

  Widget _buildPanelContent(double bottomPad) {
    switch (_phase) {
      case 1:
        return _buildPickupSearchPanel(bottomPad);
      case 2:
        return _buildPickupContactPanel(bottomPad);
      case 3:
        return _buildDeliverySearchPanel(bottomPad);
      case 4:
        return _buildDeliveryContactPanel(bottomPad);
      case 5:
        return _buildColisDetailsPanel(bottomPad);
      case 6:
        return _buildConfirmPanel(bottomPad);
      default:
        return const SizedBox();
    }
  }

  // ── Phase 1 : sélection point récupération ───────────────────────────────

  Widget _buildPickupSearchPanel(double bottomPad) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, bottomPad + 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _handle(),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Où récupérons-nous votre colis ?',
                  style: GoogleFonts.urbanist(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: AppColors.text)),
              const SizedBox(height: 4),
              Text('Recherchez une adresse ou déplacez la carte.',
                  style: GoogleFonts.urbanist(
                      fontSize: 12, color: AppColors.textMuted)),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _buildSearchField(
          ctrl: _depCtrl,
          focus: _depFocus,
          hint: 'Chercher une adresse, un quartier…',
          icon: Icons.radio_button_checked_rounded,
          iconColor: const Color(0xFF22C55E),
          field: _ActiveField.departure,
        ),
        const SizedBox(height: 10),
        _pickupLocationCard(),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            _pickupQuickChip('Ma position', Icons.my_location_rounded, _getGPS),
            _pickupQuickChip('Lieux récents', Icons.history_rounded, () {
              _depFocus.requestFocus();
            }),
          ]),
        ),
        const SizedBox(height: 14),
        _pickupConfirmButton(
            _departure != null && _departure!.hasCoords && !_gpsLoading),
      ]),
    );
  }

  // ── Phase 2 : contact expéditeur ─────────────────────────────────────────

  Widget _buildPickupContactPanel(double bottomPad) {
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(20, 14, 20, bottomPad + 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _handle(),
        const SizedBox(height: 10),

        // Illustration
        _contactIllustration(isPickup: true),
        const SizedBox(height: 12),

        // Adresse sélectionnée
        _addressChip(
          name: _departure?.name ?? '—',
          label: 'Point de récupération',
          color: const Color(0xFF22C55E),
          icon: Icons.radio_button_checked_rounded,
          onEdit: () => setState(() => _phase = 1),
        ),
        const SizedBox(height: 16),

        _premiumField(
            ctrl: _pickupContactNameCtrl,
            hint: 'Nom complet de la personne',
            icon: Icons.person_outline_rounded,
            type: TextInputType.name,
            textInputAction: TextInputAction.next,
            nextFocusNode: _pickupContactPhoneFocus),
        const SizedBox(height: 10),
        _premiumField(
            ctrl: _pickupContactPhoneCtrl,
            hint: '07 XX XX XX XX',
            icon: Icons.phone_outlined,
            type: TextInputType.phone,
            focusNode: _pickupContactPhoneFocus),
        const SizedBox(height: 20),

        _primaryBtn(
          label: 'Choisir le point de livraison',
          onTap: _goToDeliverySearch,
        ),
      ]),
    );
  }

  // ── Phase 3 : sélection point livraison ──────────────────────────────────

  Widget _buildDeliverySearchPanel(double bottomPad) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, bottomPad + 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _handle(),
        const SizedBox(height: 14),
        _buildSearchField(
          ctrl: _destCtrl,
          focus: _destFocus,
          hint: 'Chercher une adresse, un quartier…',
          icon: Icons.place_rounded,
          iconColor: AppColors.primary,
          field: _ActiveField.destination,
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            _pickupQuickChip(
              'Ma position',
              Icons.my_location_rounded,
              () => _getGPS(_ActiveField.destination),
            ),
            _pickupQuickChip(
              'Choisir sur la carte',
              Icons.map_outlined,
              () {
                _dismissKeyboard();
                setState(() => _selectingDestinationOnMap = true);
              },
            ),
          ]),
        ),
        if (_destination != null) ...[
          const SizedBox(height: 12),
          _primaryBtn(
            label: 'Confirmer ce lieu',
            onTap: () => setState(() => _phase = 4),
          ),
        ],
      ]),
    );
  }

  // ── Phase 4 : contact destinataire ───────────────────────────────────────

  Widget _buildDeliveryContactPanel(double bottomPad) {
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(20, 14, 20, bottomPad + 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _handle(),
        const SizedBox(height: 10),

        // Illustration
        _contactIllustration(isPickup: false),
        const SizedBox(height: 12),

        _addressChip(
          name: _destination?.name ?? '—',
          label: 'Point de livraison',
          color: AppColors.primary,
          icon: Icons.place_rounded,
          onEdit: () {
            setState(() {
              _phase = 3;
              _destination = null;
              _destCtrl.clear();
              _route = RouteModel.empty();
              _polylines = {};
            });
            _updateMarkers();
          },
        ),
        const SizedBox(height: 16),

        _premiumField(
            ctrl: _recipientNameCtrl,
            hint: 'Nom complet du destinataire',
            icon: Icons.person_outline_rounded,
            type: TextInputType.name,
            textInputAction: TextInputAction.next,
            nextFocusNode: _recipientPhoneFocus),
        const SizedBox(height: 10),
        _premiumField(
            ctrl: _recipientCtrl,
            hint: '07 XX XX XX XX',
            icon: Icons.phone_outlined,
            type: TextInputType.phone,
            focusNode: _recipientPhoneFocus),
        const SizedBox(height: 20),

        _primaryBtn(label: 'Continuer', onTap: _goToColisDetails),
      ]),
    );
  }

  // ── Phase 5 : détails du colis ───────────────────────────────────────────

  Widget _buildColisDetailsPanel(double bottomPad) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 14, 20, bottomPad + 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _handle(),
        const SizedBox(height: 14),

        // Sélection type en grille de cards
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.95,
          children: _catItems.map((cat) {
            final sel = _category == cat.$1;
            final parts = cat.$2.split(' ');
            final emoji = parts.first;
            final label = parts.skip(1).join(' ');
            return ScaleTap(
              onTap: () => setState(() => _category = cat.$1),
              scaleDown: 0.95,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  color: sel ? cat.$3.withValues(alpha: 0.09) : AppColors.bg,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: sel ? cat.$3 : AppColors.divider,
                    width: sel ? 2.0 : 1.0,
                  ),
                  boxShadow: sel
                      ? [
                          BoxShadow(
                              color: cat.$3.withValues(alpha: 0.15),
                              blurRadius: 10)
                        ]
                      : null,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(emoji, style: const TextStyle(fontSize: 26)),
                    const SizedBox(height: 6),
                    Text(
                      label,
                      style: GoogleFonts.urbanist(
                        fontSize: 11,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                        color: sel ? cat.$3 : AppColors.text,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),

        const SizedBox(height: 16),

        _premiumField(
            ctrl: _colisCtrl,
            hint: 'Description (optionnel)',
            icon: Icons.edit_note_rounded,
            maxLines: 2),
        const SizedBox(height: 10),

        // Champ poids optionnel
        Container(
          decoration: BoxDecoration(
            color: AppColors.bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: TextField(
            controller: _poidsCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: GoogleFonts.urbanist(fontSize: 14, color: AppColors.text),
            decoration: InputDecoration(
              hintText: 'Poids en kg (optionnel)',
              hintStyle: GoogleFonts.urbanist(
                  fontSize: 13, color: AppColors.textLight),
              prefixIcon: const Padding(
                padding: EdgeInsets.only(left: 12, right: 8),
                child: Icon(Icons.scale_rounded,
                    color: AppColors.textMuted, size: 18),
              ),
              prefixIconConstraints: const BoxConstraints(),
              suffixText: 'kg',
              suffixStyle: GoogleFonts.urbanist(
                  fontSize: 13,
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            ),
          ),
        ),

        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: AppColors.bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: TextField(
            controller: _shoppingBudgetCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
            style: GoogleFonts.urbanist(fontSize: 14, color: AppColors.text),
            decoration: const InputDecoration(
              hintText: 'Budget d’achat (optionnel)',
              helperText: 'Montant des achats, hors frais de livraison',
              prefixIcon: Icon(Icons.shopping_basket_outlined,
                  color: AppColors.textMuted, size: 18),
              suffixText: 'FCFA',
              border: InputBorder.none,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            ),
          ),
        ),

        const SizedBox(height: 20),
        _primaryBtn(label: 'Voir les prix', onTap: _goToConfirm),
      ]),
    );
  }

  // ── Phase 5 : confirmation ────────────────────────────────────────────────

  Widget _buildConfirmPanel(double bottomPad) {
    final shoppingBudget =
        parseLivraisonShoppingBudget(_shoppingBudgetCtrl.text);
    final hasFunds = _wallet >= _selectedPrice + shoppingBudget;
    final modeColor = _deliveryMode == 'express'
        ? AppColors.primary
        : const Color(0xFF22C55E);

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 14, 20, bottomPad + 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _handle(),
        const SizedBox(height: 14),

        // Récap adresses
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.bg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(children: [
            _routeRow(
              icon: Icons.radio_button_checked_rounded,
              color: const Color(0xFF22C55E),
              label: 'Récupération',
              name: _departure?.name ?? '—',
              contact: _pickupContactNameCtrl.text.trim(),
              phone: _pickupContactPhoneCtrl.text.trim(),
              onEdit: () => setState(() => _phase = 2),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child:
                  Container(width: 1.5, height: 18, color: AppColors.divider),
            ),
            _routeRow(
              icon: Icons.place_rounded,
              color: AppColors.primary,
              label: 'Livraison',
              name: _destination?.name ?? '—',
              contact: _recipientNameCtrl.text.trim(),
              phone: _recipientCtrl.text.trim(),
              onEdit: () => setState(() => _phase = 4),
            ),
          ]),
        ),

        const SizedBox(height: 10),

        // Résumé type colis
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.divider),
          ),
          child: Row(children: [
            Text(_categoryLabel,
                style: GoogleFonts.urbanist(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text)),
            if (_poidsCtrl.text.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text('· ${_poidsCtrl.text} kg',
                  style: GoogleFonts.urbanist(
                      fontSize: 12, color: AppColors.textMuted)),
            ],
            const Spacer(),
            GestureDetector(
              onTap: () => setState(() => _phase = 5),
              child: Text('Modifier',
                  style: GoogleFonts.urbanist(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary)),
            ),
          ]),
        ),

        const SizedBox(height: 10),

        // Stats distance + ETA
        if (_route.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(children: [
              Expanded(
                  child: _miniStat(Icons.straighten_rounded, 'Distance',
                      _route.distanceText, const Color(0xFF1565C0))),
              Container(width: 1, height: 26, color: AppColors.divider),
              Expanded(
                  child: _miniStat(Icons.access_time_rounded, 'Délai',
                      _etaRange, const Color(0xFF22C55E))),
              Container(width: 1, height: 26, color: AppColors.divider),
              Expanded(
                  child: _miniStat(
                      _deliveryMode == 'express'
                          ? Icons.rocket_launch_rounded
                          : Icons.electric_bike_rounded,
                      'Mode',
                      _deliveryMode == 'express' ? 'Express' : 'Standard',
                      modeColor)),
            ]),
          ),

        const SizedBox(height: 12),

        // Mode Standard / Express
        _buildModeCard(
          mode: 'standard',
          icon: Icons.electric_bike_rounded,
          title: 'STANDARD',
          subtitle: 'Économique · groupage possible',
          etaText: _route.etaMinutes > 0
              ? '${_route.etaMinutes + 15}–${_route.etaMinutes + 40} min'
              : '30–60 min',
          price: _standardPrice,
          iconColor: const Color(0xFF22C55E),
        ),
        const SizedBox(height: 8),
        _buildModeCard(
          mode: 'express',
          icon: Icons.rocket_launch_rounded,
          title: 'EXPRESS',
          subtitle: 'Prioritaire · livreur dédié',
          etaText: _route.etaMinutes > 0
              ? '${(_route.etaMinutes * 0.8).ceil()}–${_route.etaMinutes + 5} min'
              : '10–20 min',
          price: _expressPrice,
          iconColor: AppColors.primary,
          badge: 'Prioritaire',
        ),

        const SizedBox(height: 12),

        // Prix total
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              modeColor.withValues(alpha: 0.08),
              modeColor.withValues(alpha: 0.02),
            ]),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: modeColor.withValues(alpha: 0.22)),
          ),
          child: Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Frais de livraison',
                      style: GoogleFonts.urbanist(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.text)),
                  if (_tarifResult?.isNight == true)
                    Text('🌙 Tarif nuit',
                        style: GoogleFonts.urbanist(
                            fontSize: 11, color: AppColors.textMuted)),
                ])),
            Text(_selectedPrice > 0 ? '$_selectedPrice FCFA' : '—',
                style: GoogleFonts.urbanist(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: modeColor)),
          ]),
        ),

        if (shoppingBudget > 0) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.divider),
            ),
            child: Column(children: [
              Row(children: [
                const Expanded(child: Text('Budget d’achat')),
                Text('$shoppingBudget FCFA'),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: Text('Total à payer',
                      style: GoogleFonts.urbanist(fontWeight: FontWeight.w700)),
                ),
                Text('${_selectedPrice + shoppingBudget} FCFA',
                    style: GoogleFonts.urbanist(fontWeight: FontWeight.w800)),
              ]),
            ]),
          ),
        ],

        const SizedBox(height: 14),

        // Paiement
        Text('Mode de paiement',
            style: GoogleFonts.urbanist(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.text)),
        const SizedBox(height: 10),

        _payRow(
            icon: Icons.money_rounded,
            color: _codEnabled ? const Color(0xFF22C55E) : Colors.grey,
            label: 'Espèces',
            sub: _codEnabled
                ? 'Payer au livreur à la livraison'
                : 'Désactivé — 3 fausses commandes détectées',
            value: 'cash',
            disabled: !_codEnabled),
        const SizedBox(height: 8),
        _payRow(
            icon: Icons.smartphone_rounded,
            color: const Color(0xFF1565C0),
            label: 'Mobile Money',
            sub: 'Orange Money · MTN MoMo · Wave',
            value: 'mobile_money'),
        const SizedBox(height: 8),
        _payRow(
          icon: Icons.account_balance_wallet_rounded,
          color: hasFunds ? const Color(0xFF6A1B9A) : Colors.grey,
          label: hasFunds ? 'Wallet · $_wallet FCFA' : 'Solde insuffisant',
          sub: hasFunds ? 'Paiement immédiat' : 'Rechargez votre wallet',
          value: 'wallet',
          disabled: !hasFunds,
        ),

        const SizedBox(height: 18),

        // Bouton commander
        ScaleTap(
          onTap: (_sending || _routeLoading) ? null : _sendOrder,
          child: AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, child) => Transform.scale(
              scale: 1.0 + _pulseCtrl.value * 0.012,
              child: child,
            ),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                gradient: (_sending || _routeLoading)
                    ? null
                    : const LinearGradient(
                        colors: [
                          Color(0xFFE65100),
                          AppColors.primary,
                          Color(0xFFFF8C42)
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                color: (_sending || _routeLoading) ? AppColors.divider : null,
                borderRadius: BorderRadius.circular(18),
                boxShadow: (_sending || _routeLoading)
                    ? null
                    : [
                        BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.40),
                            blurRadius: 20,
                            offset: const Offset(0, 8)),
                      ],
              ),
              child: _sending
                  ? const Center(
                      child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5)))
                  : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.delivery_dining_rounded,
                          color: Colors.white, size: 24),
                      const SizedBox(width: 10),
                      Text('Commander un livreur',
                          style: GoogleFonts.urbanist(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Colors.white)),
                    ]),
            ),
          ),
        ),

        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.lock_rounded, size: 11, color: AppColors.textLight),
          const SizedBox(width: 4),
          Text('Vos données sont sécurisées',
              style: GoogleFonts.urbanist(
                  fontSize: 11, color: AppColors.textLight)),
        ]),
      ]),
    );
  }

  // ── Mode Standard / Express ───────────────────────────────────────────────

  Widget _buildModeCard({
    required String mode,
    required IconData icon,
    required String title,
    required String subtitle,
    required String etaText,
    required int price,
    required Color iconColor,
    String? badge,
  }) {
    final sel = _deliveryMode == mode;
    return ScaleTap(
      onTap: () => setState(() => _deliveryMode = mode),
      scaleDown: 0.97,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: sel ? iconColor.withValues(alpha: 0.06) : AppColors.bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: sel ? iconColor : AppColors.divider,
            width: sel ? 2 : 1,
          ),
          boxShadow: sel
              ? [
                  BoxShadow(
                      color: iconColor.withValues(alpha: 0.12), blurRadius: 10)
                ]
              : null,
        ),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: sel
                  ? iconColor.withValues(alpha: 0.14)
                  : AppColors.divider.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon,
                color: sel ? iconColor : AppColors.textLight, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(title,
                    style: GoogleFonts.urbanist(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: sel ? iconColor : AppColors.text)),
                if (badge != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(badge,
                        style: GoogleFonts.urbanist(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: iconColor)),
                  ),
                ],
              ]),
              Text(subtitle,
                  style: GoogleFonts.urbanist(
                      fontSize: 11, color: AppColors.textMuted)),
              Row(children: [
                const Icon(Icons.access_time_rounded,
                    size: 11, color: Colors.grey),
                const SizedBox(width: 3),
                Text(etaText,
                    style: GoogleFonts.urbanist(
                        fontSize: 10,
                        color: AppColors.textLight,
                        fontWeight: FontWeight.w600)),
              ]),
            ],
          )),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(price > 0 ? '$price F' : '—',
                style: GoogleFonts.urbanist(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: sel ? iconColor : AppColors.text)),
            const SizedBox(height: 4),
            Icon(
              sel
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: sel ? iconColor : AppColors.textLight,
              size: 20,
            ),
          ]),
        ]),
      ),
    );
  }

  // ── Suggestions overlay ───────────────────────────────────────────────────

  Widget _buildSuggestionsOverlay(double topPad, double keyboardHeight) {
    return Container(
      color: Colors.white,
      margin: EdgeInsets.only(top: topPad + 60),
      // Scaffold a resizeToAvoidBottomInset:false, donc cette zone n'est
      // jamais compensée automatiquement pour le clavier (contrairement au
      // panel bas, décalé manuellement) — sans ce padding, "Aucun lieu
      // trouvé" et le bas de la liste de suggestions se retrouvaient
      // visuellement cachés derrière le clavier, toujours présents mais
      // invisibles/hors de portée pour l'utilisateur.
      padding: EdgeInsets.only(bottom: keyboardHeight),
      child: Column(children: [
        if (_searching)
          LinearProgressIndicator(
            color: AppColors.primary,
            backgroundColor: AppColors.primary.withValues(alpha: 0.10),
            minHeight: 2,
          ),
        // Active search field header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: _buildSearchField(
            ctrl: _activeField == _ActiveField.departure ? _depCtrl : _destCtrl,
            focus:
                _activeField == _ActiveField.departure ? _depFocus : _destFocus,
            hint: 'Chercher une adresse…',
            icon: _activeField == _ActiveField.departure
                ? Icons.radio_button_checked_rounded
                : Icons.place_rounded,
            iconColor: _activeField == _ActiveField.departure
                ? const Color(0xFF22C55E)
                : AppColors.primary,
            field: _activeField,
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildResultsList()),
      ]),
    );
  }

  Widget _buildResultsList() {
    final hasQuery = (_activeField == _ActiveField.departure
                ? _depCtrl.text
                : _destCtrl.text)
            .trim()
            .length >=
        2;

    if (!hasQuery && !_searched) return _buildQuickPlaces();
    if (_searched && !_searching && _suggestions.isEmpty) {
      final query = (_activeField == _ActiveField.departure
              ? _depCtrl.text
              : _destCtrl.text)
          .trim();
      final showExpansion = shouldShowLivraisonSearchExpansion(
        query: query,
        searched: _searched,
        searching: _searching,
        hasResults: _suggestions.isNotEmpty,
        searchState: _awaitingExpansion
            ? PlacesSearchState.awaitingExpansion
            : PlacesSearchState.idle,
      );
      return Center(
          child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.search_off_rounded,
              size: 56, color: AppColors.divider),
          const SizedBox(height: 12),
          Text('Aucun lieu trouvé',
              style: GoogleFonts.urbanist(
                  fontSize: 15, color: AppColors.textMuted)),
          const SizedBox(height: 4),
          Text('Essayez : "Cafétou", "CHU", "Marché"…',
              style: GoogleFonts.urbanist(
                  fontSize: 12, color: AppColors.textLight)),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              _pickupQuickChip(
                'Utiliser ma position actuelle',
                Icons.my_location_rounded,
                () => _getGPS(_activeField),
              ),
              _pickupQuickChip(
                'Choisir un point sur la carte',
                Icons.map_outlined,
                () {
                  final target = _activeField;
                  _dismissKeyboard();
                  if (target == _ActiveField.destination) {
                    setState(() => _selectingDestinationOnMap = true);
                  }
                },
              ),
            ],
          ),
          if (showExpansion) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('expand-place-search-button'),
              onPressed: _expandingSearch ? null : _expandSearch,
              icon: const Icon(Icons.travel_explore_rounded),
              label: const Text('Élargir la recherche'),
            ),
            const SizedBox(height: 4),
            Text(
              'Cette action interroge un service externe.',
              style: GoogleFonts.urbanist(
                fontSize: 11,
                color: AppColors.textLight,
              ),
            ),
          ],
        ],
      ));
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _suggestions.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, indent: 60, color: Color(0xFFE2E8F0)),
      itemBuilder: (_, i) => _PlaceTile(
          place: _suggestions[i], onTap: () => _selectPlace(_suggestions[i])),
    );
  }

  Widget _buildQuickPlaces() {
    final cityProvider = context.watch<ActiveCityProvider>();
    final cityName = activeLivraisonCityName(cityProvider);
    if (cityName.isEmpty ||
        _popularPlacesCityId != cityProvider.activeCityId ||
        _popularPlaces.isEmpty) {
      return const SizedBox.shrink();
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Text(
            'Lieux populaires à $cityName',
            style: GoogleFonts.urbanist(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textMuted,
                letterSpacing: 0.3),
          ),
        ),
        ..._popularPlaces.map((place) => ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.place_rounded,
                    color: AppColors.primary, size: 20),
              ),
              title: Text(place.name,
                  style: GoogleFonts.urbanist(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              subtitle: Text(place.address,
                  style: GoogleFonts.urbanist(
                      fontSize: 12, color: AppColors.textMuted)),
              onTap: () => _selectPlace(place),
            )),
      ],
    );
  }

  // ── Helpers UI ────────────────────────────────────────────────────────────

  // ── Illustration moderne pour phases contact ──────────────────────────────

  Widget _contactIllustration({required bool isPickup}) {
    final colorA = isPickup ? const Color(0xFF22C55E) : AppColors.primary;
    final iconA =
        isPickup ? Icons.person_rounded : Icons.local_shipping_rounded;
    final iconB = isPickup ? Icons.inventory_2_rounded : Icons.person_rounded;
    return SizedBox(
      height: 80,
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        // Gauche
        Stack(clipBehavior: Clip.none, children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
                color: colorA.withValues(alpha: 0.12), shape: BoxShape.circle),
          ),
          Positioned.fill(
              child: Center(
            child: Icon(iconA, color: colorA, size: 30),
          )),
        ]),

        // Flèche
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.arrow_forward_rounded,
                color: AppColors.divider, size: 22),
          ]),
        ),

        // Droite
        Stack(clipBehavior: Clip.none, children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
          ),
          Positioned.fill(
              child: Center(
            child: Icon(iconB, color: AppColors.primary, size: 28),
          )),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: const Icon(Icons.check_rounded,
                  color: Colors.white, size: 11),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _handle() => Center(
          child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
            color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
      ));

  Widget _addressChip({
    required String name,
    required String label,
    required Color color,
    required IconData icon,
    required VoidCallback onEdit,
  }) {
    return GestureDetector(
      onTap: onEdit,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 15),
          ),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: GoogleFonts.urbanist(
                      fontSize: 10, color: color, fontWeight: FontWeight.w600)),
              Text(name,
                  style: GoogleFonts.urbanist(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text),
                  overflow: TextOverflow.ellipsis),
            ],
          )),
          Icon(Icons.edit_rounded, size: 14, color: color),
        ]),
      ),
    );
  }

  Widget _pickupLocationCard() {
    final isLoading = _gpsLoading;
    final address = _departure;
    return Semantics(
      label: isLoading
          ? 'Recherche de la position en cours'
          : 'Point de récupération sélectionné',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
        ),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: isLoading
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.location_on_rounded,
                    color: AppColors.primary, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    isLoading
                        ? 'Localisation en cours…'
                        : 'Point de récupération',
                    style: GoogleFonts.urbanist(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary)),
                const SizedBox(height: 2),
                Text(
                  isLoading
                      ? 'Nous vérifions l’adresse sélectionnée'
                      : address?.address ??
                          'Déplacez la carte ou recherchez une adresse',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.urbanist(
                      fontSize: 12, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _pickupQuickChip(String label, IconData icon, VoidCallback onTap) {
    return ActionChip(
      avatar: Icon(icon, size: 16, color: AppColors.primary),
      label: Text(label,
          style: GoogleFonts.urbanist(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.text)),
      onPressed: onTap,
      backgroundColor: Colors.white,
      side: const BorderSide(color: AppColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }

  Widget _pickupConfirmButton(bool enabled) {
    final label = _gpsLoading
        ? 'Vérification de l’adresse…'
        : 'Confirmer le point de récupération';
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: ScaleTap(
        onTap: enabled ? () => setState(() => _phase = 2) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: enabled ? null : AppColors.divider,
            gradient: enabled
                ? const LinearGradient(
                    colors: [Color(0xFFE65100), AppColors.primary],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  )
                : null,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (!enabled && _gpsLoading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            else
              const Icon(Icons.check_circle_outline_rounded,
                  color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(label,
                style: GoogleFonts.urbanist(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ]),
        ),
      ),
    );
  }

  Widget _buildSearchField({
    required TextEditingController ctrl,
    required FocusNode focus,
    required String hint,
    required IconData icon,
    required Color iconColor,
    required _ActiveField field,
    bool autoFocus = false,
  }) {
    final isActive = _activeField == field;
    return GestureDetector(
      onTap: () {
        setState(() {
          _activeField = field;
          _searched = false;
        });
        focus.requestFocus();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? AppColors.primary : AppColors.border,
            width: isActive ? 1.5 : 1,
          ),
          boxShadow: isActive ? AppShadow.sm : AppShadow.xs,
        ),
        child: Row(children: [
          Icon(icon, color: iconColor, size: 18),
          const SizedBox(width: 10),
          Expanded(
              child: TextField(
            controller: ctrl,
            focusNode: focus,
            autofocus: autoFocus,
            style: GoogleFonts.urbanist(fontSize: 13, color: AppColors.text),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: GoogleFonts.urbanist(
                  fontSize: 13, color: AppColors.textLight),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: _onSearchChanged,
            onTap: () {
              setState(() {
                _activeField = field;
                _searched = false;
              });
            },
          )),
          if (ctrl.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                ctrl.clear();
                setState(() {
                  _suggestions = [];
                  _searched = false;
                });
              },
              child: const Icon(Icons.close_rounded,
                  size: 16, color: AppColors.textLight),
            ),
        ]),
      ),
    );
  }

  Widget _premiumField({
    required TextEditingController ctrl,
    required String hint,
    required IconData icon,
    TextInputType? type,
    int maxLines = 1,
    TextInputAction textInputAction = TextInputAction.done,
    FocusNode? focusNode,
    FocusNode? nextFocusNode,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: TextField(
        controller: ctrl,
        focusNode: focusNode,
        keyboardType: type,
        maxLines: maxLines,
        textInputAction: textInputAction,
        // La flèche "Suivant" du clavier doit avancer le focus vers le champ
        // suivant explicite, pas juste fermer le clavier — et pas via
        // FocusScope.nextFocus() générique, qui ne traverse pas correctement
        // les Padding/SizedBox intermédiaires de cette Column (vérifié sur
        // appareil réel : le focus se perdait sans jamais atteindre le champ
        // téléphone).
        onSubmitted: (_) => nextFocusNode != null
            ? nextFocusNode.requestFocus()
            : FocusScope.of(context).unfocus(),
        style: GoogleFonts.urbanist(fontSize: 14, color: AppColors.text),
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle:
              GoogleFonts.urbanist(fontSize: 13, color: AppColors.textLight),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 12, right: 8),
            child: Icon(icon, color: AppColors.textMuted, size: 20),
          ),
          prefixIconConstraints: const BoxConstraints(),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        ),
      ),
    );
  }

  Widget _primaryBtn({required String label, required VoidCallback? onTap}) {
    return ScaleTap(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFE65100), AppColors.primary, Color(0xFFFF8C42)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            )
          ],
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(label,
              style: GoogleFonts.urbanist(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
          const SizedBox(width: 8),
          const Icon(Icons.arrow_forward_rounded,
              color: Colors.white, size: 22),
        ]),
      ),
    );
  }

  Widget _routeRow({
    required IconData icon,
    required Color color,
    required String label,
    required String name,
    required String contact,
    required String phone,
    required VoidCallback onEdit,
  }) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
        child: Icon(icon, color: color, size: 14),
      ),
      const SizedBox(width: 10),
      Expanded(
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: GoogleFonts.urbanist(
                  fontSize: 10,
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600)),
          Text(name,
              style: GoogleFonts.urbanist(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.text),
              overflow: TextOverflow.ellipsis),
          if (contact.isNotEmpty)
            Text('👤 $contact${phone.isNotEmpty ? ' · $phone' : ''}',
                style: GoogleFonts.urbanist(
                    fontSize: 11, color: AppColors.textMuted)),
        ],
      )),
      GestureDetector(
        onTap: onEdit,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.divider),
          ),
          child: Text('Modifier',
              style: GoogleFonts.urbanist(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.text)),
        ),
      ),
    ]);
  }

  Widget _miniStat(IconData icon, String label, String value, Color color) {
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(height: 2),
      Text(label,
          style: GoogleFonts.urbanist(fontSize: 9, color: AppColors.textMuted)),
      Text(value,
          style: GoogleFonts.urbanist(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.text)),
    ]);
  }

  Widget _payRow({
    required IconData icon,
    required Color color,
    required String label,
    required String sub,
    required String value,
    bool disabled = false,
  }) {
    final sel = _payment == value;
    return ScaleTap(
      onTap: disabled ? null : () => setState(() => _payment = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: sel ? color.withValues(alpha: 0.05) : AppColors.bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: sel ? color : AppColors.divider,
            width: sel ? 2 : 1,
          ),
        ),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: GoogleFonts.urbanist(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: disabled ? AppColors.textLight : AppColors.text)),
              Text(sub,
                  style: GoogleFonts.urbanist(
                      fontSize: 11, color: AppColors.textMuted)),
            ],
          )),
          Icon(
            sel
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            color: sel ? color : AppColors.textLight,
            size: 20,
          ),
        ]),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DISPOSE
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void dispose() {
    _routeAnim.dispose();
    _pulseCtrl.dispose();
    _walletSub?.cancel();
    _debounce?.cancel();
    _depCtrl.dispose();
    _destCtrl.dispose();
    _colisCtrl.dispose();
    _recipientCtrl.dispose();
    _pickupContactNameCtrl.dispose();
    _pickupContactPhoneCtrl.dispose();
    _recipientNameCtrl.dispose();
    _poidsCtrl.dispose();
    _shoppingBudgetCtrl.dispose();
    _depFocus.removeListener(_onDepFocusChange);
    _destFocus.removeListener(_onDestFocusChange);
    _depFocus.dispose();
    _destFocus.dispose();
    _pickupContactPhoneFocus.dispose();
    _recipientPhoneFocus.dispose();
    _mapCtrl?.dispose();
    super.dispose();
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// WIDGETS LOCAUX
// ═════════════════════════════════════════════════════════════════════════════

class _PickupMapPin extends StatelessWidget {
  const _PickupMapPin();

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(color: Color(0x26000000), blurRadius: 12),
              ],
            ),
            child: Text('Déplacez la carte pour ajuster',
                style: GoogleFonts.urbanist(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text)),
          ),
          const SizedBox(height: 6),
          const Icon(Icons.location_on_rounded,
              size: 46, color: AppColors.primary),
        ],
      );
}

class _PlaceTile extends StatelessWidget {
  final LocalPlace place;
  final VoidCallback onTap;
  const _PlaceTile({required this.place, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: place.color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(place.icon, color: place.color, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(place.name,
                    style: GoogleFonts.urbanist(
                        fontSize: 14, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  place.district.isNotEmpty
                      ? '${place.district} · ${place.address.split(',').last.trim()}'
                      : place.address,
                  style: GoogleFonts.urbanist(
                      fontSize: 12, color: AppColors.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            )),
            if (place.source != 'firestore')
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(4)),
                child: Text(place.source.toUpperCase(),
                    style: GoogleFonts.urbanist(
                        fontSize: 8,
                        color: AppColors.textLight,
                        fontWeight: FontWeight.w600)),
              ),
          ]),
        ),
      );
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 48,
          height: 48,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: AppShadow.md,
          ),
          child: Icon(icon, size: 22, color: AppColors.text),
        ),
      );
}
