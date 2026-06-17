import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/mp_product.dart';
import '../services/mp_service.dart';

class MpProvider extends ChangeNotifier {
  List<MpProduct> _products  = [];
  List<MpProduct> _searchResults = [];
  bool _loading   = false;
  bool _searching = false;
  String _selectedCategory = 'all';
  StreamSubscription<List<MpProduct>>? _sub;

  List<MpProduct> get products       => _products;
  List<MpProduct> get searchResults  => _searchResults;
  bool get loading                   => _loading;
  bool get searching                 => _searching;
  String get selectedCategory        => _selectedCategory;

  List<MpProduct> get newProducts =>
      _products.where((p) => p.condition == 'new').take(10).toList();
  List<MpProduct> get likeNewProducts =>
      _products.where((p) => p.condition == 'like_new').take(10).toList();
  List<MpProduct> get usedProducts =>
      _products.where((p) => p.condition == 'used').take(10).toList();

  MpProvider();

  /// Appelé par MpHomeScreen au premier affichage — évite un stream Firestore
  /// inutile si l'utilisateur n'ouvre jamais l'onglet Djassa.
  void ensureLoaded() {
    if (_sub != null) return;
    _subscribe();
  }

  void _subscribe() {
    _loading = true;
    notifyListeners();
    _sub?.cancel();
    final stream = _selectedCategory == 'all'
        ? MpService.streamActive()
        : MpService.streamByCategory(_selectedCategory);
    _sub = stream.listen(
      (list) {
        // Sort VIP first
        list.sort((a, b) {
          if (a.sellerVipStatus == 'active' && b.sellerVipStatus != 'active') return -1;
          if (b.sellerVipStatus == 'active' && a.sellerVipStatus != 'active') return 1;
          return 0;
        });
        _products = list;
        _loading  = false;
        notifyListeners();
      },
      onError: (_) {
        _loading = false;
        notifyListeners();
      },
    );
  }

  void selectCategory(String cat) {
    if (_selectedCategory == cat) return;
    _selectedCategory = cat;
    _subscribe();
  }

  Future<void> search({
    String? query,
    String? category,
    String? condition,
    String? brand,
    int? minPrice,
    int? maxPrice,
  }) async {
    _searching = true;
    notifyListeners();
    _searchResults = await MpService.search(
      query: query,
      category: category,
      condition: condition,
      brand: brand,
      minPrice: minPrice,
      maxPrice: maxPrice,
    );
    _searching = false;
    notifyListeners();
  }

  void clearSearch() {
    _searchResults = [];
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
