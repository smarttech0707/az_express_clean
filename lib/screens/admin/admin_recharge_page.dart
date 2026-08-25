import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../services/firestore_service.dart';
import '../../theme/app_theme.dart';

class AdminRechargePage extends StatefulWidget {
  const AdminRechargePage({super.key});

  @override
  State<AdminRechargePage> createState() => _AdminRechargePageState();
}

class _AdminRechargePageState extends State<AdminRechargePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverAppBar(
            expandedHeight:
                (MediaQuery.of(context).size.height * 0.18).clamp(130.0, 190.0),
            floating: false,
            pinned: true,
            backgroundColor: const Color(0xFF2E7D32),
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF1B5E20), Color(0xFF388E3C)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const SafeArea(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20, 56, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Retraits manuels",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          "Traiter les retraits en attente",
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: const Text("Wallets",
                style: TextStyle(color: Colors.white, fontSize: 18)),
            centerTitle: true,
            bottom: TabBar(
              controller: _tabs,
              indicatorColor: Colors.white,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white60,
              isScrollable: true,
              tabAlignment: TabAlignment.center,
              tabs: const [
                Tab(text: "Recharge livreur"),
                Tab(text: "Retraits en attente"),
                Tab(text: "Traités"),
                Tab(text: "Échoués / Rejetés"),
              ],
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabs,
          children: const [
            _RechargeDriverTab(),
            _RequestList(
                collection: 'withdrawal_requests', status: 'pending_manual'),
            _RequestList(
                collection: 'withdrawal_requests', status: 'processed'),
            _RequestList(collection: 'withdrawal_requests', status: 'failed'),
          ],
        ),
      ),
    );
  }
}

// ── Recharge directe livreur ──────────────────────────────────────

class _RechargeDriverTab extends StatefulWidget {
  const _RechargeDriverTab();

  @override
  State<_RechargeDriverTab> createState() => _RechargeDriverTabState();
}

class _RechargeDriverTabState extends State<_RechargeDriverTab> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Barre de recherche
        Container(
          color: const Color(0xFF2E7D32),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: TextField(
            controller: _searchCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Nom ou téléphone du livreur…',
              hintStyle: const TextStyle(color: Colors.white54),
              prefixIcon: const Icon(Icons.search, color: Colors.white70),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    )
                  : null,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.15),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
          ),
        ),
        // Liste des livreurs
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('livreurs')
                .orderBy('name')
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final allDocs = snap.data?.docs ?? [];
              final docs = _query.isEmpty
                  ? allDocs
                  : allDocs.where((d) {
                      final data = d.data() as Map<String, dynamic>;
                      final name =
                          (data['name'] as String? ?? '').toLowerCase();
                      final phone =
                          (data['phone'] as String? ?? '').toLowerCase();
                      return name.contains(_query) || phone.contains(_query);
                    }).toList();

              if (docs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.delivery_dining_rounded,
                          size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      Text(
                        _query.isEmpty
                            ? 'Aucun livreur enregistré'
                            : 'Aucun livreur trouvé pour "$_query"',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                );
              }

              return ListView.builder(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                itemBuilder: (context, i) => _DriverRechargeCard(
                  docId: docs[i].id,
                  data: docs[i].data() as Map<String, dynamic>,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DriverRechargeCard extends StatefulWidget {
  final String docId;
  final Map<String, dynamic> data;

  const _DriverRechargeCard({required this.docId, required this.data});

  @override
  State<_DriverRechargeCard> createState() => _DriverRechargeCardState();
}

class _DriverRechargeCardState extends State<_DriverRechargeCard> {
  bool _loading = false;

  String _fmt(int v) {
    final s = v.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return '${buf.toString()} F';
  }

  void _showRechargeDialog() {
    final name = widget.data['name'] as String? ?? 'Livreur';
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          const Icon(Icons.add_card_rounded, color: Color(0xFF2E7D32)),
          const SizedBox(width: 10),
          Expanded(
            child:
                Text('Recharger $name', style: const TextStyle(fontSize: 16)),
          ),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Montant (FCFA)',
                prefixIcon: const Icon(Icons.attach_money_rounded,
                    color: Color(0xFF2E7D32)),
                suffixText: 'FCFA',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: Color(0xFF2E7D32), width: 2)),
              ),
            ),
            const SizedBox(height: 12),
            // Montants rapides
            Wrap(
              spacing: 8,
              children: [500, 1000, 2000, 5000].map((v) {
                return ActionChip(
                  label: Text('$v F'),
                  onPressed: () => amountCtrl.text = v.toString(),
                  backgroundColor: const Color(0xFFE8F5E9),
                  side: const BorderSide(color: Color(0xFF2E7D32)),
                  labelStyle: const TextStyle(
                      color: Color(0xFF2E7D32), fontWeight: FontWeight.bold),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration: InputDecoration(
                labelText: 'Note (optionnel)',
                hintText: 'Motif du crédit…',
                prefixIcon: const Icon(Icons.note_outlined, color: Colors.grey),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              maxLines: 1,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              final amount = int.tryParse(amountCtrl.text.trim()) ?? 0;
              if (amount <= 0) return;
              Navigator.pop(context);
              setState(() => _loading = true);
              try {
                final note = noteCtrl.text.trim().isNotEmpty
                    ? noteCtrl.text.trim()
                    : "Rechargé par l'admin";
                await FirestoreService().rechargeDriverWallet(
                    widget.docId, amount,
                    adminNote: note);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content:
                        Text('${_fmt(amount)} ajoutés au wallet de $name ✓'),
                    backgroundColor: const Color(0xFF2E7D32),
                  ));
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Erreur : $e'),
                    backgroundColor: Colors.red,
                  ));
                }
              }
              if (mounted) setState(() => _loading = false);
            },
            icon: const Icon(Icons.check_circle_rounded,
                color: Colors.white, size: 16),
            label: const Text('Confirmer',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2E7D32),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.data['name'] as String? ?? '—';
    final phone = widget.data['phone'] as String? ?? '—';
    final wallet = (widget.data['wallet'] as num? ?? 0).toInt();
    final isOnline = widget.data['isOnline'] == true;
    final ownerId = widget.data['ownerId'] as String?;
    final idNum = widget.data['identifiant'] as String? ?? '—';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(children: [
        // Avatar + statut online
        Stack(children: [
          CircleAvatar(
            radius: 22,
            backgroundColor:
                isOnline ? Colors.green.shade100 : Colors.grey.shade100,
            child: Icon(Icons.delivery_dining_rounded,
                color: isOnline ? Colors.green : Colors.grey, size: 22),
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: isOnline ? Colors.green : Colors.grey,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ),
        ]),
        const SizedBox(width: 12),
        // Infos livreur
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            Text(phone,
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            Row(children: [
              Text('ID $idNum',
                  style:
                      TextStyle(color: Colors.purple.shade300, fontSize: 11)),
              if (ownerId != null && ownerId.isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('Flotte',
                      style: TextStyle(
                          color: Color(0xFF6A1B9A),
                          fontSize: 9,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ]),
          ]),
        ),
        // Wallet + bouton recharge
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(
            _fmt(wallet),
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: wallet < 200 ? Colors.red : const Color(0xFF1B5E20),
            ),
          ),
          const SizedBox(height: 6),
          _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFF2E7D32)))
              : GestureDetector(
                  onTap: _showRechargeDialog,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color:
                              const Color(0xFF2E7D32).withValues(alpha: 0.4)),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.add_card_rounded,
                          color: Color(0xFF2E7D32), size: 16),
                      SizedBox(width: 4),
                      Text('Recharger',
                          style: TextStyle(
                              color: Color(0xFF2E7D32),
                              fontSize: 12,
                              fontWeight: FontWeight.bold)),
                    ]),
                  ),
                ),
        ]),
      ]),
    );
  }
}

// ── Liste des demandes ────────────────────────────────────────────

class _RequestList extends StatelessWidget {
  final String collection;
  final String status;
  const _RequestList({required this.collection, required this.status});

  bool get _isWithdraw => collection == 'withdrawal_requests';
  bool get _isPending => status == 'pending_manual';

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(collection)
          .where('status', isEqualTo: status)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = List.of(snap.data?.docs ?? []);
        docs.sort((a, b) {
          final ta = (a.data() as Map)['createdAt'] as Timestamp?;
          final tb = (b.data() as Map)['createdAt'] as Timestamp?;
          if (ta == null || tb == null) return 0;
          return tb.compareTo(ta);
        });

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isPending
                      ? Icons.hourglass_empty
                      : status == 'processed'
                          ? Icons.check_circle_outline
                          : Icons.cancel_outlined,
                  size: 64,
                  color: Colors.grey.shade300,
                ),
                const SizedBox(height: 12),
                Text(
                  _isPending
                      ? "Aucun retrait en attente"
                      : status == 'processed'
                          ? "Aucun retrait traité"
                          : "Aucun retrait échoué",
                  style: const TextStyle(color: Colors.grey, fontSize: 15),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final doc = docs[i];
            return _RequestCard(
              docId: doc.id,
              data: doc.data() as Map<String, dynamic>,
              isWithdraw: _isWithdraw,
              isPending: _isPending,
            );
          },
        );
      },
    );
  }
}

// ── Carte d'une demande ───────────────────────────────────────────

class _RequestCard extends StatefulWidget {
  final String docId;
  final Map<String, dynamic> data;
  final bool isWithdraw;
  final bool isPending;

  const _RequestCard({
    required this.docId,
    required this.data,
    required this.isWithdraw,
    required this.isPending,
  });

  @override
  State<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<_RequestCard> {
  bool _loading = false;
  final _fs = FirestoreService();

  // ── Approuver ───────────────────────────────────────────────────
  Future<void> _approve() async {
    final userId =
        widget.data['userId'] as String? ?? widget.data['clientId'] as String?;
    final userType = widget.data['userType'] as String? ?? 'client';
    final amount = (widget.data['amount'] as num? ?? 0).toInt();
    final method = widget.data['method'] ?? 'wave';
    if (userId == null || amount <= 0) return;

    setState(() => _loading = true);
    try {
      if (widget.isWithdraw) {
        await _fs.approveWithdrawal(widget.docId, userId, userType, amount);
        if (mounted) _snack("Retrait marqué comme traité ✓", Colors.green);
      } else {
        await _fs.approveRecharge(
            widget.docId, userId, userType, amount, method);
        if (mounted)
          _snack("Wallet crédité de ${_fmt(amount)} FCFA ✓", Colors.green);
      }
    } catch (e) {
      if (mounted) _snack("Erreur : $e", Colors.red);
    }
    if (mounted) setState(() => _loading = false);
  }

  // ── Rejeter ────────────────────────────────────────────────────
  Future<void> _reject() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.isWithdraw
            ? "Rejeter le retrait ?"
            : "Rejeter la recharge ?"),
        content: const Text("Cette action est définitive."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text("Rejeter"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _loading = true);
    try {
      if (widget.isWithdraw) {
        await _fs.rejectWithdrawal(widget.docId);
      } else {
        await _fs.rejectRecharge(widget.docId);
      }
      if (mounted) _snack("Demande rejetée", Colors.orange);
    } catch (e) {
      if (mounted) _snack("Erreur : $e", Colors.red);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  String _fmt(int v) {
    if (v >= 1000)
      return "${v ~/ 1000} ${(v % 1000).toString().padLeft(3, '0')}";
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    final amount = (widget.data['amount'] as num? ?? 0).toInt();
    final method = widget.data['method'] ?? 'wave';
    final userType = widget.data['userType'] ?? 'client';
    final userName = widget.data['userName'] ?? '—';
    final userId = widget.data['userId'] ?? widget.data['clientId'] ?? '—';
    // Recharge: senderPhone, Retrait: phone
    final phone = widget.data[widget.isWithdraw ? 'phone' : 'senderPhone'] ??
        widget.data['phone'] ??
        '—';
    final txRef = widget.data['txRef'] as String?;
    final ts = widget.data['createdAt'] as Timestamp?;
    final date = ts?.toDate();
    final dateStr = date != null
        ? "${date.day.toString().padLeft(2, '0')}/"
            "${date.month.toString().padLeft(2, '0')}/"
            "${date.year}  "
            "${date.hour.toString().padLeft(2, '0')}:"
            "${date.minute.toString().padLeft(2, '0')}"
        : '—';

    final isWave = method == 'wave';
    final methodColor = isWave ? const Color(0xFF1565C0) : Colors.orange;
    final methodLabel = isWave ? 'Wave' : 'Orange Money';

    final typeColor = userType == 'driver'
        ? const Color(0xFF1565C0)
        : userType == 'seller'
            ? const Color(0xFF6A1B9A)
            : AppColors.primary;
    final typeLabel = userType == 'driver'
        ? 'Livreur'
        : userType == 'seller'
            ? 'Vendeur'
            : 'Client';

    final accentColor =
        widget.isWithdraw ? const Color(0xFF1565C0) : const Color(0xFF2E7D32);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Ligne montant + méthode + type ────────────────
            Row(
              children: [
                // Icône recharge / retrait
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    widget.isWithdraw
                        ? Icons.arrow_circle_up
                        : Icons.add_circle_outline,
                    color: accentColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                // Montant
                Text(
                  "${_fmt(amount)} FCFA",
                  style: TextStyle(
                    color: accentColor,
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                  ),
                ),
                const Spacer(),
                // Badge méthode
                _badge(methodLabel, isWave ? Icons.bolt : Icons.phone_android,
                    methodColor),
                const SizedBox(width: 6),
                // Badge type utilisateur
                _badge(typeLabel, Icons.person, typeColor),
              ],
            ),

            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),

            // ── Infos ─────────────────────────────────────────
            _row(
                Icons.person_outline,
                "Nom",
                userName.length > 28
                    ? "${userName.substring(0, 28)}…"
                    : userName),
            const SizedBox(height: 5),
            _row(Icons.fingerprint, "ID",
                userId.length > 24 ? "${userId.substring(0, 24)}…" : userId),
            const SizedBox(height: 5),
            _row(
                Icons.phone_outlined,
                widget.isWithdraw ? "Numéro de retrait" : "Numéro ayant payé",
                phone),
            if (txRef != null && txRef.isNotEmpty) ...[
              const SizedBox(height: 5),
              _row(Icons.receipt_long, "Réf. transaction", txRef),
            ],
            const SizedBox(height: 5),
            _row(Icons.access_time, "Date", dateStr),

            // ── Boutons (si en attente) ───────────────────────
            if (widget.isPending) ...[
              const SizedBox(height: 16),
              _loading
                  ? const Center(child: CircularProgressIndicator())
                  : Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _reject,
                            icon: const Icon(Icons.close,
                                size: 16, color: Colors.red),
                            label: const Text("Rejeter",
                                style: TextStyle(color: Colors.red)),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.red),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            onPressed: _approve,
                            icon: const Icon(Icons.check_circle,
                                size: 16, color: Colors.white),
                            label: Text(
                              widget.isWithdraw
                                  ? "Paiement effectué ✓"
                                  : "Approuver & Créditer",
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: accentColor,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _badge(String label, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.grey),
        const SizedBox(width: 6),
        Text("$label : ",
            style: const TextStyle(color: Colors.grey, fontSize: 12)),
        Expanded(
          child: Text(value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}
