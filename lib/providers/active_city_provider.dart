import 'package:flutter/foundation.dart';

import '../models/delivery_zone.dart';
import '../services/active_city_service.dart';

class ActiveCityProvider extends ChangeNotifier {
  final ActiveCityService _service;
  ActiveCityState _state = ActiveCityState.initial;
  bool _initialized = false;
  bool _loading = false;
  Object? _error;

  ActiveCityProvider({ActiveCityService? service})
      : _service = service ?? ActiveCityService();

  ActiveCityService get service => _service;
  String? get activeCityId => _state.activeCityId;
  String? get gpsDetectedCityId => _state.gpsDetectedCityId;
  String get citySelectionSource => _state.citySelectionSource.value;
  String get cityResolutionStatus => _state.cityResolutionStatus.value;
  List<DeliveryZone> get activeCities => _service.activeCities;
  bool get initialized => _initialized;
  bool get loading => _loading;
  Object? get error => _error;

  Future<void> initialize() async {
    if (_initialized || _loading) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _state = await _service.initialize();
      _initialized = true;
    } catch (error) {
      _error = error;
      rethrow;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> resolveGps({
    required double latitude,
    required double longitude,
  }) async {
    _state = await _service.resolveGps(
      latitude: latitude,
      longitude: longitude,
    );
    _initialized = true;
    notifyListeners();
  }

  Future<void> selectManualCity(String cityId) async {
    _state = await _service.setManualOverride(cityId);
    notifyListeners();
  }

  Future<void> clearManualCity() async {
    _state = await _service.clearManualOverride();
    notifyListeners();
  }
}
