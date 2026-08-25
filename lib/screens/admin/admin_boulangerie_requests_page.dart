import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../utils/partner_location_validator.dart';

class AdminBoulangerieRequestsPage extends StatefulWidget {
  const AdminBoulangerieRequestsPage({super.key});

  @override
  State<AdminBoulangerieRequestsPage> createState() =>
      _AdminBoulangerieRequestsPageState();
}

class _AdminBoulangerieRequestsPageState
    extends State<AdminBoulangerieRequestsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _approve(String uid, Map<String, dynamic> data) async {
    final latitude = (data['lat'] as num?)?.toDouble();
    final longitude = (data['lng'] as num?)?.toDouble();
    final locationError =
        PartnerLocationValidator.validate(latitude, longitude);
    if (locationError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(locationError), backgroundColor: Colors.red),
        );
      }
      return;
    }
    final db = FirebaseFirestore.instance;
    final batch = db.batch();

    batch.set(db.collection('boulangeries').doc(uid), {
      'uid': uid,
      'ownerName': data['ownerName'] ?? '',
      'name': data['boulangerieName'] ?? '',
      'phone': data['phone'] ?? '',
      'address': data['address'] ?? '',
      'lat': latitude,
      'lng': longitude,
      'isActive': true,
      'isOpen': false,
      'createdAt': FieldValue.serverTimestamp(),
    });

    batch.update(db.collection('boulangerie_requests').doc(uid), {
      'status': 'approved',
      'approvedAt': FieldValue.serverTimestamp(),
    });

    await batch.commit();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${data['boulangerieName']} approuvée !'),
      backgroundColor: const Color(0xFF2E7D32),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _reject(String uid, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Refuser la demande',
            style: GoogleFonts.urbanist(fontWeight: FontWeight.bold)),
        content: Text('Refuser la demande de "$name" ?',
            style: GoogleFonts.urbanist()),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Refuser', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await FirebaseFirestore.instance
        .collection('boulangerie_requests')
        .doc(uid)
        .update(
            {'status': 'rejected', 'rejectedAt': FieldValue.serverTimestamp()});

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Demande refusée.'),
      backgroundColor: Colors.red,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('Demandes Boulangeries',
            style: GoogleFonts.urbanist(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF5D4037),
        foregroundColor: Colors.white,
        centerTitle: true,
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(text: 'En attente'),
            Tab(text: 'Traitées'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: [
          _BoulangerieRequestsList(
            statusFilter: 'pending',
            onApprove: _approve,
            onReject: _reject,
          ),
          _BoulangerieRequestsList(
            statusFilter: null,
            onApprove: _approve,
            onReject: _reject,
          ),
        ],
      ),
    );
  }
}

class _BoulangerieRequestsList extends StatelessWidget {
  final String? statusFilter;
  final Future<void> Function(String uid, Map<String, dynamic> data) onApprove;
  final Future<void> Function(String uid, String name) onReject;

  const _BoulangerieRequestsList({
    required this.statusFilter,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> query;

    if (statusFilter != null) {
      query = FirebaseFirestore.instance
          .collection('boulangerie_requests')
          .where('status', isEqualTo: statusFilter)
          .orderBy('createdAt', descending: true);
    } else {
      query = FirebaseFirestore.instance
          .collection('boulangerie_requests')
          .where('status', whereIn: ['approved', 'rejected']).orderBy(
              'createdAt',
              descending: true);
    }

    return StreamBuilder<QuerySnapshot>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.inbox_rounded,
                    size: 64, color: Colors.grey.shade300),
                const SizedBox(height: 12),
                Text('Aucune demande',
                    style: GoogleFonts.urbanist(color: Colors.grey)),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final doc = docs[i];
            final data = doc.data() as Map<String, dynamic>;
            return _BoulangerieRequestCard(
              uid: doc.id,
              data: data,
              onApprove: () => onApprove(doc.id, data),
              onReject: () => onReject(
                  doc.id, data['boulangerieName'] ?? 'cette boulangerie'),
            );
          },
        );
      },
    );
  }
}

class _BoulangerieRequestCard extends StatelessWidget {
  final String uid;
  final Map<String, dynamic> data;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _BoulangerieRequestCard({
    required this.uid,
    required this.data,
    required this.onApprove,
    required this.onReject,
  });

  Color get _statusColor {
    switch (data['status']) {
      case 'approved':
        return const Color(0xFF2E7D32);
      case 'rejected':
        return const Color(0xFFC62828);
      default:
        return const Color(0xFFFF8F00);
    }
  }

  String get _statusLabel {
    switch (data['status']) {
      case 'approved':
        return 'Approuvée';
      case 'rejected':
        return 'Refusée';
      default:
        return 'En attente';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPending = data['status'] == 'pending';
    final ts = data['createdAt'] as Timestamp?;
    final date = ts != null
        ? '${ts.toDate().day}/${ts.toDate().month}/${ts.toDate().year}'
        : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: isPending
            ? Border.all(
                color: const Color(0xFFFF8F00).withValues(alpha: 0.5),
                width: 1.5)
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFF5D4037).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.bakery_dining_rounded,
                    color: Color(0xFF5D4037)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data['boulangerieName'] ?? '—',
                      style: GoogleFonts.urbanist(
                          fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    Text(
                      data['address'] ?? '',
                      style: GoogleFonts.urbanist(
                          fontSize: 12, color: Colors.grey.shade500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(_statusLabel,
                    style: TextStyle(
                        color: _statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 12),
            _infoRow(Icons.person_outline, data['ownerName'] ?? '—'),
            const SizedBox(height: 6),
            _infoRow(Icons.phone_outlined, data['phone'] ?? '—'),
            const SizedBox(height: 6),
            _infoRow(Icons.location_on_outlined, data['address'] ?? '—'),
            if (date.isNotEmpty) ...[
              const SizedBox(height: 6),
              _infoRow(Icons.calendar_today_outlined, date),
            ],
            if (isPending) ...[
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onReject,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text('Refuser',
                        style: GoogleFonts.urbanist(
                            color: Colors.red, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ScaleButton(
                    onPressed: onApprove,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF5D4037),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      elevation: 2,
                    ),
                    child: Text('Approuver',
                        style: GoogleFonts.urbanist(
                            color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String text) {
    return Row(children: [
      Icon(icon, size: 15, color: Colors.grey.shade400),
      const SizedBox(width: 8),
      Expanded(
        child: Text(text,
            style:
                GoogleFonts.urbanist(fontSize: 13, color: Colors.grey.shade700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ),
    ]);
  }
}
