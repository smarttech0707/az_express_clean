import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../utils/partner_location_validator.dart';

/// Document `pharmacies` créé à l'approbation d'une demande.
///
/// `password` / `accessCode` sont VOLONTAIREMENT absents : `firestore.rules`
/// rejette tout batch admin contenant ne serait-ce que la CLÉ
/// (`!request.resource.data.keys().hasAny(['password','accessCode'])`). Le
/// secret vit haché dans `pharmacie_credentials`, écrit uniquement par les
/// Cloud Functions `setPharmaciePassword()` / `pharmacieLogin()`.
///
/// Extrait en fonction pure pour être vérifiable sans Firestore.
@visibleForTesting
Map<String, dynamic> buildApprovedPharmacieDoc(
  Map<String, dynamic> request, {
  required double latitude,
  required double longitude,
  required Object createdAt,
}) =>
    {
      'name': request['pharmacieName'] ?? '',
      'ownerName': request['ownerName'] ?? '',
      'phone': request['phone'] ?? '',
      'address': request['address'] ?? '',
      'lat': latitude,
      'lng': longitude,
      'isActive': true,
      'isOpen': false,
      'mustChangePassword': false,
      'createdAt': createdAt,
    };

/// Message affiché à l'admin selon le résultat RÉEL du commit Firestore.
///
/// `error == null` est le seul cas qui produit un message de succès : un rejet
/// Firestore ne peut donc jamais être présenté comme une réussite. Avant ce
/// correctif, l'exception remontait dans un `VoidCallback` non attendu et
/// l'écran restait totalement muet.
@visibleForTesting
({String message, bool isSuccess}) pharmacieApprovalFeedback({
  required Object? error,
  required String pharmacieName,
}) =>
    error == null
        ? (message: '$pharmacieName approuvée !', isSuccess: true)
        : (
            message: 'Approbation impossible. Vérifiez vos droits '
                'administrateur et réessayez.',
            isSuccess: false
          );

class AdminPharmacieRequestsPage extends StatefulWidget {
  const AdminPharmacieRequestsPage({super.key});

  @override
  State<AdminPharmacieRequestsPage> createState() =>
      _AdminPharmacieRequestsPageState();
}

class _AdminPharmacieRequestsPageState extends State<AdminPharmacieRequestsPage>
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

  Future<void> _approve(String docId, Map<String, dynamic> data) async {
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

    // Create pharmacie doc (auto-id)
    //
    // `password` / `accessCode` sont VOLONTAIREMENT absents : `firestore.rules`
    // interdit à un admin d'écrire ces clés sur `pharmacies`
    // (`!request.resource.data.keys().hasAny(['password','accessCode'])`), et
    // la simple PRÉSENCE de la clé suffisait à faire rejeter tout le batch —
    // donc aucune pharmacie ne pouvait être approuvée. Le secret vit désormais
    // haché dans `pharmacie_credentials`, alimenté uniquement par les Cloud
    // Functions `setPharmaciePassword()` / `pharmacieLogin()`. Après
    // approbation, l'admin définit le mot de passe depuis l'écran Pharmacies
    // (bouton dédié → `setPharmaciePassword`). La demande ne transportait de
    // toute façon aucun mot de passe : `pharmacie_register.dart` n'en envoie
    // pas, la valeur écrite ici était donc toujours la chaîne vide.
    final pharmRef = db.collection('pharmacies').doc();
    batch.set(
      pharmRef,
      buildApprovedPharmacieDoc(
        data,
        // Non-null garanti : `PartnerLocationValidator.validate` ci-dessus
        // retourne un message dès que l'une des deux coordonnées est nulle.
        latitude: latitude!,
        longitude: longitude!,
        createdAt: FieldValue.serverTimestamp(),
      ),
    );

    batch.update(db.collection('pharmacie_requests').doc(docId), {
      'status': 'approved',
      'approvedAt': FieldValue.serverTimestamp(),
      'pharmacieId': pharmRef.id,
    });

    // Le batch reste atomique : création de la pharmacie et passage de la
    // demande en `approved` réussissent ou échouent ensemble. Le message de
    // succès n'est affiché QU'APRÈS confirmation du commit — auparavant, un
    // rejet Firestore laissait l'écran totalement muet (l'exception remontait
    // dans un `VoidCallback` non attendu, donc perdue en erreur asynchrone).
    Object? commitError;
    try {
      await batch.commit();
    } catch (e) {
      commitError = e;
      debugPrint('[ADMIN_PHARMACIE] approbation échouée '
          'requestId=$docId type=${e.runtimeType}');
    }

    if (!mounted) return;
    final feedback = pharmacieApprovalFeedback(
      error: commitError,
      pharmacieName: '${data['pharmacieName'] ?? 'La pharmacie'}',
    );
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(feedback.message),
      backgroundColor:
          feedback.isSuccess ? const Color(0xFF2E7D32) : Colors.red,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _reject(String docId, String name) async {
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
        .collection('pharmacie_requests')
        .doc(docId)
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
        title: Text('Demandes Pharmacies',
            style: GoogleFonts.urbanist(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.red.shade700,
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
          _PharmacieRequestsList(
            statusFilter: 'pending',
            onApprove: _approve,
            onReject: _reject,
          ),
          _PharmacieRequestsList(
            statusFilter: null,
            onApprove: _approve,
            onReject: _reject,
          ),
        ],
      ),
    );
  }
}

class _PharmacieRequestsList extends StatelessWidget {
  final String? statusFilter;
  final Future<void> Function(String docId, Map<String, dynamic> data)
      onApprove;
  final Future<void> Function(String docId, String name) onReject;

  const _PharmacieRequestsList({
    required this.statusFilter,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> query;

    if (statusFilter != null) {
      query = FirebaseFirestore.instance
          .collection('pharmacie_requests')
          .where('status', isEqualTo: statusFilter)
          .orderBy('createdAt', descending: true);
    } else {
      query = FirebaseFirestore.instance
          .collection('pharmacie_requests')
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
            return _PharmacieRequestCard(
              docId: doc.id,
              data: data,
              onApprove: () => onApprove(doc.id, data),
              onReject: () =>
                  onReject(doc.id, data['pharmacieName'] ?? 'cette pharmacie'),
            );
          },
        );
      },
    );
  }
}

class _PharmacieRequestCard extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> data;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _PharmacieRequestCard({
    required this.docId,
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
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.local_pharmacy_rounded,
                    color: Colors.red.shade700),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data['pharmacieName'] ?? '—',
                      style: GoogleFonts.urbanist(
                          fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    Text(
                      data['phone'] ?? '',
                      style: GoogleFonts.urbanist(
                          fontSize: 12, color: Colors.grey.shade500),
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
                      backgroundColor: Colors.red.shade700,
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
