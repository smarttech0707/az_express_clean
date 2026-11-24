import 'package:flutter/material.dart';

class AdminEmailVerificationPrompt extends StatelessWidget {
  const AdminEmailVerificationPrompt({
    super.key,
    required this.visible,
    required this.onResend,
    this.remaining = Duration.zero,
    this.sending = false,
  });

  final bool visible;
  final VoidCallback onResend;
  final Duration remaining;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();

    final seconds = (remaining.inMilliseconds / 1000).ceil();
    final blocked = sending || seconds > 0;
    return Column(
      children: [
        const SizedBox(height: 12),
        const Text(
          'Vérifiez votre adresse email avant d’utiliser la 2FA Admin.',
          textAlign: TextAlign.center,
        ),
        TextButton.icon(
          onPressed: blocked ? null : onResend,
          icon: sending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.mark_email_read_outlined),
          label: Text(
            seconds > 0
                ? 'Renvoyer dans ${seconds}s'
                : 'Renvoyer l’email de vérification',
          ),
        ),
      ],
    );
  }
}
