import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AdminFleetPage extends StatefulWidget {
  const AdminFleetPage({super.key});

  @override
  State<AdminFleetPage> createState() => _AdminFleetPageState();
}

class _AdminFleetPageState extends State<AdminFleetPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
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
            expandedHeight: (MediaQuery.of(context).size.height * 0.18)
                .clamp(130.0, 190.0),
            floating: false,
            pinned: true,
            backgroundColor: const Color(0xFF6A1B9A),
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF4A148C), Color(0xFF8E24AA)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const SafeArea(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(height: 40),
                        Text(
                          "Patrons de Flotte",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          "Gérer les demandes d'inscription",
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: const Text("Flottes",
                style: TextStyle(color: Colors.white, fontSize: 18)),
            centerTitle: true,
            bottom: TabBar(
              controller: _tabs,
              indicatorColor: Colors.white,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white60,
              tabs: const [
                Tab(text: "En attente"),
                Tab(text: "Approuvés"),
                Tab(text: "Rejetés"),
              ],
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabs,
          children: const [
            _FleetList(status: "pending"),
            _FleetList(status: "approved"),
            _FleetList(status: "rejected"),
          ],
        ),
      ),
    );
  }
}

class _FleetList extends StatelessWidget {
  final String status;
  const _FleetList({required this.status});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection("fleet_owners")
          .where("status", isEqualTo: status)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = List.of(snap.data?.docs ?? []);
        docs.sort((a, b) {
          final ta = (a.data() as Map)["createdAt"] as Timestamp?;
          final tb = (b.data() as Map)["createdAt"] as Timestamp?;
          if (ta == null || tb == null) return 0;
          return tb.compareTo(ta);
        });

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  status == "pending"
                      ? Icons.hourglass_empty
                      : status == "approved"
                          ? Icons.check_circle_outline
                          : Icons.cancel_outlined,
                  size: 64,
                  color: Colors.grey.shade300,
                ),
                const SizedBox(height: 12),
                Text(
                  status == "pending"
                      ? "Aucune demande en attente"
                      : status == "approved"
                          ? "Aucun patron approuvé"
                          : "Aucun patron rejeté",
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
            final data = doc.data() as Map<String, dynamic>;
            return _FleetCard(docId: doc.id, data: data, status: status);
          },
        );
      },
    );
  }
}

class _FleetCard extends StatefulWidget {
  final String docId;
  final Map<String, dynamic> data;
  final String status;

  const _FleetCard({
    required this.docId,
    required this.data,
    required this.status,
  });

  @override
  State<_FleetCard> createState() => _FleetCardState();
}

class _FleetCardState extends State<_FleetCard> {
  bool _loading = false;

  Future<void> _approve() async {
    setState(() => _loading = true);
    try {
      await FirebaseFirestore.instance
          .collection("fleet_owners")
          .doc(widget.docId)
          .update({
        "status": "approved",
        "approvedAt": FieldValue.serverTimestamp(),
      });
      if (mounted) _snack("Patron approuvé ✓", Colors.green);
    } catch (e) {
      if (mounted) _snack("Erreur : $e", Colors.red);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _reject() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Rejeter la demande ?"),
        content: Text(
            "Le patron \"${widget.data['name'] ?? ''}\" ne pourra pas accéder à l'application."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Annuler"),
          ),
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
      await FirebaseFirestore.instance
          .collection("fleet_owners")
          .doc(widget.docId)
          .update({
        "status": "rejected",
        "rejectedAt": FieldValue.serverTimestamp(),
      });
      if (mounted) _snack("Demande rejetée", Colors.orange);
    } catch (e) {
      if (mounted) _snack("Erreur : $e", Colors.red);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _reactivate() async {
    setState(() => _loading = true);
    try {
      await FirebaseFirestore.instance
          .collection("fleet_owners")
          .doc(widget.docId)
          .update({
        "status": "approved",
        "approvedAt": FieldValue.serverTimestamp(),
      });
      if (mounted) _snack("Patron réactivé ✓", Colors.green);
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

  @override
  Widget build(BuildContext context) {
    final name = widget.data["name"] ?? "—";
    final phone = widget.data["phone"] ?? "—";
    final identifiant = widget.data["identifiant"] ?? "—";
    final ts = widget.data["createdAt"] as Timestamp?;
    final date = ts?.toDate();
    final dateStr = date != null
        ? "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}"
        : "—";

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
            // Header
            Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6A1B9A), Color(0xFF8E24AA)],
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.motorcycle,
                      color: Colors.white, size: 26),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        "ID : $identifiant",
                        style: TextStyle(
                            color: Colors.grey.shade600, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                _StatusBadge(status: widget.status),
              ],
            ),

            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),

            Row(
              children: [
                const Icon(Icons.phone_outlined, size: 15, color: Colors.grey),
                const SizedBox(width: 6),
                Text(phone,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const Spacer(),
                const Icon(Icons.calendar_today_outlined,
                    size: 13, color: Colors.grey),
                const SizedBox(width: 4),
                Text(dateStr,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey)),
              ],
            ),

            // Buttons
            if (widget.status == "pending") ...[
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
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
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
                            label: const Text(
                              "Approuver",
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF6A1B9A),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
            ] else if (widget.status == "rejected") ...[
              const SizedBox(height: 12),
              _loading
                  ? const Center(child: CircularProgressIndicator())
                  : SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _reactivate,
                        icon: const Icon(Icons.refresh,
                            size: 16, color: Color(0xFF6A1B9A)),
                        label: const Text("Réactiver le compte",
                            style: TextStyle(color: Color(0xFF6A1B9A))),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF6A1B9A)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    IconData icon;
    if (status == "pending") {
      color = Colors.orange;
      label = "En attente";
      icon = Icons.hourglass_top;
    } else if (status == "approved") {
      color = const Color(0xFF2E7D32);
      label = "Approuvé";
      icon = Icons.check_circle;
    } else {
      color = Colors.red;
      label = "Rejeté";
      icon = Icons.cancel;
    }
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
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
