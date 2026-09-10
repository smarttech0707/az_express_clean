import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/delivery_zone.dart';

/// Catalogue national AZ Market. Il réutilise les documents ville existants
/// sans les rendre desservis par les services de Livraison.
class MarketCityCatalogService {
  static const _limit = 100;

  MarketCityCatalogService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;
  List<DeliveryZone>? _cachedCities;
  Future<List<DeliveryZone>>? _loading;

  Future<List<DeliveryZone>> loadCities() {
    final cached = _cachedCities;
    if (cached != null) return Future.value(cached);
    return _loading ??= _loadCities();
  }

  Future<List<DeliveryZone>> _loadCities() async {
    final snapshot = await _firestore
        .collection('zones_livraison')
        .where('type', isEqualTo: 'ville')
        .where('isMarketplaceEnabled', isEqualTo: true)
        .limit(_limit)
        .get();
    final cities = snapshot.docs
        .map((document) => DeliveryZone.fromMap(document.id, document.data()))
        .where((city) => (city.cityId ?? city.id).isNotEmpty)
        .toList()
      ..sort((left, right) =>
          (left.name ?? left.cityId ?? left.id).compareTo(
            right.name ?? right.cityId ?? right.id,
          ));
    _cachedCities = List.unmodifiable(cities);
    return _cachedCities!;
  }
}
