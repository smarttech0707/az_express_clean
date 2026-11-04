import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/cash_remittance_view.dart';
import '../../theme/app_theme.dart';
import '../../widgets/cash_remittance_panel.dart';
import '../../widgets/stream_error_state.dart';
import '../driver/driver_cash_remittance_page.dart' show CashOrderRow;

/// Source des non-paiements à examiner : au plus [limit] documents, relue en direct. Remplaçable dans les tests.
typedef CashReviewSource = Stream<List<CashOrderRow>> Function(int limit);

/// Commandes v2 dont le non-paiement déclaré attend un examen (`cashPayment.verification == 'pending_review'`), QUEL QUE SOIT
/// l'état du reversement (`merchantCashSettled` n'est volontairement pas filtré : un reversement clos ne retire pas
/// l'incident de la liste). Une seule égalité sur un champ imbriqué : index mono-champ automatique, aucun index composite.
Stream<List<CashOrderRow>> firestorePendingCashReviews(int limit) =>
    FirebaseFirestore.instance
        .collection('orders')
        .where('cashPayment.verification', isEqualTo: 'pending_review')
        .limit(limit)
        .snapshots()
        .map((s) => [for (final d in s.docs) (id: d.id, data: d.data())]);

/// Incidents de paiement cash à examiner (super-administrateur). L'examen du PAIEMENT (confirmer ou infirmer le non-paiement)
/// est distinct de la RÉSOLUTION du reversement (montant final retenu) : l'examen ne règle aucune dette. Les dossiers restent
/// listés jusqu'à leur examen ; « Afficher plus » élargit la fenêtre au-delà de [pageSize]. Aucune écriture directe : tout
/// passe par partnerOrderActionCF, qui revérifie le rôle super-administrateur.
class AdminCashPaymentReviewPage extends StatefulWidget {
  final CashReviewSource? source;
  final int pageSize;
  const AdminCashPaymentReviewPage(
      {super.key, this.source, this.pageSize = 50});

  @override
  State<AdminCashPaymentReviewPage> createState() =>
      _AdminCashPaymentReviewPageState();
}

class _AdminCashPaymentReviewPageState
    extends State<AdminCashPaymentReviewPage> {
  late int _limit = widget.pageSize;
  late Stream<List<CashOrderRow>> _stream = _open();

  Stream<List<CashOrderRow>> _open() =>
      (widget.source ?? firestorePendingCashReviews)(_limit);

  void _showMore() => setState(() {
        _limit += widget.pageSize;
        _stream = _open();
      });

  static int _declaredMs(Map<String, dynamic> data) {
    final cp = data['cashPayment'];
    final t = cp is Map ? cp['declaredAtMs'] : null;
    return t is int ? t : 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Incidents paiement cash'),
        backgroundColor: AppColors.primaryAction,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: StreamBuilder<List<CashOrderRow>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) {
            return const StreamErrorState(
              message:
                  'Impossible de charger les incidents.\nVérifiez votre connexion et vos droits.',
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snap.data!;
          // Plus anciens d'abord : ce sont ceux qui attendent depuis le plus longtemps.
          final items = [...rows]..sort(
              (a, b) => _declaredMs(a.data).compareTo(_declaredMs(b.data)));
          final maybeMore = rows.length >= _limit;
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Aucun non-paiement à examiner.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.urbanist(color: AppColors.textLight)),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: items.length + 1 + (maybeMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == 0) return const _Explanation();
              if (i == items.length + 1) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: OutlinedButton(
                    onPressed: _showMore,
                    child: const Text('Afficher plus d’incidents'),
                  ),
                );
              }
              return _IncidentTile(row: items[i - 1]);
            },
          );
        },
      ),
    );
  }
}

class _Explanation extends StatelessWidget {
  const _Explanation();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: Text(
        'Le livreur déclare que le client n’a pas payé. « Examiner le non-paiement » confirme ou infirme cette déclaration : '
        'cela ne modifie aucun montant, ne touche aucun wallet et ne règle pas le reversement. Le montant dû au restaurant se '
        'décide séparément avec « Régulariser », tant que le reversement n’est pas clos.',
        style: GoogleFonts.urbanist(fontSize: 12, color: AppColors.textMuted),
      ),
    );
  }
}

class _IncidentTile extends StatelessWidget {
  final CashOrderRow row;
  const _IncidentTile({required this.row});

  @override
  Widget build(BuildContext context) {
    final view = CashRemittanceView.tryParse(row.data);
    final name = (row.data['sellerName'] as String?) ?? 'Restaurant';
    final driverId = (row.data['driverId'] as String?) ?? '—';
    final id = row.id;
    final shortId = id.length > 8 ? id.substring(0, 8) : id;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name,
              style: GoogleFonts.urbanist(
                  fontWeight: FontWeight.w800, fontSize: 15)),
          Text(
              'Commande $shortId… · livreur ${driverId.length > 8 ? driverId.substring(0, 8) : driverId}…',
              style: GoogleFonts.urbanist(
                  fontSize: 12, color: AppColors.textMuted)),
          if (view == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  'Suivi du reversement absent ou incohérent : à examiner par le support avant toute décision.',
                  style: GoogleFonts.urbanist(
                      fontSize: 12, color: AppColors.errorStrong)),
            )
          else
            CashRemittancePanel(
                key: ValueKey(id),
                orderId: id,
                view: view,
                role: CashRole.admin),
        ],
      ),
    );
  }
}
