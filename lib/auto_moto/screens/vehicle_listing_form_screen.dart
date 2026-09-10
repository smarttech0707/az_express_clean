import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/delivery_zone.dart';
import '../../theme/app_theme.dart';
import '../models/vehicle_listing.dart';
import '../models/vehicle_media.dart';
import '../models/vehicle_seller_profile.dart';
import '../vehicle_formatters.dart';
import '../vehicle_listing_form_data.dart';
import '../vehicle_listing_repository.dart';
import '../vehicle_media_service.dart';

typedef VehicleListingSaver = Future<void> Function(VehicleListing listing);

class VehicleListingFormScreen extends StatefulWidget {
  const VehicleListingFormScreen({
    super.key,
    required this.profile,
    required this.cityId,
    required this.cityName,
    this.cities = const [],
    this.original,
    this.saveListing,
    this.mediaService,
    this.imagePicker,
  });

  final VehicleSellerProfile profile;
  final String cityId;
  final String cityName;
  final List<DeliveryZone> cities;
  final VehicleListing? original;
  final VehicleListingSaver? saveListing;
  final VehicleMediaService? mediaService;
  final ImagePicker? imagePicker;

  @override
  State<VehicleListingFormScreen> createState() =>
      _VehicleListingFormScreenState();
}

class _VehicleListingFormScreenState extends State<VehicleListingFormScreen> {
  static const _stepTitles = [
    'Type d’offre',
    'Type de véhicule',
    'État',
    'Identité du véhicule',
    'Caractéristiques',
    'Prix',
    'Description',
    'Photos et vidéo',
    'Prévisualisation',
  ];

  late final VehicleListingFormData _data;
  late final Map<String, TextEditingController> _controllers;
  late final VehicleMediaSelection _media;
  late final VehicleMediaService? _injectedMediaService;
  late final ImagePicker _picker;
  final Map<String, Uint8List> _localBytes = {};
  int _step = 0;
  bool _saving = false;
  double _uploadProgress = 0;
  late String _listingCityId;
  late String _listingCityName;

  @override
  void initState() {
    super.initState();
    _data = widget.original == null
        ? VehicleListingFormData()
        : VehicleListingFormData.fromListing(widget.original!);
    _listingCityId = widget.original?.cityId ?? widget.cityId;
    _listingCityName = widget.original?.cityName ?? widget.cityName;
    _media =
        VehicleMediaSelection(existing: widget.original?.media ?? const []);
    if (widget.original?.coverMediaId != null) {
      _media.coverMediaId = widget.original!.coverMediaId;
    }
    _injectedMediaService = widget.mediaService;
    _picker = widget.imagePicker ?? ImagePicker();
    _controllers = {
      'brand': TextEditingController(text: _data.brand),
      'model': TextEditingController(text: _data.model),
      'year': TextEditingController(text: _data.year),
      'color': TextEditingController(text: _data.color),
      'mileage': TextEditingController(text: _data.mileageKm),
      'engine': TextEditingController(text: _data.engineCapacityCc),
      'seats': TextEditingController(text: _data.seats),
      'salePrice': TextEditingController(text: _data.salePrice),
      'dayPrice': TextEditingController(text: _data.rentalPricePerDay),
      'weekPrice': TextEditingController(text: _data.rentalPricePerWeek),
      'deposit': TextEditingController(text: _data.depositAmount),
      'title': TextEditingController(text: _data.title),
      'description': TextEditingController(text: _data.description),
    };
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.original == null
            ? 'Publier une annonce'
            : 'Modifier l’annonce'),
        leading: BackButton(onPressed: _back),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            LinearProgressIndicator(value: (_step + 1) / _stepTitles.length),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _stepTitles[_step],
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ),
                  Text('${_step + 1}/${_stepTitles.length}'),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                children: [_buildStep()],
              ),
            ),
            _NavigationBar(
              canGoBack: _step > 0,
              saving: _saving,
              isLast: _step == _stepTitles.length - 1,
              finalLabel: widget.original == null ? 'Publier' : 'Enregistrer',
              onBack: _back,
              onNext: _next,
            ),
            if (_saving && _media.pending.isNotEmpty)
              LinearProgressIndicator(value: _uploadProgress),
          ],
        ),
      ),
    );
  }

  Widget _buildStep() => switch (_step) {
        0 => _ChoiceGrid<VehicleOfferType>(
            value: _data.offerType,
            choices: const {
              VehicleOfferType.sale: ('Vente', Icons.sell_rounded),
              VehicleOfferType.rental: ('Location', Icons.key_rounded),
            },
            onChanged: (value) => setState(() => _data.offerType = value),
          ),
        1 => _ChoiceGrid<VehicleType>(
            value: _data.vehicleType,
            choices: const {
              VehicleType.car: ('Voiture', Icons.directions_car_rounded),
              VehicleType.motorcycle: ('Moto', Icons.two_wheeler_rounded),
              VehicleType.tricycle: (
                'Tricycle',
                Icons.electric_rickshaw_rounded
              ),
            },
            onChanged: (value) => setState(() => _data.vehicleType = value),
          ),
        2 => _ChoiceGrid<VehicleCondition>(
            value: _data.condition,
            choices: const {
              VehicleCondition.newVehicle: ('Neuf', Icons.auto_awesome_rounded),
              VehicleCondition.used: ('Occasion', Icons.history_rounded),
            },
            onChanged: (value) => setState(() => _data.condition = value),
          ),
        3 => _identityFields(),
        4 => _characteristicFields(),
        5 => _priceFields(),
        6 => _descriptionFields(),
        7 => _mediaFields(),
        _ => _preview(),
      };

  Widget _identityFields() => Column(
        children: [
          _field('brand', 'Marque', (value) => _data.brand = value),
          _field('model', 'Modèle', (value) => _data.model = value),
          _field('year', 'Année', (value) => _data.year = value, numeric: true),
          _field('color', 'Couleur', (value) => _data.color = value),
        ],
      );

  Widget _characteristicFields() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_data.condition == VehicleCondition.used)
            _field('mileage', 'Kilométrage (km)',
                (value) => _data.mileageKm = value,
                numeric: true),
          if (_data.vehicleType == VehicleType.car) ...[
            DropdownButtonFormField<VehicleTransmission>(
              initialValue: _data.transmission,
              decoration: const InputDecoration(labelText: 'Transmission'),
              items: const [
                DropdownMenuItem(
                    value: VehicleTransmission.manual, child: Text('Manuelle')),
                DropdownMenuItem(
                    value: VehicleTransmission.automatic,
                    child: Text('Automatique')),
              ],
              onChanged: (value) => setState(() => _data.transmission = value),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<VehicleFuelType>(
              initialValue: _data.fuelType,
              decoration: const InputDecoration(labelText: 'Carburant'),
              items: const [
                DropdownMenuItem(
                    value: VehicleFuelType.petrol, child: Text('Essence')),
                DropdownMenuItem(
                    value: VehicleFuelType.diesel, child: Text('Diesel')),
                DropdownMenuItem(
                    value: VehicleFuelType.electric, child: Text('Électrique')),
                DropdownMenuItem(
                    value: VehicleFuelType.hybrid, child: Text('Hybride')),
                DropdownMenuItem(
                    value: VehicleFuelType.other, child: Text('Autre')),
              ],
              onChanged: (value) => setState(() => _data.fuelType = value),
            ),
            const SizedBox(height: 14),
            _field('seats', 'Nombre de places', (value) => _data.seats = value,
                numeric: true),
          ] else ...[
            _field('engine', 'Cylindrée (cm³)',
                (value) => _data.engineCapacityCc = value,
                numeric: true),
            if (_data.vehicleType == VehicleType.tricycle)
              _field('seats', 'Nombre de places (facultatif)',
                  (value) => _data.seats = value,
                  numeric: true),
          ],
        ],
      );

  Widget _priceFields() => Column(
        children: [
          if (_data.offerType == VehicleOfferType.sale)
            _field('salePrice', 'Prix de vente (FCFA)',
                (value) => _data.salePrice = value,
                numeric: true)
          else ...[
            _field('dayPrice', 'Prix par jour (FCFA)',
                (value) => _data.rentalPricePerDay = value,
                numeric: true),
            _field('weekPrice', 'Prix par semaine (facultatif)',
                (value) => _data.rentalPricePerWeek = value,
                numeric: true),
            _field('deposit', 'Caution (facultatif)',
                (value) => _data.depositAmount = value,
                numeric: true),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _data.rentalWithDriver,
              title: const Text('Location avec chauffeur'),
              onChanged: (value) =>
                  setState(() => _data.rentalWithDriver = value ?? false),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _data.rentalWithoutDriver,
              title: const Text('Location sans chauffeur'),
              onChanged: (value) =>
                  setState(() => _data.rentalWithoutDriver = value ?? false),
            ),
          ],
        ],
      );

  Widget _descriptionFields() => Column(
        children: [
          _field('title', 'Titre de l’annonce', (value) => _data.title = value,
              maxLength: 120),
          _field('description', 'Description',
              (value) => _data.description = value,
              maxLength: 3000, maxLines: 7),
          DropdownButtonFormField<String>(
            key: const Key('listing_city'),
            initialValue: _validListingCityValue,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Ville de l’annonce',
              prefixIcon: Icon(Icons.location_city_rounded),
            ),
            items: widget.cities
                .where((city) => (city.cityId ?? city.id).isNotEmpty)
                .map(
                  (city) => DropdownMenuItem(
                    value: city.cityId ?? city.id,
                    child: Text(
                      city.name ?? city.cityId ?? city.id,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: widget.cities.isEmpty
                ? null
                : (value) {
                    if (value == null) return;
                    final city = widget.cities.firstWhere(
                      (candidate) => (candidate.cityId ?? candidate.id) == value,
                    );
                    setState(() {
                      _listingCityId = value;
                      _listingCityName = city.name ?? value;
                    });
                  },
          ),
          if (widget.cities.isEmpty)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.location_city_rounded),
              title: Text(_listingCityName),
              subtitle: const Text('Ville de l’annonce'),
            ),
        ],
      );

  Widget _mediaFields() {
    final items = _media.orderedItems;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Jusqu’à 8 photos et une vidéo de 30 secondes maximum.',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _media.imageCount >= VehicleMediaService.maxImages
                  ? null
                  : _pickImages,
              icon: const Icon(Icons.photo_library_rounded),
              label: const Text('Photos'),
            ),
            OutlinedButton.icon(
              onPressed: _media.imageCount >= VehicleMediaService.maxImages
                  ? null
                  : _takePhoto,
              icon: const Icon(Icons.photo_camera_rounded),
              label: const Text('Appareil photo'),
            ),
            OutlinedButton.icon(
              onPressed: _media.videoCount >= VehicleMediaService.maxVideos
                  ? null
                  : _pickVideo,
              icon: const Icon(Icons.videocam_rounded),
              label: const Text('Vidéo'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (items.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(Icons.image_not_supported_outlined),
              title: Text('Aucun média ajouté'),
              subtitle: Text('Vous pouvez publier sans média.'),
            ),
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            onReorderItem: (oldIndex, newIndex) {
              final imageCount = _media.imageCount;
              if (oldIndex >= imageCount || newIndex > imageCount) return;
              setState(() => _media.reorderImage(oldIndex, newIndex));
            },
            itemBuilder: (context, index) {
              final item = items[index];
              final id = item is VehicleMedia
                  ? item.id
                  : (item as PendingVehicleMedia).id;
              final type = item is VehicleMedia
                  ? item.type
                  : (item as PendingVehicleMedia).type;
              return Card(
                key: ValueKey(id),
                child: ListTile(
                  leading: SizedBox.square(
                    dimension: 54,
                    child: _mediaThumbnail(item),
                  ),
                  title:
                      Text(type == VehicleMediaType.image ? 'Photo' : 'Vidéo'),
                  subtitle: type == VehicleMediaType.image &&
                          _media.coverMediaId == id
                      ? const Text('Photo principale')
                      : null,
                  onTap: type == VehicleMediaType.image
                      ? () => setState(() => _media.setCover(id))
                      : null,
                  trailing: IconButton(
                    tooltip: 'Retirer',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => setState(() {
                      if (item is VehicleMedia) {
                        _media.removeExisting(id);
                      } else {
                        _media.removePending(id);
                        _localBytes.remove(id);
                      }
                    }),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _mediaThumbnail(Object item) {
    final type =
        item is VehicleMedia ? item.type : (item as PendingVehicleMedia).type;
    if (type == VehicleMediaType.video) {
      return const ColoredBox(
        color: Colors.black12,
        child: Icon(Icons.play_circle_fill_rounded),
      );
    }
    if (item is VehicleMedia) {
      return CachedNetworkImage(
        imageUrl: item.thumbnailUrl ?? item.downloadUrl,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => const Icon(Icons.broken_image_outlined),
      );
    }
    final bytes = _localBytes[(item as PendingVehicleMedia).id];
    return bytes == null
        ? const Icon(Icons.image_outlined)
        : Image.memory(bytes, fit: BoxFit.cover);
  }

  Future<void> _pickImages() async {
    final remaining = VehicleMediaService.maxImages - _media.imageCount;
    final files = await _picker.pickMultiImage(
      imageQuality: 80,
      maxWidth: 1600,
      maxHeight: 1600,
      limit: remaining,
    );
    await _addImages(files.take(remaining));
  }

  Future<void> _takePhoto() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
      maxWidth: 1600,
      maxHeight: 1600,
    );
    if (file != null) await _addImages([file]);
  }

  Future<void> _addImages(Iterable<XFile> files) async {
    try {
      for (final file in files) {
        final pending = PendingVehicleMedia(
          id: (_injectedMediaService ?? VehicleMediaService()).newMediaId(),
          type: VehicleMediaType.image,
          file: file,
        );
        final bytes = await file.readAsBytes();
        if (bytes.length > VehicleMediaService.maxImageBytes) {
          throw const VehicleMediaException(
              'Une photo dépasse 5 Mo après traitement.');
        }
        _media.add(pending);
        _localBytes[pending.id] = bytes;
      }
      if (mounted) setState(() {});
    } on VehicleMediaException catch (error) {
      if (mounted) _showError(error.message);
    }
  }

  Future<void> _pickVideo() async {
    final file = await _picker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(seconds: 30),
    );
    if (file == null) return;
    try {
      if (await file.length() > VehicleMediaService.maxVideoBytes) {
        throw const VehicleMediaException('Cette vidéo dépasse 20 Mo.');
      }
      final mediaService = _injectedMediaService ?? VehicleMediaService();
      setState(() => _media.add(PendingVehicleMedia(
            id: mediaService.newMediaId(),
            type: VehicleMediaType.video,
            file: file,
          )));
    } on VehicleMediaException catch (error) {
      if (mounted) _showError(error.message);
    }
  }

  void _showError(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Widget _preview() {
    final listing = _buildListing();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 160,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          child: _media.coverMediaId == null
              ? Icon(
                  listing.vehicleType == VehicleType.motorcycle
                      ? Icons.two_wheeler_rounded
                      : Icons.directions_car_rounded,
                  size: 72,
                )
              : _previewCover(),
        ),
        const SizedBox(height: 16),
        Text(listing.title,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(formatVehiclePrice(listing.price),
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: AppColors.primary, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          Chip(label: Text(vehicleOfferLabel(listing.offerType))),
          Chip(label: Text(vehicleTypeLabel(listing.vehicleType))),
          Chip(
              label: Text(listing.condition == VehicleCondition.newVehicle
                  ? 'Neuf'
                  : 'Occasion')),
          Chip(label: Text(listing.cityName)),
        ]),
        const SizedBox(height: 16),
        Text('${listing.brand} ${listing.model} • ${listing.year}'),
        if (listing.color != null) Text('Couleur : ${listing.color}'),
        if (listing.mileageKm != null)
          Text('Kilométrage : ${listing.mileageKm} km'),
        const SizedBox(height: 16),
        Text('Vendeur', style: Theme.of(context).textTheme.titleMedium),
        Text(widget.profile.sellerType == VehicleSellerType.professional
            ? widget.profile.shopName ?? widget.profile.displayName
            : widget.profile.displayName),
        const SizedBox(height: 16),
        Text(listing.description),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              'AZ Express facilite la mise en relation entre utilisateurs. '
              'Vérifiez les informations du véhicule et vos échanges avant toute transaction.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ],
    );
  }

  Widget _field(
    String key,
    String label,
    ValueChanged<String> onChanged, {
    bool numeric = false,
    int? maxLength,
    int maxLines = 1,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: TextField(
          controller: _controllers[key],
          keyboardType: numeric
              ? TextInputType.number
              : maxLines > 1
                  ? TextInputType.multiline
                  : TextInputType.text,
          maxLength: maxLength,
          maxLines: maxLines,
          decoration: InputDecoration(labelText: label),
          onChanged: onChanged,
        ),
      );

  Widget _previewCover() {
    final id = _media.coverMediaId;
    for (final item in _media.existing) {
      if (item.id == id) {
        return CachedNetworkImage(
          imageUrl: item.thumbnailUrl ?? item.downloadUrl,
          width: double.infinity,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => const Icon(Icons.broken_image_outlined),
        );
      }
    }
    final bytes = _localBytes[id];
    return bytes == null
        ? const Icon(Icons.image_outlined)
        : Image.memory(bytes, width: double.infinity, fit: BoxFit.cover);
  }

  VehicleListing _buildListing({String? listingId}) {
    final listing = _data.toListing(
      sellerId: widget.profile.ownerId,
      profile: widget.profile,
      cityId: _listingCityId,
      cityName: _listingCityName,
      original: widget.original,
    );
    return listingId == null ? listing : listing.copyWith(id: listingId);
  }

  String? get _validListingCityValue => widget.cities.any(
        (city) => (city.cityId ?? city.id) == _listingCityId,
      )
      ? _listingCityId
      : null;

  Future<void> _next() async {
    if (_step < _stepTitles.length - 1) {
      final errors = _data.validateStep(_step);
      if (errors.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(errors.first)));
        return;
      }
      setState(() => _step++);
      return;
    }
    setState(() => _saving = true);
    try {
      final repository =
          widget.saveListing == null ? VehicleListingRepository() : null;
      final listingId =
          widget.original?.id ?? repository?.newListingId() ?? 'preview-id';
      var listing = _buildListing(listingId: listingId);
      final uploaded = <VehicleMedia>[];
      final mediaService = _injectedMediaService ??
          (_media.pending.isEmpty && _media.removed.isEmpty
              ? null
              : VehicleMediaService());
      try {
        if (_media.pending.isNotEmpty) {
          final offset = _media.existing.length;
          final batch = VehicleMediaBatchUploader(
            upload: (pending, position) => mediaService.upload(
              media: pending,
              sellerId: widget.profile.ownerId,
              listingId: listingId,
              position: position,
              onProgress: (value) {
                if (mounted) {
                  setState(() => _uploadProgress =
                      (position - offset + value) / _media.pending.length);
                }
              },
            ),
            cleanup: mediaService!.cleanup,
          );
          uploaded.addAll(
            await batch.run(_media.pending, positionOffset: offset),
          );
        }
        final allMedia = <VehicleMedia>[
          ..._media.existing,
          ...uploaded,
        ];
        final byId = {for (final item in allMedia) item.id: item};
        final images = _media.imageOrder
            .map((id) => byId[id])
            .whereType<VehicleMedia>()
            .toList();
        final videos = allMedia
            .where((item) => item.type == VehicleMediaType.video)
            .toList();
        final ordered = <VehicleMedia>[
          ...images,
          ...videos,
        ]
            .indexed
            .map((entry) => entry.$2.copyWith(position: entry.$1))
            .toList();
        listing = listing.copyWith(
          media: ordered,
          coverMediaId: images.isEmpty
              ? null
              : ordered.any((item) => item.id == _media.coverMediaId)
                  ? _media.coverMediaId
                  : images.first.id,
          clearCoverMediaId: images.isEmpty,
        );
        final VehicleListingSaver saver;
        if (widget.saveListing != null) {
          saver = widget.saveListing!;
        } else {
          saver = widget.original == null
              ? repository!.createListingWithId
              : repository!.updateListing;
        }
        await saver(listing);
      } catch (_) {
        await mediaService?.cleanup(uploaded);
        rethrow;
      }
      await mediaService?.cleanup(_media.removed);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d’enregistrer l’annonce.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _back() {
    if (_step > 0) {
      setState(() => _step--);
    } else {
      Navigator.maybePop(context);
    }
  }
}

class _ChoiceGrid<T> extends StatelessWidget {
  const _ChoiceGrid({
    required this.value,
    required this.choices,
    required this.onChanged,
  });

  final T value;
  final Map<T, (String, IconData)> choices;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 10,
        runSpacing: 10,
        children: choices.entries
            .map((entry) => ChoiceChip(
                  avatar: Icon(entry.value.$2, size: 18),
                  label: Text(entry.value.$1),
                  selected: value == entry.key,
                  onSelected: (_) => onChanged(entry.key),
                ))
            .toList(),
      );
}

class _NavigationBar extends StatelessWidget {
  const _NavigationBar({
    required this.canGoBack,
    required this.saving,
    required this.isLast,
    required this.finalLabel,
    required this.onBack,
    required this.onNext,
  });

  final bool canGoBack;
  final bool saving;
  final bool isLast;
  final String finalLabel;
  final VoidCallback onBack;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => Material(
        elevation: 8,
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                if (canGoBack)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: saving ? null : onBack,
                      child: const Text('Retour'),
                    ),
                  ),
                if (canGoBack) const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: saving ? null : onNext,
                    child: saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(isLast ? finalLabel : 'Suivant'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
