import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../models/delivery_zone.dart';
import '../../providers/active_city_provider.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import '../models/vehicle_listing.dart';
import '../models/vehicle_seller_profile.dart';
import '../vehicle_media_service.dart';
import '../vehicle_seller_profile_repository.dart';
import '../vehicle_seller_profile_validator.dart';

typedef VehicleSellerProfileSaver = Future<void> Function(
  VehicleSellerProfile profile,
  bool isCreating,
);

class VehicleSellerProfileScreen extends StatefulWidget {
  const VehicleSellerProfileScreen({
    super.key,
    required this.ownerId,
    this.initialProfile,
    this.initialCityId,
    this.cities,
    this.saveProfile,
    this.imagePicker,
    this.mediaService,
  });

  final String ownerId;
  final VehicleSellerProfile? initialProfile;
  final String? initialCityId;
  final List<DeliveryZone>? cities;
  final VehicleSellerProfileSaver? saveProfile;
  final ImagePicker? imagePicker;
  final VehicleMediaService? mediaService;

  @override
  State<VehicleSellerProfileScreen> createState() =>
      _VehicleSellerProfileScreenState();
}

class _VehicleSellerProfileScreenState
    extends State<VehicleSellerProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _zone;
  late final TextEditingController _shop;
  late final TextEditingController _professionalPhone;
  late final TextEditingController _address;
  late final ImagePicker _picker;
  VehicleMediaService? _mediaInstance;

  VehicleSellerType? _sellerType;
  VehicleBusinessType? _businessType;
  VehicleLocationVisibility _visibility = VehicleLocationVisibility.hidden;
  String? _cityId;
  XFile? _pendingLogo;
  Uint8List? _pendingLogoBytes;
  bool _saving = false;
  double? _uploadProgress;

  bool get _isCreating => widget.initialProfile == null;
  bool get _isProfessional => _sellerType == VehicleSellerType.professional;

  @override
  void initState() {
    super.initState();
    final profile = widget.initialProfile;
    _sellerType = profile?.sellerType;
    _businessType = profile?.businessType;
    _visibility =
        profile?.locationVisibility ?? VehicleLocationVisibility.hidden;
    _cityId = profile?.cityId ?? widget.initialCityId;
    _name = TextEditingController(text: profile?.displayName);
    _phone = TextEditingController(text: profile?.phone);
    _zone = TextEditingController(text: profile?.zoneId);
    _shop = TextEditingController(text: profile?.shopName);
    _professionalPhone =
        TextEditingController(text: profile?.professionalPhone);
    _address = TextEditingController(text: profile?.address);
    _picker = widget.imagePicker ?? ImagePicker();
    _mediaInstance = widget.mediaService;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _zone.dispose();
    _shop.dispose();
    _professionalPhone.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cities =
        widget.cities ?? context.watch<ActiveCityProvider>().activeCities;
    return Scaffold(
      appBar: AppBar(
        title: Text(
            _isCreating ? 'Créer mon profil vendeur' : 'Mon profil vendeur'),
      ),
      body: SafeArea(
        top: false,
        child: Form(
          key: _formKey,
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (_sellerType == null)
                _sellerTypeChoice()
              else ...[
                _profileHeader(),
                const SizedBox(height: 20),
                _sectionTitle('Informations vendeur'),
                const SizedBox(height: 10),
                TextFormField(
                  key: const Key('seller_display_name'),
                  controller: _name,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText:
                        _isProfessional ? 'Nom du responsable' : 'Nom affiché',
                    prefixIcon: const Icon(Icons.person_outline_rounded),
                  ),
                  validator: (value) =>
                      _requiredLength(value, 2, 100, 'Nom requis'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('seller_phone'),
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Téléphone',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                  validator: _validatePhone,
                ),
                if (_isProfessional) ..._professionalFields(),
                const SizedBox(height: 12),
                _sectionTitle('Localisation'),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  key: const Key('seller_city'),
                  initialValue: _validCityValue(cities),
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Ville',
                    prefixIcon: Icon(Icons.location_city_rounded),
                  ),
                  items: cities
                      .where((city) => (city.cityId ?? city.id).isNotEmpty)
                      .map((city) => DropdownMenuItem(
                            value: city.cityId ?? city.id,
                            child: Text(
                              city.name ?? city.cityId ?? city.id,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ))
                      .toList(),
                  onChanged: (value) => setState(() => _cityId = value),
                  validator: (value) => value == null ? 'Ville requise' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('seller_zone'),
                  controller: _zone,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Quartier / zone (facultatif)',
                    prefixIcon: Icon(Icons.place_outlined),
                  ),
                  maxLength: 100,
                ),
                if (_isProfessional) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('seller_address'),
                    controller: _address,
                    decoration: const InputDecoration(
                      labelText: 'Adresse descriptive',
                      hintText: 'Ex. près du marché central',
                      prefixIcon: Icon(Icons.store_mall_directory_outlined),
                    ),
                    maxLength: 300,
                    validator: (value) =>
                        _requiredLength(value, 2, 300, 'Adresse requise'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<VehicleLocationVisibility>(
                    key: const Key('seller_visibility'),
                    initialValue: _visibility,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Localisation publique',
                      prefixIcon: Icon(Icons.visibility_outlined),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: VehicleLocationVisibility.exact,
                        child: Text(
                          'Exacte : ville, quartier et adresse',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: VehicleLocationVisibility.approximate,
                        child: Text(
                          'Approximative : ville et quartier',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: VehicleLocationVisibility.hidden,
                        child: Text(
                          'Masquée : ville uniquement',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _visibility = value ?? _visibility),
                  ),
                ],
                const SizedBox(height: 22),
                FilledButton.icon(
                  key: const Key('save_seller_profile'),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(_uploadProgress == null
                      ? 'Enregistrer le profil'
                      : 'Logo ${(_uploadProgress! * 100).round()} %'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String value) => Text(
        value,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
      );

  Widget _sellerTypeChoice() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Vous vendez en tant que :',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  )),
          const SizedBox(height: 18),
          _TypeCard(
            key: const Key('choose_individual'),
            icon: Icons.person_rounded,
            title: 'Particulier',
            subtitle: 'Je vends ou loue mes propres véhicules.',
            onTap: () =>
                setState(() => _sellerType = VehicleSellerType.individual),
          ),
          const SizedBox(height: 12),
          _TypeCard(
            key: const Key('choose_professional'),
            icon: Icons.storefront_rounded,
            title: 'Professionnel',
            subtitle:
                'Je représente un magasin, garage, concessionnaire ou une activité professionnelle.',
            onTap: () =>
                setState(() => _sellerType = VehicleSellerType.professional),
          ),
        ],
      );

  Widget _profileHeader() => Row(
        children: [
          Expanded(
            child: Text(
              _isProfessional ? 'Profil professionnel' : 'Profil particulier',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          if (_isCreating)
            TextButton(
              onPressed: () => setState(() => _sellerType = null),
              child: const Text('Changer'),
            ),
        ],
      );

  List<Widget> _professionalFields() => [
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('seller_shop_name'),
          controller: _shop,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Nom du magasin / entreprise',
            prefixIcon: Icon(Icons.store_outlined),
          ),
          validator: (value) =>
              _requiredLength(value, 2, 120, 'Magasin requis'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<VehicleBusinessType>(
          key: const Key('seller_business_type'),
          initialValue: _businessType,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Type d’activité',
            prefixIcon: Icon(Icons.business_center_outlined),
          ),
          items: VehicleBusinessType.values
              .where((type) => type != VehicleBusinessType.unknown)
              .map((type) => DropdownMenuItem(
                    value: type,
                    child: Text(
                      _businessLabel(type),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ))
              .toList(),
          onChanged: (value) => setState(() => _businessType = value),
          validator: (value) => value == null ? 'Activité requise' : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('seller_professional_phone'),
          controller: _professionalPhone,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Téléphone professionnel',
            prefixIcon: Icon(Icons.phone_in_talk_outlined),
          ),
          validator: _validatePhone,
        ),
        const SizedBox(height: 14),
        _logoPicker(),
      ];

  Widget _logoPicker() {
    final currentUrl = widget.initialProfile?.logoUrl;
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox.square(
            dimension: 72,
            child: _pendingLogoBytes != null
                ? Image.memory(_pendingLogoBytes!, fit: BoxFit.cover)
                : currentUrl != null
                    ? CachedNetworkImage(
                        imageUrl: currentUrl, fit: BoxFit.cover)
                    : ColoredBox(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: const Icon(Icons.storefront_rounded),
                      ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('pick_seller_logo'),
            onPressed: _pickLogo,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Choisir un logo'),
          ),
        ),
      ],
    );
  }

  Future<void> _pickLogo() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1000,
      maxHeight: 1000,
      imageQuality: 80,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    if (bytes.length > VehicleMediaService.maxSellerLogoBytes) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Le logo dépasse 2 Mo après traitement.')),
      );
      return;
    }
    setState(() {
      _pendingLogo = file;
      _pendingLogoBytes = bytes;
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    String? uploadedPath;
    try {
      final initial = widget.initialProfile;
      String? logoUrl = initial?.logoUrl;
      String? logoPath = initial?.logoStoragePath;
      if (_isProfessional && _pendingLogo != null) {
        final uploaded = await _media.uploadSellerLogo(
          file: _pendingLogo!,
          ownerId: widget.ownerId,
          mediaId: _media.newMediaId(),
          onProgress: (value) {
            if (mounted) setState(() => _uploadProgress = value);
          },
        );
        logoUrl = uploaded.downloadUrl;
        logoPath = uploaded.storagePath;
        uploadedPath = uploaded.storagePath;
      }
      final professional = _isProfessional;
      final profile = VehicleSellerProfile(
        ownerId: widget.ownerId,
        sellerType: _sellerType!,
        displayName: _name.text.trim(),
        phone: AuthService.toE164(_phone.text),
        cityId: _cityId!,
        zoneId: _normalizedZone,
        shopName: professional ? _shop.text.trim() : null,
        businessType: professional ? _businessType : null,
        professionalPhone:
            professional ? AuthService.toE164(_professionalPhone.text) : null,
        address: professional ? _address.text.trim() : null,
        locationVisibility: professional ? _visibility : null,
        logoUrl: professional ? logoUrl : null,
        logoStoragePath: professional ? logoPath : null,
        description: initial?.description,
        openingHours: initial?.openingHours,
        verificationStatus: initial?.verificationStatus ??
            VehicleSellerVerificationStatus.unverified,
        createdAt: initial?.createdAt,
        updatedAt: initial?.updatedAt,
      );
      VehicleSellerProfileValidator.validateOrThrow(profile);
      final saver = widget.saveProfile ?? _defaultSave;
      await saver(profile, _isCreating);
      final oldLogo = initial?.logoStoragePath;
      if (oldLogo != null && uploadedPath != null && oldLogo != uploadedPath) {
        try {
          await _media.deleteSellerLogo(oldLogo, widget.ownerId);
        } catch (_) {}
      }
      if (mounted) Navigator.pop(context, profile);
    } catch (error) {
      if (uploadedPath != null) {
        try {
          await _media.deleteSellerLogo(uploadedPath, widget.ownerId);
        } catch (_) {}
      }
      if (!mounted) return;
      final message = error is VehicleSellerProfileValidationException
          ? error.errors.first
          : error is VehicleMediaException
              ? error.message
              : 'Impossible d’enregistrer le profil. Réessayez.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _uploadProgress = null;
        });
      }
    }
  }

  Future<void> _defaultSave(VehicleSellerProfile profile, bool creating) =>
      creating
          ? VehicleSellerProfileRepository().createSellerProfile(profile)
          : VehicleSellerProfileRepository().updateSellerProfile(profile);

  VehicleMediaService get _media => _mediaInstance ??= VehicleMediaService();

  String? get _normalizedZone {
    final value = _zone.text.trim().toLowerCase();
    if (value.isEmpty) return null;
    return value
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  String? _validCityValue(List<DeliveryZone> cities) {
    return cities.any((city) => (city.cityId ?? city.id) == _cityId)
        ? _cityId
        : null;
  }

  String? _validatePhone(String? value) =>
      value == null || !AuthService.isValidPhone(value)
          ? 'Téléphone invalide'
          : null;

  String? _requiredLength(
      String? value, int min, int max, String emptyMessage) {
    final length = value?.trim().length ?? 0;
    if (length == 0) return emptyMessage;
    if (length < min || length > max) return 'Entre $min et $max caractères';
    return null;
  }
}

String vehicleBusinessLabel(VehicleBusinessType type) => _businessLabel(type);

String _businessLabel(VehicleBusinessType type) => switch (type) {
      VehicleBusinessType.dealership => 'Concessionnaire automobile',
      VehicleBusinessType.garage => 'Garage',
      VehicleBusinessType.motorcycleShop => 'Vente de motos',
      VehicleBusinessType.vehicleRental => 'Location de véhicules',
      VehicleBusinessType.other => 'Autre',
      VehicleBusinessType.unknown => 'Activité non renseignée',
    };

class _TypeCard extends StatelessWidget {
  const _TypeCard(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              Icon(icon, size: 34, color: AppColors.primary),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(title,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(subtitle),
                  ])),
              const Icon(Icons.chevron_right_rounded),
            ]),
          ),
        ),
      );
}
