import 'package:flutter/material.dart';

import '../models/vehicle_listing.dart';
import '../vehicle_formatters.dart';
import '../vehicle_listing_query.dart';

class VehicleFilterSheet extends StatefulWidget {
  const VehicleFilterSheet({
    super.key,
    required this.initial,
    required this.offerType,
    required this.vehicleType,
    this.cityLabel = 'Toute la Côte d’Ivoire',
  });

  final VehicleListingFilters initial;
  final VehicleOfferType offerType;
  final VehicleType vehicleType;
  final String cityLabel;

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
      top: false,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.82,
        minChildSize: 0.55,
        maxChildSize: 0.96,
        builder: (context, scrollController) => Material(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: Column(
            children: [
              Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                decoration: BoxDecoration(
                  color: colors.outlineVariant,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Filtres',
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 2),
                          Text('Affinez votre recherche',
                              style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    ),
                    TextButton(
                        key: const Key('vehicle_filter_reset'),
                        onPressed: _reset,
                        child: const Text('Réinitialiser')),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.outlineVariant),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  children: [
                    _section('RECHERCHE ACTUELLE'),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      _ContextPill(label: vehicleOfferLabel(widget.offerType)),
                      _ContextPill(label: vehicleTypeLabel(widget.vehicleType)),
                    ]),
                    const SizedBox(height: 16),
                    _section('VILLE'),
                    _CityField(label: widget.cityLabel),
                    _section('ÉTAT'),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      _choice('Neuf', VehicleCondition.newVehicle),
                      _choice('Occasion', VehicleCondition.used),
                    ]),
                    _section('MARQUE'),
                    TextField(
                      key: const Key('vehicle_filter_brand'),
                      controller: _brand,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Marque',
                        hintText: 'Ex. Toyota, Yamaha',
                        prefixIcon: Icon(Icons.directions_car_outlined),
                      ),
                    ),
                    _section('PRIX'),
                    _pair(_minPrice, 'Prix min', _maxPrice, 'Prix max'),
                    _section('ANNÉE'),
                    _pair(_minYear, 'Année min', _maxYear, 'Année max'),
                    if (widget.vehicleType == VehicleType.car) ...[
                      _section('TRANSMISSION'),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        _transmissionChoice('Manuelle', VehicleTransmission.manual),
                        _transmissionChoice(
                            'Automatique', VehicleTransmission.automatic),
                      ]),
                      _section('CARBURANT'),
                      DropdownButtonFormField<VehicleFuelType>(
                        initialValue: _fuel,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Carburant',
                          prefixIcon: Icon(Icons.local_gas_station_outlined),
                        ),
                        items: const [
                          DropdownMenuItem(
                              value: VehicleFuelType.petrol, child: Text('Essence')),
                          DropdownMenuItem(
                              value: VehicleFuelType.diesel, child: Text('Diesel')),
                          DropdownMenuItem(
                              value: VehicleFuelType.electric, child: Text('Électrique')),
                          DropdownMenuItem(
                              value: VehicleFuelType.hybrid, child: Text('Hybride')),
                        ],
                        onChanged: (value) => setState(() => _fuel = value),
                      ),
                      _section('CARACTÉRISTIQUES'),
                      _pair(_mileage, 'Km max', _seats, 'Places'),
                    ],
                    if (widget.vehicleType != VehicleType.car) ...[
                      _section('CARACTÉRISTIQUES'),
                      _number(_engine, 'Cylindrée min (cm³)'),
                    ],
                    if (widget.offerType == VehicleOfferType.rental) ...[
                      _section('LOCATION'),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        _toggleChip('Avec chauffeur', _withDriver,
                            (value) => setState(() => _withDriver = value)),
                        _toggleChip('Sans chauffeur', _withoutDriver,
                            (value) => setState(() => _withoutDriver = value)),
                      ]),
                    ],
                  ],
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border(top: BorderSide(color: colors.outlineVariant)),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key('vehicle_filter_apply'),
                        onPressed: _apply,
                        icon: const Icon(Icons.tune_rounded),
                        label: const Text('Afficher les résultats'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                )),
      );

  Widget _choice(String label, VehicleCondition value) => _MarketChoiceChip(
        label: label,
        selected: _condition == value,
        onSelected: (selected) =>
            setState(() => _condition = selected ? value : null),
      );

  Widget _transmissionChoice(String label, VehicleTransmission value) =>
      _MarketChoiceChip(
        label: label,
        selected: _transmission == value,
        onSelected: (selected) =>
            setState(() => _transmission = selected ? value : null),
      );

  Widget _toggleChip(String label, bool selected, ValueChanged<bool> onSelected) =>
      _MarketChoiceChip(label: label, selected: selected, onSelected: onSelected);

  Widget _pair(TextEditingController first, String firstLabel,
          TextEditingController second, String secondLabel) =>
      LayoutBuilder(builder: (context, constraints) {
        final horizontal = constraints.maxWidth >= 300;
        final fields = [
          Expanded(child: _number(first, firstLabel)),
          const SizedBox(width: 10),
          Expanded(child: _number(second, secondLabel)),
        ];
        return horizontal
            ? Row(children: fields)
            : Column(
                children: [
                  _number(first, firstLabel),
                  const SizedBox(height: 10),
                  _number(second, secondLabel),
                ],
              );
      });

  Widget _number(TextEditingController controller, String label) => TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
      );

  int? _int(TextEditingController controller) =>
      int.tryParse(controller.text.trim());

  void _reset() => Navigator.pop(context, const VehicleListingFilters());

  void _apply() => Navigator.pop(
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

class _MarketChoiceChip extends StatelessWidget {
  const _MarketChoiceChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: selected,
      selectedColor: colors.primary,
      backgroundColor: colors.surfaceContainerHighest,
      side: BorderSide(color: selected ? colors.primary : colors.outlineVariant),
      labelStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: selected ? colors.onPrimary : colors.onSurface,
            fontWeight: FontWeight.w700,
          ),
      onSelected: onSelected,
    );
  }
}

class _ContextPill extends StatelessWidget {
  const _ContextPill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Chip(
      label: Text(label),
      avatar: Icon(Icons.check_circle_rounded, size: 16, color: colors.primary),
      backgroundColor: colors.primaryContainer,
      side: BorderSide(color: colors.primary.withValues(alpha: 0.35)),
      labelStyle: Theme.of(context)
          .textTheme
          .labelLarge
          ?.copyWith(color: colors.onPrimaryContainer),
    );
  }
}

class _CityField extends StatelessWidget {
  const _CityField({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const Key('vehicle_filter_city'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        Icon(Icons.location_on_outlined, color: colors.primary),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: Theme.of(context).textTheme.titleSmall)),
      ]),
    );
  }
}
