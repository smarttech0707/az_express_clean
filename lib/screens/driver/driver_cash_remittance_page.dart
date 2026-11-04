import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/cash_remittance_view.dart';
import '../../theme/app_theme.dart';
import '../../widgets/cash_remittance_panel.dart';
import '../../widgets/stream_error_state.dart';

/// Espèces à reverser aux restaurants (commandes Restaurant/Boulangerie v2 livrées et payées en espèces).
/// Le livreur déclare ici les sommes remises ; seule la confirmation du restaurant règle la commande. Les commandes
/// historiques et les paiements wallet n'apparaissent jamais ici. Aucune écriture : tout passe par partnerOrderActionCF.
class DriverCashRemittancePage extends StatelessWidget {
  final String driverId;
  const DriverCashRemittancePage({super.key, required this.driverId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Espèces à reverser'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        // Filtres d'égalité uniquement (pas d'index composite) : commandes livrées de ce livreur dont le règlement
        // marchand n'est pas soldé. Les v2 en espèces sont retenues côté client.
        stream: FirebaseFirestore.instance
            .collection('orders')
            .where('driverId', isEqualTo: driverId)
            .where('status', isEqualTo: 'delivered')
            .where('merchantCashSettled', isEqualTo: false)
            .limit(50)
            .snapshots(),
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
          final items = <({
            String id,
            Map<String, dynamic> data,
            CashRemittanceView view
          })>[];
          for (final d in snap.data!.docs) {
            final data = d.data();
            final view = CashRemittanceView.tryParse(data);
            if (view != null && !view.closed) {
              items.add((id: d.id, data: data, view: view));
            }
          }
          if (items.isEmpty) {
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
            itemCount: items.length,
            itemBuilder: (context, i) {
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
