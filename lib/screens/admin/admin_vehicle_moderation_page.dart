import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class AdminVehicleModerationPage extends StatefulWidget {
  const AdminVehicleModerationPage({super.key});

  @override
  State<AdminVehicleModerationPage> createState() =>
      _AdminVehicleModerationPageState();
}

class _AdminVehicleModerationPageState extends State<AdminVehicleModerationPage>
    with SingleTickerProviderStateMixin {
  static const _pageSize = 20;
  static const _tabCount = 4;
  late final TabController _tabController;
  final _itemsByTab = List.generate(
    _tabCount,
    (_) => <QueryDocumentSnapshot<Map<String, dynamic>>>[],
  );
  final _cursors =
      List<DocumentSnapshot<Map<String, dynamic>>?>.filled(_tabCount, null);
  final _loadingByTab = List<bool>.filled(_tabCount, false);
  final _hasMoreByTab = List<bool>.filled(_tabCount, true);
  final _errorsByTab = List<Object?>.filled(_tabCount, null);
  final _loadGenerationByTab = List<int>.filled(_tabCount, 0);

  String _collectionForTab(int tab) => switch (tab) {
        0 => 'vehicle_listings',
        1 || 2 => 'vehicle_seller_profiles',
        _ => 'vehicle_reports',
      };

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabCount, vsync: this)
      ..addListener(_handleTabChange);
    _loadMore(0);
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabChange)
      ..dispose();
    super.dispose();
  }

  void _handleTabChange() {
    final tab = _tabController.index;
    if (_itemsByTab[tab].isEmpty && !_loadingByTab[tab] && _hasMoreByTab[tab]) {
      _loadMore(tab);
    }
  }

  Future<void> _reload(int tab) async {
    setState(() {
      _loadGenerationByTab[tab]++;
      _itemsByTab[tab].clear();
      _cursors[tab] = null;
      _hasMoreByTab[tab] = true;
      _loadingByTab[tab] = false;
      _errorsByTab[tab] = null;
    });
    await _loadMore(tab);
  }

  Future<void> _loadMore(int tab) async {
    if (_loadingByTab[tab] || !_hasMoreByTab[tab]) return;
    final generation = _loadGenerationByTab[tab];
    setState(() {
      _loadingByTab[tab] = true;
      _errorsByTab[tab] = null;
    });
    try {
      final collection = _collectionForTab(tab);
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collection(collection)
          .orderBy(collection == 'vehicle_reports' ? 'createdAt' : 'updatedAt',
              descending: true)
          .limit(_pageSize + 1);
      if (tab == 2) {
        query = query.where('sellerType', isEqualTo: 'professional');
      }
      final cursor = _cursors[tab];
      if (cursor != null) query = query.startAfterDocument(cursor);
      final snapshot = await query.get();
      final page = snapshot.docs.take(_pageSize).toList();
      if (!mounted) return;
      if (generation != _loadGenerationByTab[tab]) return;
      setState(() {
        _itemsByTab[tab].addAll(page);
        _cursors[tab] = page.isEmpty ? null : page.last;
        _hasMoreByTab[tab] = snapshot.docs.length > _pageSize;
      });
    } catch (error) {
      if (mounted && generation == _loadGenerationByTab[tab]) {
        setState(() => _errorsByTab[tab] = error);
      }
    } finally {
      if (mounted && generation == _loadGenerationByTab[tab]) {
        setState(() => _loadingByTab[tab] = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 400;
    final textScaler = MediaQuery.textScalerOf(context);
    final titleSize = compact ? 16.0 : AppTypography.titleLarge(context);
    final tabHeight =
        (textScaler.scale(AppTypography.labelLarge(context)) * 1.4 + 20)
            .clamp(48.0, double.infinity);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: compact ? 8 : 16,
        toolbarHeight: (textScaler.scale(titleSize) * 1.4 + 16)
            .clamp(56.0, double.infinity),
        title: Tooltip(
          message: 'Modération Auto & Moto',
          child: Text(
            'Modération Auto & Moto',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.titleLargeStyle(context).copyWith(
              fontSize: titleSize,
            ),
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelPadding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
          labelStyle: AppTypography.labelLargeStyle(context),
          unselectedLabelStyle: AppTypography.labelLargeStyle(context),
          tabs: [
            for (final label in const [
              'Annonces',
              'Vendeurs',
              'Pros/Magasins',
              'Signalements',
            ])
              Tab(
                height: tabHeight,
                child: Text(label, maxLines: 1, softWrap: false),
              ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: TabBarView(
          controller: _tabController,
          children: List.generate(_tabCount, _tabBody),
        ),
      ),
    );
  }

  Widget _tabBody(int tab) {
    final items = _itemsByTab[tab];
    final loading = _loadingByTab[tab];
    final error = _errorsByTab[tab];
    if (loading && items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null && items.isEmpty) {
      return Center(
        child: FilledButton.tonal(
          onPressed: () => _reload(tab),
          child: const Text('Réessayer'),
        ),
      );
    }
    if (items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Aucun élément.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _reload(tab),
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: items.length + (_hasMoreByTab[tab] ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == items.length) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: OutlinedButton(
                onPressed: loading ? null : () => _loadMore(tab),
                child: Text(loading ? 'Chargement…' : 'Charger la suite'),
              ),
            );
          }
          return _card(items[index], tab);
        },
      ),
    );
  }

  Widget _card(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
    int tab,
  ) {
    final data = document.data();
    final title = tab == 0
        ? data['title']
        : tab == 3
            ? '${data['targetType']} • ${data['reason']}'
            : data['shopName'] ?? data['displayName'];
    final status = tab == 2
        ? data['verificationStatus']
        : tab == 1
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
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _actions(document, data, tab),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
    Map<String, dynamic> data,
    int tab,
  ) {
    if (tab == 0) {
      return [
        _action(document.id, 'listing', 'suspend', 'Suspendre',
            tab: tab, needsReason: true),
        _action(document.id, 'listing', 'restore', 'Restaurer', tab: tab),
        _action(document.id, 'listing', 'archive', 'Archiver', tab: tab),
      ];
    }
    if (tab == 1) {
      final suspended = data['suspended'] == true;
      return [
        _action(document.id, 'seller', suspended ? 'restore' : 'suspend',
            suspended ? 'Restaurer' : 'Suspendre',
            tab: tab, needsReason: !suspended),
      ];
    }
    if (tab == 2) {
      return [
        _action(document.id, 'verification', 'verify', 'Vérifier', tab: tab),
        _action(document.id, 'verification', 'reject', 'Refuser',
            tab: tab, needsReason: true),
      ];
    }
    return [
      _action(document.id, 'report', 'resolve', 'Résoudre', tab: tab),
      _action(document.id, 'report', 'dismiss', 'Classer', tab: tab),
    ];
  }

  Widget _action(String id, String type, String action, String label,
          {required int tab, bool needsReason = false}) =>
      FilledButton.tonal(
        onPressed: () => _moderate(id, type, action, label, tab, needsReason),
        child: Text(label),
      );

  Future<void> _moderate(
    String id,
    String type,
    String action,
    String label,
    int tab,
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
      await _reload(tab);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Action refusée ou impossible.')),
        );
      }
    }
  }
}
