import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/cash_remittance_view.dart';
import '../../theme/app_theme.dart';
import '../../widgets/cash_remittance_panel.dart';
import '../../widgets/stream_error_state.dart';

/// Une commande lue depuis le flux (identifiant + données), indépendante de Firestore pour rester testable.
typedef CashOrderRow = ({String id, Map<String, dynamic> data});

/// Source des commandes à suivre : au plus [limit] documents, relue en direct. Remplaçable dans les tests.
typedef CashOrdersSource = Stream<List<CashOrderRow>> Function(
    String driverId, int limit);

/// Commandes livrées de ce livreur dont le règlement marchand n'est pas soldé. Filtres d'ÉGALITÉ uniquement (aucun index
/// composite) : `amountsVersion == 2` et `paymentMethod == 'cash'` écartent côté serveur les commandes historiques, qui
/// sinon occuperaient la fenêtre de [limit] documents (sans tri, Firestore ordonne par identifiant) et pourraient en
/// chasser des commandes v2 à signaler ou à reverser.
Stream<List<CashOrderRow>> firestoreCashOrders(String driverId, int limit) =>
    FirebaseFirestore.instance
        .collection('orders')
        .where('driverId', isEqualTo: driverId)
        .where('status', isEqualTo: 'delivered')
        .where('merchantCashSettled', isEqualTo: false)
        .where('amountsVersion', isEqualTo: 2)
        .where('paymentMethod', isEqualTo: 'cash')
        .limit(limit)
        .snapshots()
        .map((s) => [for (final d in s.docs) (id: d.id, data: d.data())]);

/// Espèces à reverser aux restaurants (commandes Restaurant/Boulangerie v2 livrées et payées en espèces).
/// Le livreur déclare ici les sommes remises et signale un éventuel non-paiement ; seule la confirmation du restaurant
/// règle la commande. Une commande y reste tant qu'elle n'est pas soldée : l'état vient de Firestore, jamais d'un
/// stockage local, donc la liste se retrouve intacte après fermeture et réouverture de l'application. Si plus de
/// [pageSize] commandes sont en attente, « Afficher plus » élargit la fenêtre. Aucune écriture : tout passe par
/// partnerOrderActionCF.
class DriverCashRemittancePage extends StatefulWidget {
  final String driverId;
  final CashOrdersSource? source;
  final int pageSize;
  const DriverCashRemittancePage({
    super.key,
    required this.driverId,
    this.source,
    this.pageSize = 50,
  });

  @override
  State<DriverCashRemittancePage> createState() =>
      _DriverCashRemittancePageState();
}

class _DriverCashRemittancePageState extends State<DriverCashRemittancePage> {
  late int _limit = widget.pageSize;
  late Stream<List<CashOrderRow>> _stream = _open();

  Stream<List<CashOrderRow>> _open() =>
      (widget.source ?? firestoreCashOrders)(widget.driverId, _limit);

  void _showMore() => setState(() {
        _limit += widget.pageSize;
        _stream = _open();
      });

  static int _deliveredMs(Map<String, dynamic> data) {
    final t = data['deliveredAt'];
    return t is Timestamp ? t.millisecondsSinceEpoch : 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Espèces à reverser'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: StreamBuilder<List<CashOrderRow>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) {
            return const StreamErrorState(
              message:
                  'Impossible de charger vos reversements.\nVérifiez votre connexion et réessayez.',
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snap.data!;
          final items = <({
            String id,
            Map<String, dynamic> data,
            CashRemittanceView view
          })>[];
          for (final r in rows) {
            final view = CashRemittanceView.tryParse(r.data);
            if (view != null && !view.closed) {
              items.add((id: r.id, data: r.data, view: view));
            }
          }
          // Plus récentes d'abord (le flux n'est pas trié).
          items.sort((a, b) =>
              _deliveredMs(b.data).compareTo(_deliveredMs(a.data)));
          // Fenêtre pleine : d'autres commandes en attente peuvent exister au-delà.
          final maybeMore = rows.length >= _limit;
          if (items.isEmpty && !maybeMore) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Aucun reversement en attente.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.urbanist(color: AppColors.textLight)),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: items.length + (maybeMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == items.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: OutlinedButton(
                    onPressed: _showMore,
                    child: const Text('Afficher plus de commandes'),
                  ),
                );
              }
              final it = items[i];
              final total = it.data['totalAmount'];
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(AppRadius.lg)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((it.data['sellerName'] as String?) ?? 'Restaurant',
                        style: GoogleFonts.urbanist(
                            fontWeight: FontWeight.w800, fontSize: 15)),
                    CashRemittancePanel(
                      key: ValueKey(it.id),
                      orderId: it.id,
                      view: it.view,
                      role: CashRole.driver,
                      totalCollected: total is num ? total.toInt() : null,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
