import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import 'glass_kit.dart';

/// Master Prompt 126 (Partie 9) — vocabulaire d'affichage unique pour un
/// statut de commande. Ceci est une couche de PRÉSENTATION uniquement :
/// elle ne touche jamais aux valeurs réellement stockées dans Firestore
/// (`orders.status`, state machine déjà documentée dans CLAUDE.md,
/// "pending → broadcast/assigned → accepted → picked_up → delivered, ou
/// cancelled") — `AppStatus.fromRaw()` traduit ces valeurs réelles vers cet
/// enum d'affichage, jamais l'inverse.
enum AppOrderStatus {
  pending,
  accepted,
  preparing,
  onTheWay,
  delivered,
  cancelled,
  failed,
  completed,
}

class StatusMeta {
  final Color color;
  final IconData icon;
  final String label;
  final bool pulsing;
  const StatusMeta({
    required this.color,
    required this.icon,
    required this.label,
    this.pulsing = false,
  });
}

class AppStatus {
  AppStatus._();

  static const Map<AppOrderStatus, StatusMeta> _meta = {
    AppOrderStatus.pending: StatusMeta(
      color: AppColors.warning,
      icon: Icons.schedule_rounded,
      label: 'En attente',
      pulsing: true,
    ),
    AppOrderStatus.accepted: StatusMeta(
      color: AppColors.info,
      icon: Icons.check_circle_outline_rounded,
      label: 'Acceptée',
      pulsing: true,
    ),
    AppOrderStatus.preparing: StatusMeta(
      color: AppColors.blue,
      icon: Icons.soup_kitchen_rounded,
      label: 'En préparation',
      pulsing: true,
    ),
    AppOrderStatus.onTheWay: StatusMeta(
      color: AppColors.primary,
      icon: Icons.local_shipping_rounded,
      label: 'En livraison',
      pulsing: true,
    ),
    AppOrderStatus.delivered: StatusMeta(
      color: AppColors.success,
      icon: Icons.task_alt_rounded,
      label: 'Livrée',
    ),
    AppOrderStatus.completed: StatusMeta(
      color: AppColors.success,
      icon: Icons.verified_rounded,
      label: 'Terminée',
    ),
    AppOrderStatus.cancelled: StatusMeta(
      color: AppColors.error,
      icon: Icons.cancel_outlined,
      label: 'Annulée',
    ),
    AppOrderStatus.failed: StatusMeta(
      color: AppColors.error,
      icon: Icons.error_outline_rounded,
      label: 'Échouée',
    ),
  };

  static StatusMeta metaFor(AppOrderStatus s) => _meta[s]!;

  /// Traduit une valeur brute `orders.status` (ou un vocabulaire proche déjà
  /// utilisé par certains écrans partenaires, ex. `preparing`/`ready`) vers
  /// l'enum d'affichage. Ne devine jamais au-delà de ce qui est déjà
  /// documenté dans CLAUDE.md — toute valeur non reconnue retombe sur
  /// [AppOrderStatus.pending] avec le libellé brut conservé via
  /// [StatusBadge.fromRaw] plutôt qu'un libellé français inventé.
  static AppOrderStatus fromRaw(String raw) {
    switch (raw) {
      case 'pending':
      case 'broadcast':
        return AppOrderStatus.pending;
      case 'assigned':
      case 'accepted':
        return AppOrderStatus.accepted;
      case 'preparing':
        return AppOrderStatus.preparing;
      case 'picked_up':
      case 'delivering':
      case 'ready':
        return AppOrderStatus.onTheWay;
      case 'delivered':
        return AppOrderStatus.delivered;
      case 'completed':
        return AppOrderStatus.completed;
      case 'cancelled':
        return AppOrderStatus.cancelled;
      case 'failed':
      case 'error':
        return AppOrderStatus.failed;
      default:
        return AppOrderStatus.pending;
    }
  }
}

/// Badge de statut — construit sur `StatusPill` déjà existant
/// (`glass_kit.dart`) plutôt qu'une nouvelle pastille dupliquée. Ajoute
/// uniquement l'icône + l'animation de pulsation pour les statuts "actifs".
class StatusBadge extends StatelessWidget {
  final AppOrderStatus status;
  final String? overrideLabel;

  const StatusBadge(this.status, {super.key, this.overrideLabel});

  /// Construit directement depuis une valeur brute Firestore — si elle
  /// n'est reconnue par aucun vocabulaire connu, le libellé brut est
  /// affiché tel quel (jamais un libellé français deviné au hasard).
  factory StatusBadge.fromRaw(String raw) {
    final known = {
      'pending',
      'broadcast',
      'assigned',
      'accepted',
      'preparing',
      'picked_up',
      'delivering',
      'ready',
      'delivered',
      'completed',
      'cancelled',
      'failed',
      'error',
    };
    return StatusBadge(
      AppStatus.fromRaw(raw),
      overrideLabel: known.contains(raw) ? null : raw,
    );
  }

  @override
  Widget build(BuildContext context) {
    final meta = AppStatus.metaFor(status);
    final pill = StatusPill(
      label: overrideLabel ?? meta.label,
      color: meta.color,
      icon: meta.icon,
    );
    if (!meta.pulsing) return pill;
    return pill
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .fade(begin: 1.0, end: 0.55, duration: 900.ms, curve: Curves.easeInOut);
  }
}
