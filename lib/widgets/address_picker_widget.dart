import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../services/places_service.dart';
import 'destination_picker.dart';
import '../theme/app_theme.dart';

// ── Résultat de la sélection d'adresse ─────────────────────────────────────
class AddressResult {
  final double latitude;
  final double longitude;
  final String address;
  final String coordinateSource;

  const AddressResult({
    required this.latitude,
    required this.longitude,
    required this.address,
    this.coordinateSource = 'map_pin',
  });
}

// ── Mode de saisie ──────────────────────────────────────────────────────────
enum AddressMode { gps, manual }

// ═══════════════════════════════════════════════════════════════════════════
// Widget principal — sélecteur d'adresse deux modes
// ═══════════════════════════════════════════════════════════════════════════
class AddressPickerWidget extends StatefulWidget {
  final String title;
  final String hint;
  final AddressMode initialMode;
  final AddressResult? initialValue;
  final bool showModeToggle;
  final LatLng? referencePosition;
  final ValueChanged<AddressResult?> onChanged;

  /// LOT 4.1 (Courses) — accent de la carte résultat GPS ("Ma position"),
  /// optionnel. `null` préserve exactement le comportement déjà en place
  /// (vert historique) pour les consommateurs qui ne le fournissent pas
  /// (ex. `create_order.dart`, non touché par ce lot) — configuration
  /// locale au lieu d'un changement de comportement partagé.
  final Color? gpsAccentColor;

  const AddressPickerWidget({
    super.key,
    required this.title,
    required this.hint,
    required this.onChanged,
    this.initialMode = AddressMode.gps,
    this.initialValue,
    this.showModeToggle = true,
    this.referencePosition,
    this.gpsAccentColor,
  });

  @override
  State<AddressPickerWidget> createState() => _AddressPickerWidgetState();
}

class _AddressPickerWidgetState extends State<AddressPickerWidget> {
  AddressMode _mode = AddressMode.gps;
  AddressResult? _result;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _result = widget.initialValue;
    if (_mode == AddressMode.gps && _result == null) {
      _detectGPS();
    }
  }

  // ── GPS : détection + géocodage inverse ───────────────────────────────────
  Future<void> _detectGPS() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'GPS désactivé';
          });
        }
        return;
      }

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'Permission GPS refusée';
          });
        }
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );

      final address = await PlacesService.reverseGeocode(
              pos.latitude, pos.longitude) ??
          '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';

      if (!mounted) return;
      final result = AddressResult(
        latitude: pos.latitude,
        longitude: pos.longitude,
        address: address,
        coordinateSource: 'gps',
      );
      setState(() {
        _result = result;
        _loading = false;
      });
      widget.onChanged(result);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Impossible de localiser';
        });
      }
    }
  }

  // ── Manuel : ouvrir le sélecteur Places + carte ───────────────────────────
  Future<void> _openPicker() async {
    final ref = _result != null
        ? LatLng(_result!.latitude, _result!.longitude)
        : (widget.referencePosition ?? const LatLng(6.7273, -3.4961));

    final selected = await Navigator.push<DestinationResult>(
      context,
      MaterialPageRoute(
        builder: (_) => DestinationPickerScreen(clientPosition: ref),
      ),
    );

    if (selected != null && mounted) {
      final result = AddressResult(
        latitude: selected.position.latitude,
        longitude: selected.position.longitude,
        address: selected.address,
        coordinateSource: 'map_pin',
      );
      setState(() => _result = result);
      widget.onChanged(result);
    }
  }

  // ── Changer de mode ───────────────────────────────────────────────────────
  void _switchMode(AddressMode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _result = null;
      _error = null;
    });
    widget.onChanged(null);
    if (mode == AddressMode.gps) _detectGPS();
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.premiumSurfaceElevated(brightness),
        borderRadius: AppRadius.premiumLgR,
        border: Border.all(color: AppColors.premiumBorder(brightness)),
        boxShadow: AppShadow.xs,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Toggle Mode (si activé)
          if (widget.showModeToggle) _buildModeToggle(),

          // Contenu
          Padding(
            padding: const EdgeInsets.all(14),
            child: _mode == AddressMode.gps
                ? _buildGPSContent()
                : _buildManualContent(),
          ),
        ],
      ),
    );
  }

  // ── Toggle ─────────────────────────────────────────────────────────────────
  Widget _buildModeToggle() {
    final brightness = Theme.of(context).brightness;
    return Container(
      color: AppColors.premiumSurface(brightness),
      padding: const EdgeInsets.all(6),
      child: Row(
        children: [
          _modeTab('📍 Ma position', AddressMode.gps),
          _modeTab('🔍 Autre adresse', AddressMode.manual),
        ],
      ),
    );
  }

  Widget _modeTab(String label, AddressMode mode) {
    final sel = _mode == mode;
    final brightness = Theme.of(context).brightness;
    final muted = brightness == Brightness.dark
        ? AppColors.premiumTextMutedDark
        : AppColors.premiumTextMutedLight;
    return Expanded(
      child: GestureDetector(
        onTap: () => _switchMode(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: sel ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: sel ? FontWeight.bold : FontWeight.normal,
              color: sel ? Colors.white : muted,
            ),
          ),
        ),
      ),
    );
  }

  // ── Contenu GPS ────────────────────────────────────────────────────────────
  Widget _buildGPSContent() {
    final brightness = Theme.of(context).brightness;
    final muted = brightness == Brightness.dark
        ? AppColors.premiumTextMutedDark
        : AppColors.premiumTextMutedLight;
    if (_loading) {
      // LOT 4.1 (Courses) — bug réel trouvé et corrigé : ce texte n'était
      // pas contraint dans le Row (ni Expanded ni Flexible), provoquant un
      // RenderFlex overflow sur un écran étroit (iPhone 390px). Fix sûr
      // pour les deux consommateurs (Courses et create_order.dart) —
      // aucun changement de comportement, juste l'ajout d'un Expanded.
      return Row(children: [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AppColors.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text('Localisation GPS en cours…',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: muted, fontSize: 14)),
        ),
      ]);
    }

    if (_error != null) {
      // LOT 4.1 — `Colors.red.shade*` n'était pas theme-aware (rouge pâle
      // fixe, jamais vérifié en dark mode) ; remplacé par le token déjà
      // existant `AppColors.error` avec le même mécanisme de tinte par
      // opacité déjà utilisé ailleurs dans ce fichier (`_buildResultCard`),
      // aucune nouvelle couleur introduite.
      return GestureDetector(
        onTap: _detectGPS,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.error
                .withValues(alpha: brightness == Brightness.dark ? 0.16 : 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.error.withValues(alpha: 0.35)),
          ),
          child: Row(children: [
            const Icon(Icons.location_off_rounded,
                color: AppColors.error, size: 20),
            const SizedBox(width: 10),
            Expanded(
                child: Text(_error!,
                    style:
                        const TextStyle(color: AppColors.error, fontSize: 13))),
            const Icon(Icons.refresh_rounded, color: AppColors.error, size: 18),
          ]),
        ),
      );
    }

    if (_result == null) {
      return GestureDetector(
        onTap: _detectGPS,
        child: _emptyState(
            Icons.my_location_rounded, 'Appuyer pour détecter votre position'),
      );
    }

    // LOT 4.1 — `gpsAccentColor` (fourni par Courses) recentre cette carte
    // sur le bleu premium ("localisation" dans la palette Premium V1) ;
    // sans le paramètre, le vert historique est conservé à l'identique pour
    // les autres consommateurs (ex. `create_order.dart`).
    final accent = widget.gpsAccentColor ?? const Color(0xFF2E7D32);
    return _buildResultCard(
      icon: Icons.my_location_rounded,
      color: accent,
      trailing: IconButton(
        icon: const Icon(Icons.refresh_rounded, size: 18),
        color: accent,
        tooltip: 'Relancer le GPS',
        onPressed: _detectGPS,
      ),
    );
  }

  // ── Contenu Manuel ─────────────────────────────────────────────────────────
  Widget _buildManualContent() {
    final brightness = Theme.of(context).brightness;
    final muted = brightness == Brightness.dark
        ? AppColors.premiumTextMutedDark
        : AppColors.premiumTextMutedLight;
    if (_result == null) {
      return GestureDetector(
        onTap: _openPicker,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.premiumSurface(brightness),
            borderRadius: AppRadius.mdR,
            border: Border.all(color: AppColors.premiumBorder(brightness)),
          ),
          child: Row(children: [
            const Icon(Icons.search_rounded,
                color: AppColors.primary, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.hint,
                style: TextStyle(color: muted, fontSize: 14),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: muted),
          ]),
        ),
      );
    }

    return _buildResultCard(
      icon: Icons.place_rounded,
      color: AppColors.primary,
      trailing: IconButton(
        icon: const Icon(Icons.edit_rounded, size: 18),
        color: AppColors.primary,
        tooltip: 'Modifier',
        onPressed: _openPicker,
      ),
    );
  }

  // ── Carte résultat ─────────────────────────────────────────────────────────
  Widget _buildResultCard({
    required IconData icon,
    required Color color,
    required Widget trailing,
  }) {
    final brightness = Theme.of(context).brightness;
    final textPrimary = brightness == Brightness.dark
        ? AppColors.premiumTextPrimaryDark
        : AppColors.premiumTextPrimaryLight;
    final muted = brightness == Brightness.dark
        ? AppColors.premiumTextMutedDark
        : AppColors.premiumTextMutedLight;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              _result!.address,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: textPrimary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              '${_result!.latitude.toStringAsFixed(5)}, ${_result!.longitude.toStringAsFixed(5)}',
              style: TextStyle(fontSize: 11, color: muted),
            ),
          ]),
        ),
        trailing,
      ]),
    );
  }

  Widget _emptyState(IconData icon, String label) {
    final brightness = Theme.of(context).brightness;
    final muted = brightness == Brightness.dark
        ? AppColors.premiumTextMutedDark
        : AppColors.premiumTextMutedLight;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.premiumSurface(brightness),
        borderRadius: AppRadius.mdR,
        border: Border.all(color: AppColors.premiumBorder(brightness)),
      ),
      child: Row(children: [
        Icon(icon, color: AppColors.primary, size: 22),
        const SizedBox(width: 12),
        Expanded(
            child: Text(label, style: TextStyle(color: muted, fontSize: 14))),
        Icon(Icons.chevron_right_rounded, color: muted),
      ]),
    );
  }
}
