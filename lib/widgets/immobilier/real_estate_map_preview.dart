import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../theme/app_theme.dart';

/// Aperçu carte pur — reçoit uniquement des coordonnées DÉJÀ autorisées
/// (jamais de logique de droits ici, voir `RealEstateLocationCard`).
///
/// [isApproximate] bascule un marqueur précis (précision exacte) vers un
/// cercle de zone (Mission 5 : "ne pas utiliser un marqueur précis qui
/// induit le client en erreur" pour une position approximative).
class RealEstateMapPreview extends StatefulWidget {
  final double latitude;
  final double longitude;
  final bool isApproximate;
  final double height;

  const RealEstateMapPreview({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.isApproximate,
    this.height = 180,
  });

  @override
  State<RealEstateMapPreview> createState() => _RealEstateMapPreviewState();
}

class _RealEstateMapPreviewState extends State<RealEstateMapPreview> {
  @override
  Widget build(BuildContext context) {
    final target = LatLng(widget.latitude, widget.longitude);
    return ClipRRect(
      borderRadius: AppRadius.cardR,
      child: SizedBox(
        height: widget.height,
        child: GoogleMap(
          initialCameraPosition: CameraPosition(
            target: target,
            zoom: widget.isApproximate ? 13.5 : 16,
          ),
          markers: widget.isApproximate
              ? const {}
              : {
                  Marker(
                    markerId: const MarkerId('listing_location'),
                    position: target,
                  ),
                },
          circles: widget.isApproximate
              ? {
                  Circle(
                    circleId: const CircleId('listing_area'),
                    center: target,
                    radius: 900,
                    fillColor: AppColors.primary15,
                    strokeColor: AppColors.primary,
                    strokeWidth: 2,
                  ),
                }
              : const {},
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          zoomGesturesEnabled: false,
          scrollGesturesEnabled: false,
          rotateGesturesEnabled: false,
          tiltGesturesEnabled: false,
          mapToolbarEnabled: false,
          compassEnabled: false,
          liteModeEnabled: true,
          onMapCreated: (_) {},
        ),
      ),
    );
  }
}
