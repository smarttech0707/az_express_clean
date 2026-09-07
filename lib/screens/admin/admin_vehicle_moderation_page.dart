import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

class AdminVehicleModerationPage extends StatefulWidget {
  const AdminVehicleModerationPage({super.key});

  @override
  State<AdminVehicleModerationPage> createState() =>
      _AdminVehicleModerationPageState();
}

class _AdminVehicleModerationPageState
    extends State<AdminVehicleModerationPage> {
  static const _pageSize = 20;
  final _items = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
  DocumentSnapshot<Map<String, dynamic>>? _cursor;
  int _tab = 0;
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;

  String get _collection => switch (_tab) {
        0 => 'vehicle_listings',
        1 || 2 => 'vehicle_seller_profiles',
        _ => 'vehicle_reports',
      };

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    _items.clear();
    _cursor = null;
    _hasMore = true;
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collection(_collection)
          .orderBy(_collection == 'vehicle_reports' ? 'createdAt' : 'updatedAt',
              descending: true)
          .limit(_pageSize + 1);
      if (_tab == 2) {
        query = query.where('sellerType', isEqualTo: 'professional');
      }
      if (_cursor != null) query = query.startAfterDocument(_cursor!);
      final snapshot = await query.get();
      final page = snapshot.docs.take(_pageSize).toList();
      if (!mounted) return;
      setState(() {
        _items.addAll(page);
        _cursor = page.isEmpty ? null : page.last;
        _hasMore = snapshot.docs.length > _pageSize;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Modération Auto & Moto'),
            bottom: TabBar(
              isScrollable: true,
              onTap: (value) {
                _tab = value;
                _reload();
              },
              tabs: const [
                Tab(text: 'Annonces'),
                Tab(text: 'Vendeurs'),
                Tab(text: 'Pros/Magasins'),
                Tab(text: 'Signalements'),
              ],
            ),
          ),
          body: SafeArea(top: false, child: _body()),
        ),
      );

  Widget _body() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: FilledButton.tonal(
          onPressed: _reload,
          child: const Text('Réessayer'),
        ),
      );
    }
    if (_items.isEmpty) return const Center(child: Text('Aucun élément.'));
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _items.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _items.length) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: OutlinedButton(
                onPressed: _loading ? null : _loadMore,
                child: Text(_loading ? 'Chargement…' : 'Charger la suite'),
              ),
            );
          }
          return _card(_items[index]);
        },
      ),
    );
  }

  Widget _card(QueryDocumentSnapshot<Map<String, dynamic>> document) {
    final data = document.data();
    final title = _tab == 0
        ? data['title']
        : _tab == 3
            ? '${data['targetType']} • ${data['reason']}'
            : data['shopName'] ?? data['displayName'];
    final status = _tab == 2
        ? data['verificationStatus']
        : _tab == 1
            ? (data['suspended'] == true ? 'suspended' : 'active')
            : data['status'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$title',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Statut : ${status ?? 'inconnu'}'),
            if (data['details'] case final String details) ...[
              const SizedBox(height: 6),
              Text(details, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: _actions(document, data)),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
    Map<String, dynamic> data,
  ) {
    if (_tab == 0) {
      return [
        _action(document.id, 'listing', 'suspend', 'Suspendre',
            needsReason: true),
        _action(document.id, 'listing', 'restore', 'Restaurer'),
        _action(document.id, 'listing', 'archive', 'Archiver'),
      ];
    }
    if (_tab == 1) {
      final suspended = data['suspended'] == true;
      return [
        _action(document.id, 'seller', suspended ? 'restore' : 'suspend',
            suspended ? 'Restaurer' : 'Suspendre',
            needsReason: !suspended),
      ];
    }
    if (_tab == 2) {
      return [
        _action(document.id, 'verification', 'verify', 'Vérifier'),
        _action(document.id, 'verification', 'reject', 'Refuser',
            needsReason: true),
      ];
    }
    return [
      _action(document.id, 'report', 'resolve', 'Résoudre'),
      _action(document.id, 'report', 'dismiss', 'Classer'),
    ];
  }

  Widget _action(String id, String type, String action, String label,
          {bool needsReason = false}) =>
      FilledButton.tonal(
        onPressed: () => _moderate(id, type, action, label, needsReason),
        child: Text(label),
      );

  Future<void> _moderate(
    String id,
    String type,
    String action,
    String label,
    bool needsReason,
  ) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$label ?'),
        content: needsReason
            ? TextField(
                controller: controller,
                maxLength: 300,
                maxLines: 3,
                decoration:
                    const InputDecoration(labelText: 'Motif obligatoire'),
              )
            : const Text('Confirmer cette action de modération.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmer')),
        ],
      ),
    );
    final reason = controller.text.trim();
    controller.dispose();
    if (confirmed != true || (needsReason && reason.isEmpty)) return;
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('moderateVehicleEntity')
          .call({
        'targetType': type,
        'targetId': id,
        'action': action,
        'reason': reason
      });
      await _reload();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Action refusée ou impossible.')),
        );
      }
    }
  }
}
