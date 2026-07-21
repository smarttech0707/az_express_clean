import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../theme/app_theme.dart';

class AdminPurgePage extends StatefulWidget {
  const AdminPurgePage({super.key});

  @override
  State<AdminPurgePage> createState() => _AdminPurgePageState();
}

class _AdminPurgePageState extends State<AdminPurgePage> {
  bool _purgeOrders = true;
  bool _purgeChats = true;
  bool _purgeRecharges = false;

  bool _loading = false;
  String _log = '';
  int _totalDeleted = 0;

  Future<int> _deleteCollection(String collection) async {
    int deleted = 0;
    QuerySnapshot snap;
    do {
      snap = await FirebaseFirestore.instance
          .collection(collection)
          .limit(400)
          .get();
      if (snap.docs.isEmpty) break;

      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snap.docs) {
        batch.delete(doc.reference);
        deleted++;
      }
      await batch.commit();

      if (mounted) {
        setState(() {
          _log += "  $collection : $deleted docs supprimés…\n";
        });
      }
    } while (snap.docs.length == 400);

    return deleted;
  }

  Future<void> _purge() async {
    if (!_purgeOrders && !_purgeChats && !_purgeRecharges) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Sélectionnez au moins une collection")),
      );
      return;
    }

    // Confirmation
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_rounded, color: Colors.red),
            SizedBox(width: 8),
            Text("Confirmer la purge"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Cette action est IRRÉVERSIBLE.\nLes données suivantes seront supprimées définitivement :",
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            if (_purgeOrders)
              _confirmRow(Icons.receipt_long, "Toutes les commandes"),
            if (_purgeChats)
              _confirmRow(Icons.chat_bubble, "Tous les messages chat"),
            if (_purgeRecharges)
              _confirmRow(Icons.account_balance_wallet,
                  "Toutes les demandes de recharge"),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Annuler"),
          ),
          ScaleButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("Purger",
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _loading = true;
      _log = '';
      _totalDeleted = 0;
    });

    try {
      if (_purgeOrders) {
        setState(() => _log += "Suppression des commandes…\n");
        final n = await _deleteCollection("orders");
        _totalDeleted += n;
        setState(() => _log += "✓ Commandes : $n supprimées\n\n");
      }
      if (_purgeChats) {
        setState(() => _log += "Suppression des chats…\n");
        final n = await _deleteCollection("chats");
        _totalDeleted += n;
        setState(() => _log += "✓ Chats : $n supprimés\n\n");
      }
      if (_purgeRecharges) {
        setState(() => _log += "Suppression des recharges…\n");
        final n = await _deleteCollection("recharge_requests");
        _totalDeleted += n;
        setState(() => _log += "✓ Recharges : $n supprimées\n\n");
      }

      setState(() {
        _log += "═══════════════════\n"
            "✅ Purge terminée — $_totalDeleted document(s) supprimé(s)";
      });
    } catch (e) {
      setState(() => _log += "\n❌ Erreur : $e");
    }

    setState(() => _loading = false);
  }

  Widget _confirmRow(IconData icon, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.red),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        title: const Text("Purger les données"),
        backgroundColor: Colors.red.shade700,
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Warning banner
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: Colors.red.shade700, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      "Action irréversible. Les données supprimées ne pourront pas être récupérées.",
                      style: TextStyle(
                        color: Colors.red.shade800,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            const Text(
              "Sélectionner les collections à vider",
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 12),

            _CollectionTile(
              icon: Icons.receipt_long_rounded,
              title: "Commandes",
              subtitle: "Toutes les commandes clients (orders)",
              color: AppColors.primary,
              value: _purgeOrders,
              onChanged: _loading
                  ? null
                  : (v) => setState(() => _purgeOrders = v ?? false),
            ),
            const SizedBox(height: 10),
            _CollectionTile(
              icon: Icons.chat_bubble_rounded,
              title: "Messages chat",
              subtitle: "Conversations livreur ↔ client (chats)",
              color: const Color(0xFF1565C0),
              value: _purgeChats,
              onChanged: _loading
                  ? null
                  : (v) => setState(() => _purgeChats = v ?? false),
            ),
            const SizedBox(height: 10),
            _CollectionTile(
              icon: Icons.account_balance_wallet_rounded,
              title: "Demandes de recharge",
              subtitle: "Historique des recharges wallet (recharge_requests)",
              color: const Color(0xFF2E7D32),
              value: _purgeRecharges,
              onChanged: _loading
                  ? null
                  : (v) => setState(() => _purgeRecharges = v ?? false),
            ),

            const SizedBox(height: 28),

            // Purge button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _purge,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                  disabledBackgroundColor: Colors.red.shade200,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 4,
                ),
                icon: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_sweep_rounded,
                        color: Colors.white),
                label: Text(
                  _loading ? "Suppression en cours…" : "Lancer la purge",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

            // Log output
            if (_log.isNotEmpty) ...[
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  _log,
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final bool value;
  final ValueChanged<bool?>? onChanged;

  const _CollectionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Master Prompt 125 (Partie 8) — MergeSemantics regroupe titre/sous-titre
    // et la case à cocher en une seule annonce cohérente pour un lecteur
    // d'écran (sinon la case s'annoncerait "coché/non coché" sans jamais
    // dire de quelle collection il s'agit).
    return MergeSemantics(
      child: GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: value ? color : Colors.grey.shade200,
            width: value ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                        color: Colors.grey.shade600, fontSize: 12),
                  ),
                ],
              ),
            ),
            Checkbox(
              value: value,
              onChanged: onChanged,
              activeColor: color,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4)),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
