import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';

String _generatePin() {
  final rand = Random.secure();
  return List.generate(6, (_) => rand.nextInt(10).toString()).join();
}

const _kSubcatLabels = {
  'macon':                'Maçon',
  'plombier':             'Plombier',
  'electricien':          'Électricien',
  'ferronnier':           'Ferronnier',
  'menuisier':            'Menuisier',
  'carreleur':            'Carreleur',
  'peintre':              'Peintre',
  'vitrier':              'Vitrier',
  'reparateur_tv':        'Réparateur TV',
  'installation_camera':  'Installation caméra',
  'decoration':           'Décoration intérieure',
  'reparateur_portable':  'Réparateur portable',
  'salon_coiffure_homme': 'Salon coiffure homme',
  'barber_shop':          'Barber Shop',
  'salon_coiffure_femme': 'Salon coiffure femme',
  'onglerie':             'Onglerie',
  'mecanicien_voiture':   'Mécanicien voiture',
  'mecanicien_moto':      'Mécanicien moto',
  'electrique_auto':      'Électricien auto',
  'carrosserie':          'Carrosserie',
  'location':             'Location maison',
  'vente_maison':         'Vente maison',
  'local_commercial':     'Local commercial',
  'terrain':              'Terrain',
  'eau_pack':             'Eau en pack',
  'ciment_briques':       'Ciment & Briques',
  'telephone':            'Téléphones',
  'accessoires':          'Accessoires téléphonie',
  'cave_vins':            'Vins & Spiritueux',
  'cave_bieres':          'Bières',
  'cave_sans_alcool':     'Boissons sans alcool',
};

class AdminServiceRequestsPage extends StatelessWidget {
  const AdminServiceRequestsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFFF2F3F7),
        appBar: AppBar(
          title: Text('Demandes prestataires',
              style: GoogleFonts.inter(
                  color: Colors.white, fontWeight: FontWeight.bold)),
          backgroundColor: const Color(0xFF1565C0),
          foregroundColor: Colors.white,
          centerTitle: true,
          bottom: TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            indicatorColor: Colors.white,
            labelStyle:
                GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13),
            tabs: const [
              Tab(text: 'En attente'),
              Tab(text: 'Traitées'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _RequestsList(statusFilter: 'pending'),
            _RequestsList(statusFilter: 'done'),
          ],
        ),
      ),
    );
  }
}

class _RequestsList extends StatelessWidget {
  final String statusFilter;
  const _RequestsList({required this.statusFilter});

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> query = FirebaseFirestore.instance
        .collection('service_providers');

    if (statusFilter == 'pending') {
      query = query.where('status', isEqualTo: 'pending');
    } else {
      // Treated = approved or rejected (not pending, not admin-created without status)
      query = query.where('status', whereIn: ['approved', 'rejected']);
    }

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data?.docs ?? [];
        // Filter self-registrations only (status field exists)
        final filtered = docs
            .where((d) => (d.data()['status'] as String?)?.isNotEmpty == true)
            .toList();

        if (filtered.isEmpty) {
          return _Empty(
            message: statusFilter == 'pending'
                ? 'Aucune demande en attente'
                : 'Aucune demande traitée',
            icon: statusFilter == 'pending'
                ? Icons.hourglass_empty_rounded
                : Icons.check_circle_outline_rounded,
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: filtered.length,
          itemBuilder: (ctx, i) {
            final doc = filtered[i];
            return _RequestCard(doc: doc);
          },
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  final String message;
  final IconData icon;
  const _Empty({required this.message, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 60, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text(message,
              style: GoogleFonts.inter(
                  fontSize: 15, color: Colors.grey.shade500)),
        ],
      ),
    );
  }
}

class _RequestCard extends StatefulWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  const _RequestCard({required this.doc});

  @override
  State<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<_RequestCard> {
  bool _loading = false;

  Future<void> _approve() async {
    setState(() => _loading = true);
    final pin = _generatePin();
    try {
      await FirebaseFirestore.instance
          .collection('service_providers')
          .doc(widget.doc.id)
          .update({
        'status':      'approved',
        'isAvailable': true,
        'artisanPin':  pin,
        'approvedAt':  FieldValue.serverTimestamp(),
      });
      if (mounted) _showPin(pin);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Erreur : $e'), backgroundColor: Colors.red));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _reject() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rejeter la demande ?'),
        content: Text(
          'Voulez-vous rejeter la demande de ${widget.doc.data()['name'] ?? ''}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Rejeter', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _loading = true);
    try {
      await FirebaseFirestore.instance
          .collection('service_providers')
          .doc(widget.doc.id)
          .update({
        'status':     'rejected',
        'rejectedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Erreur : $e'), backgroundColor: Colors.red));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _showPin(String pin) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          const Icon(Icons.check_circle_rounded, color: Colors.green, size: 28),
          const SizedBox(width: 8),
          Text('Demande approuvée',
              style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 16)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Voici le code PIN du prestataire. '
              'Communiquez-le lui pour qu\'il puisse se connecter.',
              style: GoogleFonts.inter(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF1565C0).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border:
                    Border.all(color: const Color(0xFF1565C0).withValues(alpha: 0.3)),
              ),
              child: Text(
                pin,
                style: GoogleFonts.inter(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 8,
                    color: const Color(0xFF1565C0)),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1565C0),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text('OK',
                style: GoogleFonts.inter(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.doc.data();
    final status   = d['status'] as String? ?? 'pending';
    final name     = d['name'] as String? ?? '—';
    final phone    = d['phone'] as String? ?? '';
    final address  = d['address'] as String? ?? '';
    final subcat   = d['subcategory'] as String? ?? '';
    final desc     = d['description'] as String? ?? '';
    final photos   = List<String>.from(d['photos'] ?? []);
    final pin      = d['artisanPin'] as String?;

    final subcatLabel = _kSubcatLabels[subcat] ?? subcat;

    final Color statusColor;
    final String statusLabel;
    final IconData statusIcon;

    switch (status) {
      case 'approved':
        statusColor = Colors.green;
        statusLabel = 'Approuvé';
        statusIcon  = Icons.check_circle_rounded;
        break;
      case 'rejected':
        statusColor = Colors.red;
        statusLabel = 'Rejeté';
        statusIcon  = Icons.cancel_rounded;
        break;
      default:
        statusColor = Colors.orange;
        statusLabel = 'En attente';
        statusIcon  = Icons.hourglass_top_rounded;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
          // ── En-tête ──────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.06),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1565C0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.storefront_rounded,
                      color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: GoogleFonts.inter(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      Text(subcatLabel,
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              color: const Color(0xFF1565C0),
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, color: statusColor, size: 14),
                      const SizedBox(width: 4),
                      Text(statusLabel,
                          style: GoogleFonts.inter(
                              color: statusColor,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Détails ───────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row(Icons.phone_rounded, phone),
                const SizedBox(height: 6),
                _row(Icons.location_on_rounded, address),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _row(Icons.description_rounded, desc),
                ],

                // Photos
                if (photos.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 70,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: photos.map((url) {
                        return Container(
                          width: 70,
                          height: 70,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            image: DecorationImage(
                                image: NetworkImage(url), fit: BoxFit.cover),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],

                // PIN affiché si approuvé
                if (status == 'approved' && pin != null && pin.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: Colors.green.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_rounded,
                            color: Colors.green, size: 16),
                        const SizedBox(width: 8),
                        Text('Code PIN : ',
                            style: GoogleFonts.inter(
                                fontSize: 13, color: Colors.green.shade700)),
                        Text(pin,
                            style: GoogleFonts.inter(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 4,
                                color: Colors.green.shade800)),
                      ],
                    ),
                  ),
                ],

                // Boutons d'action pour les demandes en attente
                if (status == 'pending') ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _loading ? null : _reject,
                          icon: const Icon(Icons.close_rounded,
                              color: Colors.red, size: 16),
                          label: Text('Rejeter',
                              style: GoogleFonts.inter(
                                  color: Colors.red,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.red),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding:
                                const EdgeInsets.symmetric(vertical: 11),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _loading ? null : _approve,
                          icon: _loading
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : const Icon(Icons.check_rounded,
                                  color: Colors.white, size: 16),
                          label: Text('Approuver',
                              style: GoogleFonts.inter(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding:
                                const EdgeInsets.symmetric(vertical: 11),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: Colors.grey.shade500),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: GoogleFonts.inter(
                  fontSize: 12.5, color: Colors.grey.shade700)),
        ),
      ],
    );
  }
}
