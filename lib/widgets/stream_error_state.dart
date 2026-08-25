import 'package:flutter/material.dart';
import 'app_button.dart';

/// État d'erreur générique pour un `StreamBuilder`/`FutureBuilder` Firestore
/// (Master Prompt 121) — à utiliser dans la branche `snapshot.hasError`,
/// pour éviter qu'un flux en échec laisse un spinner tourner indéfiniment
/// plutôt que de dégrader proprement. Un seul widget partagé plutôt que de
/// dupliquer ce petit bloc dans chaque écran.
///
/// Master Prompt 126 (Partie 11) — `onRetry` est optionnel et purement
/// additif : les call-sites existants (Prompt 121) ne passent pas ce
/// paramètre et continuent d'afficher exactement le même widget qu'avant.
class StreamErrorState extends StatelessWidget {
  final String message;
  final IconData icon;
  final VoidCallback? onRetry;
  final String retryLabel;

  const StreamErrorState({
    super.key,
    this.message =
        'Impossible de charger les données. Vérifiez votre connexion.',
    this.icon = Icons.wifi_off_rounded,
    this.onRetry,
    this.retryLabel = 'Réessayer',
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: Colors.grey),
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey)),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              AppButton(
                label: retryLabel,
                icon: Icons.refresh_rounded,
                variant: AppButtonVariant.outlined,
                fullWidth: false,
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
