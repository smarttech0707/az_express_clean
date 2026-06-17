import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AdminOrders extends StatefulWidget {
  const AdminOrders({super.key});

  @override
  State<AdminOrders> createState() => _AdminOrdersState();
}

class _AdminOrdersState extends State<AdminOrders> {
  static const _pageSize = 30;

  final _db = FirebaseFirestore.instance;
  final List<QueryDocumentSnapshot> _docs = [];
  DocumentSnapshot? _lastDoc;
  bool _loading = false;
  bool _hasMore = true;
  String _filterStatus = 'all';

  static const _statuses = [
    ('all', 'Toutes'),
    ('pending', 'En attente'),
    ('assigned', 'Assignées'),
    ('accepted', 'Acceptées'),
    ('picked_up', 'Récupérées'),
    ('delivered', 'Livrées'),
    ('cancelled', 'Annulées'),
  ];

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Query get _baseQuery {
    var q = _db.collection("orders").orderBy("createdAt", descending: true);
    if (_filterStatus != 'all') {
      q = q.where("status", isEqualTo: _filterStatus);
    }
    return q;
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      var q = _baseQuery.limit(_pageSize);
      if (_lastDoc != null) q = q.startAfterDocument(_lastDoc!);
      final snap = await q.get();
      if (!mounted) return;
      setState(() {
        _docs.addAll(snap.docs);
        _lastDoc = snap.docs.isNotEmpty ? snap.docs.last : _lastDoc;
        _hasMore = snap.docs.length == _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erreur : $e"), backgroundColor: Colors.red),
      );
    }
  }

  void _resetAndLoad() {
    setState(() {
      _docs.clear();
      _lastDoc = null;
      _hasMore = true;
    });
    _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text("Commandes"),
        backgroundColor: const Color(0xFF2E7D32),
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _resetAndLoad,
            tooltip: "Actualiser",
          ),
        ],
      ),
      body: Column(
        children: [
          // Filtre par statut
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _statuses.map((s) {
                  final selected = _filterStatus == s.$1;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _filterStatus = s.$1);
                        _resetAndLoad();
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFF2E7D32)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: selected
                                ? const Color(0xFF2E7D32)
                                : Colors.grey.shade300,
                          ),
                        ),
                        child: Text(
                          s.$2,
                          style: TextStyle(
                            color: selected ? Colors.white : Colors.black87,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          // Liste
          Expanded(
            child: _docs.isEmpty && !_loading
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.inbox_rounded,
                            size: 64, color: Colors.grey.shade300),
                        const SizedBox(height: 12),
                        const Text("Aucune commande",
                            style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  )
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    itemCount: _docs.length + (_hasMore ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == _docs.length) {
                        // Chargement page suivante
                        if (!_loading) _loadMore();
                        return const Padding(
                          padding: EdgeInsets.all(20),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final data =
                          _docs[i].data() as Map<String, dynamic>;
                      return _OrderCard(data: data, docId: _docs[i].id);
                    },
                  ),
          ),

          if (_loading && _docs.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

// ── Carte commande ────────────────────────────────────────────

class _OrderCard extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> data;
  const _OrderCard({required this.docId, required this.data});

  static const _statusColors = {
    'pending':   Color(0xFFFFA000),
    'assigned':  Color(0xFF1565C0),
    'accepted':  Color(0xFF1976D2),
    'picked_up': Color(0xFF7B1FA2),
    'delivered': Color(0xFF2E7D32),
    'cancelled': Color(0xFFB71C1C),
  };

  static const _statusLabels = {
    'pending':   'En attente',
    'assigned':  'Assignée',
    'accepted':  'Acceptée',
    'picked_up': 'Récupérée',
    'delivered': 'Livrée',
    'cancelled': 'Annulée',
  };

  @override
  Widget build(BuildContext context) {
    final status   = data["status"] as String? ?? 'pending';
    final client   = data["clientName"] as String? ?? "Client";
    final phone    = data["clientPhone"] as String? ?? "—";
    final desc     = data["description"] as String? ?? "—";
    final budget   = (data["budget"] as num? ?? 0).toInt();
    final ts       = data["createdAt"] as Timestamp?;
    final date     = ts?.toDate();
    final color    = _statusColors[status] ?? Colors.grey;
    final label    = _statusLabels[status] ?? status;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    desc,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: color.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            _row(Icons.person_outline, client),
            const SizedBox(height: 4),
            _row(Icons.phone_outlined, phone),
            const SizedBox(height: 4),
            _row(
              Icons.payments_outlined,
              "$budget FCFA",
              color: const Color(0xFF2E7D32),
            ),
            if (date != null) ...[
              const SizedBox(height: 4),
              _row(
                Icons.access_time,
                "${date.day.toString().padLeft(2, '0')}/"
                "${date.month.toString().padLeft(2, '0')}/"
                "${date.year}  "
                "${date.hour.toString().padLeft(2, '0')}:"
                "${date.minute.toString().padLeft(2, '0')}",
                color: Colors.grey,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(IconData icon, String text, {Color? color}) => Row(
        children: [
          Icon(icon, size: 14, color: color ?? Colors.grey),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: color ?? Colors.black87,
                fontWeight: color != null ? FontWeight.w600 : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
}
