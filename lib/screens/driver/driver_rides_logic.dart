import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter/foundation.dart';

/// Rubrique « Mes courses » du livreur — logique pure (sans Firestore) pour
/// pouvoir la tester sans initialiser Firebase.

enum DriverRideTab { inProgress, delivered, refused, cancelled, all }

/// Nature d'une course vue par le livreur. `expired` et `cancelled` partagent
/// `orders.status == 'cancelled'` : seule `cancelReason` les distingue, et une
/// expiration automatique n'est jamais un refus volontaire du livreur.
enum DriverRideKind {
  proposed,
  inProgress,
  delivered,
  cancelled,
  expired,
  other
}

const int kDriverRidesBatchSize = 20;

/// `cancelReason` posé par `expireOrderTx` quand personne n'a accepté à temps.
const String kCancelReasonNoDriver = 'no_driver_found';

/// Statuts `orders` réels interrogés par onglet. `null` = pas de filtre de
/// statut (« Toutes »). L'onglet Refusées n'a pas de requête : le serveur
/// supprime `driverId` de la commande au refus, elle n'est donc plus lisible
/// par ce livreur (voir docs/…, tranche 2 pour le suivi serveur).
List<String>? statusesForTab(DriverRideTab tab) {
  switch (tab) {
    case DriverRideTab.inProgress:
      return const ['accepted', 'picked_up'];
    case DriverRideTab.delivered:
      return const ['delivered'];
    case DriverRideTab.cancelled:
      return const ['cancelled'];
    case DriverRideTab.all:
      return null;
    case DriverRideTab.refused:
      throw ArgumentError('Pas de requête pour l\'onglet Refusées');
  }
}

class DriverRide {
  const DriverRide({
    required this.id,
    required this.status,
    required this.budget,
    required this.description,
    required this.paymentMethod,
    this.createdAt,
    this.deliveredAt,
    this.cancelledAt,
    this.pickupAddress,
    this.deliveryAddress,
    this.cancelReason,
    this.type,
    this.shoppingBudget = 0,
  });

  final String id;
  final String status;
  final int budget;
  final String description;
  final String paymentMethod;
  final DateTime? createdAt;
  final DateTime? deliveredAt;
  final DateTime? cancelledAt;
  final String? pickupAddress;
  final String? deliveryAddress;
  final String? cancelReason;
  final String? type;
  final int shoppingBudget;

  factory DriverRide.fromMap(String id, Map<String, dynamic> d) {
    DateTime? date(Object? v) => v is Timestamp ? v.toDate() : null;
    String? text(Object? v) {
      if (v is! String) return null;
      final t = v.trim();
      return t.isEmpty ? null : t;
    }

    final budget = d['budget'];
    return DriverRide(
      id: id,
      status: (d['status'] as String?) ?? '',
      // Montant lu tel qu'écrit à la création (`orders.budget`), jamais recalculé.
      budget: budget is num ? budget.toInt() : 0,
      description: (d['description'] as String?) ?? '',
      paymentMethod: (d['paymentMethod'] as String?) ?? '',
      createdAt: date(d['createdAt']),
      deliveredAt: date(d['deliveredAt']),
      cancelledAt: date(d['cancelledAt']),
      pickupAddress: text(d['pickupAddress']),
      deliveryAddress: text(d['deliveryAddress']),
      cancelReason: text(d['cancelReason']),
      type: text(d['type']),
      shoppingBudget: d['shoppingBudget'] is num ? (d['shoppingBudget'] as num).toInt() : 0,
    );
  }

  DriverRideKind get kind {
    switch (status) {
      case 'assigned':
        return DriverRideKind.proposed;
      case 'accepted':
      case 'picked_up':
        return DriverRideKind.inProgress;
      case 'delivered':
        return DriverRideKind.delivered;
      case 'cancelled':
        return cancelReason == kCancelReasonNoDriver
            ? DriverRideKind.expired
            : DriverRideKind.cancelled;
      default:
        return DriverRideKind.other;
    }
  }

  /// Libellé à afficher quand le vocabulaire partagé (`AppStatus`) ne dit pas
  /// la vérité pour cette vue : une proposition n'est pas « Acceptée », une
  /// expiration n'est pas une annulation décidée par quelqu'un.
  String? get statusLabelOverride {
    switch (kind) {
      case DriverRideKind.proposed:
        return 'Proposée';
      case DriverRideKind.expired:
        return 'Expirée (aucun livreur)';
      case DriverRideKind.other:
        return status.isEmpty ? 'Statut inconnu' : status;
      default:
        return null;
    }
  }

  String get shortId =>
      (id.length > 8 ? id.substring(0, 8) : id).toUpperCase();
}

/// Montant crédité à attendre pour une course livrée, ou `null` si on ne peut
/// pas le certifier. Le serveur crédite `budget` (frais de livraison) ; avec un
/// budget d'achat il crédite `budget + shoppingBudget`, ce qui mêle gain et
/// remboursement d'avance : on ne le présente alors pas comme un gain.
int? expectedCredit(DriverRide r) {
  if (r.kind != DriverRideKind.delivered) return null;
  if (r.shoppingBudget != 0 || r.budget <= 0) return null;
  return r.budget;
}

/// Gain « fiable » : le crédit `earning` du portefeuille du livreur
/// (`wallet_transactions`). Ce journal est inscriptible par son propriétaire
/// (règle existante) : un crédit n'est donc retenu que s'il est UNIQUE pour la
/// commande (zéro = non crédité, cash ou transférée ; plusieurs = ambigu) et
/// ÉGAL au montant attendu [expected] (dérivé de `orders.budget`, non
/// modifiable par le livreur). Sinon : pas de gain affiché (« — »).
/// Rien n'est jamais calculé : on ne fait que confirmer un montant écrit par le serveur.
Map<String, int> reliableEarnings(
  Iterable<({String orderId, Object? amount})> credits, {
  required Map<String, int> expected,
}) {
  final counts = <String, int>{};
  final amounts = <String, int>{};
  for (final c in credits) {
    counts[c.orderId] = (counts[c.orderId] ?? 0) + 1;
    final a = c.amount;
    if (a is int && a > 0) amounts[c.orderId] = a;
  }
  return {
    for (final e in amounts.entries)
      if (counts[e.key] == 1 && expected[e.key] == e.value) e.key: e.value,
  };
}

class DriverRidesBatch {
  const DriverRidesBatch({
    required this.rides,
    required this.hasMore,
    this.cursor,
    this.earnings = const {},
  });
  final List<DriverRide> rides;
  final bool hasMore;
  final Object? cursor;
  final Map<String, int> earnings;
}

typedef DriverRidesFetcher = Future<DriverRidesBatch> Function(
    Object? cursor, int limit);

/// État paginé d'une liste de courses (premier chargement, pages suivantes,
/// erreur, rafraîchissement). Aucune requête Firestore ici : le chargement
/// passe par [fetcher], ce qui le rend testable.
class DriverRidesController extends ChangeNotifier {
  DriverRidesController(this.fetcher, {this.pageSize = kDriverRidesBatchSize});

  final DriverRidesFetcher fetcher;
  final int pageSize;

  final List<DriverRide> rides = [];
  final Map<String, int> earnings = {};
  bool loading = false;
  bool loadingMore = false;
  bool hasMore = true;
  bool loaded = false;
  Object? error;
  Object? _cursor;
  int _generation = 0;
  bool _disposed = false;

  bool get isEmpty => loaded && error == null && rides.isEmpty;

  Future<void> refresh() async {
    _generation++;
    rides.clear();
    earnings.clear();
    _cursor = null;
    hasMore = true;
    loaded = false;
    error = null;
    loadingMore = false;
    loading = false;
    return loadMore();
  }

  Future<void> loadMore() async {
    if (loading || loadingMore || !hasMore) return;
    final first = rides.isEmpty;
    if (first) {
      loading = true;
    } else {
      loadingMore = true;
    }
    error = null;
    _notify();
    final generation = _generation;
    try {
      final page = await fetcher(_cursor, pageSize);
      if (generation != _generation) return; // un refresh a pris le relais
      final seen = rides.map((r) => r.id).toSet();
      rides.addAll(page.rides.where((r) => !seen.contains(r.id)));
      earnings.addAll(page.earnings);
      _cursor = page.cursor;
      hasMore = page.hasMore;
      loaded = true;
    } catch (e) {
      if (generation != _generation) return;
      error = e;
    } finally {
      if (generation == _generation) {
        loading = false;
        loadingMore = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

String two(int n) => n.toString().padLeft(2, '0');

String formatRideDateTime(DateTime? d) {
  if (d == null) return 'Date inconnue';
  final l = d.toLocal();
  return '${two(l.day)}/${two(l.month)}/${l.year} à ${two(l.hour)}:${two(l.minute)}';
}

String formatFcfa(int amount) {
  final s = amount.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return '${amount < 0 ? '-' : ''}$b FCFA';
}

String paymentLabel(String raw) {
  switch (raw) {
    case 'cash':
      return 'Espèces';
    case 'wallet':
      return 'Portefeuille';
    case '':
      return 'Non renseigné';
    default:
      return raw;
  }
}
