import 'package:cloud_firestore/cloud_firestore.dart';

import 'driver_rides_logic.dart';

/// Accès Firestore de « Mes courses ». Toutes les requêtes portent
/// `driverId == <ce livreur>` : c'est ce que la règle de lecture de `orders`
/// exige (`resource.data.driverId == uid()`), donc un livreur ne peut jamais
/// lire les courses d'un autre. Lecture seule : aucune écriture ici.
class DriverRidesService {
  DriverRidesService({required this.driverId, FirebaseFirestore? db})
      : _dbOverride = db;

  final String driverId;
  final FirebaseFirestore? _dbOverride;

  // Paresseux : construire le service (ex. dans un test) n'initialise pas Firebase.
  FirebaseFirestore get _db => _dbOverride ?? FirebaseFirestore.instance;

  /// Requête d'un onglet. Index requis (voir firestore.indexes.json) :
  /// `driverId + createdAt desc` (Toutes) et
  /// `driverId + status + createdAt desc` (En cours, Terminées, Annulées).
  Query<Map<String, dynamic>> query(DriverRideTab tab) {
    Query<Map<String, dynamic>> q =
        _db.collection('orders').where('driverId', isEqualTo: driverId);
    final statuses = statusesForTab(tab);
    if (statuses != null) {
      q = statuses.length == 1
          ? q.where('status', isEqualTo: statuses.first)
          : q.where('status', whereIn: statuses);
    }
    return q.orderBy('createdAt', descending: true);
  }

  List<DriverRide> _rides(Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs) =>
      docs
          // Garde-fou défensif : la règle l'impose déjà côté serveur.
          .where((d) => d.data()['driverId'] == driverId)
          .map((d) => DriverRide.fromMap(d.id, d.data()))
          .toList();

  /// Courses en cours, en temps réel (peu nombreuses : une seule page).
  Stream<List<DriverRide>> watchInProgress() => query(DriverRideTab.inProgress)
      .limit(kDriverRidesBatchSize)
      .snapshots()
      .map((s) => _rides(s.docs));

  /// Une page, avec les gains fiables des courses livrées de cette page.
  Future<DriverRidesBatch> fetchPage(
    DriverRideTab tab,
    Object? cursor,
    int limit,
  ) async {
    var q = query(tab).limit(limit);
    if (cursor is DocumentSnapshot) q = q.startAfterDocument(cursor);
    final snap = await q.get();
    final rides = _rides(snap.docs);
    // Le gain est un complément : s'il est illisible, la liste reste affichée
    // et le gain montre « — » (jamais une valeur devinée).
    var earnings = const <String, int>{};
    try {
      earnings = await fetchEarnings(rides);
    } catch (_) {}
    return DriverRidesBatch(
      rides: rides,
      hasMore: snap.docs.length == limit,
      cursor: snap.docs.isEmpty ? cursor : snap.docs.last,
      earnings: earnings,
    );
  }

  /// Crédits de gain du livreur pour les courses livrées de [rides] (portefeuille
  /// du livreur, lisible par lui seul), confirmés par [reliableEarnings].
  /// Par lots de 30 (limite de `whereIn`).
  Future<Map<String, int>> fetchEarnings(Iterable<DriverRide> rides) async {
    final expected = <String, int>{
      for (final r in rides)
        if (expectedCredit(r) != null) r.id: expectedCredit(r)!,
    };
    final ids = expected.keys.toList();
    final credits = <({String orderId, Object? amount})>[];
    for (var i = 0; i < ids.length; i += 30) {
      final chunk = ids.sublist(i, i + 30 > ids.length ? ids.length : i + 30);
      final snap = await _db
          .collection('livreurs')
          .doc(driverId)
          .collection('wallet_transactions')
          .where('type', isEqualTo: 'earning')
          .where('orderId', whereIn: chunk)
          .get();
      for (final d in snap.docs) {
        final data = d.data();
        final orderId = data['orderId'];
        if (orderId is String) credits.add((orderId: orderId, amount: data['amount']));
      }
    }
    return reliableEarnings(credits, expected: expected);
  }
}
