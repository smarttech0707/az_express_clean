import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/firestore_service.dart';
import '../../models/driver_earnings_summary.dart';
import '../../widgets/stream_error_state.dart';
import '../../theme/app_theme.dart';

class AdminEarnings extends StatefulWidget {
  const AdminEarnings({super.key});

  @override
  State<AdminEarnings> createState() => _AdminEarningsState();
}

class _AdminEarningsState extends State<AdminEarnings> {
  int _period = 0; // 0=jour, 1=semaine, 2=mois

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text("Revenus & Gains"),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // ── Sélecteur période ─────────────────────────
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _periodBtn("Aujourd'hui", 0),
                const SizedBox(width: 8),
                _periodBtn("Semaine", 1),
                const SizedBox(width: 8),
                _periodBtn("Mois", 2),
              ],
            ),
          ),

          // ── Totaux globaux ────────────────────────────
          _GlobalTotals(period: _period),

          const SizedBox(height: 8),

          // ── Graphique 7 jours ────────────────────────
          const _WeeklyChart(),

          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Détail par livreur",
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Colors.black87),
              ),
            ),
          ),

          // ── Liste livreurs ────────────────────────────
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream:
                  FirebaseFirestore.instance.collection("livreurs").snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return const StreamErrorState(
                      message: "Impossible de charger les livreurs.");
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final drivers = snap.data!.docs;
                if (drivers.isEmpty) {
                  return const Center(child: Text("Aucun livreur"));
                }
                return ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: drivers.length,
                  itemBuilder: (context, i) {
                    final doc = drivers[i];
                    final data = doc.data() as Map<String, dynamic>;
                    return _DriverRevenueCard(
                      driverId: doc.id,
                      name: data["name"] ?? "—",
                      phone: data["phone"] ?? "—",
                      wallet: (data["wallet"] as num? ?? 0).toInt(),
                      isOnline: data["isOnline"] == true,
                      period: _period,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _periodBtn(String label, int value) {
    final selected = _period == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _period = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? AppColors.primary : Colors.grey.shade300,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? Colors.white : Colors.grey,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Totaux globaux AZ Express ─────────────────────────────────

class _GlobalTotals extends StatelessWidget {
  final int period;
  const _GlobalTotals({required this.period});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final start = period == 0
        ? DateTime(now.year, now.month, now.day)
        : period == 1
            ? DateTime(now.year, now.month, now.day)
                .subtract(Duration(days: now.weekday - 1))
            : DateTime(now.year, now.month, 1);

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection("orders")
          .where("status", isEqualTo: "delivered")
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError || !snap.hasData) return const SizedBox.shrink();

        int totalCourses = 0;
        int totalCommissions = 0;
        int totalBudget = 0;
        double avgRating = 0;
        int ratingCount = 0;

        for (final doc in snap.data!.docs) {
          final data = doc.data() as Map<String, dynamic>;
          final ts = data["createdAt"];
          if (ts == null) continue;
          final date = (ts as Timestamp).toDate();
          if (date.isBefore(start)) continue;

          final budget = (data["budget"] as num? ?? 0).toInt();
          totalCourses++;
          totalBudget += budget;
          totalCommissions += FirestoreService().calculateCommission(budget);
          if (data["rating"] != null) {
            avgRating += (data["rating"] as num).toDouble();
            ratingCount++;
          }
        }

        final avg = ratingCount > 0 ? avgRating / ratingCount : 0.0;

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.primary, Color(0xFFFF8F00)],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.orange.withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _stat("Courses", "$totalCourses"),
                  _stat("Revenus AZ", "$totalCommissions FCFA"),
                  _stat("Vol. total", "$totalBudget FCFA"),
                ],
              ),
              if (ratingCount > 0) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.star, color: Colors.amber, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      "Note moyenne : ${avg.toStringAsFixed(1)}/5  ($ratingCount avis)",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16)),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ],
    );
  }
}

// ── Carte par livreur ─────────────────────────────────────────

class _DriverRevenueCard extends StatelessWidget {
  final String driverId;
  final String name;
  final String phone;
  final int wallet;
  final bool isOnline;
  final int period;

  const _DriverRevenueCard({
    required this.driverId,
    required this.name,
    required this.phone,
    required this.wallet,
    required this.isOnline,
    required this.period,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DriverEarningsSummary>(
      future: FirestoreService().driverEarningsSummary(driverId),
      builder: (context, snap) {
        final s = snap.data;
        final courses = s == null
            ? 0
            : (period == 0
                ? s.todayCourses
                : period == 1
                    ? s.weekCourses
                    : s.monthCourses);
        final gain = s == null
            ? 0
            : (period == 0
                ? s.todayGain
                : period == 1
                    ? s.weekGain
                    : s.monthGain);
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor:
                    isOnline ? Colors.green.shade100 : Colors.grey.shade200,
                child: Icon(Icons.delivery_dining,
                    color: isOnline ? Colors.green : Colors.grey),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(phone,
                        style:
                            const TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _chip("$courses courses", Colors.blue),
                        const SizedBox(width: 6),
                        _chip("$gain FCFA gain", Colors.green),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text("Crédit",
                      style:
                          TextStyle(color: Colors.grey.shade500, fontSize: 11)),
                  Text(
                    "$wallet FCFA",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: wallet < 200 ? Colors.red : Colors.orange,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }
}

// ── Graphique 7 jours ────────────────────────────────────────

class _WeeklyChart extends StatefulWidget {
  const _WeeklyChart();

  @override
  State<_WeeklyChart> createState() => _WeeklyChartState();
}

class _WeeklyChartState extends State<_WeeklyChart>
    with SingleTickerProviderStateMixin {
  List<int> _orders = List.filled(7, 0);
  List<int> _revenues = List.filled(7, 0);
  bool _loading = true;
  bool _showRevenue = false;
  late AnimationController _animCtrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _anim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
    _fetchData();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchData() async {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day - 6);

    final snap = await FirebaseFirestore.instance
        .collection('orders')
        .where('status', isEqualTo: 'delivered')
        .where('createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
        .get();

    final orders = List<int>.filled(7, 0);
    final revenues = List<int>.filled(7, 0);

    for (final doc in snap.docs) {
      final data = doc.data();
      final ts = data['createdAt'] as Timestamp?;
      if (ts == null) continue;
      final date = ts.toDate();
      final dayDiff = now.difference(date).inDays;
      if (dayDiff >= 0 && dayDiff < 7) {
        final idx = 6 - dayDiff;
        orders[idx]++;
        revenues[idx] += FirestoreService()
            .calculateCommission((data['budget'] as num? ?? 0).toInt());
      }
    }

    if (!mounted) return;
    setState(() {
      _orders = orders;
      _revenues = revenues;
      _loading = false;
    });
    _animCtrl.forward(from: 0);
  }

  List<String> get _dayLabels {
    const days = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
    final now = DateTime.now();
    return List.generate(7, (i) {
      final d = now.subtract(Duration(days: 6 - i));
      return days[d.weekday - 1];
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _showRevenue ? _revenues : _orders;
    final maxVal = data.isEmpty ? 1 : data.reduce((a, b) => a > b ? a : b);
    final labels = _dayLabels;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title + toggle
          Row(
            children: [
              const Text(
                '7 derniers jours',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const Spacer(),
              _ToggleChip(
                label: 'Courses',
                active: !_showRevenue,
                onTap: () => setState(() {
                  _showRevenue = false;
                  _animCtrl.forward(from: 0);
                }),
              ),
              const SizedBox(width: 6),
              _ToggleChip(
                label: 'Revenus',
                active: _showRevenue,
                onTap: () => setState(() {
                  _showRevenue = true;
                  _animCtrl.forward(from: 0);
                }),
              ),
            ],
          ),

          const SizedBox(height: 18),

          if (_loading)
            const SizedBox(
              height: 100,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            AnimatedBuilder(
              animation: _anim,
              builder: (context, _) {
                return SizedBox(
                  height: 110,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: List.generate(7, (i) {
                      final ratio =
                          maxVal > 0 ? data[i] / maxVal * _anim.value : 0.0;
                      final barH = 80.0 * ratio;
                      final isToday = i == 6;

                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              // Value label
                              SizedBox(
                                height: 20,
                                child: data[i] > 0
                                    ? Text(
                                        _showRevenue
                                            ? '${data[i] ~/ 1000}k'
                                            : '${data[i]}',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: isToday
                                              ? const Color(0xFFFF5A3C)
                                              : Colors.grey.shade600,
                                        ),
                                      )
                                    : null,
                              ),
                              const SizedBox(height: 2),
                              // Bar
                              Container(
                                height: barH.clamp(4, 80),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: isToday
                                        ? [
                                            const Color(0xFFFF5A3C),
                                            const Color(0xFFFF8F00)
                                          ]
                                        : [
                                            Colors.blue.shade300,
                                            Colors.blue.shade500
                                          ],
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                              const SizedBox(height: 6),
                              // Day label
                              Text(
                                labels[i],
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: isToday
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: isToday
                                      ? const Color(0xFFFF5A3C)
                                      : Colors.grey.shade500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ToggleChip(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active ? AppColors.primary : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            color: active ? Colors.white : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }
}
