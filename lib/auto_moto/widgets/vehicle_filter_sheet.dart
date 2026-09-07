import 'package:flutter/material.dart';

import '../models/vehicle_listing.dart';
import '../vehicle_listing_query.dart';

class VehicleFilterSheet extends StatefulWidget {
  const VehicleFilterSheet({
    super.key,
    required this.initial,
    required this.offerType,
    required this.vehicleType,
  });

  final VehicleListingFilters initial;
  final VehicleOfferType offerType;
  final VehicleType vehicleType;

  @override
  State<VehicleFilterSheet> createState() => _VehicleFilterSheetState();
}

class _VehicleFilterSheetState extends State<VehicleFilterSheet> {
  late VehicleCondition? _condition = widget.initial.condition;
  late VehicleTransmission? _transmission = widget.initial.transmission;
  late VehicleFuelType? _fuel = widget.initial.fuelType;
  late bool _withDriver = widget.initial.withDriver == true;
  late bool _withoutDriver = widget.initial.withoutDriver == true;
  late final _brand = TextEditingController(text: widget.initial.brand);
  late final _minYear = _controller(widget.initial.minYear);
  late final _maxYear = _controller(widget.initial.maxYear);
  late final _minPrice = _controller(widget.initial.minPrice);
  late final _maxPrice = _controller(widget.initial.maxPrice);
  late final _mileage = _controller(widget.initial.maxMileageKm);
  late final _engine = _controller(widget.initial.minEngineCapacityCc);
  late final _seats = _controller(widget.initial.seats);

  TextEditingController _controller(int? value) =>
      TextEditingController(text: value?.toString() ?? '');

  @override
  void dispose() {
    for (final controller in [
      _brand,
      _minYear,
      _maxYear,
      _minPrice,
      _maxPrice,
      _mileage,
      _engine,
      _seats,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                  child: Text('Filtres',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                TextButton(
                    onPressed: _reset, child: const Text('Réinitialiser')),
              ]),
              _label('État'),
              Wrap(
                spacing: 8,
                children: [
                  _choice('Neuf', VehicleCondition.newVehicle, colors),
                  _choice('Occasion', VehicleCondition.used, colors),
                ],
              ),
              TextField(
                controller: _brand,
                decoration: const InputDecoration(labelText: 'Marque exacte'),
              ),
              const SizedBox(height: 12),
              _pair(_minYear, 'Année min', _maxYear, 'Année max'),
              const SizedBox(height: 12),
              _pair(_minPrice, 'Prix min', _maxPrice, 'Prix max'),
              if (widget.vehicleType == VehicleType.car) ...[
                _label('Transmission'),
                Wrap(spacing: 8, children: [
                  _transmissionChoice('Manuelle', VehicleTransmission.manual),
                  _transmissionChoice(
                      'Automatique', VehicleTransmission.automatic),
                ]),
                _label('Carburant'),
                DropdownButtonFormField<VehicleFuelType>(
                  initialValue: _fuel,
                  decoration: const InputDecoration(labelText: 'Carburant'),
                  items: const [
                    DropdownMenuItem(
                        value: VehicleFuelType.petrol, child: Text('Essence')),
                    DropdownMenuItem(
                        value: VehicleFuelType.diesel, child: Text('Diesel')),
                    DropdownMenuItem(
                        value: VehicleFuelType.electric,
                        child: Text('Électrique')),
                    DropdownMenuItem(
                        value: VehicleFuelType.hybrid, child: Text('Hybride')),
                  ],
                  onChanged: (value) => setState(() => _fuel = value),
                ),
                const SizedBox(height: 12),
                _pair(_mileage, 'Kilométrage max', _seats, 'Places'),
              ],
              if (widget.vehicleType != VehicleType.car) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _engine,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Cylindrée min (cm³)'),
                ),
              ],
              if (widget.offerType == VehicleOfferType.rental) ...[
                _label('Location'),
                Wrap(spacing: 8, children: [
                  FilterChip(
                    label: const Text('Avec chauffeur'),
                    selected: _withDriver,
                    onSelected: (value) => setState(() => _withDriver = value),
                  ),
                  FilterChip(
                    label: const Text('Sans chauffeur'),
                    selected: _withoutDriver,
                    onSelected: (value) =>
                        setState(() => _withoutDriver = value),
                  ),
                ]),
              ],
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _apply,
                child: const Text('Afficher les résultats'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
      );

  Widget _choice(String label, VehicleCondition value, ColorScheme colors) =>
      ChoiceChip(
        label: Text(label),
        selected: _condition == value,
        selectedColor: colors.primaryContainer,
        onSelected: (selected) =>
            setState(() => _condition = selected ? value : null),
      );

  Widget _transmissionChoice(String label, VehicleTransmission value) =>
      ChoiceChip(
        label: Text(label),
        selected: _transmission == value,
        onSelected: (selected) =>
            setState(() => _transmission = selected ? value : null),
      );

  Widget _pair(TextEditingController first, String firstLabel,
          TextEditingController second, String secondLabel) =>
      Row(children: [
        Expanded(child: _number(first, firstLabel)),
        const SizedBox(width: 10),
        Expanded(child: _number(second, secondLabel)),
      ]);

  Widget _number(TextEditingController controller, String label) => TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
      );

  int? _int(TextEditingController controller) =>
      int.tryParse(controller.text.trim());

  void _reset() {
    Navigator.pop(context, const VehicleListingFilters());
  }

  void _apply() {
    Navigator.pop(
      context,
      VehicleListingFilters(
        condition: _condition,
        brand: _brand.text.trim(),
        minYear: _int(_minYear),
        maxYear: _int(_maxYear),
        minPrice: _int(_minPrice),
        maxPrice: _int(_maxPrice),
        transmission: _transmission,
        fuelType: _fuel,
        maxMileageKm: _int(_mileage),
        minEngineCapacityCc: _int(_engine),
        seats: _int(_seats),
        withDriver: _withDriver ? true : null,
        withoutDriver: _withoutDriver ? true : null,
      ),
    );
  }
}
