import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import '../../widgets/az_tab_bar.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/status_badge.dart';
import '../../widgets/stream_error_state.dart';
import 'driver_rides_logic.dart';
import 'driver_rides_service.dart';

/// « Mes courses » : historique du livreur connecté, par onglet. Les
/// requêtes sont toutes bornées à `driverId` (voir [DriverRidesService]).
class DriverRidesPage extends StatefulWidget {
  const DriverRidesPage({super.key, required this.driverId, this.service});

  final String driverId;

  /// Injectable pour les tests ; par défaut, le service Firestore.
  final DriverRidesService? service;

  @override
  State<DriverRidesPage> createState() => _DriverRidesPageState();
}

const _tabs = <DriverRideTab, String>{
  DriverRideTab.inProgress: 'En cours',
  DriverRideTab.delivered: 'Terminées',
  DriverRideTab.refused: 'Refusées',
  DriverRideTab.cancelled: 'Annulées',
  DriverRideTab.all: 'Toutes',
};

class _DriverRidesPageState extends State<DriverRidesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _controller =
      TabController(length: _tabs.length, vsync: this);
  late final DriverRidesService _service =
      widget.service ?? DriverRidesService(driverId: widget.driverId);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Mes courses'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
        bottom: AzTabBar(
          labels: _tabs.values.toList(),
          controller: _controller,
          backgroundColor: AppColors.primary,
        ),
      ),
      body: TabBarView(
        controller: _controller,
        children: [
          for (final tab in _tabs.keys)
            _RidesTab(key: PageStorageKey(tab), tab: tab, service: _service),
        ],
      ),
    );
  }
}

class _RidesTab extends StatefulWidget {
  const _RidesTab({super.key, required this.tab, required this.service});

  final DriverRideTab tab;
  final DriverRidesService service;

  @override
  State<_RidesTab> createState() => _RidesTabState();
}

class _RidesTabState extends State<_RidesTab>
    with AutomaticKeepAliveClientMixin {
  DriverRidesController? _controller;
  Stream<List<DriverRide>>? _live;
  final ScrollController _scroll = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    switch (widget.tab) {
      case DriverRideTab.refused:
        break; // pas de requête : voir _refusedPlaceholder
      case DriverRideTab.inProgress:
        _live = widget.service.watchInProgress();
        break;
      default:
        _controller = DriverRidesController(
          (cursor, limit) => widget.service.fetchPage(widget.tab, cursor, limit),
        )..loadMore();
        _scroll.addListener(_onScroll);
    }
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 400) _controller?.loadMore();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.tab == DriverRideTab.refused) return _refusedPlaceholder();
    if (_live != null) return _liveList();
    return _pagedList();
  }

  Widget _refusedPlaceholder() => const EmptyState(
        icon: Icons.do_not_disturb_alt_rounded,
        title: 'Historique des refus bientôt disponible',
        description:
            'Le suivi serveur des refus n\'est pas encore activé. Il sera '
            'disponible après son activation ; les refus faits avant ne '
            'pourront pas être retrouvés.',
      );

  Widget _liveList() {
    return StreamBuilder<List<DriverRide>>(
      stream: _live,
      builder: (context, snap) {
        if (snap.hasError) {
          return const StreamErrorState(
              message: 'Impossible de charger vos courses en cours.');
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rides = snap.data!;
        if (rides.isEmpty) return _empty();
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(15, 12, 15, 24),
          itemCount: rides.length,
          itemBuilder: (_, i) => _RideCard(ride: rides[i]),
        );
      },
    );
  }

  Widget _pagedList() {
    final c = _controller!;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (c.loading) return const Center(child: CircularProgressIndicator());
        if (c.error != null && c.rides.isEmpty) {
          return StreamErrorState(
            message: 'Impossible de charger vos courses.',
            onRetry: c.refresh,
          );
        }
        return RefreshIndicator(
          onRefresh: c.refresh,
          child: c.isEmpty
              // Liste défilante même vide : le geste d'actualisation reste possible.
              ? ListView(children: [SizedBox(height: 420, child: _empty())])
              : ListView.builder(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(15, 12, 15, 24),
                  itemCount: c.rides.length + 1,
                  itemBuilder: (_, i) {
                    if (i < c.rides.length) {
                      final r = c.rides[i];
                      return _RideCard(ride: r, gain: c.earnings[r.id]);
                    }
                    return _footer(c);
                  },
                ),
        );
      },
    );
  }

  Widget _footer(DriverRidesController c) {
    if (c.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (c.error != null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: StreamErrorState(
          message: 'Impossible de charger la suite.',
          onRetry: c.loadMore,
        ),
      );
    }
    if (!c.hasMore) return const SizedBox(height: 8);
    return const SizedBox(height: 40);
  }

  Widget _empty() {
    switch (widget.tab) {
      case DriverRideTab.inProgress:
        return const EmptyState(
          icon: Icons.two_wheeler_rounded,
          title: 'Aucune course en cours',
          description: 'Vos courses acceptées apparaîtront ici.',
        );
      case DriverRideTab.delivered:
        return const EmptyState(
          icon: Icons.task_alt_rounded,
          title: 'Aucune course terminée',
          description: 'Vos livraisons terminées apparaîtront ici.',
        );
      case DriverRideTab.cancelled:
        return const EmptyState(
          icon: Icons.event_busy_rounded,
          title: 'Aucune course annulée',
        );
      default:
        return const EmptyState(
          icon: Icons.receipt_long_rounded,
          title: 'Aucune course pour le moment',
          description: 'Votre historique apparaîtra ici dès votre première course.',
        );
    }
  }
}

class _RideCard extends StatelessWidget {
  const _RideCard({required this.ride, this.gain});

  final DriverRide ride;
  final int? gain;

  @override
  Widget build(BuildContext context) {
    final pickup = ride.pickupAddress ?? 'Adresse non renseignée';
    final dest = ride.deliveryAddress ?? 'Adresse non renseignée';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(14),
        semanticLabel: 'Course ${ride.shortId}',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DriverRideDetailPage(ride: ride, gain: gain),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    formatRideDateTime(ride.createdAt),
                    style: AppTypography.bodySmallStyle(context,
                        color: AppColors.textLight),
                  ),
                ),
                StatusBadge(
                  AppStatus.fromRaw(ride.status),
                  overrideLabel: ride.statusLabelOverride,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('N° ${ride.shortId}',
                style: AppTypography.titleSmallStyle(context)),
            const SizedBox(height: 8),
            _AddressLine(
                icon: Icons.trip_origin_rounded,
                color: AppColors.success,
                text: pickup),
            const SizedBox(height: 4),
            _AddressLine(
                icon: Icons.place_rounded,
                color: AppColors.error,
                text: dest),
            const Divider(height: 20, color: AppColors.divider),
            Row(
              children: [
                Expanded(
                  child: Text('Course : ${formatFcfa(ride.budget)}',
                      style: AppTypography.bodyMediumStyle(context)),
                ),
                Text(
                  gain == null ? 'Gain : —' : 'Gain : ${formatFcfa(gain!)}',
                  style: AppTypography.bodyMediumStyle(context,
                      color: gain == null
                          ? AppColors.textLight
                          : AppColors.success),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AddressLine extends StatelessWidget {
  const _AddressLine(
      {required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.bodyMediumStyle(context)),
          ),
        ],
      );
}

/// Détail d'une course. Aucune requête : tout vient de la liste (même document).
class DriverRideDetailPage extends StatelessWidget {
  const DriverRideDetailPage({super.key, required this.ride, this.gain});

  final DriverRide ride;
  final int? gain;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text('Course ${ride.shortId}'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(15, 16, 15, 32),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: StatusBadge(
              AppStatus.fromRaw(ride.status),
              overrideLabel: ride.statusLabelOverride,
            ),
          ),
          if (_statusNote() != null) ...[
            const SizedBox(height: 10),
            Text(_statusNote()!,
                style: AppTypography.bodyMediumStyle(context,
                    color: AppColors.textLight)),
          ],
          const SizedBox(height: 14),
          AppCard(
            child: Column(
              children: [
                _row(context, 'Numéro de commande', ride.id, selectable: true),
                _row(context, 'Créée le', formatRideDateTime(ride.createdAt)),
                if (ride.deliveredAt != null)
                  _row(context, 'Livrée le',
                      formatRideDateTime(ride.deliveredAt)),
                if (ride.cancelledAt != null)
                  _row(context, 'Annulée le',
                      formatRideDateTime(ride.cancelledAt)),
                _row(context, 'Récupération',
                    ride.pickupAddress ?? 'Adresse non renseignée'),
                _row(context, 'Destination',
                    ride.deliveryAddress ?? 'Adresse non renseignée'),
                if (ride.description.isNotEmpty)
                  _row(context, 'Description', ride.description),
                _row(context, 'Paiement', paymentLabel(ride.paymentMethod)),
                _row(context, 'Montant de la course', formatFcfa(ride.budget)),
                _row(
                  context,
                  'Gain crédité (commission AZ déjà déduite à l\'acceptation)',
                  gain == null ? '—' : formatFcfa(gain!),
                  last: true,
                ),
              ],
            ),
          ),
          if (gain == null && ride.kind == DriverRideKind.delivered) ...[
            const SizedBox(height: 10),
            Text(
              'Le gain n\'est affiché que lorsque le crédit de votre '
              'portefeuille correspond exactement à la course. Il reste « — » '
              'pour un paiement en espèces, une course avec achats ou une '
              'course transférée : consultez alors « Portefeuille ».',
              style: AppTypography.bodySmallStyle(context,
                  color: AppColors.textLight),
            ),
          ],
        ],
      ),
    );
  }

  String? _statusNote() {
    switch (ride.kind) {
      case DriverRideKind.expired:
        return 'Aucun livreur n\'a accepté cette course à temps : elle a '
            'expiré automatiquement. Ce n\'est pas un refus.';
      case DriverRideKind.proposed:
        return 'Course proposée, pas encore acceptée.';
      default:
        return null;
    }
  }

  Widget _row(BuildContext context, String label, String value,
      {bool selectable = false, bool last = false}) {
    final valueText = selectable
        ? SelectableText(value, style: AppTypography.bodyMediumStyle(context))
        : Text(value, style: AppTypography.bodyMediumStyle(context));
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: AppTypography.bodySmallStyle(context,
                  color: AppColors.textLight)),
          const SizedBox(height: 2),
          valueText,
        ],
      ),
    );
  }
}
