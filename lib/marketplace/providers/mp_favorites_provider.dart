import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/mp_service.dart';

class MpFavoritesProvider extends ChangeNotifier {
  Set<String> _ids = {};
  bool _loaded = false;

  Set<String> get ids => _ids;
  bool get loaded => _loaded;
  bool isFav(String id) => _ids.contains(id);

  Future<void> load() async {
    if (_loaded) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _ids = await MpService.getFavorites(uid);
    _loaded = true;
    notifyListeners();
  }

  Future<void> toggle(String productId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final adding = !_ids.contains(productId);
    if (adding) {
      _ids.add(productId);
    } else {
      _ids.remove(productId);
    }
    notifyListeners();
    await MpService.toggleFavorite(uid, productId, adding);
  }

  void reset() {
    _ids = {};
    _loaded = false;
    notifyListeners();
  }
}
