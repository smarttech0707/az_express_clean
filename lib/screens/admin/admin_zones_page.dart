import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/delivery_zone.dart';
import '../../models/delivery_zone_form.dart';
import '../../theme/app_theme.dart';

class AdminZonesPage extends StatefulWidget {
  const AdminZonesPage({super.key});

  @override
  State<AdminZonesPage> createState() => _AdminZonesPageState();
}

class _AdminZonesPageState extends State<AdminZonesPage>
    with SingleTickerProviderStateMixin {
  static const _tabs = ['Tout', 'Villes', 'Quartiers', 'Villages', 'Secteurs'];
  static const _types = ['', 'ville', 'quartier', 'village', 'secteur'];

  late final TabController _tabController;
  CollectionReference<Map<String, dynamic>> get _zones =>
      FirebaseFirestore.instance.collection('zones_livraison');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<Position?> _captureGps() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) _snack('Permission GPS refusée.', Colors.red);
      return null;
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
  }

  Future<LatLng?> _pickOnMap(LatLng? initial) {
    return showDialog<LatLng>(
      context: context,
      builder: (context) => _MapPointDialog(initial: initial),
    );
  }

  Future<void> _openForm(
      [DocumentSnapshot<Map<String, dynamic>>? document]) async {
    final snapshot = await _zones.get();
    if (!mounted) return;
    final allZones = snapshot.docs
        .map((doc) => DeliveryZone.fromMap(doc.id, doc.data()))
        .toList(growable: false);
    final cities = allZones.where((zone) => zone.type == 'ville').toList();
    final zone = document == null
        ? null
        : DeliveryZone.fromMap(document.id, document.data()!);

    final nameController = TextEditingController(text: zone?.name ?? '');
    final cityIdController = TextEditingController(text: zone?.cityId ?? '');
    final aliasController = TextEditingController();
    final latController = TextEditingController(text: _number(zone?.lat));
    final lngController = TextEditingController(text: _number(zone?.lng));
    final radiusController =
        TextEditingController(text: _number(zone?.radiusKm));
    final orderController =
        TextEditingController(text: zone?.order?.toInt().toString() ?? '0');
    var type = zone?.type ?? 'ville';
    var parentZoneId = zone?.parentZoneId;
    var aliases = [...?zone?.aliases];
    var isServiceable = zone?.isServiceable ?? false;
    var isActive = zone?.isActive ?? true;
    var cityIdWasEdited = zone != null;
    var gpsLoading = false;

    nameController.addListener(() {
      if (!cityIdWasEdited) {
        cityIdController.text =
            DeliveryZoneFormData.cityIdFromName(nameController.text);
      }
    });

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(zone == null ? 'Nouvelle zone' : 'Modifier la zone'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _field(nameController, 'Nom *'),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(
                      labelText: 'Type *',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'ville', child: Text('Ville')),
                      DropdownMenuItem(
                          value: 'quartier', child: Text('Quartier')),
                      DropdownMenuItem(
                          value: 'village', child: Text('Village')),
                      DropdownMenuItem(
                          value: 'secteur', child: Text('Secteur')),
                    ],
                    onChanged: (value) => setDialogState(() {
                      type = value ?? type;
                      if (type == 'ville') {
                        parentZoneId = null;
                        cityIdController.text =
                            DeliveryZoneFormData.cityIdFromName(
                                nameController.text);
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: cityIdController,
                    decoration: const InputDecoration(
                      labelText: 'cityId *',
                      helperText: 'Généré depuis le nom, puis modifiable.',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => cityIdWasEdited = true,
                  ),
                  if (type != 'ville') ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: cities.any((c) => c.id == parentZoneId)
                          ? parentZoneId
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Ville parente *',
                        border: OutlineInputBorder(),
                      ),
                      items: cities
                          .map((city) => DropdownMenuItem(
                                value: city.id,
                                child: Text(city.name ?? city.id),
                              ))
                          .toList(),
                      onChanged: (value) => setDialogState(() {
                        parentZoneId = value;
                        final parent = cities
                            .where((city) => city.id == value)
                            .firstOrNull;
                        if (parent?.cityId != null) {
                          cityIdController.text = parent!.cityId!;
                        }
                      }),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _aliasesEditor(
                    aliasController,
                    aliases,
                    () => setDialogState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                        child:
                            _field(latController, 'Latitude', decimal: true)),
                    const SizedBox(width: 10),
                    Expanded(
                        child:
                            _field(lngController, 'Longitude', decimal: true)),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: gpsLoading
                            ? null
                            : () async {
                                setDialogState(() => gpsLoading = true);
                                final position = await _captureGps();
                                if (!dialogContext.mounted) return;
                                setDialogState(() {
                                  gpsLoading = false;
                                  if (position != null) {
                                    latController.text =
                                        position.latitude.toString();
                                    lngController.text =
                                        position.longitude.toString();
                                  }
                                });
                              },
                        icon: gpsLoading
                            ? const SizedBox.square(
                                dimension: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.my_location),
                        label: const Text('Capturer le GPS'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final point = await _pickOnMap(_pointFromControllers(
                              latController, lngController));
                          if (point != null && dialogContext.mounted) {
                            setDialogState(() {
                              latController.text = point.latitude.toString();
                              lngController.text = point.longitude.toString();
                            });
                          }
                        },
                        icon: const Icon(Icons.map_outlined),
                        label: const Text('Choisir sur carte'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child:
                          _field(radiusController, 'Rayon (km)', decimal: true),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: _field(orderController, 'Ordre')),
                  ]),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Zone desservie'),
                    subtitle: const Text(
                        'Exige latitude, longitude et rayon supérieur à 0.'),
                    value: isServiceable,
                    onChanged: (value) {
                      if (value &&
                          !_hasGeometry(
                              latController, lngController, radiusController)) {
                        _dialogSnack(dialogContext,
                            'Renseignez un point propre et un rayon supérieur à 0.');
                        return;
                      }
                      setDialogState(() => isServiceable = value);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Zone active'),
                    value: isActive,
                    onChanged: (value) =>
                        setDialogState(() => isActive = value),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () async {
                final form = DeliveryZoneFormData(
                  name: nameController.text,
                  type: type,
                  cityId: cityIdController.text.trim(),
                  parentZoneId: parentZoneId,
                  aliases: aliases,
                  lat: _parseDouble(latController.text),
                  lng: _parseDouble(lngController.text),
                  radiusKm: _parseDouble(radiusController.text),
                  isServiceable: isServiceable,
                  isActive: isActive,
                  order: int.tryParse(orderController.text.trim()) ?? 0,
                );
                final otherCityIds = cities
                    .where((city) => city.id != zone?.id)
                    .map((city) => city.cityId)
                    .whereType<String>();
                final error = form.validate(existingCityIds: otherCityIds);
                if (error != null) {
                  _dialogSnack(dialogContext, error);
                  return;
                }
                final payload = form.toMap()
                  ..['updatedAt'] = FieldValue.serverTimestamp();
                if (zone != null) {
                  if (form.type == 'ville') {
                    payload['parentZoneId'] = FieldValue.delete();
                  }
                  if (form.lat == null) payload['lat'] = FieldValue.delete();
                  if (form.lng == null) payload['lng'] = FieldValue.delete();
                  if (form.radiusKm == null) {
                    payload['radiusKm'] = FieldValue.delete();
                  }
                }
                if (zone == null) {
                  payload['createdAt'] = FieldValue.serverTimestamp();
                  await _zones.add(payload);
                } else {
                  await document!.reference
                      .set(payload, SetOptions(merge: true));
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: Text(zone == null ? 'Ajouter' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );

    nameController.dispose();
    cityIdController.dispose();
    aliasController.dispose();
    latController.dispose();
    lngController.dispose();
    radiusController.dispose();
    orderController.dispose();
  }

  Future<void> _delete(DocumentSnapshot<Map<String, dynamic>> document) async {
    final zone = DeliveryZone.fromMap(document.id, document.data()!);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer la zone ?'),
        content: Text('Supprimer « ${zone.name ?? zone.id} » ?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Supprimer')),
        ],
      ),
    );
    if (confirmed == true) await document.reference.delete();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: const Text('Gestion géographique'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: _tabs.map((label) => Tab(text: label)).toList(),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: List.generate(
          _types.length,
          (index) => _ZonesList(
            type: _types[index],
            onEdit: _openForm,
            onDelete: _delete,
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        onPressed: _openForm,
        icon: const Icon(Icons.add_location_alt),
        label: const Text('Ajouter une zone'),
      ),
    );
  }

  Widget _field(TextEditingController controller, String label,
      {bool decimal = false}) {
    return TextField(
      controller: controller,
      keyboardType: decimal
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration:
          InputDecoration(labelText: label, border: const OutlineInputBorder()),
    );
  }

  Widget _aliasesEditor(TextEditingController controller, List<String> aliases,
      VoidCallback refresh) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: 'Alias',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty && !aliases.contains(value)) {
                aliases.add(value);
              }
              controller.clear();
              refresh();
            },
          ),
        ),
        onSubmitted: (value) {
          final alias = value.trim();
          if (alias.isNotEmpty && !aliases.contains(alias)) {
            aliases.add(alias);
          }
          controller.clear();
          refresh();
        },
      ),
      if (aliases.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          children: aliases
              .map((alias) => InputChip(
                    label: Text(alias),
                    onDeleted: () {
                      aliases.remove(alias);
                      refresh();
                    },
                  ))
              .toList(),
        ),
      ],
    ]);
  }

  static bool _hasGeometry(TextEditingController lat, TextEditingController lng,
      TextEditingController radius) {
    return _parseDouble(lat.text) != null &&
        _parseDouble(lng.text) != null &&
        (_parseDouble(radius.text) ?? 0) > 0;
  }

  static LatLng? _pointFromControllers(
      TextEditingController lat, TextEditingController lng) {
    final latitude = _parseDouble(lat.text);
    final longitude = _parseDouble(lng.text);
    return latitude == null || longitude == null
        ? null
        : LatLng(latitude, longitude);
  }

  static double? _parseDouble(String text) => text.trim().isEmpty
      ? null
      : double.tryParse(text.trim().replaceAll(',', '.'));

  static String _number(num? value) => value?.toString() ?? '';

  void _snack(String message, Color color) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  static void _dialogSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }
}

class _ZonesList extends StatelessWidget {
  final String type;
  final Future<void> Function(DocumentSnapshot<Map<String, dynamic>>?) onEdit;
  final Future<void> Function(DocumentSnapshot<Map<String, dynamic>>) onDelete;

  const _ZonesList({
    required this.type,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> query = FirebaseFirestore.instance
        .collection('zones_livraison')
        .orderBy('order')
        .orderBy('name');
    if (type.isNotEmpty) query = query.where('type', isEqualTo: type);
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final documents = snapshot.data?.docs ?? const [];
        if (documents.isEmpty) {
          return const Center(child: Text('Aucune zone définie.'));
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
          itemCount: documents.length,
          itemBuilder: (context, index) {
            final document = documents[index];
            final zone = DeliveryZone.fromMap(document.id, document.data());
            return Card(
              child: ListTile(
                leading: Icon(zone.type == 'ville'
                    ? Icons.location_city
                    : Icons.place_outlined),
                title: Text(zone.name ?? zone.id),
                subtitle: Text([
                  zone.type,
                  zone.cityId,
                  if (zone.isServiceable) 'desservie',
                  if (zone.isActive == false) 'inactive',
                ].whereType<String>().join(' · ')),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') onEdit(document);
                    if (value == 'delete') onDelete(document);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('Modifier')),
                    PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _MapPointDialog extends StatefulWidget {
  final LatLng? initial;

  const _MapPointDialog({required this.initial});

  @override
  State<_MapPointDialog> createState() => _MapPointDialogState();
}

class _MapPointDialogState extends State<_MapPointDialog> {
  static const _abengourou = LatLng(6.7273, -3.4961);
  late LatLng _selected = widget.initial ?? _abengourou;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 640,
        height: 560,
        child: Column(children: [
          const ListTile(
            title: Text('Choisir le point propre de la zone'),
            subtitle: Text('Touchez la carte pour placer le repère.'),
          ),
          Expanded(
            child: GoogleMap(
              initialCameraPosition:
                  CameraPosition(target: _selected, zoom: 14),
              markers: {
                Marker(markerId: const MarkerId('zone'), position: _selected),
              },
              onTap: (point) => setState(() => _selected = point),
              mapToolbarEnabled: false,
            ),
          ),
          OverflowBar(children: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Annuler')),
            FilledButton(
                onPressed: () => Navigator.pop(context, _selected),
                child: const Text('Utiliser ce point')),
          ]),
        ]),
      ),
    );
  }
}
