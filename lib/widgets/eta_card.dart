import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/route_model.dart';
import '../screens/chat/chat_page.dart';
import '../services/realtime_tracking_service.dart';
import '../theme/app_theme.dart';

/// Carte ETA style Yango — affichée en bas de l'écran de suivi client.
/// Affiche le statut commande, les infos livreur, boutons Appeler/Chat, stats ETA.
class EtaCard extends StatelessWidget {
  final RealtimeTrackingService tracking;
  final String? driverName;
  final String? driverPhotoUrl;
  final String? driverPhone;
  final double? driverRating;
  final String  orderStatus;
  final String  orderId;
  final VoidCallback? onFollowToggle;
  final VoidCallback? onRecenter;

  const EtaCard({
    super.key,
    required this.tracking,
    required this.orderStatus,
    required this.orderId,
    this.driverName,
    this.driverPhotoUrl,
    this.driverPhone,
    this.driverRating,
    this.onFollowToggle,
    this.onRecenter,
  });

  // ── Couleur de statut ────────────────────────────────────────────────────────

  Color get _statusColor {
    if (!tracking.hasDriver) return AppColors.textMuted;
    switch (orderStatus) {
      case 'picked_up': return const Color(0xFF1565C0);
      case 'delivered': return AppColors.success;
      default:          return AppColors.primary;
    }
  }

  void _callDriver() {
    if (driverPhone == null) return;
    final uri = Uri.parse('tel:$driverPhone');
    canLaunchUrl(uri).then((can) { if (can) launchUrl(uri); });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasDriver = tracking.hasDriver;
    final r2c       = tracking.routeToClient;
    final r2d       = tracking.routeToDest;
    final hasDest   = tracking.hasDest;
    final loading   = tracking.routeLoading;
    final color     = _statusColor;

    return Container(
      decoration: const BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(color: Color(0x1A000000), blurRadius: 32, offset: Offset(0, -8)),
          BoxShadow(color: Color(0x08000000), blurRadius: 8,  offset: Offset(0, -2)),
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [

        // Drag handle
        Center(child: Container(
          width: 36, height: 4,
          margin: const EdgeInsets.only(top: 10, bottom: 14),
          decoration: BoxDecoration(
            color: AppColors.divider, borderRadius: BorderRadius.circular(4)),
        )),

        // ── Barre de progression livraison ────────────────────────────────────
        if (hasDriver)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: _DeliveryProgressBar(
              orderStatus: orderStatus,
              loading:     loading,
            ),
          ),

        // ── Chip statut (si pas encore de livreur) ─────────────────────────────
        if (!hasDriver)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Container(
                key: ValueKey(orderStatus),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: orderStatus == 'broadcast'
                      ? const Color(0xFFF0FDF4)
                      : color.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: orderStatus == 'broadcast'
                        ? AppColors.success.withValues(alpha: 0.35)
                        : color.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(
                    orderStatus == 'broadcast'
                        ? Icons.notifications_active_rounded
                        : Icons.search_rounded,
                    color: orderStatus == 'broadcast'
                        ? AppColors.success
                        : AppColors.textMuted,
                    size: 15,
                  ),
                  const SizedBox(width: 7),
                  Flexible(child: Text(
                    orderStatus == 'broadcast'
                        ? 'Livreurs contactés — en attente d\'acceptation'
                        : 'Recherche d\'un livreur…',
                    style: GoogleFonts.urbanist(
                      fontSize: 12.5, fontWeight: FontWeight.w600,
                      color: orderStatus == 'broadcast'
                          ? AppColors.success
                          : AppColors.textMuted),
                  )),
                ]),
              ),
            ),
          ),

        // ── Infos livreur ──────────────────────────────────────────────────────
        if (hasDriver)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: Row(children: [
              // Photo
              Container(
                width: 50, height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.25), width: 2),
                ),
                child: ClipOval(child: (driverPhotoUrl?.isNotEmpty ?? false)
                    ? Image.network(driverPhotoUrl!, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _defaultAvatar())
                    : _defaultAvatar()),
              ),
              const SizedBox(width: 12),

              // Nom + rating
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  driverName ?? 'Votre livreur',
                  style: GoogleFonts.urbanist(
                    fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.text),
                ),
                const SizedBox(height: 3),
                if (driverRating != null)
                  _StarRating(rating: driverRating!)
                else
                  Row(children: [
                    Container(
                      width: 8, height: 8,
                      margin: const EdgeInsets.only(right: 5),
                      decoration: const BoxDecoration(
                          color: AppColors.success, shape: BoxShape.circle)),
                    Text('En ligne',
                      style: GoogleFonts.urbanist(
                          fontSize: 11, color: AppColors.textMuted)),
                  ]),
              ])),

              // Bouton recentrer
              Semantics(
                label: 'Recentrer la carte sur le livreur',
                button: true,
                excludeSemantics: true,
                child: GestureDetector(
                onTap: onRecenter,
                child: Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color:        AppColors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.my_location_rounded,
                      color: AppColors.primary, size: 19),
                ),
                ),
              ),
            ]),
          ),

        // ── Boutons Appeler / Chat ─────────────────────────────────────────────
        if (hasDriver)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: Row(children: [
              Expanded(child: _ActionButton(
                icon:    Icons.phone_rounded,
                label:   'Appeler',
                color:   AppColors.success,
                enabled: driverPhone != null,
                onTap:   () => _callDriver(),
              )),
              const SizedBox(width: 10),
              Expanded(child: _ActionButton(
                icon:  Icons.chat_bubble_rounded,
                label: 'Chat',
                color: const Color(0xFF1565C0),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ChatPage(
                    orderId:    orderId,
                    senderRole: 'client',
                  ),
                )),
              )),
            ]),
          ),

        // ── Stats ETA / Distance / Prix ────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            _StatChip(
              icon:  Icons.access_time_rounded,
              label: 'Arrivée',
              value: hasDriver
                  ? (hasDest
                      ? RouteModel.formatEta(tracking.totalEta)
                      : r2c.etaText)
                  : '--',
              color: AppColors.primary,
            ),
            const SizedBox(width: 10),
            _StatChip(
              icon:  Icons.straighten_rounded,
              label: 'Distance',
              value: hasDriver
                  ? (hasDest
                      ? RouteModel.formatDistance(tracking.totalDistKm)
                      : r2c.distanceText)
                  : '--',
              color: const Color(0xFF1565C0),
            ),
            const SizedBox(width: 10),
            _StatChip(
              icon:  Icons.payments_rounded,
              label: 'Tarif',
              value: hasDriver && r2c.estimatedPrice > 0
                  ? '${r2c.estimatedPrice} F'
                  : '--',
              color: const Color(0xFF16A34A),
            ),
          ]),
        ),

        const SizedBox(height: 12),

        // ── Légende itinéraires (avant picked_up uniquement) ──────────────────
        if (hasDest && orderStatus != 'picked_up') ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(children: [
              _LegendItem(
                color: AppColors.primary,
                label: 'Livreur → Récupération',
                sub:   r2c.distanceText,
              ),
              const SizedBox(width: 16),
              _LegendItem(
                color:  const Color(0xFF1565C0),
                label:  'Récupération → Livraison',
                sub:    r2d.distanceText,
                dashed: true,
              ),
            ]),
          ),
          const SizedBox(height: 12),
        ],

        // ── Boutons Suivre / Centrer ───────────────────────────────────────────
        Padding(
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, MediaQuery.of(context).padding.bottom + 14),
          child: Row(children: [
            Expanded(child: _ActionButton(
              icon:  tracking.followDriver
                  ? Icons.location_searching_rounded
                  : Icons.location_disabled_rounded,
              label: tracking.followDriver ? 'Suivre' : 'Libre',
              color: tracking.followDriver ? AppColors.primary : AppColors.textMuted,
              onTap: onFollowToggle,
            )),
            const SizedBox(width: 10),
            Expanded(child: _ActionButton(
              icon:  Icons.center_focus_strong_rounded,
              label: 'Centrer',
              color: const Color(0xFF1565C0),
              onTap: onRecenter,
            )),
          ]),
        ),
      ]),
    );
  }

  Widget _defaultAvatar() => Container(
    color: AppColors.primary,
    child: const Icon(Icons.delivery_dining_rounded,
        color: Colors.white, size: 22),
  );
}

// ── Stars rating ──────────────────────────────────────────────────────────────

class _StarRating extends StatelessWidget {
  final double rating;
  const _StarRating({required this.rating});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    ...List.generate(5, (i) => Icon(
      i < rating.floor()
          ? Icons.star_rounded
          : (i < rating.ceil() && rating % 1 >= 0.5)
              ? Icons.star_half_rounded
              : Icons.star_outline_rounded,
      color: const Color(0xFFF59E0B),
      size: 13,
    )),
    const SizedBox(width: 4),
    Text(
      rating.toStringAsFixed(1),
      style: GoogleFonts.urbanist(
          fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textMuted),
    ),
  ]);
}

// ── Chip statistique ──────────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String   label, value;
  final Color    color;
  const _StatChip({required this.icon, required this.label,
      required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(child: Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color:        color.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(14),
      border:       Border.all(color: color.withValues(alpha: 0.2)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, color: color, size: 12),
        const SizedBox(width: 4),
        Text(label, style: GoogleFonts.urbanist(
            fontSize: 10, color: AppColors.textMuted)),
      ]),
      const SizedBox(height: 4),
      Text(value, style: GoogleFonts.urbanist(
          fontSize: 15, fontWeight: FontWeight.w800, color: color)),
    ]),
  ));
}

// ── Légende itinéraire ────────────────────────────────────────────────────────

class _LegendItem extends StatelessWidget {
  final Color  color;
  final String label, sub;
  final bool   dashed;
  const _LegendItem({required this.color, required this.label,
      required this.sub, this.dashed = false});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(
      width: 22, height: 4,
      decoration: BoxDecoration(
        color:        dashed ? Colors.transparent : color,
        borderRadius: BorderRadius.circular(2),
        border:       dashed ? Border.all(color: color) : null,
      ),
    ),
    const SizedBox(width: 6),
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: GoogleFonts.urbanist(
          fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.text)),
      Text(sub, style: GoogleFonts.urbanist(
          fontSize: 10, color: AppColors.textMuted)),
    ]),
  ]);
}

// ── Barre de progression livraison ───────────────────────────────────────────

class _DeliveryProgressBar extends StatelessWidget {
  final String orderStatus;
  final bool   loading;
  const _DeliveryProgressBar({required this.orderStatus, required this.loading});

  // 0=En route, 1=Récupéré, 2=En livraison, 3=Livré
  int get _activeStep {
    switch (orderStatus) {
      case 'picked_up': return 2;
      case 'delivered': return 3;
      default:          return 0;
    }
  }

  static const _steps = [
    (Icons.two_wheeler_rounded,       'En route'),
    (Icons.inventory_2_rounded,       'Récupéré'),
    (Icons.local_shipping_rounded,    'En livraison'),
    (Icons.check_circle_rounded,      'Livré'),
  ];

  static const _labels = [
    '🛵 En route vers la récupération',
    '📦 Colis récupéré',
    '🚚 En route vers la livraison',
    '✅ Livraison terminée',
  ];

  @override
  Widget build(BuildContext context) {
    final step = _activeStep;

    return Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
      // Track
      Row(children: [
        for (int i = 0; i < _steps.length; i++) ...[
          _ProgressDot(
            icon:      _steps[i].$1,
            isPast:    i < step,
            isCurrent: i == step,
            isLoading: i == step && loading,
          ),
          if (i < _steps.length - 1)
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                height: 3,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: i < step ? AppColors.primary : AppColors.divider,
                ),
              ),
            ),
        ],
      ]),

      const SizedBox(height: 8),

      // Label étape courante
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: Text(
          _labels[step],
          key: ValueKey(step),
          style: GoogleFonts.urbanist(
            fontSize: 12, fontWeight: FontWeight.w600,
            color: step == 3 ? AppColors.success : AppColors.primary,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    ]);
  }
}

class _ProgressDot extends StatelessWidget {
  final IconData icon;
  final bool     isPast, isCurrent, isLoading;
  const _ProgressDot({
    required this.icon,
    required this.isPast,
    required this.isCurrent,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    final active = isPast || isCurrent;
    final size   = isCurrent ? 32.0 : 24.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: size, height: size,
      decoration: BoxDecoration(
        color: active ? AppColors.primary : const Color(0xFFE2E8F0),
        shape: BoxShape.circle,
        boxShadow: isCurrent ? [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.30),
            blurRadius: 10, spreadRadius: 1,
          ),
        ] : null,
      ),
      child: isLoading
          ? const Padding(
              padding: EdgeInsets.all(6),
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : Icon(icon,
              size:  isCurrent ? 16 : 12,
              color: active ? Colors.white : AppColors.textLight),
    );
  }
}

// ── Bouton action ─────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final IconData      icon;
  final String        label;
  final Color         color;
  final VoidCallback? onTap;
  final bool          enabled;
  const _ActionButton({required this.icon, required this.label,
      required this.color, this.onTap, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    final effectiveColor = enabled ? color : AppColors.textLight;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color:        effectiveColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border:       Border.all(color: effectiveColor.withValues(alpha: 0.25)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: effectiveColor, size: 17),
          const SizedBox(width: 6),
          Text(label, style: GoogleFonts.urbanist(
              fontSize: 13, fontWeight: FontWeight.w600, color: effectiveColor)),
        ]),
      ),
    );
  }
}
