import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../utils/partner_location_validator.dart';

class PartnerLocationInput extends StatefulWidget {
  const PartnerLocationInput({
    super.key,
    required this.latitudeController,
    required this.longitudeController,
  });

  final TextEditingController latitudeController;
  final TextEditingController longitudeController;

  @override
  State<PartnerLocationInput> createState() => _PartnerLocationInputState();
}

class _PartnerLocationInputState extends State<PartnerLocationInput> {
  bool _loading = false;

  Future<Position> _currentPosition() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('Permission GPS refusée.');
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
  }

  void _setPoint(double latitude, double longitude) {
    widget.latitudeController.text = latitude.toStringAsFixed(6);
    widget.longitudeController.text = longitude.toStringAsFixed(6);
    setState(() {});
  }

  Future<void> _useGps() async {
    setState(() => _loading = true);
    try {
      final position = await _currentPosition();
      if (mounted) _setPoint(position.latitude, position.longitude);
    } catch (error) {
      if (mounted) _showError('$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _chooseOnMap() async {
    setState(() => _loading = true);
    try {
      final latitude = double.tryParse(widget.latitudeController.text.trim());
      final longitude = double.tryParse(widget.longitudeController.text.trim());
      LatLng initial;
      if (PartnerLocationValidator.validate(latitude, longitude) == null) {
        initial = LatLng(latitude!, longitude!);
      } else {
        final position = await _currentPosition();
        initial = LatLng(position.latitude, position.longitude);
      }
      if (!mounted) return;
      final selected = await Navigator.of(context).push<LatLng>(
        MaterialPageRoute(builder: (_) => _PartnerPointMap(initial: initial)),
      );
      if (selected != null && mounted) {
        _setPoint(selected.latitude, selected.longitude);
      }
    } catch (error) {
      if (mounted) _showError('$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    const numberType =
        TextInputType.numberWithOptions(decimal: true, signed: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          PartnerLocationValidator.requiredMessage,
          style: TextStyle(fontSize: 12, color: Colors.deepOrange),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: widget.latitudeController,
              keyboardType: numberType,
              decoration: const InputDecoration(labelText: 'Latitude *'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: widget.longitudeController,
              keyboardType: numberType,
              decoration: const InputDecoration(labelText: 'Longitude *'),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            onPressed: _loading ? null : _useGps,
            icon: const Icon(Icons.my_location),
            label: const Text('Utiliser le GPS'),
          ),
          OutlinedButton.icon(
            onPressed: _loading ? null : _chooseOnMap,
            icon: const Icon(Icons.map_outlined),
            label: const Text('Choisir sur la carte'),
          ),
        ]),
      ],
    );
  }
}

class _PartnerPointMap extends StatefulWidget {
  const _PartnerPointMap({required this.initial});

  final LatLng initial;

  @override
  State<_PartnerPointMap> createState() => _PartnerPointMapState();
}

class _PartnerPointMapState extends State<_PartnerPointMap> {
  late LatLng _selected = widget.initial;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Point du partenaire')),
      body: GoogleMap(
        initialCameraPosition: CameraPosition(target: widget.initial, zoom: 16),
        markers: {
          Marker(markerId: const MarkerId('partner'), position: _selected),
        },
        onTap: (point) => setState(() => _selected = point),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pop(context, _selected),
        icon: const Icon(Icons.check),
        label: const Text('Confirmer ce point'),
      ),
    );
  }
}
