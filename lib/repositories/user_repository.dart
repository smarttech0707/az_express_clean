import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../constants/app_constants.dart';

class UserRepository {
  static final _db = FirebaseFirestore.instance;
  static final _auth = FirebaseAuth.instance;

  static String? get _uid => _auth.currentUser?.uid;

  // ── Profil client ────────────────────────────────────────────────────────
  static Stream<DocumentSnapshot> clientStream() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    return _db.collection(Collections.clients).doc(uid).snapshots();
  }

  static Future<Map<String, dynamic>?> getClient(String uid) async {
    final snap = await _db.collection(Collections.clients).doc(uid).get();
    return snap.data();
  }

  static Future<void> createClient({
    required String uid,
    required String name,
    required String phone,
  }) async {
    await _db.collection(Collections.clients).doc(uid).set({
      'name':                  name,
      'phone':                 phone,
      'wallet':                0,
      'cashOnDeliveryEnabled': true,
      'fakeOrderCount':        0,
      'createdAt':             FieldValue.serverTimestamp(),
    });
  }

  static const _clientProfileAllowedFields = {
    'name', 'phone', 'address', 'profilePhoto', 'bio',
  };

  static Future<void> updateClientProfile(
      String uid, Map<String, dynamic> data) async {
    final filtered = Map.fromEntries(
      data.entries.where((e) => _clientProfileAllowedFields.contains(e.key)),
    );
    if (filtered.isEmpty) return;
    await _db.collection(Collections.clients).doc(uid).update({
      ...filtered,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // ── Profil livreur ────────────────────────────────────────────────────────
  static Stream<DocumentSnapshot> driverStream(String uid) =>
      _db.collection(Collections.livreurs).doc(uid).snapshots();

  static Future<void> updateDriverStatus(
      String uid, bool isOnline) async {
    await _db.collection(Collections.livreurs).doc(uid).update({
      'isOnline':  isOnline,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> updateDriverLocation(
      String uid, double lat, double lng) async {
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      throw ArgumentError('Coordonnées GPS invalides');
    }
    await _db.collection(Collections.livreurs).doc(uid).update({
      'lat': lat,
      'lng': lng,
      'lastLocationAt': FieldValue.serverTimestamp(),
    });
  }

  // ── FCM Token ─────────────────────────────────────────────────────────────
  static Future<void> saveFcmToken(
      String uid, String token, String collection) async {
    await _db.collection(collection).doc(uid).update({
      'fcmToken':       token,
      'tokenUpdatedAt': FieldValue.serverTimestamp(),
    });
  }

  // ── Vérifier si admin ─────────────────────────────────────────────────────
  static Future<bool> isAdmin(String uid) async {
    final snap = await _db.collection(Collections.admins).doc(uid).get();
    return snap.exists;
  }

  // ── Vérifier si vendeur ───────────────────────────────────────────────────
  static Future<DocumentSnapshot?> getSellerProfile(String uid) async {
    final snap = await _db.collection(Collections.sellers).doc(uid).get();
    return snap.exists ? snap : null;
  }

  // ── Livreurs en ligne ─────────────────────────────────────────────────────
  static Stream<QuerySnapshot> onlineDriversStream() {
    return _db
        .collection(Collections.livreurs)
        .where('isOnline', isEqualTo: true)
        .snapshots();
  }

  // ── Supprimer compte ──────────────────────────────────────────────────────
  static Future<void> deleteAccount() async {
    final uid = _uid;
    if (uid == null) return;
    // Auth supprimé en premier : si ça échoue (re-login requis),
    // le document Firestore reste intact et l'app ne se retrouve pas dans un état brisé.
    await _auth.currentUser!.delete();
    await _db.collection(Collections.clients).doc(uid).delete();
  }
}
