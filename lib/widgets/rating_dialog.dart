import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import '../services/firestore_service.dart';
import '../theme/app_theme.dart';
import 'app_snack.dart';

class RatingDialog extends StatefulWidget {
  final String orderId;
  final String driverName;

  /// Injection de test uniquement ; en production : `FirestoreService.rateOrder`.
  final Future<void> Function(String orderId, int rating)? submit;

  const RatingDialog({
    super.key,
    required this.orderId,
    required this.driverName,
    this.submit,
  });

  @override
  State<RatingDialog> createState() => _RatingDialogState();
}

class _RatingDialogState extends State<RatingDialog> {
  int _selected = 0;
  bool _sending = false;
  String? _error;

  static const _labels = [
    "",
    "Très mauvais",
    "Mauvais",
    "Correct",
    "Bien",
    "Excellent !"
  ];

  static String _messageFor(Object error) {
    if (error is FirebaseException && error.code == 'permission-denied') {
      return "Cette commande ne peut pas être notée (livraison non terminée "
          "ou déjà notée).";
    }
    return "Impossible d'enregistrer votre note. Vérifiez votre connexion "
        "et réessayez.";
  }

  Future<void> _submit() async {
    if (_selected == 0 || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final send = widget.submit ?? FirestoreService().rateOrder;
      await send(widget.orderId, _selected);
    } catch (e) {
      // Sans ce garde, une écriture refusée laissait le bouton en chargement
      // indéfiniment, sans aucun message.
      if (mounted) {
        setState(() {
          _sending = false;
          _error = _messageFor(e);
        });
      }
      return;
    }
    if (!mounted) return;
    AppSnack.show(context, 'Merci pour votre note !',
        type: AppSnackType.success);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 52),
            const SizedBox(height: 12),
            const Text(
              "Livraison effectuée !",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              "Comment était ${widget.driverName} ?",
              style: const TextStyle(color: Colors.grey, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),

            // Étoiles
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (i) {
                final star = i + 1;
                return GestureDetector(
                  onTap: () => setState(() => _selected = star),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      star <= _selected ? Icons.star : Icons.star_border,
                      color: Colors.amber,
                      size: 40,
                    ),
                  ),
                );
              }),
            ),

            if (_selected > 0) ...[
              const SizedBox(height: 8),
              Text(
                _labels[_selected],
                style: const TextStyle(
                    color: Colors.amber, fontWeight: FontWeight.bold),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.errorText(Theme.of(context).brightness),
                    fontSize: 13,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text("Plus tard"),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ScaleButton(
                    onPressed: (_selected == 0 || _sending) ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: _sending
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2),
                          )
                        : const Text("Envoyer"),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
