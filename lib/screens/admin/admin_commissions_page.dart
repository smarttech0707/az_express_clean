import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';

const _kCommission = 100;

class AdminCommissionsPage extends StatefulWidget {
  const AdminCommissionsPage({super.key});

  @override
  State<AdminCommissionsPage> createState() => _AdminCommissionsPageState();
}

class _AdminCommissionsPageState extends State<AdminCommissionsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  int _filterPeriod = 0; // 0=aujourd'hui  1=semaine  2=mois  3=tout

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F3F7),
      appBar: AppBar(
        title: Text('Commissions livreurs',
            style: GoogleFonts.inter(
                color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
        bottom: TabBar(
          controller: _tabs,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          indicatorColor: Colors.white,
          labelStyle:
              GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13),
          tabs: const [
            Tab(text: 'Statistiques'),
            Tab(text: 'Historique'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _StatsTab(filterPeriod: _filterPeriod,
              onPeriodChanged: (v) => setState(() => _filterPeriod = v)),
          const _HistoryTab(),
        ],
      ),
    );
  }
}

// ── ONGLET STATISTIQUES ───────────────────────────────────────────────────

class _StatsTab extends StatelessWidget {
  final int filterPeriod;
  final ValueChanged<int> onPeriodChanged;
  const _StatsTab({required this.filterPeriod, required this.onPeriodChanged});

  DateTime _startDate() {
    final now = DateTime.now();
    switch (filterPeriod) {
      case 0: return DateTime(now.year, now.month, now.day);
      case 1: return DateTime(now.year, now.month, now.day)
                    .subtract(Duration(days: now.weekday - 1));
      case 2: return DateTime(now.year, now.month, 1);
      default: return DateTime(2020);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('commissions')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final all  = snap.data!.docs;
        final now  = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final month = DateTime(now.year, now.month, 1);
        final start = _startDate();

        int totalAll        = 0;
        int totalToday      = 0;
        int totalMonth      = 0;
        int countAll        = 0;
        int countToday      = 0;
        int countMonth      = 0;
        int totalPeriod     = 0;
        int countPeriod     = 0;
        int totalDriverGain = 0;

        for (final doc in all) {
          final d    = doc.data() as Map<String, dynamic>;
          final ts   = (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime(2020);
          final amt  = (d['amount'] as num? ?? 0).toInt();
          final gain = (d['driverGain'] as num? ?? 0).toInt();

          totalAll++;
          countAll++;
          totalDriverGain += gain;

          if (!ts.isBefore(today)) { totalToday++; countToday++; }
          if (!ts.isBefore(month)) { totalMonth++; countMonth++; }
          if (!ts.isBefore(start)) {
            totalPeriod += amt;
            countPeriod++;
          }
        }

        // Real totals using amount field
        totalAll   = 0;
        totalToday = 0;
        totalMonth = 0;
        for (final doc in all) {
          final d  = doc.data() as Map<String, dynamic>;
          final ts = (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime(2020);
          final amt = (d['amount'] as num? ?? _kCommission).toInt();
          totalAll += amt;
          if (!ts.isBefore(today)) totalToday += amt;
          if (!ts.isBefore(month)) totalMonth += amt;
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Filtre période ──────────────────────────────────────────
              Row(
                children: [
                  _PeriodBtn("Aujourd'hui", 0, filterPeriod, onPeriodChanged),
                  const SizedBox(width: 6),
                  _PeriodBtn('Semaine', 1, filterPeriod, onPeriodChanged),
                  const SizedBox(width: 6),
                  _PeriodBtn('Mois', 2, filterPeriod, onPeriodChanged),
                  const SizedBox(width: 6),
                  _PeriodBtn('Tout', 3, filterPeriod, onPeriodChanged),
                ],
              ),
              const SizedBox(height: 18),

              // ── Carte récap période ─────────────────────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1565C0), Color(0xFF1E88E5)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF1565C0).withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Text(
                      _periodLabel(filterPeriod),
                      style: GoogleFonts.inter(
                          color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$totalPeriod FCFA',
                      style: GoogleFonts.inter(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '$countPeriod livraisons terminées',
                      style: GoogleFonts.inter(
                          color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        const _MiniStat('Commission/livraison',
                            '$_kCommission FCFA', Colors.white),
                        _MiniStat('Gain livreur moyen',
                            countPeriod > 0
                                ? '${totalDriverGain ~/ countAll} FCFA'
                                : '—',
                            Colors.white),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // ── Grille des stats ────────────────────────────────────────
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.4,
                children: [
                  _StatCard(
                    label: 'Total commissions',
                    value: '$totalAll FCFA',
                    sub: '$countAll livraisons',
                    icon: Icons.account_balance_wallet_rounded,
                    color: const Color(0xFF1565C0),
                  ),
                  _StatCard(
                    label: "Aujourd'hui",
                    value: '$totalToday FCFA',
                    sub: '$countToday livraison(s)',
                    icon: Icons.today_rounded,
                    color: Colors.green,
                  ),
                  _StatCard(
                    label: 'Ce mois',
                    value: '$totalMonth FCFA',
                    sub: '$countMonth livraison(s)',
                    icon: Icons.calendar_month_rounded,
                    color: Colors.orange,
                  ),
                  const _StatCard(
                    label: 'Commission fixe',
                    value: '$_kCommission FCFA',
                    sub: 'par livraison',
                    icon: Icons.percent_rounded,
                    color: Colors.purple,
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Classement livreurs ──────────────────────────────────────
              Text('Top livreurs (période)',
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 10),
              _TopDrivers(docs: all, start: start),

              const SizedBox(height: 20),

              // ── Graphique 7 jours ───────────────────────────────────────
              _CommissionChart(docs: all),
            ],
          ),
        );
      },
    );
  }

  String _periodLabel(int p) {
    switch (p) {
      case 0: return "Commissions aujourd'hui";
      case 1: return 'Commissions cette semaine';
      case 2: return 'Commissions ce mois';
      default: return 'Commissions totales';
    }
  }
}

// ── TOP LIVREURS ─────────────────────────────────────────────────────────

class _TopDrivers extends StatelessWidget {
  final List<QueryDocumentSnapshot> docs;
  final DateTime start;
  const _TopDrivers({required this.docs, required this.start});

  @override
  Widget build(BuildContext context) {
    final Map<String, Map<String, dynamic>> byDriver = {};

    for (final doc in docs) {
      final d   = doc.data() as Map<String, dynamic>;
      final ts  = (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime(2020);
      if (ts.isBefore(start)) continue;

      final id   = d['driverId'] as String? ?? '';
      final name = d['driverName'] as String? ?? id;
      final amt  = (d['amount'] as num? ?? _kCommission).toInt();

      if (!byDriver.containsKey(id)) {
        byDriver[id] = {'name': name, 'total': 0, 'count': 0};
      }
      byDriver[id]!['total'] = (byDriver[id]!['total'] as int) + amt;
      byDriver[id]!['count'] = (byDriver[id]!['count'] as int) + 1;
    }

    final sorted = byDriver.entries.toList()
      ..sort((a, b) =>
          (b.value['total'] as int).compareTo(a.value['total'] as int));

    if (sorted.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text('Aucune donnée pour cette période',
            style: GoogleFonts.inter(color: Colors.grey, fontSize: 13)),
      );
    }

    return Column(
      children: sorted.take(5).map((e) {
        final rank = sorted.indexOf(e) + 1;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 6,
                  offset: const Offset(0, 2)),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: rank == 1
                      ? Colors.amber
                      : rank == 2
                          ? Colors.grey.shade400
                          : rank == 3
                              ? const Color(0xFFCD7F32)
                              : const Color(0xFF1565C0).withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text('$rank',
                      style: GoogleFonts.inter(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: rank <= 3 ? Colors.white : const Color(0xFF1565C0))),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.value['name'] as String,
                        style: GoogleFonts.inter(
                            fontWeight: FontWeight.w600, fontSize: 13)),
                    Text('${e.value['count']} livraison(s)',
                        style: GoogleFonts.inter(
                            fontSize: 11, color: Colors.grey.shade500)),
                  ],
                ),
              ),
              Text('${e.value['total']} FCFA',
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: const Color(0xFF1565C0))),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// ── GRAPHIQUE 7 JOURS ─────────────────────────────────────────────────────

class _CommissionChart extends StatelessWidget {
  final List<QueryDocumentSnapshot> docs;
  const _CommissionChart({required this.docs});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final daily = List<int>.filled(7, 0);

    for (final doc in docs) {
      final d  = doc.data() as Map<String, dynamic>;
      final ts = (d['createdAt'] as Timestamp?)?.toDate();
      if (ts == null) continue;
      final diff = now.difference(ts).inDays;
      if (diff >= 0 && diff < 7) {
        daily[6 - diff] += (d['amount'] as num? ?? _kCommission).toInt();
      }
    }

    const days = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
    final labels = List.generate(7, (i) {
      final d = now.subtract(Duration(days: 6 - i));
      return days[d.weekday - 1];
    });

    final maxVal = daily.isEmpty ? 1 : daily.reduce((a, b) => a > b ? a : b);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Commissions — 7 derniers jours',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 16),
          SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(7, (i) {
                final ratio = maxVal > 0 ? daily[i] / maxVal : 0.0;
                final barH  = 80.0 * ratio;
                final isToday = i == 6;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        SizedBox(
                          height: 20,
                          child: daily[i] > 0
                              ? Text(
                                  '${daily[i]}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: isToday
                                        ? const Color(0xFF1565C0)
                                        : Colors.grey.shade600,
                                  ),
                                )
                              : null,
                        ),
                        const SizedBox(height: 2),
                        Container(
                          height: barH.clamp(4, 80),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: isToday
                                  ? [const Color(0xFF1565C0), const Color(0xFF42A5F5)]
                                  : [Colors.blue.shade200, Colors.blue.shade400],
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                            ),
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(labels[i],
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                              color: isToday
                                  ? const Color(0xFF1565C0)
                                  : Colors.grey.shade500,
                            )),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

// ── ONGLET HISTORIQUE ─────────────────────────────────────────────────────

class _HistoryTab extends StatefulWidget {
  const _HistoryTab();

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  String _search = '';
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Barre de recherche
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 2)),
              ],
            ),
            child: TextField(
              controller: _ctrl,
              onChanged: (v) => setState(() => _search = v.toLowerCase()),
              style: GoogleFonts.inter(fontSize: 13.5),
              decoration: InputDecoration(
                hintText: 'Rechercher un livreur…',
                hintStyle: GoogleFonts.inter(fontSize: 13.5, color: Colors.grey),
                prefixIcon: const Icon(Icons.search_rounded,
                    color: Color(0xFF1565C0), size: 20),
                suffixIcon: _search.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _ctrl.clear();
                          setState(() => _search = '');
                        })
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('commissions')
                .orderBy('createdAt', descending: true)
                .limit(200)
                .snapshots(),
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              var docs = snap.data!.docs;
              if (_search.isNotEmpty) {
                docs = docs.where((d) {
                  final data = d.data() as Map<String, dynamic>;
                  final name = (data['driverName'] as String? ?? '').toLowerCase();
                  return name.contains(_search);
                }).toList();
              }

              if (docs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.receipt_long_rounded,
                          size: 56, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      Text('Aucune commission enregistrée',
                          style: GoogleFonts.inter(
                              color: Colors.grey.shade500, fontSize: 14)),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                itemCount: docs.length,
                itemBuilder: (_, i) => _CommissionTile(doc: docs[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CommissionTile extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _CommissionTile({required this.doc});

  @override
  Widget build(BuildContext context) {
    final d           = doc.data() as Map<String, dynamic>;
    final driverName  = d['driverName'] as String? ?? '—';
    final deliveryFee = (d['deliveryFee'] as num? ?? 0).toInt();
    final driverGain  = (d['driverGain'] as num? ?? 0).toInt();
    final amount      = (d['amount'] as num? ?? _kCommission).toInt();
    final payMethod   = d['paymentMethod'] as String? ?? '';
    final ts          = (d['createdAt'] as Timestamp?)?.toDate();

    final dateStr = ts != null
        ? '${_z(ts.day)}/${_z(ts.month)}/${ts.year} ${_z(ts.hour)}:${_z(ts.minute)}'
        : '—';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            // Icône
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF1565C0).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.delivery_dining_rounded,
                  color: Color(0xFF1565C0), size: 22),
            ),
            const SizedBox(width: 12),
            // Infos
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(driverName,
                      style: GoogleFonts.inter(
                          fontWeight: FontWeight.bold, fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(dateStr,
                      style: GoogleFonts.inter(
                          fontSize: 11, color: Colors.grey.shade500)),
                  const SizedBox(height: 4),
                  // Détail montants
                  Row(children: [
                    _badge('Course: $deliveryFee F', Colors.grey.shade600),
                    const SizedBox(width: 5),
                    _badge('AZ: $amount F', const Color(0xFF1565C0)),
                    const SizedBox(width: 5),
                    _badge('Livreur: $driverGain F', Colors.green.shade700),
                  ]),
                  if (payMethod.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Row(children: [
                      Icon(
                        payMethod == 'wallet'
                            ? Icons.account_balance_wallet_rounded
                            : Icons.money_rounded,
                        size: 11,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        payMethod == 'wallet' ? 'Paiement wallet' : 'Espèces',
                        style: GoogleFonts.inter(
                            fontSize: 10.5, color: Colors.grey.shade400),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
            // Commission montant mis en avant
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('$amount',
                    style: GoogleFonts.inter(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: const Color(0xFF1565C0))),
                Text('FCFA',
                    style: GoogleFonts.inter(
                        fontSize: 10,
                        color: const Color(0xFF1565C0).withValues(alpha: 0.7))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w600)),
    );
  }

  String _z(int n) => n.toString().padLeft(2, '0');
}

// ── WIDGETS COMMUNS ───────────────────────────────────────────────────────

class _PeriodBtn extends StatelessWidget {
  final String label;
  final int value;
  final int current;
  final ValueChanged<int> onChange;
  const _PeriodBtn(this.label, this.value, this.current, this.onChange);

  @override
  Widget build(BuildContext context) {
    final sel = value == current;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChange(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: sel ? const Color(0xFF1565C0) : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: sel
                    ? const Color(0xFF1565C0)
                    : Colors.grey.shade300),
            boxShadow: sel
                ? [
                    BoxShadow(
                        color: const Color(0xFF1565C0).withValues(alpha: 0.25),
                        blurRadius: 6,
                        offset: const Offset(0, 2))
                  ]
                : null,
          ),
          child: Text(label,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                  color: sel ? Colors.white : Colors.grey.shade600)),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final IconData icon;
  final Color color;
  const _StatCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const Spacer(),
          Text(value,
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: color)),
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 11, color: Colors.grey.shade600)),
          Text(sub,
              style: GoogleFonts.inter(
                  fontSize: 10, color: Colors.grey.shade400)),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _MiniStat(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: GoogleFonts.inter(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 15)),
        Text(label,
            style: GoogleFonts.inter(
                color: color.withValues(alpha: 0.7), fontSize: 10.5)),
      ],
    );
  }
}
