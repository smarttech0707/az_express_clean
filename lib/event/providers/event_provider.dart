import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../event_constants.dart';
import '../models/event_models.dart';
import '../services/event_service.dart';

class EventProvider extends ChangeNotifier {
  EventProvider({EventService? service}) : service = service ?? EventService();
  final EventService service;

  final List<EventOffer> _offers = [];
  final Map<String, EventCartItem> _cart = {};
  final Set<String> _comparisonIds = {};
  DocumentSnapshot<Map<String, dynamic>>? _cursor;
  EventCategory? category;
  String? subcategory;
  String zone = '';
  String search = '';
  bool loading = false;
  bool hasMore = true;
  String? error;

  List<EventOffer> get offers {
    final q = search.trim().toLowerCase();
    if (q.isEmpty) return List.unmodifiable(_offers);
    return _offers
        .where((e) =>
            e.title.toLowerCase().contains(q) ||
            e.subcategory.toLowerCase().contains(q) ||
            e.providerName.toLowerCase().contains(q))
        .toList(growable: false);
  }

  List<EventCartItem> get cart => List.unmodifiable(_cart.values);
  List<EventOffer> get comparison => _offers
      .where((offer) => _comparisonIds.contains(offer.id))
      .toList(growable: false);
  int get cartCount => _cart.values.fold(0, (total, e) => total + e.quantity);
  int get cartTotal => _cart.values.fold(0, (total, e) => total + e.total);

  Future<void> load({bool refresh = false}) async {
    if (loading || (!refresh && !hasMore)) return;
    if (refresh) {
      _cursor = null;
      hasMore = true;
      _offers.clear();
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final (items, cursor) = await service.fetchOffers(
        category: category,
        subcategory: subcategory,
        zone: zone,
        after: _cursor,
      );
      _offers.addAll(items);
      _cursor = cursor;
      hasMore = items.length == EventService.pageSize;
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void setSearch(String value) {
    search = value;
    notifyListeners();
  }

  Future<void> setCategory(EventCategory? value) async {
    category = value;
    subcategory = null;
    await load(refresh: true);
  }

  Future<void> setSubcategory(String? value) async {
    subcategory = value;
    await load(refresh: true);
  }

  void addToCart(EventOffer offer, {int quantity = 1}) {
    final current = _cart[offer.id]?.quantity ?? 0;
    final next = (current + quantity).clamp(1, offer.availableQuantity);
    _cart[offer.id] = EventCartItem(offer: offer, quantity: next);
    notifyListeners();
  }

  void setQuantity(String offerId, int quantity) {
    final current = _cart[offerId];
    if (current == null) return;
    if (quantity <= 0) {
      _cart.remove(offerId);
    } else {
      _cart[offerId] = EventCartItem(
        offer: current.offer,
        quantity: quantity.clamp(1, current.offer.availableQuantity),
      );
    }
    notifyListeners();
  }

  void clearCart() {
    _cart.clear();
    notifyListeners();
  }

  bool isCompared(String id) => _comparisonIds.contains(id);

  void toggleComparison(EventOffer offer) {
    if (_comparisonIds.remove(offer.id)) {
      notifyListeners();
      return;
    }
    if (_comparisonIds.length >= 3) return;
    _comparisonIds.add(offer.id);
    notifyListeners();
  }

  void clearComparison() {
    _comparisonIds.clear();
    notifyListeners();
  }
}
