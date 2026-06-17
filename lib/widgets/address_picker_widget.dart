import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../services/places_service.dart';
import 'destination_picker.dart';

// ── Résultat de la sélection d'adresse ─────────────────────────────────────
class AddressResult {
  final double latitude;
  final double longitude;
  final String address;

  const AddressResult({
    required this.latitude,
    required this.longitude,
    required this.address,
  });
}

// ── Mode de saisie ──────────────────────────────────────────────────────────
enum AddressMode { gps, manual }

// ═══════════════════════════════════════════════════════════════════════════
// Widget principal — sélecteur d'adresse deux modes
// ═══════════════════════════════════════════════════════════════════════════
class AddressPickerWidget extends StatefulWidget {
  final String          title;
  final String          hint;
  final AddressMode     initialMode;
  final AddressResult?  initialValue;
  final bool            showModeToggle;
  final LatLng?         referencePosition;
  final ValueChanged<AddressResult?> onChanged;

  const AddressPickerWidget({
    super.key,
    required this.title,
    required this.hint,
    required this.onChanged,
    this.initialMode     = AddressMode.gps,
    this.initialValue,
    this.showModeToggle  = true,
    this.referencePosition,
  });

  @override
  State<AddressPickerWidget> createState() => _AddressPickerWidgetState();
}

class _AddressPickerWidgetState extends State<AddressPickerWidget> {
  AddressMode    _mode    = AddressMode.gps;
  AddressResult? _result;
  bool           _loading = false;
  String?        _error;

  @override
  void initState() {
    super.initState();
    _mode   = widget.initialMode;
    _result = widget.initialValue;
    if (_mode == AddressMode.gps && _result == null) {
      _detectGPS();
    }
  }

  // ── GPS : détection + géocodage inverse ───────────────────────────────────
  Future<void> _detectGPS() async {
    setState(() { _loading = true; _error = null; });

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) setState(() { _loading = false; _error = 'GPS désactivé'; });
        return;
      }

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) setState(() { _loading = false; _error = 'Permission GPS refusée'; });
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy:  LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );

      final address = await PlacesService.reverseGeocode(pos.latitude, pos.longitude)
          ?? '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';

      if (!mounted) return;
      final result = AddressResult(
        latitude:  pos.latitude,
        longitude: pos.longitude,
        address:   address,
      );
      setState(() { _result = result; _loading = false; });
      widget.onChanged(result);
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = 'Impossible de localiser'; });
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
        latitude:  selected.position.latitude,
        longitude: selected.position.longitude,
        address:   selected.address,
      );
      setState(() => _result = result);
      widget.onChanged(result);
    }
  }

  // ── Changer de mode ───────────────────────────────────────────────────────
  void _switchMode(AddressMode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode   = mode;
      _result = null;
      _error  = null;
    });
    widget.onChanged(null);
    if (mode == AddressMode.gps) _detectGPS();
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
        ],
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
    return Container(
      color: const Color(0xFFF8F8F8),
      padding: const EdgeInsets.all(6),
      child: Row(
        children: [
          _modeTab('📍 Ma position',   AddressMode.gps),
          _modeTab('🔍 Autre adresse', AddressMode.manual),
        ],
      ),
    );
  }

  Widget _modeTab(String label, AddressMode mode) {
    final sel = _mode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () => _switchMode(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color:        sel ? const Color(0xFFFF6D00) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize:   13,
              fontWeight: sel ? FontWeight.bold : FontWeight.normal,
              color:      sel ? Colors.white : Colors.grey.shade600,
            ),
          ),
        ),
      ),
    );
  }

  // ── Contenu GPS ────────────────────────────────────────────────────────────
  Widget _buildGPSContent() {
    if (_loading) {
      return Row(children: [
        const SizedBox(
          width: 20, height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF6D00)),
        ),
        const SizedBox(width: 12),
        Text('Localisation GPS en cours…',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
      ]);
    }

    if (_error != null) {
      return GestureDetector(
        onTap: _detectGPS,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color:        Colors.red.shade50,
            borderRadius: BorderRadius.circular(12),
            border:       Border.all(color: Colors.red.shade200),
          ),
          child: Row(children: [
            Icon(Icons.location_off_rounded, color: Colors.red.shade400, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(_error!, style: TextStyle(color: Colors.red.shade700, fontSize: 13))),
            Icon(Icons.refresh_rounded, color: Colors.red.shade400, size: 18),
          ]),
        ),
      );
    }

    if (_result == null) {
      return GestureDetector(
        onTap: _detectGPS,
        child: _emptyState(Icons.my_location_rounded, 'Appuyer pour détecter votre position'),
      );
    }

    return _buildResultCard(
      icon:  Icons.my_location_rounded,
      color: const Color(0xFF2E7D32),
      trailing: IconButton(
        icon: const Icon(Icons.refresh_rounded, size: 18),
        color: const Color(0xFF2E7D32),
        tooltip: 'Relancer le GPS',
        onPressed: _detectGPS,
      ),
    );
  }

  // ── Contenu Manuel ─────────────────────────────────────────────────────────
  Widget _buildManualContent() {
    if (_result == null) {
      return GestureDetector(
        onTap: _openPicker,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color:        const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(12),
            border:       Border.all(color: Colors.grey.shade300),
          ),
          child: Row(children: [
            const Icon(Icons.search_rounded, color: Color(0xFFFF6D00), size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.hint,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: Colors.grey.shade400),
          ]),
        ),
      );
    }

    return _buildResultCard(
      icon:  Icons.place_rounded,
      color: const Color(0xFFFF6D00),
      trailing: IconButton(
        icon: const Icon(Icons.edit_rounded, size: 18),
        color: const Color(0xFFFF6D00),
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
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              _result!.address,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              '${_result!.latitude.toStringAsFixed(5)}, ${_result!.longitude.toStringAsFixed(5)}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          ]),
        ),
        trailing,
      ]),
    );
  }

  Widget _emptyState(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: Colors.grey.shade300),
      ),
      child: Row(children: [
        Icon(icon, color: const Color(0xFFFF6D00), size: 22),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: TextStyle(color: Colors.grey.shade500, fontSize: 14))),
        Icon(Icons.chevron_right_rounded, color: Colors.grey.shade400),
      ]),
    );
  }
}
