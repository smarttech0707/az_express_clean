import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AdminGeoStatsPage extends StatefulWidget {
  const AdminGeoStatsPage({super.key});

  @override
  State<AdminGeoStatsPage> createState() => _AdminGeoStatsPageState();
}

class _AdminGeoStatsPageState extends State<AdminGeoStatsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  bool _loading = true;

  // Zone stats: zone name → order count (delivery destination)
  Map<String, int> _deliveryZones = {};
  // Route stats: 'pickup → delivery' → count
  Map<String, int> _routes = {};
  // Peak hours: hour (0–23) → count
  Map<int, int> _peakHours = {};
  // Daily totals for the last 14 days
  Map<String, int> _dailyTotals = {};

  int _totalOrders = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _loadStats();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadStats() async {
    setState(() => _loading = true);
    try {
      final since =
          Timestamp.fromDate(DateTime.now().subtract(const Duration(days: 30)));
      final snap = await FirebaseFirestore.instance
          .collection('orders')
          .where('createdAt', isGreaterThan: since)
          .orderBy('createdAt', descending: true)
          .limit(500)
          .get();

      final Map<String, int> dz = {};
      final Map<String, int> routes = {};
      final Map<int, int> hours = {};
      final Map<String, int> daily = {};

      for (final doc in snap.docs) {
        final d = doc.data();
        final deliveryZone = d['deliveryZone'] as String?;
        final pickupZone = d['pickupZone'] as String?;
        final createdAt = (d['createdAt'] as Timestamp?)?.toDate();

        // Delivery zone counts
        if (deliveryZone != null && deliveryZone.isNotEmpty) {
          dz[deliveryZone] = (dz[deliveryZone] ?? 0) + 1;
        }

        // Route counts
        if (pickupZone != null &&
            deliveryZone != null &&
            pickupZone.isNotEmpty &&
            deliveryZone.isNotEmpty) {
          final route = '$pickupZone → $deliveryZone';
          routes[route] = (routes[route] ?? 0) + 1;
        }

        // Peak hours
        if (createdAt != null) {
          final h = createdAt.hour;
          hours[h] = (hours[h] ?? 0) + 1;

          // Daily totals (last 14 days)
          final dayKey =
              '${createdAt.day.toString().padLeft(2, '0')}/${createdAt.month.toString().padLeft(2, '0')}';
          daily[dayKey] = (daily[dayKey] ?? 0) + 1;
        }
      }

      // Sort and keep top entries
      final sortedDz = Map.fromEntries(
          dz.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
      final sortedRoutes = Map.fromEntries(
          routes.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));

      setState(() {
        _deliveryZones = sortedDz;
        _routes = sortedRoutes;
        _peakHours = hours;
        _dailyTotals = daily;
        _totalOrders = snap.docs.length;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: const Text('Statistiques Géographiques',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadStats,
            tooltip: 'Actualiser',
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          labelStyle:
              const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          tabs: const [
            Tab(text: 'Zones actives'),
            Tab(text: 'Routes fréquentes'),
            Tab(text: 'Horaires de pointe'),
            Tab(text: 'Évolution'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildSummaryBar(),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _buildZonesTab(),
                      _buildRoutesTab(),
                      _buildPeakHoursTab(),
                      _buildEvolutionTab(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildSummaryBar() {
    return Container(
      color: const Color(0xFF1565C0),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(children: [
        _SummaryChip(
          icon: Icons.local_shipping_rounded,
          label: 'Commandes (30j)',
          value: '$_totalOrders',
        ),
        const SizedBox(width: 12),
        _SummaryChip(
          icon: Icons.place_rounded,
          label: 'Zones actives',
          value: '${_deliveryZones.length}',
        ),
        const SizedBox(width: 12),
        _SummaryChip(
          icon: Icons.alt_route_rounded,
          label: 'Routes',
          value: '${_routes.length}',
        ),
      ]),
    );
  }

  Widget _buildZonesTab() {
    if (_deliveryZones.isEmpty) {
      return _emptyState(
          'Aucune commande avec zone de livraison enregistrée dans les 30 derniers jours.',
          Icons.place_outlined);
    }
    final maxCount = _deliveryZones.values.reduce((a, b) => a > b ? a : b);
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _deliveryZones.length,
      itemBuilder: (context, i) {
        final entry = _deliveryZones.entries.elementAt(i);
        final pct = maxCount > 0 ? entry.value / maxCount : 0.0;
        return _ZoneBar(
          rank: i + 1,
          name: entry.key,
          count: entry.value,
          total: _totalOrders,
          pct: pct,
        );
      },
    );
  }

  Widget _buildRoutesTab() {
    if (_routes.isEmpty) {
      return _emptyState(
          'Aucune route avec zone de collecte ET zone de livraison enregistrées.',
          Icons.alt_route_outlined);
    }
    final maxCount = _routes.values.reduce((a, b) => a > b ? a : b);
    final topRoutes = _routes.entries.take(20).toList();
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: topRoutes.length,
      itemBuilder: (context, i) {
        final entry = topRoutes[i];
        final pct = maxCount > 0 ? entry.value / maxCount : 0.0;
        return _RouteCard(
          rank: i + 1,
          route: entry.key,
          count: entry.value,
          pct: pct,
        );
      },
    );
  }

  Widget _buildPeakHoursTab() {
    if (_peakHours.isEmpty) {
      return _emptyState('Aucune commande dans les 30 derniers jours.',
          Icons.access_time_outlined);
    }
    final maxCount = _peakHours.values.reduce((a, b) => a > b ? a : b);
    // Build all 24 hours
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionHeader('Commandes par heure (30 derniers jours)'),
        const SizedBox(height: 12),
        ...List.generate(24, (h) {
          final count = _peakHours[h] ?? 0;
          final pct = maxCount > 0 ? count / maxCount : 0.0;
          final label = '${h.toString().padLeft(2, '0')}h';
          final isNight = h >= 21 || h < 6;
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              SizedBox(
                width: 36,
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isNight
                            ? Colors.indigo.shade700
                            : Colors.grey.shade700)),
              ),
              Expanded(
                child: Stack(children: [
                  Container(
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: pct,
                    child: Container(
                      height: 20,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: isNight
                              ? [Colors.indigo.shade600, Colors.indigo.shade300]
                              : [
                                  const Color(0xFF1565C0),
                                  const Color(0xFF42A5F5)
                                ],
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 28,
                child: Text(
                  count > 0 ? '$count' : '',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: count > 0
                          ? Colors.grey.shade800
                          : Colors.grey.shade400),
                ),
              ),
            ]),
          );
        }),
        const SizedBox(height: 16),
        _NightServiceNote(),
      ],
    );
  }

  Widget _buildEvolutionTab() {
    if (_dailyTotals.isEmpty) {
      return _emptyState('Aucune commande dans les 30 derniers jours.',
          Icons.show_chart_outlined);
    }
    // Trier les jours chronologiquement (format DD/MM → tri naturel inversé)
    final sorted = _dailyTotals.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final maxCount = sorted.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    final totalPeriode = sorted.fold<int>(0, (s, e) => s + e.value);
    final moyenne = sorted.isEmpty ? 0 : (totalPeriode / sorted.length).round();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionHeader('Évolution quotidienne (30 derniers jours)'),
        const SizedBox(height: 8),
        Row(children: [
          _MiniStat(label: 'Total période', value: '$totalPeriode'),
          const SizedBox(width: 12),
          _MiniStat(label: 'Moyenne / jour', value: '$moyenne'),
          const SizedBox(width: 12),
          _MiniStat(label: 'Jours actifs', value: '${sorted.length}'),
        ]),
        const SizedBox(height: 16),
        ...sorted.reversed.map((entry) {
          final pct = maxCount > 0 ? entry.value / maxCount : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              SizedBox(
                width: 44,
                child: Text(entry.key,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade700)),
              ),
              Expanded(
                child: Stack(children: [
                  Container(
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: pct,
                    child: Container(
                      height: 24,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [Color(0xFF1A237E), Color(0xFF3949AB)]),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          '${entry.value}',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: pct > 0.4
                                  ? Colors.white
                                  : Colors.grey.shade800),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ]),
          );
        }),
      ],
    );
  }

  Widget _emptyState(String msg, IconData icon) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 72, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(msg,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.grey.shade500, fontSize: 14, height: 1.5)),
        ]),
      ),
    );
  }
}

// ── WIDGETS ──────────────────────────────────────────────────────────────────

class _SummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _SummaryChip(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Icon(icon, color: Colors.white70, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 16)),
              Text(label,
                  style: const TextStyle(color: Colors.white70, fontSize: 9),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A237E).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1A237E))),
          Text(label,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
        ]),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: Color(0xFF1565C0)));
  }
}

class _ZoneBar extends StatelessWidget {
  final int rank;
  final String name;
  final int count;
  final int total;
  final double pct;
  const _ZoneBar({
    required this.rank,
    required this.name,
    required this.count,
    required this.total,
    required this.pct,
  });

  @override
  Widget build(BuildContext context) {
    final sharePct =
        total > 0 ? (count / total * 100).toStringAsFixed(1) : '0.0';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Row(children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: rank <= 3
                ? [
                    const Color(0xFFFFD700),
                    const Color(0xFFC0C0C0),
                    const Color(0xFFCD7F32),
                  ][rank - 1]
                : Colors.grey.shade200,
            shape: BoxShape.circle,
          ),
          child: Text('$rank',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: rank <= 3 ? Colors.black87 : Colors.grey.shade600)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
              ),
              Text('$count livraisons',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1565C0))),
            ]),
            const SizedBox(height: 6),
            Stack(children: [
              Container(
                  height: 8,
                  decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(4))),
              FractionallySizedBox(
                widthFactor: pct,
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [Color(0xFF1565C0), Color(0xFF42A5F5)]),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Text('$sharePct% des livraisons',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ]),
        ),
      ]),
    );
  }
}

class _RouteCard extends StatelessWidget {
  final int rank;
  final String route;
  final int count;
  final double pct;
  const _RouteCard({
    required this.rank,
    required this.route,
    required this.count,
    required this.pct,
  });

  @override
  Widget build(BuildContext context) {
    final parts = route.split(' → ');
    final from = parts.isNotEmpty ? parts[0] : route;
    final to = parts.length > 1 ? parts[1] : '';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF1565C0).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('#$rank',
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1565C0))),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(children: [
              Flexible(
                child: Text(from,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.arrow_forward_rounded,
                    size: 16, color: Color(0xFF1565C0)),
              ),
              Flexible(
                child: Text(to,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
          Text('$count ×',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1565C0))),
        ]),
        const SizedBox(height: 8),
        Stack(children: [
          Container(
              height: 6,
              decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(3))),
          FractionallySizedBox(
            widthFactor: pct,
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFF1565C0), Color(0xFF42A5F5)]),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}

class _NightServiceNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.indigo.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.indigo.shade200),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.nights_stay_rounded,
            color: Colors.indigo.shade600, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Service de nuit (21h–6h) : tarif majoré (1 000 FCFA). '
            'Livraisons >10 km refusées après 21h.',
            style: TextStyle(
                fontSize: 12, color: Colors.indigo.shade700, height: 1.4),
          ),
        ),
      ]),
    );
  }
}
