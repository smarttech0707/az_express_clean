import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/delivery_zone.dart';

enum CitySelectionSource { gps, manualOverride }

enum CityResolutionStatus { resolved, border, outsideService, unknown }

extension CitySelectionSourceValue on CitySelectionSource {
  String get value => switch (this) {
        CitySelectionSource.gps => 'gps',
        CitySelectionSource.manualOverride => 'manual_override',
      };
}

extension CityResolutionStatusValue on CityResolutionStatus {
  String get value => switch (this) {
        CityResolutionStatus.resolved => 'resolved',
        CityResolutionStatus.border => 'border',
        CityResolutionStatus.outsideService => 'outside_service',
        CityResolutionStatus.unknown => 'unknown',
      };
}

@immutable
class ActiveCityState {
  final String? activeCityId;
  final String? gpsDetectedCityId;
  final CitySelectionSource citySelectionSource;
  final CityResolutionStatus cityResolutionStatus;

  const ActiveCityState({
    required this.activeCityId,
    required this.gpsDetectedCityId,
    required this.citySelectionSource,
    required this.cityResolutionStatus,
  });

  static const initial = ActiveCityState(
    activeCityId: null,
    gpsDetectedCityId: null,
    citySelectionSource: CitySelectionSource.gps,
    cityResolutionStatus: CityResolutionStatus.unknown,
  );
}

typedef ActiveCitiesLoader = Future<List<DeliveryZone>> Function();
typedef DeliveryZonesLoader = Future<List<DeliveryZone>> Function(
  String cityId,
);

@immutable
class DispatchGeography {
  final String pickupCityId;
  final String? pickupZoneId;
  final String deliveryCityId;
  final String? deliveryZoneId;
  final String cityResolutionStatus;

  const DispatchGeography({
    required this.pickupCityId,
    required this.pickupZoneId,
    required this.deliveryCityId,
    required this.deliveryZoneId,
    required this.cityResolutionStatus,
  });
}

class ActiveCityService {
  static const int cityQueryLimit = 50;
  static const int zoneQueryLimit = 200;
  static const double movementThresholdMeters = 250;
  static const String manualOverridePreferenceKey =
      'active_city_manual_override_v1';

  final FirebaseFirestore? _firestore;
  final ActiveCitiesLoader? _cityLoader;
  final DeliveryZonesLoader? _zoneLoader;
  final Future<SharedPreferences> Function() _preferencesLoader;

  List<DeliveryZone>? _cities;
  Future<void>? _citiesLoading;
  final Map<String, List<DeliveryZone>> _zonesByCity = {};
  final Map<String, Future<List<DeliveryZone>>> _zonesLoading = {};
  Future<ActiveCityState>? _initializing;
  bool _initialized = false;
  ActiveCityState _state = ActiveCityState.initial;
  String? _manualOverrideCityId;
  double? _lastLatitude;
  double? _lastLongitude;

  ActiveCityService({
    FirebaseFirestore? firestore,
    ActiveCitiesLoader? cityLoader,
    DeliveryZonesLoader? zoneLoader,
    Future<SharedPreferences> Function()? preferencesLoader,
  })  : _firestore = firestore,
        _cityLoader = cityLoader,
        _zoneLoader = zoneLoader,
        _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  ActiveCityState get state => _state;
  String? get activeCityId => _state.activeCityId;
  String? get gpsDetectedCityId => _state.gpsDetectedCityId;
  String get citySelectionSource => _state.citySelectionSource.value;
  String get cityResolutionStatus => _state.cityResolutionStatus.value;
  List<DeliveryZone> get activeCities =>
      List.unmodifiable(_cities ?? const <DeliveryZone>[]);

  /// True when a resolved GPS city or a validated manual override may scope
  /// local searches.
  bool get hasUsableActiveCity =>
      _state.activeCityId != null &&
      (_state.cityResolutionStatus == CityResolutionStatus.resolved ||
          _state.cityResolutionStatus == CityResolutionStatus.border ||
          _state.citySelectionSource == CitySelectionSource.manualOverride);

  Future<ActiveCityState> initialize() async {
    if (_initialized) return _state;
    final inProgress = _initializing;
    if (inProgress != null) return inProgress;
    final future = _initialize();
    _initializing = future;
    return future;
  }

  Future<ActiveCityState> _initialize() async {
    await _loadCitiesOnce();
    final preferences = await _preferencesLoader();
    final stored = preferences.getString(manualOverridePreferenceKey);
    if (stored != null && _containsActiveCity(stored)) {
      _manualOverrideCityId = stored;
      _state = ActiveCityState(
        activeCityId: stored,
        gpsDetectedCityId: _state.gpsDetectedCityId,
        citySelectionSource: CitySelectionSource.manualOverride,
        cityResolutionStatus: _state.cityResolutionStatus,
      );
    } else if (stored != null) {
      await preferences.remove(manualOverridePreferenceKey);
    }
    _initialized = true;
    return _state;
  }

  Future<ActiveCityState> resolveGps({
    required double latitude,
    required double longitude,
  }) async {
    await initialize();
    if (_canReuseLastResolution(latitude, longitude)) return _state;

    _lastLatitude = latitude;
    _lastLongitude = longitude;
    final cities = _cities!;
    if (cities.isEmpty) {
      return _setGpsResolution(
        detectedCityId: null,
        status: CityResolutionStatus.unknown,
      );
    }

    final matches = <({DeliveryZone city, double normalizedDistance})>[];
    for (final city in cities) {
      if (!city.hasUsableGeometry || city.cityId == null) continue;
      final distanceMeters = Geolocator.distanceBetween(
        latitude,
        longitude,
        city.lat!,
        city.lng!,
      );
      final radiusMeters = city.radiusKm! * 1000;
      if (distanceMeters <= radiusMeters) {
        matches.add((
          city: city,
          normalizedDistance: distanceMeters / radiusMeters,
        ));
      }
    }

    if (matches.isEmpty) {
      return _setGpsResolution(
        detectedCityId: null,
        status: CityResolutionStatus.outsideService,
      );
    }

    matches.sort(
      (left, right) =>
          left.normalizedDistance.compareTo(right.normalizedDistance),
    );
    return _setGpsResolution(
      detectedCityId: matches.first.city.cityId,
      status: matches.length > 1
          ? CityResolutionStatus.border
          : CityResolutionStatus.resolved,
    );
  }

  Future<ActiveCityState> setManualOverride(String cityId) async {
    await initialize();
    if (!_containsActiveCity(cityId)) {
      throw ArgumentError.value(
        cityId,
        'cityId',
        'La surcharge doit désigner une ville active et desservie.',
      );
    }
    final preferences = await _preferencesLoader();
    await preferences.setString(manualOverridePreferenceKey, cityId);
    _manualOverrideCityId = cityId;
    _state = ActiveCityState(
      activeCityId: cityId,
      gpsDetectedCityId: _state.gpsDetectedCityId,
      citySelectionSource: CitySelectionSource.manualOverride,
      cityResolutionStatus: _state.cityResolutionStatus,
    );
    return _state;
  }

  Future<ActiveCityState> clearManualOverride() async {
    final preferences = await _preferencesLoader();
    await preferences.remove(manualOverridePreferenceKey);
    _manualOverrideCityId = null;
    _state = ActiveCityState(
      activeCityId: _state.gpsDetectedCityId,
      gpsDetectedCityId: _state.gpsDetectedCityId,
      citySelectionSource: CitySelectionSource.gps,
      cityResolutionStatus: _state.cityResolutionStatus,
    );
    return _state;
  }

  /// Retourne le quartier ou village actif le plus précis contenant [point].
  /// La résolution utilise uniquement les géométries locales mises en cache.
  Future<DeliveryZone?> resolveZone({
    required double latitude,
    required double longitude,
    String? cityId,
  }) async {
    await initialize();
    final resolvedCityId = cityId ?? activeCityId;
    if (resolvedCityId == null) return null;

    final zones = await _loadZonesOnce(resolvedCityId);
    final matches = <({DeliveryZone zone, double normalizedDistance})>[];
    for (final zone in zones) {
      if (zone.cityId != resolvedCityId ||
          zone.isActive != true ||
          (zone.type != 'quartier' && zone.type != 'village') ||
          !zone.hasUsableGeometry) {
        continue;
      }
      final distanceMeters = Geolocator.distanceBetween(
        latitude,
        longitude,
        zone.lat!,
        zone.lng!,
      );
      final radiusMeters = zone.radiusKm! * 1000;
      if (distanceMeters <= radiusMeters) {
        matches.add((
          zone: zone,
          normalizedDistance: distanceMeters / radiusMeters,
        ));
      }
    }
    if (matches.isEmpty) return null;
    matches.sort(
      (left, right) =>
          left.normalizedDistance.compareTo(right.normalizedDistance),
    );
    return matches.first.zone;
  }

  Future<DispatchGeography> resolveDispatchGeography({
    required double pickupLatitude,
    required double pickupLongitude,
    required double deliveryLatitude,
    required double deliveryLongitude,
  }) async {
    if (!_isValidDispatchPoint(pickupLatitude, pickupLongitude)) {
      throw StateError('Coordonnées du point de collecte indisponibles.');
    }
    if (!_isValidDispatchPoint(deliveryLatitude, deliveryLongitude)) {
      throw StateError('Coordonnées du point de livraison indisponibles.');
    }
    await initialize();
    final pickupCities = _citiesContainingPoint(
      pickupLatitude,
      pickupLongitude,
    );
    final deliveryCities = _citiesContainingPoint(
      deliveryLatitude,
      deliveryLongitude,
    );
    if (pickupCities.isEmpty) {
      throw StateError('Le point de collecte est hors des villes desservies.');
    }
    if (deliveryCities.isEmpty) {
      throw StateError('Le point de livraison est hors des villes desservies.');
    }
    final pickupCityId = pickupCities.first.city.cityId!;
    final deliveryCityId = deliveryCities.first.city.cityId!;
    final zones = await Future.wait([
      resolveZone(
        latitude: pickupLatitude,
        longitude: pickupLongitude,
        cityId: pickupCityId,
      ),
      resolveZone(
        latitude: deliveryLatitude,
        longitude: deliveryLongitude,
        cityId: deliveryCityId,
      ),
    ]);
    return DispatchGeography(
      pickupCityId: pickupCityId,
      pickupZoneId: zones[0]?.id,
      deliveryCityId: deliveryCityId,
      deliveryZoneId: zones[1]?.id,
      cityResolutionStatus: pickupCities.length > 1 ? 'border' : 'resolved',
    );
  }

  List<({DeliveryZone city, double normalizedDistance})> _citiesContainingPoint(
      double latitude, double longitude) {
    final matches = <({DeliveryZone city, double normalizedDistance})>[];
    for (final city in _cities ?? const <DeliveryZone>[]) {
      if (!city.hasUsableGeometry || city.cityId == null) continue;
      final radiusMeters = city.radiusKm! * 1000;
      final distanceMeters = Geolocator.distanceBetween(
        latitude,
        longitude,
        city.lat!,
        city.lng!,
      );
      if (distanceMeters <= radiusMeters) {
        matches.add((
          city: city,
          normalizedDistance: distanceMeters / radiusMeters,
        ));
      }
    }
    matches.sort(
      (left, right) =>
          left.normalizedDistance.compareTo(right.normalizedDistance),
    );
    return matches;
  }

  static bool _isValidDispatchPoint(double latitude, double longitude) =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      !(latitude == 0 && longitude == 0);

  Future<List<DeliveryZone>> _loadZonesOnce(String cityId) {
    final cached = _zonesByCity[cityId];
    if (cached != null) return Future.value(cached);
    final loading = _zonesLoading[cityId];
    if (loading != null) return loading;
    final future = _loadZones(cityId);
    _zonesLoading[cityId] = future;
    return future.whenComplete(() => _zonesLoading.remove(cityId));
  }

  Future<List<DeliveryZone>> _loadZones(String cityId) async {
    final loader = _zoneLoader;
    final List<DeliveryZone> zones;
    if (loader != null) {
      zones = await loader(cityId);
    } else {
      final snapshot = await (_firestore ?? FirebaseFirestore.instance)
          .collection('zones_livraison')
          .where('cityId', isEqualTo: cityId)
          .limit(zoneQueryLimit)
          .get();
      zones = snapshot.docs
          .map((document) => DeliveryZone.fromMap(document.id, document.data()))
          .toList(growable: false);
    }
    final cached = List<DeliveryZone>.unmodifiable(zones);
    _zonesByCity[cityId] = cached;
    if (cached.length >= zoneQueryLimit) {
      debugPrint(
        '[ActiveCityService] Limite de $zoneQueryLimit zones atteinte pour '
        '$cityId ; vérifier si des zones supplémentaires ne sont pas chargées.',
      );
    }
    return cached;
  }

  ActiveCityState _setGpsResolution({
    required String? detectedCityId,
    required CityResolutionStatus status,
  }) {
    _state = ActiveCityState(
      activeCityId: _manualOverrideCityId ?? detectedCityId,
      gpsDetectedCityId: detectedCityId,
      citySelectionSource: _manualOverrideCityId == null
          ? CitySelectionSource.gps
          : CitySelectionSource.manualOverride,
      cityResolutionStatus: status,
    );
    return _state;
  }

  bool _canReuseLastResolution(double latitude, double longitude) {
    final lastLatitude = _lastLatitude;
    final lastLongitude = _lastLongitude;
    if (lastLatitude == null || lastLongitude == null) return false;
    return Geolocator.distanceBetween(
          lastLatitude,
          lastLongitude,
          latitude,
          longitude,
        ) <
        movementThresholdMeters;
  }

  bool _containsActiveCity(String cityId) =>
      _cities!.any((city) => city.cityId == cityId);

  Future<void> _loadCitiesOnce() async {
    if (_cities != null) return;
    final inProgress = _citiesLoading;
    if (inProgress != null) return inProgress;
    final future = _loadCities();
    _citiesLoading = future;
    return future;
  }

  Future<void> _loadCities() async {
    final loader = _cityLoader;
    if (loader != null) {
      _cities = List.unmodifiable(await loader());
    } else {
      final snapshot = await (_firestore ?? FirebaseFirestore.instance)
          .collection('zones_livraison')
          .where('type', isEqualTo: 'ville')
          .where('isActive', isEqualTo: true)
          .where('isServiceable', isEqualTo: true)
          .limit(cityQueryLimit)
          .get();
      _cities = List.unmodifiable(snapshot.docs
          .map((document) => DeliveryZone.fromMap(document.id, document.data()))
          .toList(growable: false));
    }
    if (_cities!.length >= cityQueryLimit) {
      debugPrint(
        '[ActiveCityService] Limite de $cityQueryLimit villes atteinte ; '
        'vérifier si des villes actives supplémentaires ne sont pas chargées.',
      );
    }
  }
}
