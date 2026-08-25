import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/firestore_service.dart';
import '../../theme/app_theme.dart';

class DriversPage extends StatelessWidget {
  const DriversPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        title: const Text("Gestion des livreurs"),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream:
            FirebaseFirestore.instance.collection("fleet_owners").snapshots(),
        builder: (context, patronSnap) {
          return StreamBuilder<QuerySnapshot>(
            stream:
                FirebaseFirestore.instance.collection("livreurs").snapshots(),
            builder: (context, driverSnap) {
              if (!driverSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final allDrivers = driverSnap.data!.docs;
              final patrons = patronSnap.data?.docs ?? [];

              // Séparer indépendants et livreurs de flotte
              final independent = allDrivers
                  .where((d) =>
                      (d.data() as Map)["ownerId"] == null ||
                      (d.data() as Map)["ownerId"] == "")
                  .toList();

              return ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  // ── STATS GLOBALES ─────────────────────────
                  _GlobalStats(drivers: allDrivers),
                  const SizedBox(height: 20),

                  // ── PATRONS DE FLOTTE ──────────────────────
                  _sectionTitle("Flottes", Icons.motorcycle, Colors.purple),
                  const SizedBox(height: 10),
                  if (!patronSnap.hasData)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (patrons.isEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Center(
                        child: Text("Aucun patron enregistré",
                            style: TextStyle(color: Colors.grey)),
                      ),
                    )
                  else ...[
                    ...patrons.map((patron) {
                      final patronData = patron.data() as Map<String, dynamic>;
                      final patronDrivers = allDrivers
                          .where(
                              (d) => (d.data() as Map)["ownerId"] == patron.id)
                          .toList();
                      return _PatronCard(
                        patronId: patron.id,
                        patronData: patronData,
                        drivers: patronDrivers,
                        onRecharge: (driverId, driverName) =>
                            _showRechargeDialog(context, driverId, driverName),
                        onDelete: (driverId, name) =>
                            _confirmDelete(context, driverId, name),
                        onMakeIndependent: (driverId, name) =>
                            _confirmMakeIndependent(context, driverId, name),
                      );
                    }),
                    const SizedBox(height: 4),
                  ],

                  const SizedBox(height: 16),
                  // ── LIVREURS INDÉPENDANTS ──────────────────
                  _sectionTitle("Livreurs indépendants", Icons.delivery_dining,
                      Colors.blue),
                  const SizedBox(height: 10),

                  if (independent.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Center(
                        child: Text("Aucun livreur indépendant",
                            style: TextStyle(color: Colors.grey)),
                      ),
                    )
                  else
                    ...independent.map((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                      return _DriverCard(
                        driverId: doc.id,
                        data: data,
                        onRecharge: () => _showRechargeDialog(
                            context, doc.id, data["name"] ?? "Livreur"),
                        onDelete: () =>
                            _confirmDelete(context, doc.id, data["name"]),
                        onTransfer: () => _showAssignToFleetDialog(context,
                            doc.id, data["name"] ?? "Livreur", patrons),
                      );
                    }),

                  const SizedBox(height: 30),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String title, IconData icon, Color color) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
        ),
      ],
    );
  }

  void _showRechargeDialog(
      BuildContext context, String driverId, String driverName) {
    final amountCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.account_balance_wallet, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
                child: Text("Recharger $driverName",
                    style: const TextStyle(fontSize: 16))),
          ],
        ),
        content: TextField(
          controller: amountCtrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: "Montant (FCFA)",
            prefixIcon:
                const Icon(Icons.attach_money, color: AppColors.primary),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            suffixText: "FCFA",
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  const Text("Annuler", style: TextStyle(color: Colors.grey))),
          ScaleButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green, foregroundColor: Colors.white),
            onPressed: () async {
              final amount = int.tryParse(amountCtrl.text.trim());
              if (amount == null || amount <= 0) return;
              Navigator.pop(context);
              await FirestoreService().rechargeDriverWallet(driverId, amount);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text("$amount FCFA ajoutés à $driverName"),
                  backgroundColor: Colors.green,
                ));
              }
            },
            child: const Text("Confirmer"),
          ),
        ],
      ),
    );
  }

  void _showAssignToFleetDialog(BuildContext context, String driverId,
      String driverName, List<QueryDocumentSnapshot> patrons) {
    final approved = patrons
        .where((p) => (p.data() as Map)['status'] == 'approved')
        .toList();

    if (approved.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Aucune flotte approuvée disponible"),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    String? selectedPatronId;
    String? selectedPatronName;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(children: [
            const Icon(Icons.swap_horiz_rounded, color: Color(0xFF6A1B9A)),
            const SizedBox(width: 8),
            Expanded(
              child: Text("Assigner $driverName à une flotte",
                  style: const TextStyle(fontSize: 15)),
            ),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: approved.map((p) {
              final pd = p.data() as Map<String, dynamic>;
              final selected = selectedPatronId == p.id;
              return GestureDetector(
                onTap: () => setDialogState(() {
                  selectedPatronId = p.id;
                  selectedPatronName = pd['name'] as String? ?? 'Flotte';
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0xFF6A1B9A).withValues(alpha: 0.1)
                        : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF6A1B9A)
                          : Colors.grey.shade300,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Row(children: [
                    Icon(Icons.motorcycle,
                        color: selected ? const Color(0xFF6A1B9A) : Colors.grey,
                        size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(pd['name'] ?? '—',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: selected
                                      ? const Color(0xFF6A1B9A)
                                      : Colors.black87)),
                          Text(pd['phone'] ?? '—',
                              style: const TextStyle(
                                  color: Colors.grey, fontSize: 12)),
                        ],
                      ),
                    ),
                    if (selected)
                      const Icon(Icons.check_circle,
                          color: Color(0xFF6A1B9A), size: 18),
                  ]),
                ),
              );
            }).toList(),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Annuler",
                    style: TextStyle(color: Colors.grey))),
            ScaleButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6A1B9A),
                  foregroundColor: Colors.white),
              onPressed: selectedPatronId == null
                  ? null
                  : () async {
                      Navigator.pop(ctx);
                      await FirestoreService().assignDriverToFleet(
                          driverId, selectedPatronId!, selectedPatronName!);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(
                              "$driverName assigné à la flotte $selectedPatronName"),
                          backgroundColor: const Color(0xFF6A1B9A),
                        ));
                      }
                    },
              child: const Text("Confirmer"),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmMakeIndependent(
      BuildContext context, String driverId, String? name) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.person_outline, color: Colors.blue),
          SizedBox(width: 8),
          Text("Rendre indépendant"),
        ]),
        content: Text(
            "${name ?? 'Ce livreur'} sera retiré de sa flotte et deviendra livreur indépendant."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Annuler")),
          ScaleButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            onPressed: () async {
              Navigator.pop(context);
              await FirestoreService().makeDriverIndependent(driverId);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content:
                      Text("${name ?? 'Livreur'} est maintenant indépendant"),
                  backgroundColor: Colors.blue,
                ));
              }
            },
            child:
                const Text("Confirmer", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, String driverId, String? name) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Supprimer le livreur"),
        content:
            Text("Voulez-vous vraiment supprimer ${name ?? 'ce livreur'} ?"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Annuler")),
          ScaleButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context);
              await FirebaseFirestore.instance
                  .collection("livreurs")
                  .doc(driverId)
                  .delete();
            },
            child:
                const Text("Supprimer", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// ── STATS GLOBALES ────────────────────────────────────────────

class _GlobalStats extends StatelessWidget {
  final List<QueryDocumentSnapshot> drivers;
  const _GlobalStats({required this.drivers});

  @override
  Widget build(BuildContext context) {
    final total = drivers.length;
    final online =
        drivers.where((d) => (d.data() as Map)["isOnline"] == true).length;
    final withFleet =
        drivers.where((d) => (d.data() as Map)["ownerId"] != null).length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [AppColors.primary, Color(0xFFFFB300)]),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: Colors.orange.withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 4))
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _stat("$total", "Total"),
          _divider(),
          _stat("$online", "En ligne"),
          _divider(),
          _stat("$withFleet", "En flotte"),
          _divider(),
          _stat("${total - withFleet}", "Indép."),
        ],
      ),
    );
  }

  Widget _stat(String v, String l) => Column(
        children: [
          Text(v,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          Text(l, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      );

  Widget _divider() => Container(width: 1, height: 36, color: Colors.white24);
}

// ── CARTE PATRON ──────────────────────────────────────────────

class _PatronCard extends StatefulWidget {
  final String patronId;
  final Map<String, dynamic> patronData;
  final List<QueryDocumentSnapshot> drivers;
  final Function(String driverId, String name) onRecharge;
  final Function(String driverId, String? name) onDelete;
  final Function(String driverId, String? name) onMakeIndependent;

  const _PatronCard({
    required this.patronId,
    required this.patronData,
    required this.drivers,
    required this.onRecharge,
    required this.onDelete,
    required this.onMakeIndependent,
  });

  @override
  State<_PatronCard> createState() => _PatronCardState();
}

class _PatronCardState extends State<_PatronCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final online = widget.drivers
        .where((d) => (d.data() as Map)["isOnline"] == true)
        .length;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.purple.shade100),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6)],
      ),
      child: Column(
        children: [
          // Header patron
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.purple.shade50,
                      shape: BoxShape.circle,
                    ),
                    child:
                        const Icon(Icons.motorcycle, color: Color(0xFF6A1B9A)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.patronData["name"] ?? "Patron",
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        Text(
                          widget.patronData["phone"] ?? "—",
                          style:
                              const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  // Badge livreurs
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.purple.shade50,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          "${widget.drivers.length} livreur${widget.drivers.length > 1 ? 's' : ''}",
                          style: const TextStyle(
                              color: Color(0xFF6A1B9A),
                              fontWeight: FontWeight.bold,
                              fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "$online en ligne",
                        style: TextStyle(
                            color: online > 0 ? Colors.green : Colors.grey,
                            fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),

          // Livreurs (si expanded)
          if (_expanded) ...[
            const Divider(height: 1),
            if (widget.drivers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text("Aucun livreur dans cette flotte",
                    style: TextStyle(color: Colors.grey)),
              )
            else
              ...widget.drivers.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                return _DriverCard(
                  driverId: doc.id,
                  data: data,
                  onRecharge: () =>
                      widget.onRecharge(doc.id, data["name"] ?? "Livreur"),
                  onDelete: () => widget.onDelete(doc.id, data["name"]),
                  onTransfer: () =>
                      widget.onMakeIndependent(doc.id, data["name"]),
                  isSubItem: true,
                );
              }),
          ],
        ],
      ),
    );
  }
}

// ── CARTE LIVREUR ─────────────────────────────────────────────

class _DriverCard extends StatelessWidget {
  final String driverId;
  final Map<String, dynamic> data;
  final VoidCallback onRecharge;
  final VoidCallback onDelete;
  final VoidCallback? onTransfer;
  final bool isSubItem;

  const _DriverCard({
    required this.driverId,
    required this.data,
    required this.onRecharge,
    required this.onDelete,
    this.onTransfer,
    this.isSubItem = false,
  });

  // Suspension temporaire — même mécanisme que admin_ekbine_page.dart
  // (`isSuspended`), déjà pleinement respecté côté serveur pour les livreurs
  // classiques (dispatch.js exclut isSuspended==true depuis le Prompt 26,
  // acceptOrder() le revérifie à l'acceptation) : seule l'action admin pour
  // le déclencher manquait. Écrit directement ici (pas de callback threadé
  // à travers _PatronCard/_PatronCardState) — action simple et à faible
  // risque, cohérent avec "correction minimale" (Master Prompt 77, 2026-07-09).
  Future<void> _toggleSuspend(BuildContext context, bool suspend) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title:
            Text(suspend ? 'Suspendre ce livreur ?' : 'Lever la suspension ?'),
        content: Text(suspend
            ? '${data["name"] ?? "Ce livreur"} ne recevra plus de nouvelles '
                'commandes et ne pourra plus en accepter tant qu\'il est suspendu.'
            : '${data["name"] ?? "Ce livreur"} pourra à nouveau recevoir et '
                'accepter des commandes.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          ScaleButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: suspend ? Colors.red : Colors.green),
            onPressed: () => Navigator.pop(context, true),
            child: Text(suspend ? 'Suspendre' : 'Réactiver',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await FirebaseFirestore.instance
        .collection('livreurs')
        .doc(driverId)
        .update(
          suspend
              ? {'isSuspended': true, 'isOnline': false}
              : {'isSuspended': false},
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(suspend ? 'Livreur suspendu' : 'Suspension levée'),
        backgroundColor: suspend ? Colors.red : Colors.green,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = data["isOnline"] == true;
    final isSuspended = data["isSuspended"] == true;
    final wallet = (data["wallet"] as num? ?? 0).toInt();

    return Container(
      margin: EdgeInsets.only(
        left: isSubItem ? 16 : 0,
        right: isSubItem ? 0 : 0,
        bottom: 10,
        top: isSubItem ? 4 : 0,
      ),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isSubItem ? const Color(0xFFFAFAFA) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: isSubItem
            ? Border(
                left: BorderSide(
                    color: isOnline ? Colors.green : Colors.grey.shade300,
                    width: 3))
            : null,
        boxShadow: isSubItem
            ? null
            : const [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Row(
        children: [
          Stack(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor:
                    isOnline ? Colors.green.shade100 : Colors.grey.shade200,
                child: Icon(Icons.delivery_dining,
                    color: isOnline ? Colors.green : Colors.grey, size: 20),
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: isOnline ? Colors.green : Colors.grey,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(data["name"] ?? "—",
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  if (isSuspended) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8)),
                      child: const Text('SUSPENDU',
                          style: TextStyle(
                              color: Colors.red,
                              fontSize: 9,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ]),
                Text(data["phone"] ?? "—",
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
                Text(
                  "ID: ${data['identifiant'] ?? '—'}",
                  style: TextStyle(color: Colors.purple.shade300, fontSize: 11),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                "$wallet FCFA",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: wallet < 200 ? Colors.red : Colors.orange,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Semantics(
                    label: 'Recharger le portefeuille du livreur',
                    button: true,
                    excludeSemantics: true,
                    child: GestureDetector(
                      onTap: onRecharge,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green.shade200),
                        ),
                        child: const Icon(Icons.add_card,
                            color: Colors.green, size: 18),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (onTransfer != null) ...[
                    GestureDetector(
                      onTap: onTransfer,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.purple.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.purple.shade200),
                        ),
                        child: Icon(
                          isSubItem
                              ? Icons.person_outline
                              : Icons.swap_horiz_rounded,
                          color: Colors.purple,
                          size: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  GestureDetector(
                    onTap: () => _toggleSuspend(context, !isSuspended),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                      decoration: BoxDecoration(
                        color: isSuspended
                            ? Colors.green.shade50
                            : Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: isSuspended
                                ? Colors.green.shade200
                                : Colors.orange.shade200),
                      ),
                      child: Icon(
                        isSuspended
                            ? Icons.play_circle_outline
                            : Icons.pause_circle_outline,
                        color: isSuspended ? Colors.green : Colors.orange,
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: onDelete,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: const Icon(Icons.delete_outline,
                          color: Colors.red, size: 18),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
