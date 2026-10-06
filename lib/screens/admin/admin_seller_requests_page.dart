import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../utils/partner_location_validator.dart';

/// Levée quand `sellers/{uid}` existe déjà au moment d'une approbation.
///
/// L'approbation est une création initiale : si le document existe, la demande
/// a déjà été traitée. Écraser serait destructeur (voir
/// [buildApprovedSellerDoc]), merger masquerait une double approbation — on
/// refuse donc, et l'admin voit un message explicite.
@visibleForTesting
class SellerAlreadyApprovedException implements Exception {
  const SellerAlreadyApprovedException();
}

/// Accès minimal au stockage, pour exécuter la décision d'approbation hors
/// Firestore dans les tests. Implémenté sur une `Transaction` réelle par
/// `_approve`.
@visibleForTesting
abstract class SellerApprovalStore {
  Future<bool> sellerExists();
  void createSeller(Map<String, dynamic> data);
  void markRequestApproved();
}

/// Document `sellers` créé à l'approbation d'une demande.
///
/// Ne contient volontairement AUCUN champ financier. `firestore.rules`
/// (match /sellers) désigne lui-même comme non modifiables par le propriétaire
/// — donc comme sensibles : `wallet`, `subscriptionStatus`,
/// `subscriptionExpiresAt`, `vipStatus`, `vipExpiresAt`, `vipStartedAt`,
/// `plan`, `priorityLevel`, `paymentStatus`. Aucun d'eux n'est écrit ici ; le
/// solde est créé paresseusement par les Cloud Functions (`FieldValue.increment`
/// dans orderActions.js / azia/tools/marketplace.js) à la première vente, et
/// l'abonnement par `manageProfessionalSubscription`.
///
/// Extrait en fonction pure pour être vérifiable sans Firestore.
@visibleForTesting
Map<String, dynamic> buildApprovedSellerDoc(
  String uid,
  Map<String, dynamic> request, {
  required double latitude,
  required double longitude,
  required Object createdAt,
}) =>
    {
      'uid': uid,
      'ownerName': request['ownerName'] ?? '',
      'shopName': request['shopName'] ?? '',
      'phone': request['phone'] ?? '',
      'address': request['address'] ?? '',
      'category': request['category'] ?? '',
      'lat': latitude,
      'lng': longitude,
      'isActive': true,
      'createdAt': createdAt,
    };

/// Corps de la transaction d'approbation.
///
/// La lecture d'existence et les deux écritures vivent dans la MÊME
/// transaction : une seconde approbation concurrente (double tap, deux admins,
/// relance après un commit dont le retour visuel a été manqué) est refusée au
/// lieu d'écraser. Un simple `get()` préalable suivi d'un `batch` ne fermerait
/// pas cette fenêtre.
@visibleForTesting
Future<void> runSellerApproval(
  SellerApprovalStore store,
  String uid,
  Map<String, dynamic> request, {
  required double latitude,
  required double longitude,
  required Object createdAt,
}) async {
  if (await store.sellerExists()) {
    throw const SellerAlreadyApprovedException();
  }
  store.createSeller(buildApprovedSellerDoc(
    uid,
    request,
    latitude: latitude,
    longitude: longitude,
    createdAt: createdAt,
  ));
  store.markRequestApproved();
}

/// Message affiché à l'admin selon le résultat RÉEL de la transaction.
@visibleForTesting
({String message, bool isSuccess}) sellerApprovalFeedback({
  required Object? error,
  required String shopName,
}) {
  if (error == null) return (message: '$shopName approuvé !', isSuccess: true);
  if (error is SellerAlreadyApprovedException) {
    return (
      message: 'Ce vendeur possède déjà un compte : la demande a '
          'probablement déjà été approuvée. Aucune donnée n\'a été modifiée.',
      isSuccess: false,
    );
  }
  return (
    message: 'Approbation impossible. Vérifiez vos droits administrateur '
        'et réessayez.',
    isSuccess: false,
  );
}

class _TransactionSellerApprovalStore implements SellerApprovalStore {
  _TransactionSellerApprovalStore(this._tx, this._sellerRef, this._requestRef);

  final Transaction _tx;
  final DocumentReference<Map<String, dynamic>> _sellerRef;
  final DocumentReference<Map<String, dynamic>> _requestRef;

  @override
  Future<bool> sellerExists() async => (await _tx.get(_sellerRef)).exists;

  @override
  void createSeller(Map<String, dynamic> data) => _tx.set(_sellerRef, data);

  @override
  void markRequestApproved() => _tx.update(_requestRef, {
        'status': 'approved',
        'approvedAt': FieldValue.serverTimestamp(),
      });
}

class AdminSellerRequestsPage extends StatefulWidget {
  const AdminSellerRequestsPage({super.key});

  @override
  State<AdminSellerRequestsPage> createState() =>
      _AdminSellerRequestsPageState();
}

class _AdminSellerRequestsPageState extends State<AdminSellerRequestsPage>
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
    final sellerRef = db.collection('sellers').doc(uid);
    final requestRef = db.collection('seller_requests').doc(uid);

    // Transaction plutot que WriteBatch : le batch ecrivait sans jamais
    // verifier l'existence de `sellers/{uid}`, donc une double approbation (le
    // bouton n'a aucun etat de chargement) ou deux admins simultanes
    // ecrasaient le document vendeur et ses champs financiers.
    Object? approvalError;
    try {
      await db.runTransaction((tx) async {
        await runSellerApproval(
          _TransactionSellerApprovalStore(tx, sellerRef, requestRef),
          uid,
          data,
          // Non-null garanti : `PartnerLocationValidator.validate` ci-dessus
          // retourne un message des que l'une des deux coordonnees est nulle.
          latitude: latitude!,
          longitude: longitude!,
          createdAt: FieldValue.serverTimestamp(),
        );
      });
    } catch (e) {
      approvalError = e;
      debugPrint('[ADMIN_SELLER] approbation echouee '
          'requestId=$uid type=${e.runtimeType}');
    }

    if (!mounted) return;
    final feedback = sellerApprovalFeedback(
      error: approvalError,
      shopName: '${data['shopName'] ?? 'Le vendeur'}',
    );
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(feedback.message),
      backgroundColor:
          feedback.isSuccess ? const Color(0xFF2E7D32) : Colors.red,
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
        .collection('seller_requests')
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
        title: Text('Demandes Vendeurs',
            style: GoogleFonts.urbanist(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1565C0),
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
          _SellerRequestsList(
            statusFilter: 'pending',
            onApprove: _approve,
            onReject: _reject,
          ),
          _SellerRequestsList(
            statusFilter: null,
            onApprove: _approve,
            onReject: _reject,
          ),
        ],
      ),
    );
  }
}

class _SellerRequestsList extends StatelessWidget {
  final String? statusFilter;
  final Future<void> Function(String uid, Map<String, dynamic> data) onApprove;
  final Future<void> Function(String uid, String name) onReject;

  const _SellerRequestsList({
    required this.statusFilter,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> query;

    if (statusFilter != null) {
      query = FirebaseFirestore.instance
          .collection('seller_requests')
          .where('status', isEqualTo: statusFilter)
          .orderBy('createdAt', descending: true);
    } else {
      query = FirebaseFirestore.instance
          .collection('seller_requests')
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
            return _SellerRequestCard(
              uid: doc.id,
              data: data,
              onApprove: () => onApprove(doc.id, data),
              onReject: () =>
                  onReject(doc.id, data['shopName'] ?? 'cette boutique'),
            );
          },
        );
      },
    );
  }
}

class _SellerRequestCard extends StatelessWidget {
  final String uid;
  final Map<String, dynamic> data;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _SellerRequestCard({
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
        return 'Approuvé';
      case 'rejected':
        return 'Refusé';
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
                  color: const Color(0xFF1565C0).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.storefront_rounded,
                    color: Color(0xFF1565C0)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data['shopName'] ?? '—',
                      style: GoogleFonts.urbanist(
                          fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    Text(
                      data['category'] ?? '',
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
                      backgroundColor: const Color(0xFF1565C0),
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
