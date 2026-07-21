import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';

class AdminDriversRanking extends StatefulWidget {
  const AdminDriversRanking({super.key});

  @override
  State<AdminDriversRanking> createState() => _AdminDriversRankingState();
}

class _AdminDriversRankingState extends State<AdminDriversRanking> {
  List<_DriverEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);

    final results = await Future.wait([
      FirebaseFirestore.instance.collection('livreurs').get(),
      FirebaseFirestore.instance
          .collection('orders')
          .where('status', isEqualTo: 'delivered')
          .get(),
    ]);

    final driversSnap = results[0];
    final ordersSnap = results[1];

    // Compute per-driver stats from orders
    final Map<String, int> deliveries = {};
    final Map<String, double> ratingSum = {};
    final Map<String, int> ratingCount = {};

    for (final doc in ordersSnap.docs) {
      final data = doc.data();
      final driverId = data['driverId'] as String?;
      if (driverId == null) continue;
      deliveries[driverId] = (deliveries[driverId] ?? 0) + 1;
      final r = data['rating'];
      if (r != null) {
        ratingSum[driverId] = (ratingSum[driverId] ?? 0) + (r as num).toDouble();
        ratingCount[driverId] = (ratingCount[driverId] ?? 0) + 1;
      }
    }

    final entries = driversSnap.docs.map((doc) {
      final data = doc.data();
      final id = doc.id;
      final rc = ratingCount[id] ?? 0;
      return _DriverEntry(
        id: id,
        name: data['name'] ?? '—',
        phone: data['phone'] ?? '—',
        wallet: (data['wallet'] as num? ?? 0).toInt(),
        isOnline: data['isOnline'] == true,
        deliveries: deliveries[id] ?? 0,
        avgRating: rc > 0 ? (ratingSum[id] ?? 0) / rc : 0.0,
        ratingCount: rc,
      );
    }).toList()
      ..sort((a, b) => b.deliveries.compareTo(a.deliveries));

    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final online = _entries.where((e) => e.isOnline).length;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(
          'Classement Livreurs',
          style: GoogleFonts.urbanist(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFFFF5A3C),
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: CustomScrollView(
                slivers: [
                  // ── Summary header ─────────────────────────
                  SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.all(16),
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFF5A3C), Color(0xFFFF8F00)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFFF5A3C).withValues(alpha: 0.3),
                            blurRadius: 14,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _headerStat('${_entries.length}', 'Livreurs',
                              Icons.people_rounded),
                          _divider(),
                          _headerStat('$online', 'En ligne',
                              Icons.circle, color: const Color(0xFF22C55E)),
                          _divider(),
                          _headerStat(
                            _entries.isNotEmpty
                                ? '${_entries.fold(0, (s, e) => s + e.deliveries)}'
                                : '0',
                            'Courses',
                            Icons.check_circle_rounded,
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ── List ────────────────────────────────────
                  _entries.isEmpty
                      ? SliverFillRemaining(
                          child: Center(
                            child: Text('Aucun livreur',
                                style: GoogleFonts.urbanist(color: Colors.grey)),
                          ),
                        )
                      : SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, i) => _RankCard(
                                entry: _entries[i],
                                rank: i + 1,
                              ),
                              childCount: _entries.length,
                            ),
                          ),
                        ),
                ],
              ),
            ),
    );
  }

  Widget _headerStat(String value, String label, IconData icon,
      {Color? color}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color ?? Colors.white, size: 20),
        const SizedBox(height: 4),
        Text(
          value,
          style: GoogleFonts.urbanist(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ],
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 48,
        color: Colors.white.withValues(alpha: 0.3),
      );
}

// ─────────────────────────────────────────────────────────────────────────────

class _DriverEntry {
  final String id;
  final String name;
  final String phone;
  final int wallet;
  final bool isOnline;
  final int deliveries;
  final double avgRating;
  final int ratingCount;

  const _DriverEntry({
    required this.id,
    required this.name,
    required this.phone,
    required this.wallet,
    required this.isOnline,
    required this.deliveries,
    required this.avgRating,
    required this.ratingCount,
  });
}

// ─────────────────────────────────────────────────────────────────────────────

class _RankCard extends StatelessWidget {
  final _DriverEntry entry;
  final int rank;

  const _RankCard({required this.entry, required this.rank});

  Color get _medalColor {
    switch (rank) {
      case 1:
        return const Color(0xFFFFD700);
      case 2:
        return const Color(0xFFC0C0C0);
      case 3:
        return const Color(0xFFCD7F32);
      default:
        return Colors.grey.shade300;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTop3 = rank <= 3;
    final medals = ['🥇', '🥈', '🥉'];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: isTop3
            ? Border.all(color: _medalColor.withValues(alpha: 0.7), width: 2)
            : null,
        boxShadow: [
          BoxShadow(
            color: isTop3
                ? _medalColor.withValues(alpha: 0.18)
                : Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            // Rank badge
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: isTop3
                    ? _medalColor.withValues(alpha: 0.14)
                    : Colors.grey.shade100,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: isTop3
                    ? Text(medals[rank - 1],
                        style: const TextStyle(fontSize: 24))
                    : Text(
                        '#$rank',
                        style: GoogleFonts.urbanist(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 14),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name + online dot
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.name,
                          style: GoogleFonts.urbanist(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: Colors.black87,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: entry.isOnline
                              ? const Color(0xFF22C55E)
                              : Colors.grey.shade300,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  // Chips row
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _Chip(
                        icon: Icons.check_circle_outline_rounded,
                        label: '${entry.deliveries} courses',
                        color: const Color(0xFFFF5A3C),
                      ),
                      if (entry.avgRating > 0)
                        _Chip(
                          icon: Icons.star_rounded,
                          label:
                              '${entry.avgRating.toStringAsFixed(1)} (${entry.ratingCount})',
                          color: Colors.amber.shade700,
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry.phone,
                    style: GoogleFonts.urbanist(
                        color: Colors.grey.shade400, fontSize: 11),
                  ),
                ],
              ),
            ),

            // Wallet
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Crédit',
                    style: TextStyle(
                        color: Colors.grey.shade400, fontSize: 11)),
                const SizedBox(height: 2),
                Text(
                  '${entry.wallet} F',
                  style: GoogleFonts.urbanist(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: entry.wallet < 200
                        ? Colors.red
                        : const Color(0xFFFF5A3C),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _Chip(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
