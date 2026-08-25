import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/real_estate_display_location.dart';
import '../../models/real_estate_property_type.dart';
import '../../services/map_navigation_service.dart';
import '../../services/real_estate_share_builder.dart';
import '../../theme/app_theme.dart';
import '../app_button.dart';
import 'real_estate_map_preview.dart';

/// Section « Localisation » de la fiche annonce (Mission 4/5 du chantier
/// "Activation UI carte/itinéraire") — widget de PRÉSENTATION uniquement :
/// il ne charge jamais lui-même de donnée privée, ne décide jamais des
/// droits d'accès, se contente d'afficher ce que [location] autorise déjà
/// (résolu en amont via `RealEstateDisplayLocation.resolve`).
///
/// Les callbacks d'action (`navigate`/`openMaps`/`share`) ont des
/// implémentations par défaut appelant les vrais services — surchargeables
/// en test pour éviter toute dépendance à `launchUrl`/`Share.share`/un vrai
/// widget `GoogleMap` natif (Mission 15).
class RealEstateLocationCard extends StatelessWidget {
  final String listingTitle;
  final String propertyType;
  final RealEstateDisplayLocation location;

  // ── Position du client (Mission 6/7) — jamais demandée automatiquement.
  final double? clientLatitude;
  final double? clientLongitude;
  final ClientGpsState? clientGpsState;
  final bool isLocatingClient;
  final VoidCallback? onRequestClientPosition;

  /// Ouvre les réglages de localisation Android/iOS (bouton "Activer la
  /// localisation" — Mission 6/8/14). Par défaut, appelle réellement
  /// `MapNavigationService.openLocationSettings()` — jamais confondu avec
  /// [onRequestClientPosition] (qui ne fait que retenter le calcul, sans
  /// jamais ouvrir de réglage système).
  final VoidCallback? onOpenLocationSettings;

  /// Ouvre les réglages de l'application (bouton "Ouvrir les paramètres",
  /// cas permission refusée/refusée définitivement — Mission 6/8/14).
  final VoidCallback? onOpenAppSettings;

  // ── Visite (Mission 10).
  final bool hasPendingVisitRequest;
  final String? visitRequestStatusLabel;
  final VoidCallback? onRequestVisit;

  // ── Actions (Mission 9), injectables pour les tests.
  final Future<bool> Function(BuildContext context,
      {required double latitude, required double longitude})? navigate;
  final Future<bool> Function(
      {required double latitude, required double longitude})? openMaps;
  final Future<void> Function(String text)? share;

  /// Injecté par les tests widgets pour remplacer le vrai `GoogleMap` natif
  /// (Mission 15 : "extraire le contenu logique, injecter un mapBuilder").
  final Widget Function(double lat, double lng, bool isApproximate)? mapBuilder;

  const RealEstateLocationCard({
    super.key,
    required this.listingTitle,
    required this.propertyType,
    required this.location,
    this.clientLatitude,
    this.clientLongitude,
    this.clientGpsState,
    this.isLocatingClient = false,
    this.onRequestClientPosition,
    this.onOpenLocationSettings,
    this.onOpenAppSettings,
    this.hasPendingVisitRequest = false,
    this.visitRequestStatusLabel,
    this.onRequestVisit,
    this.navigate,
    this.openMaps,
    this.share,
    this.mapBuilder,
  });

  // Master Prompt "Immobilier V6.1" — bug réel trouvé sur appareil (Mission
  // 2) : le formulaire V6 enregistre désormais le type canonique 'land'
  // (RealEstatePropertyType.land), qui ne contient jamais la sous-chaîne
  // "terrain" — l'ancien test par substring masquait donc silencieusement
  // le disclaimer foncier pour toute nouvelle annonce Terrain créée depuis
  // cette passe. Corrigé en réutilisant RealEstatePropertyType.isLand(),
  // qui reconnaît à la fois le canonique et l'ancien libellé français.
  bool get _isTerrain => RealEstatePropertyType.isLand(propertyType);

  String? _distanceLabel() {
    if (!location.hasCoordinates ||
        clientLatitude == null ||
        clientLongitude == null) {
      return null;
    }
    final meters = MapNavigationService.distanceMeters(
      fromLat: clientLatitude!,
      fromLng: clientLongitude!,
      toLat: location.latitude!,
      toLng: location.longitude!,
    );
    return MapNavigationService.distanceLabel(
        meters: meters, isApproximate: location.isApproximate);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: AppRadius.cardR,
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.place_outlined,
                  color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Text('Localisation',
                  style: AppTypography.titleLargeStyle(context)),
            ],
          ),
          const SizedBox(height: 4),
          _placeLine(context),
          const SizedBox(height: 12),
          ..._buildBody(context),
          if (_isTerrain) ...[
            const SizedBox(height: 12),
            _terrainDisclaimer(context),
          ],
        ],
      ),
    );
  }

  Widget _placeLine(BuildContext context) {
    final parts = [location.quartier, location.city]
        .where((s) => s != null && s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(parts.join(', '),
        style:
            AppTypography.bodyMediumStyle(context, color: AppColors.textLight));
  }

  List<Widget> _buildBody(BuildContext context) {
    switch (location.source) {
      case RealEstateLocationSource.publicExact:
        return _exactBody(context, accessGranted: false);
      case RealEstateLocationSource.privateAuthorized:
        return _exactBody(context, accessGranted: true);
      case RealEstateLocationSource.publicApproximate:
        return _approximateBody(context);
      case RealEstateLocationSource.unavailable:
        return location.isHidden ? _hiddenBody(context) : _absentBody(context);
    }
  }

  // ── EXACT PUBLIC / (APPROXIMATE|HIDDEN) AVEC ACCÈS PRIVÉ ─────────────────
  List<Widget> _exactBody(BuildContext context, {required bool accessGranted}) {
    final lat = location.latitude!;
    final lng = location.longitude!;
    final distance = _distanceLabel();
    return [
      if (accessGranted) _accessGrantedBanner(context),
      if (accessGranted) const SizedBox(height: 8),
      if (location.address != null && location.address!.isNotEmpty) ...[
        Text(location.address!,
            style: AppTypography.bodyMediumStyle(context,
                color: AppColors.textMuted)),
        const SizedBox(height: 8),
      ],
      _mapWidget(lat, lng, isApproximate: false),
      const SizedBox(height: 8),
      distance != null
          ? _distanceRow(context, distance)
          : _requestPositionButton(context),
      const SizedBox(height: 12),
      _actionsRow(context, lat, lng),
    ];
  }

  // ── APPROXIMATE SANS ACCÈS ────────────────────────────────────────────────
  List<Widget> _approximateBody(BuildContext context) {
    final lat = location.latitude!;
    final lng = location.longitude!;
    final distance = _distanceLabel();
    return [
      _badge(context, 'Position approximative', AppColors.warning,
          AppColors.warningBg),
      const SizedBox(height: 8),
      Text('Le repère indique la zone générale du bien.',
          style: AppTypography.bodyMediumStyle(context,
              color: AppColors.textLight)),
      const SizedBox(height: 8),
      _mapWidget(lat, lng, isApproximate: true),
      const SizedBox(height: 8),
      distance != null
          ? _distanceRow(context, distance)
          : _requestPositionButton(context),
      const SizedBox(height: 12),
      _actionsRow(context, lat, lng),
      if (onRequestVisit != null) ...[
        const SizedBox(height: 8),
        _visitButton(context),
      ],
    ];
  }

  // ── HIDDEN SANS ACCÈS ────────────────────────────────────────────────────
  List<Widget> _hiddenBody(BuildContext context) {
    return [
      Text(
        'Localisation exacte disponible après confirmation de visite.',
        style:
            AppTypography.bodyMediumStyle(context, color: AppColors.textMuted),
      ),
      const SizedBox(height: 12),
      // Mission 9 : le partage reste possible même sans localisation
      // dévoilée — titre + ville/quartier autorisés uniquement, jamais
      // d'itinéraire/Maps (pas de coordonnée à donner).
      OutlinedButton.icon(
        onPressed: () => _onShare(context),
        icon: const Icon(Icons.share_outlined, size: 18),
        label: const Text('Partager'),
      ),
      if (onRequestVisit != null) ...[
        const SizedBox(height: 12),
        _visitButton(context),
      ],
    ];
  }

  // ── LOCALISATION ABSENTE ─────────────────────────────────────────────────
  List<Widget> _absentBody(BuildContext context) {
    return [
      Text('Localisation non renseignée',
          style: AppTypography.bodyMediumStyle(context,
              color: AppColors.textLight)),
    ];
  }

  Widget _accessGrantedBanner(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: const BoxDecoration(
          color: AppColors.greenBg,
          borderRadius: AppRadius.smR,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.verified_outlined,
                size: 16, color: AppColors.success),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                  'Accès exact accordé après confirmation de votre visite',
                  style: AppTypography.bodySmallStyle(context,
                      color: AppColors.success)),
            ),
          ],
        ),
      );

  Widget _badge(BuildContext context, String text, Color color, Color bg) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: AppRadius.smR),
        child: Text(text,
            style: AppTypography.bodySmallStyle(context,
                color: color, weight: FontWeight.w600)),
      );

  Widget _distanceRow(BuildContext context, String label) => Row(
        children: [
          const Icon(Icons.social_distance_outlined,
              size: 16, color: AppColors.textLight),
          const SizedBox(width: 6),
          Expanded(
              child: Text(label,
                  style: AppTypography.bodySmallStyle(context,
                      color: AppColors.textLight))),
        ],
      );

  Widget _requestPositionButton(BuildContext context) {
    if (isLocatingClient) {
      return const Row(children: [
        SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 8),
        Text('Localisation en cours…'),
      ]);
    }
    final state = clientGpsState;
    if (state == ClientGpsState.serviceOff) {
      // Bug confirmé sur appareil réel (Mission 8/14) : ce bouton était
      // câblé sur `onRequestClientPosition` (retente juste le calcul, ne
      // rouvre jamais aucun réglage) — corrigé pour ouvrir réellement les
      // réglages de localisation Android.
      return _gpsMessage(
          context,
          'Le GPS est désactivé.',
          'Activer la localisation',
          onOpenLocationSettings ?? MapNavigationService.openLocationSettings);
    }
    if (state == ClientGpsState.deniedForever ||
        state == ClientGpsState.denied) {
      return _gpsMessage(
          context,
          'Autorisation de localisation refusée.',
          'Ouvrir les paramètres',
          onOpenAppSettings ?? MapNavigationService.openAppSettings);
    }
    if (state == ClientGpsState.timeout || state == ClientGpsState.error) {
      return _gpsMessage(context, 'Position indisponible pour le moment.',
          'Réessayer', onRequestClientPosition);
    }
    if (onRequestClientPosition == null) return const SizedBox.shrink();
    return TextButton.icon(
      onPressed: onRequestClientPosition,
      icon: const Icon(Icons.my_location_outlined, size: 18),
      label: const Text('Calculer la distance'),
    );
  }

  Widget _gpsMessage(BuildContext context, String message, String actionLabel,
          VoidCallback? onTap) =>
      Row(
        children: [
          Expanded(
              child: Text(message,
                  style: AppTypography.bodySmallStyle(context,
                      color: AppColors.textLight))),
          if (onTap != null)
            TextButton(onPressed: onTap, child: Text(actionLabel)),
        ],
      );

  Widget _mapWidget(double lat, double lng, {required bool isApproximate}) {
    if (mapBuilder != null) return mapBuilder!(lat, lng, isApproximate);
    return RealEstateMapPreview(
        latitude: lat, longitude: lng, isApproximate: isApproximate);
  }

  Widget _actionsRow(BuildContext context, double lat, double lng) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: () => (navigate ?? MapNavigationService.navigate)(context,
              latitude: lat, longitude: lng),
          icon: const Icon(Icons.directions_outlined, size: 18),
          label: const Text('Itinéraire'),
        ),
        OutlinedButton.icon(
          onPressed: () => (openMaps ?? MapNavigationService.openInMaps)(
              latitude: lat, longitude: lng),
          icon: const Icon(Icons.map_outlined, size: 18),
          label: const Text('Ouvrir dans Maps'),
        ),
        OutlinedButton.icon(
          onPressed: () => _onShare(context),
          icon: const Icon(Icons.share_outlined, size: 18),
          label: const Text('Partager'),
        ),
      ],
    );
  }

  Future<void> _onShare(BuildContext context) async {
    final text = RealEstateShareBuilder.buildShareText(
        title: listingTitle, location: location);
    if (share != null) {
      await share!(text);
    } else {
      await Share.share(text);
    }
  }

  Widget _visitButton(BuildContext context) {
    if (hasPendingVisitRequest) {
      return _badge(
          context,
          'Demande de visite : ${visitRequestStatusLabel ?? "en cours"}',
          AppColors.info,
          AppColors.blueBg);
    }
    return SizedBox(
      width: double.infinity,
      child: AppButton(
        label: 'Demander une visite',
        icon: Icons.calendar_month_outlined,
        onPressed: onRequestVisit,
      ),
    );
  }

  Widget _terrainDisclaimer(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: const BoxDecoration(
          color: AppColors.warningBg,
          borderRadius: AppRadius.smR,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: 16, color: AppColors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'La position GPS est indicative et ne remplace pas les documents fonciers ou cadastraux.',
                style: AppTypography.bodySmallStyle(context,
                    color: AppColors.textMuted),
              ),
            ),
          ],
        ),
      );
}
