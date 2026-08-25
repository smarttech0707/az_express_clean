import 'package:flutter/material.dart';

import '../../models/real_estate_search_filters.dart';
import '../../services/map_navigation_service.dart';
import '../../theme/app_theme.dart';

/// Master Prompt "Immobilier V6" — Mission 4 : feuille de filtres modernes.
/// Position GPS réutilise `MapNavigationService.requestClientPosition()`
/// (déjà construit pour la carte de localisation, Mission 7 — jamais
/// dupliqué), demandée uniquement sur action explicite de l'utilisateur
/// ("Distance" activé), jamais automatiquement à l'ouverture de la feuille.
Future<RealEstateSearchFilters?> showPropertyFilterSheet(
  BuildContext context, {
  required RealEstateSearchFilters current,
}) {
  return showModalBottomSheet<RealEstateSearchFilters>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => _PropertyFilterSheetContent(initial: current),
  );
}

class _PropertyFilterSheetContent extends StatefulWidget {
  final RealEstateSearchFilters initial;
  const _PropertyFilterSheetContent({required this.initial});

  @override
  State<_PropertyFilterSheetContent> createState() =>
      _PropertyFilterSheetContentState();
}

class _PropertyFilterSheetContentState
    extends State<_PropertyFilterSheetContent> {
  late final _cityCtrl = TextEditingController(text: widget.initial.city);
  late final _quartierCtrl =
      TextEditingController(text: widget.initial.quartier);
  late final _minPriceCtrl =
      TextEditingController(text: widget.initial.minPrice?.toString() ?? '');
  late final _maxPriceCtrl =
      TextEditingController(text: widget.initial.maxPrice?.toString() ?? '');
  late final _minSurfaceCtrl =
      TextEditingController(text: widget.initial.minSurface?.toString() ?? '');
  late final _minBedroomsCtrl =
      TextEditingController(text: widget.initial.minBedrooms?.toString() ?? '');

  bool? _furnished;
  bool? _hasPool;
  bool? _hasGarage;
  bool? _hasParking;
  bool? _hasInternet;
  bool? _availableOnly;
  bool _landOnly = false;
  bool _commercialOnly = false;
  bool _furnishedResidenceOnly = false;

  bool _distanceEnabled = false;
  double _maxDistanceKm = 5;
  double? _clientLat;
  double? _clientLng;
  bool _locatingClient = false;

  @override
  void initState() {
    super.initState();
    final f = widget.initial;
    _furnished = f.furnished;
    _hasPool = f.hasPool;
    _hasGarage = f.hasGarage;
    _hasParking = f.hasParking;
    _hasInternet = f.hasInternet;
    _availableOnly = f.availableOnly;
    _landOnly = f.landOnly;
    _commercialOnly = f.commercialOnly;
    _furnishedResidenceOnly = f.furnishedResidenceOnly;
    if (f.maxDistanceKm != null) {
      _distanceEnabled = true;
      _maxDistanceKm = f.maxDistanceKm!;
    }
  }

  @override
  void dispose() {
    _cityCtrl.dispose();
    _quartierCtrl.dispose();
    _minPriceCtrl.dispose();
    _maxPriceCtrl.dispose();
    _minSurfaceCtrl.dispose();
    _minBedroomsCtrl.dispose();
    super.dispose();
  }

  Future<void> _enableDistance(bool enabled) async {
    setState(() => _distanceEnabled = enabled);
    if (!enabled || _clientLat != null) return;
    setState(() => _locatingClient = true);
    final result = await MapNavigationService.requestClientPosition();
    if (!mounted) return;
    setState(() {
      _locatingClient = false;
      if (result.isGranted) {
        _clientLat = result.latitude;
        _clientLng = result.longitude;
      } else {
        _distanceEnabled = false;
      }
    });
  }

  void _apply() {
    final filters = RealEstateSearchFilters(
      city: _cityCtrl.text.trim().isEmpty ? null : _cityCtrl.text.trim(),
      quartier:
          _quartierCtrl.text.trim().isEmpty ? null : _quartierCtrl.text.trim(),
      minPrice: int.tryParse(_minPriceCtrl.text.trim()),
      maxPrice: int.tryParse(_maxPriceCtrl.text.trim()),
      minSurface: double.tryParse(_minSurfaceCtrl.text.trim()),
      minBedrooms: int.tryParse(_minBedroomsCtrl.text.trim()),
      furnished: _furnished,
      hasPool: _hasPool,
      hasGarage: _hasGarage,
      hasParking: _hasParking,
      hasInternet: _hasInternet,
      availableOnly: _availableOnly,
      landOnly: _landOnly,
      commercialOnly: _commercialOnly,
      furnishedResidenceOnly: _furnishedResidenceOnly,
      maxDistanceKm:
          (_distanceEnabled && _clientLat != null) ? _maxDistanceKm : null,
      fromLatitude:
          (_distanceEnabled && _clientLat != null) ? _clientLat : null,
      fromLongitude:
          (_distanceEnabled && _clientLng != null) ? _clientLng : null,
    );
    Navigator.pop(context, filters);
  }

  void _reset() => Navigator.pop(context, const RealEstateSearchFilters());

  Widget _toggleChip(String label, bool? value, ValueChanged<bool?> onTap) {
    return FilterChip(
      label: Text(label),
      selected: value == true,
      onSelected: (v) => setState(() => onTap(v ? true : null)),
      selectedColor: AppColors.primary15,
      labelStyle: TextStyle(
          color: value == true ? AppColors.primary : AppColors.text,
          fontWeight: FontWeight.w600),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Filtres', style: AppTypography.titleLargeStyle(context)),
                TextButton(
                    onPressed: _reset, child: const Text('Réinitialiser')),
              ],
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _cityCtrl,
                      decoration: const InputDecoration(labelText: 'Ville'))),
              const SizedBox(width: 8),
              Expanded(
                  child: TextField(
                      controller: _quartierCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Quartier'))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _minPriceCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Prix min', suffixText: 'FCFA'))),
              const SizedBox(width: 8),
              Expanded(
                  child: TextField(
                      controller: _maxPriceCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Prix max', suffixText: 'FCFA'))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _minSurfaceCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Surface min', suffixText: 'm²'))),
              const SizedBox(width: 8),
              Expanded(
                  child: TextField(
                      controller: _minBedroomsCtrl,
                      keyboardType: TextInputType.number,
                      decoration:
                          const InputDecoration(labelText: 'Chambres min'))),
            ]),
            const SizedBox(height: 16),
            const Text('Type',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilterChip(
                label: const Text('Terrain uniquement'),
                selected: _landOnly,
                onSelected: (v) => setState(() => _landOnly = v),
              ),
              FilterChip(
                label: const Text('Local commercial uniquement'),
                selected: _commercialOnly,
                onSelected: (v) => setState(() => _commercialOnly = v),
              ),
              FilterChip(
                label: const Text('Résidence meublée uniquement'),
                selected: _furnishedResidenceOnly,
                onSelected: (v) => setState(() => _furnishedResidenceOnly = v),
              ),
            ]),
            const SizedBox(height: 16),
            const Text('Équipements',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _toggleChip('Meublé', _furnished, (v) => _furnished = v),
              _toggleChip('Piscine', _hasPool, (v) => _hasPool = v),
              _toggleChip('Garage', _hasGarage, (v) => _hasGarage = v),
              _toggleChip('Parking', _hasParking, (v) => _hasParking = v),
              _toggleChip('Internet', _hasInternet, (v) => _hasInternet = v),
              _toggleChip(
                  'Disponible', _availableOnly, (v) => _availableOnly = v),
            ]),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Filtrer par distance depuis ma position'),
              value: _distanceEnabled,
              activeThumbColor: AppColors.primary,
              onChanged: _enableDistance,
            ),
            if (_locatingClient)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('Localisation en cours…'),
                ]),
              ),
            if (_distanceEnabled && _clientLat != null) ...[
              Text('Rayon : ${_maxDistanceKm.round()} km'),
              Slider(
                value: _maxDistanceKm,
                min: 1,
                max: 50,
                divisions: 49,
                activeColor: AppColors.primary,
                label: '${_maxDistanceKm.round()} km',
                onChanged: (v) => setState(() => _maxDistanceKm = v),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _apply,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                child: const Text('Appliquer les filtres'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
