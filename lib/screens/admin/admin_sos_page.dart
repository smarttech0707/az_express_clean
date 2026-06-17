import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';

class AdminSosPage extends StatelessWidget {
  const AdminSosPage({super.key});

  Future<void> _resolve(String id) async {
    await FirebaseFirestore.instance
        .collection('sos_alerts')
        .doc(id)
        .update({'status': 'resolved'});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Alertes SOS'),
        backgroundColor: Colors.red.shade700,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('sos_alerts')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snap.data!.docs;

          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 80, color: Colors.green.shade300),
                  const SizedBox(height: 16),
                  const Text('Aucune alerte SOS',
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                ],
              ),
            );
          }

          final active = docs
              .where((d) =>
                  (d.data() as Map<String, dynamic>)['status'] == 'active')
              .toList();
          final resolved = docs
              .where((d) =>
                  (d.data() as Map<String, dynamic>)['status'] != 'active')
              .toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (active.isNotEmpty) ...[
                _SectionHeader(
                    label: 'Actives (${active.length})', color: Colors.red),
                const SizedBox(height: 10),
                ...active.map((d) =>
                    _SosCard(doc: d, onResolve: () => _resolve(d.id))),
              ],
              if (resolved.isNotEmpty) ...[
                const SizedBox(height: 20),
                _SectionHeader(
                    label: 'Résolues (${resolved.length})',
                    color: Colors.grey),
                const SizedBox(height: 10),
                ...resolved.map((d) => _SosCard(doc: d, resolved: true)),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final Color color;
  const _SectionHeader({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _SosCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  final bool resolved;
  final VoidCallback? onResolve;

  const _SosCard({required this.doc, this.resolved = false, this.onResolve});

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return "À l'instant";
    if (diff.inHours < 1) return 'Il y a ${diff.inMinutes} min';
    if (diff.inDays < 1) return 'Il y a ${diff.inHours}h';
    return '${dt.day}/${dt.month} à ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final driverName = data['driverName'] ?? '—';
    final lat = (data['lat'] as num?)?.toDouble() ?? 0;
    final lng = (data['lng'] as num?)?.toDouble() ?? 0;
    final ts = data['timestamp'] as Timestamp?;
    final time = ts != null ? _formatTime(ts.toDate()) : '—';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: resolved ? Colors.grey.shade200 : Colors.red.shade200,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: resolved
                ? Colors.black.withValues(alpha: 0.04)
                : Colors.red.withValues(alpha: 0.10),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color:
                        resolved ? Colors.grey.shade100 : Colors.red.shade50,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.sos_rounded,
                    color: resolved ? Colors.grey : Colors.red.shade700,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        driverName,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        time,
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (!resolved)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.red.shade300),
                    ),
                    child: Text(
                      'URGENT',
                      style: TextStyle(
                        color: Colors.red.shade700,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Résolu',
                      style: TextStyle(
                          color: Colors.green.shade700,
                          fontSize: 11,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),

            // GPS
            if (lat != 0 && lng != 0) ...[
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => launchUrl(
                  Uri.parse('https://maps.google.com/?q=$lat,$lng'),
                  mode: LaunchMode.externalApplication,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.blue.shade100),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.location_on_rounded,
                          color: Colors.blue.shade700, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                          style: TextStyle(
                              fontSize: 13, color: Colors.blue.shade700),
                        ),
                      ),
                      Icon(Icons.open_in_new_rounded,
                          size: 16, color: Colors.blue.shade400),
                    ],
                  ),
                ),
              ),
            ],

            // Resolve button
            if (!resolved && onResolve != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onResolve,
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: const Text('Marquer comme résolu'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
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
