import 'dart:async';
import 'dart:io';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'admin_service_requests_page.dart';
import '../../utils/storage_cleanup.dart';

// ── DONNÉES STATIQUES (miroir de services_hub_page) ───────────

const _subcatOptions = [
  {"id": "location", "label": "Location de maison", "cat": "immobilier"},
  {"id": "vente_maison", "label": "Vente de maison", "cat": "immobilier"},
  {"id": "local_commercial", "label": "Local commercial", "cat": "immobilier"},
  {"id": "terrain", "label": "Terrain", "cat": "immobilier"},
  {"id": "macon", "label": "Maçon", "cat": "artisan"},
  {"id": "plombier", "label": "Plombier", "cat": "artisan"},
  {"id": "electricien", "label": "Électricien", "cat": "artisan"},
  {"id": "ferronnier", "label": "Ferronnier", "cat": "artisan"},
  {"id": "menuisier", "label": "Menuisier", "cat": "artisan"},
  {"id": "carreleur", "label": "Carreleur", "cat": "artisan"},
  {"id": "peintre", "label": "Peintre", "cat": "artisan"},
  {"id": "decoration", "label": "Décoration intérieure", "cat": "artisan"},
  {
    "id": "reparateur_portable",
    "label": "Réparateur portable",
    "cat": "artisan"
  },
  {"id": "vitrier", "label": "Vitrier", "cat": "artisan"},
  {"id": "reparateur_tv", "label": "Réparateur TV", "cat": "artisan"},
  {
    "id": "installation_camera",
    "label": "Installation Caméra",
    "cat": "artisan"
  },
  {
    "id": "salon_coiffure_homme",
    "label": "Salon coiffure homme",
    "cat": "artisan"
  },
  {"id": "barber_shop", "label": "Barber Shop", "cat": "artisan"},
  {
    "id": "salon_coiffure_femme",
    "label": "Salon coiffure femme",
    "cat": "artisan"
  },
  {"id": "onglerie", "label": "Onglerie", "cat": "artisan"},
  {
    "id": "mecanicien_voiture",
    "label": "Mécanicien Voiture",
    "cat": "mecanique"
  },
  {"id": "mecanicien_moto", "label": "Mécanicien Moto", "cat": "mecanique"},
  {"id": "electrique_auto", "label": "Électrique Auto", "cat": "mecanique"},
  {"id": "carrosserie", "label": "Carrosserie", "cat": "mecanique"},
  {"id": "eau_pack", "label": "Eau en pack", "cat": "construction"},
  {"id": "ciment_briques", "label": "Ciment & Briques", "cat": "construction"},
  {"id": "telephone", "label": "Téléphones portables", "cat": "telephonie"},
  {"id": "accessoires", "label": "Accessoires téléphonie", "cat": "telephonie"},
  // Cave & Boissons
  {"id": "cave_vins", "label": "Vins & Spiritueux", "cat": "cave"},
  {"id": "cave_bieres", "label": "Bières", "cat": "cave"},
  {"id": "cave_sans_alcool", "label": "Boissons sans alcool", "cat": "cave"},
];

String _labelForSubcat(String id) {
  return _subcatOptions.firstWhere((s) => s["id"] == id,
      orElse: () => {"label": id})["label"]!;
}

// ── PAGE PRINCIPALE ADMIN ─────────────────────────────────────

class AdminServicesPage extends StatefulWidget {
  const AdminServicesPage({super.key});

  @override
  State<AdminServicesPage> createState() => _AdminServicesPageState();
}

class _AdminServicesPageState extends State<AdminServicesPage> {
  String _filterSubcat = "tous";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      body: CustomScrollView(
        slivers: [
          // AppBar
          SliverAppBar(
            expandedHeight: 130,
            pinned: true,
            backgroundColor: const Color(0xFF1565C0),
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF0D47A1), Color(0xFF1976D2)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const SafeArea(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20, 52, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Services Locaux",
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold),
                        ),
                        Text(
                          "Gérer les prestataires",
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: const Text("Services Locaux",
                style: TextStyle(color: Colors.white)),
            centerTitle: true,
            actions: [
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('service_providers')
                    .where('status', isEqualTo: 'pending')
                    .snapshots(),
                builder: (ctx, snap) {
                  final count = snap.data?.docs.length ?? 0;
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.inbox_rounded,
                            color: Colors.white),
                        tooltip: 'Demandes prestataires',
                        onPressed: () => Navigator.push(
                          ctx,
                          MaterialPageRoute(
                              builder: (_) => const AdminServiceRequestsPage()),
                        ),
                      ),
                      if (count > 0)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: const BoxDecoration(
                                color: Colors.red, shape: BoxShape.circle),
                            child: Center(
                              child: Text(
                                '$count',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),

          // Filtre par sous-catégorie
          SliverToBoxAdapter(
            child: SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                children: [
                  _FilterChip(
                    label: "Tous",
                    selected: _filterSubcat == "tous",
                    onTap: () => setState(() => _filterSubcat = "tous"),
                  ),
                  ..._subcatOptions.map((s) => _FilterChip(
                        label: s["label"]!,
                        selected: _filterSubcat == s["id"],
                        onTap: () => setState(() => _filterSubcat = s["id"]!),
                      )),
                ],
              ),
            ),
          ),

          // Liste
          StreamBuilder<QuerySnapshot>(
            stream: _filterSubcat == "tous"
                ? FirebaseFirestore.instance
                    .collection("service_providers")
                    .orderBy("createdAt", descending: true)
                    .snapshots()
                : FirebaseFirestore.instance
                    .collection("service_providers")
                    .where("subcategory", isEqualTo: _filterSubcat)
                    .orderBy("createdAt", descending: true)
                    .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              final docs = snap.data?.docs ?? [];

              if (docs.isEmpty) {
                return SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.storefront_outlined,
                            size: 64, color: Colors.grey),
                        const SizedBox(height: 12),
                        const Text("Aucun prestataire",
                            style: TextStyle(color: Colors.grey)),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: () => _openForm(context),
                          icon: const Icon(Icons.add, color: Colors.white),
                          label: const Text("Ajouter",
                              style: TextStyle(color: Colors.white)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1565C0),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final doc = docs[i];
                      final data = doc.data() as Map<String, dynamic>;
                      return _AdminProviderCard(
                        docId: doc.id,
                        data: data,
                        onEdit: () =>
                            _openForm(context, docId: doc.id, data: data),
                        onDelete: () => _confirmDelete(
                            context,
                            doc.id,
                            data["name"] ?? "",
                            (data["photos"] as List?)?.cast<String>() ??
                                const []),
                        onToggle: () => _toggleAvailability(
                            doc.id, data["isAvailable"] ?? true),
                      );
                    },
                    childCount: docs.length,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(context),
        backgroundColor: const Color(0xFF1565C0),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text("Ajouter",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Future<void> _toggleAvailability(String docId, bool current) async {
    try {
      await FirebaseFirestore.instance
          .collection("service_providers")
          .doc(docId)
          .update({"isAvailable": !current});
    } catch (_) {}
  }

  Future<void> _confirmDelete(BuildContext context, String docId, String name,
      [List<String> photos = const []]) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("Supprimer"),
        content: Text("Supprimer \"$name\" ? Cette action est irréversible."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Annuler")),
          ScaleButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Supprimer"),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await FirebaseFirestore.instance
            .collection("service_providers")
            .doc(docId)
            .delete();
        await deleteStorageUrls(photos);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Prestataire supprimé"),
                backgroundColor: Colors.red),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Erreur : $e"), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  void _openForm(BuildContext context,
      {String? docId, Map<String, dynamic>? data}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ServiceProviderForm(docId: docId, existing: data),
      ),
    );
  }
}

// ── CARTE ADMIN ───────────────────────────────────────────────

class _AdminProviderCard extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> data;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onToggle;

  const _AdminProviderCard({
    required this.docId,
    required this.data,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final name = data["name"] ?? "Sans nom";
    final phone = data["phone"] ?? "";
    final address = data["address"] ?? "";
    final subcat = data["subcategory"] ?? "";
    final isAvailable = data["isAvailable"] ?? true;
    final photos = (data["photos"] as List?)?.cast<String>() ?? [];
    final hasGps = (data["lat"] ?? 0) != 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Mini photo
          if (photos.isNotEmpty)
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              child: SizedBox(
                height: 110,
                width: double.infinity,
                child: Image.network(photos.first,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                        height: 110,
                        color: Colors.grey.shade100,
                        child: const Icon(Icons.broken_image,
                            color: Colors.grey))),
              ),
            ),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(name,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                    ),
                    // Toggle disponibilité
                    GestureDetector(
                      onTap: onToggle,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isAvailable
                              ? Colors.green.shade50
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isAvailable ? Colors.green : Colors.grey,
                          ),
                        ),
                        child: Text(
                          isAvailable ? "Actif" : "Masqué",
                          style: TextStyle(
                            color: isAvailable ? Colors.green : Colors.grey,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 6),

                // Sous-catégorie badge
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1565C0).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _labelForSubcat(subcat),
                    style: const TextStyle(
                        color: Color(0xFF1565C0),
                        fontSize: 11,
                        fontWeight: FontWeight.w600),
                  ),
                ),

                const SizedBox(height: 8),

                if (phone.isNotEmpty)
                  Row(
                    children: [
                      const Icon(Icons.phone, size: 13, color: Colors.grey),
                      const SizedBox(width: 4),
                      Text(phone,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ],
                  ),

                if (address.isNotEmpty)
                  Row(
                    children: [
                      const Icon(Icons.location_on,
                          size: 13, color: Colors.grey),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(address,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),

                if (hasGps)
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Icon(Icons.gps_fixed, size: 13, color: Colors.green),
                        SizedBox(width: 4),
                        Text("GPS enregistré",
                            style:
                                TextStyle(fontSize: 11, color: Colors.green)),
                      ],
                    ),
                  ),

                const SizedBox(height: 12),

                // Actions
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onEdit,
                        icon: const Icon(Icons.edit, size: 14),
                        label: const Text("Modifier"),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF1565C0),
                          side: const BorderSide(color: Color(0xFF1565C0)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onDelete,
                        icon: const Icon(Icons.delete_outline, size: 14),
                        label: const Text("Supprimer"),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── FILTRE CHIP ───────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1565C0) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? const Color(0xFF1565C0) : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.black87,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

// ── FORMULAIRE AJOUT / MODIFICATION ──────────────────────────

class _ServiceProviderForm extends StatefulWidget {
  final String? docId;
  final Map<String, dynamic>? existing;

  const _ServiceProviderForm({this.docId, this.existing});

  @override
  State<_ServiceProviderForm> createState() => _ServiceProviderFormState();
}

class _ServiceProviderFormState extends State<_ServiceProviderForm> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();
  final _idNumberCtrl = TextEditingController();
  final _artisanPinCtrl = TextEditingController();

  String _subcategory = _subcatOptions.first["id"]!;
  List<String> _photos = [];
  final List<String> _removedPhotos = [];
  final List<File> _newPhotoFiles = [];
  File? _idPhotoFile;
  String? _existingIdPhotoUrl;
  bool _isAvailable = true;
  bool _loading = false;
  bool _gpsLoading = false;

  @override
  void initState() {
    super.initState();
    final d = widget.existing;
    if (d != null) {
      _nameCtrl.text = d["name"] ?? "";
      _phoneCtrl.text = d["phone"] ?? "";
      _addressCtrl.text = d["address"] ?? "";
      _descCtrl.text = d["description"] ?? "";
      _subcategory = d["subcategory"] ?? _subcatOptions.first["id"]!;
      _photos = (d["photos"] as List?)?.cast<String>() ?? [];
      final lat = (d["lat"] as num?)?.toDouble() ?? 0.0;
      final lng = (d["lng"] as num?)?.toDouble() ?? 0.0;
      if (lat != 0.0) _latCtrl.text = lat.toString();
      if (lng != 0.0) _lngCtrl.text = lng.toString();
      _isAvailable = d["isAvailable"] ?? true;
      _idNumberCtrl.text = d["idNumber"] ?? "";
      _existingIdPhotoUrl = d["idPhotoUrl"];
      _artisanPinCtrl.text = d["artisanPin"] ?? "";
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _descCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    _idNumberCtrl.dispose();
    _artisanPinCtrl.dispose();
    super.dispose();
  }

  Future<void> _getGps() async {
    setState(() => _gpsLoading = true);
    try {
      await Geolocator.requestPermission();
      final pos = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high));
      setState(() {
        _latCtrl.text = pos.latitude.toStringAsFixed(7);
        _lngCtrl.text = pos.longitude.toStringAsFixed(7);
      });
      _snack("Position capturée automatiquement", Colors.green);
    } catch (e) {
      _snack("Erreur GPS : $e", Colors.red);
    }
    setState(() => _gpsLoading = false);
  }

  Future<void> _pickPhoto(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 75);
    if (picked != null) {
      setState(() => _newPhotoFiles.add(File(picked.path)));
    }
  }

  void _showPhotoSourceDialog() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Color(0xFF1565C0)),
              title: const Text("Prendre une photo"),
              onTap: () {
                Navigator.pop(context);
                _pickPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, color: Color(0xFF1565C0)),
              title: const Text("Choisir depuis la galerie"),
              onTap: () {
                Navigator.pop(context);
                _pickPhoto(ImageSource.gallery);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickIdPhoto(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 80);
    if (picked != null) setState(() => _idPhotoFile = File(picked.path));
  }

  void _showIdPhotoSourceDialog() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Color(0xFF1565C0)),
              title: const Text("Photographier la pièce d'identité"),
              onTap: () {
                Navigator.pop(context);
                _pickIdPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, color: Color(0xFF1565C0)),
              title: const Text("Importer depuis la galerie"),
              onTap: () {
                Navigator.pop(context);
                _pickIdPhoto(ImageSource.gallery);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<List<String>> _uploadNewPhotos(String docId) async {
    final uploaded = <String>[..._photos];
    for (int i = 0; i < _newPhotoFiles.length; i++) {
      try {
        final ref = FirebaseStorage.instance.ref(
            "service_providers/$docId/photo_${DateTime.now().millisecondsSinceEpoch}_$i.jpg");
        await ref.putFile(_newPhotoFiles[i]);
        uploaded.add(await ref.getDownloadURL());
      } catch (_) {}
    }
    return uploaded;
  }

  Future<String?> _uploadIdPhoto(String docId) async {
    if (_idPhotoFile == null) return _existingIdPhotoUrl;
    try {
      final ref =
          FirebaseStorage.instance.ref("service_providers/$docId/id_photo.jpg");
      await ref.putFile(_idPhotoFile!);
      return await ref.getDownloadURL();
    } catch (_) {}
    return _existingIdPhotoUrl;
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      _snack("Le nom est obligatoire", Colors.orange);
      return;
    }
    if (_phoneCtrl.text.trim().isEmpty) {
      _snack("Le numéro de téléphone est obligatoire", Colors.orange);
      return;
    }

    setState(() => _loading = true);

    final catEntry = _subcatOptions.firstWhere((s) => s["id"] == _subcategory);
    final category = catEntry["cat"]!;

    final docId = widget.docId ??
        FirebaseFirestore.instance.collection("service_providers").doc().id;

    final photos = await _uploadNewPhotos(docId);
    final idPhotoUrl = await _uploadIdPhoto(docId);

    final payload = {
      "name": _nameCtrl.text.trim(),
      "phone": _phoneCtrl.text.trim(),
      "address": _addressCtrl.text.trim(),
      "description": _descCtrl.text.trim(),
      "subcategory": _subcategory,
      "category": category,
      "photos": photos,
      "lat": double.tryParse(_latCtrl.text.trim()) ?? 0.0,
      "lng": double.tryParse(_lngCtrl.text.trim()) ?? 0.0,
      "isAvailable": _isAvailable,
      "idNumber": _idNumberCtrl.text.trim(),
      "idPhotoUrl": idPhotoUrl ?? "",
      "artisanPin": _artisanPinCtrl.text.trim(),
    };

    try {
      if (widget.docId != null) {
        await FirebaseFirestore.instance
            .collection("service_providers")
            .doc(docId)
            .update(payload);
        if (mounted) _snack("Prestataire mis à jour", Colors.green);
      } else {
        payload["createdAt"] = FieldValue.serverTimestamp();
        payload["status"] = "approved";
        payload["isVerified"] = true;
        await FirebaseFirestore.instance
            .collection("service_providers")
            .doc(docId)
            .set(payload);
        if (mounted) _snack("Prestataire ajouté avec succès", Colors.green);
      }
      if (_removedPhotos.isNotEmpty) {
        unawaited(deleteStorageUrls(_removedPhotos));
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack("Erreur : $e", Colors.red);
    }

    if (mounted) setState(() => _loading = false);
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.docId != null;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        title: Text(
            isEdit ? "Modifier le prestataire" : "Ajouter un prestataire",
            style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── INFOS GÉNÉRALES ───────────────────────────
            _sectionCard(
              title: "Informations générales",
              children: [
                // Sous-catégorie
                const Text("Type de service",
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: _subcategory,
                  decoration: _inputDeco("Sous-catégorie", Icons.category),
                  items: _subcatOptions
                      .map((s) => DropdownMenuItem(
                            value: s["id"],
                            child: Text(s["label"]!,
                                style: const TextStyle(fontSize: 14)),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _subcategory = v);
                  },
                ),
                const SizedBox(height: 14),

                _field(_nameCtrl, "Nom du prestataire / magasin",
                    Icons.storefront),
                const SizedBox(height: 14),
                _field(_phoneCtrl, "Numéro de téléphone", Icons.phone,
                    type: TextInputType.phone),
                const SizedBox(height: 14),
                _field(_addressCtrl, "Adresse / Quartier", Icons.location_on),
                const SizedBox(height: 14),
                _field(_descCtrl, "Description (optionnel)", Icons.description,
                    maxLines: 3),
                const SizedBox(height: 14),
                _field(_artisanPinCtrl, "Code PIN artisan (accès photos)",
                    Icons.pin_rounded,
                    type: TextInputType.number),
                const SizedBox(height: 4),
                const Text(
                  "Ce code permet à l'artisan de se connecter pour gérer ses photos.",
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── GPS ───────────────────────────────────────
            _sectionCard(
              title: "Coordonnées GPS",
              children: [
                // Bouton capture automatique
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _gpsLoading ? null : _getGps,
                    icon: _gpsLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.my_location, color: Colors.white),
                    label: Text(
                      _gpsLoading
                          ? "Récupération en cours..."
                          : "Capturer ma position GPS automatiquement",
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Séparateur
                Row(
                  children: [
                    Expanded(child: Divider(color: Colors.grey.shade300)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text("ou saisir manuellement",
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade500)),
                    ),
                    Expanded(child: Divider(color: Colors.grey.shade300)),
                  ],
                ),

                const SizedBox(height: 12),

                // Champs manuels
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _latCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        decoration: _inputDeco("Latitude", Icons.gps_fixed),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _lngCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        decoration:
                            _inputDeco("Longitude", Icons.gps_not_fixed),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 6),
                const Text(
                  "Exemple : Lat 6.7273000  —  Lng -3.4961000",
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey,
                      fontStyle: FontStyle.italic),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── PHOTOS ────────────────────────────────────
            _sectionCard(
              title: "Photos du prestataire",
              children: [
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _showPhotoSourceDialog,
                    icon:
                        const Icon(Icons.add_a_photo, color: Color(0xFF1565C0)),
                    label: const Text("Ajouter une photo",
                        style: TextStyle(color: Color(0xFF1565C0))),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF1565C0)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                if (_photos.isNotEmpty || _newPhotoFiles.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 90,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        // Photos existantes (URLs)
                        ..._photos.asMap().entries.map((e) => Stack(
                              children: [
                                Container(
                                  width: 90,
                                  height: 90,
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    color: Colors.grey.shade200,
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: Image.network(e.value,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(
                                          Icons.broken_image,
                                          color: Colors.grey)),
                                ),
                                Positioned(
                                  top: 4,
                                  right: 12,
                                  child: GestureDetector(
                                    onTap: () => setState(() {
                                      // Nettoyage Storage différé à _save() —
                                      // ne jamais supprimer le fichier tant que
                                      // l'édition n'est pas réellement enregistrée.
                                      _removedPhotos.add(_photos[e.key]);
                                      _photos.removeAt(e.key);
                                    }),
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: const BoxDecoration(
                                          color: Colors.red,
                                          shape: BoxShape.circle),
                                      child: const Icon(Icons.close,
                                          color: Colors.white, size: 12),
                                    ),
                                  ),
                                ),
                              ],
                            )),
                        // Nouvelles photos locales
                        ..._newPhotoFiles.asMap().entries.map((e) => Stack(
                              children: [
                                Container(
                                  width: 90,
                                  height: 90,
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    color: Colors.grey.shade200,
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: Image.file(e.value, fit: BoxFit.cover),
                                ),
                                Positioned(
                                  top: 4,
                                  right: 12,
                                  child: GestureDetector(
                                    onTap: () => setState(
                                        () => _newPhotoFiles.removeAt(e.key)),
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: const BoxDecoration(
                                          color: Colors.red,
                                          shape: BoxShape.circle),
                                      child: const Icon(Icons.close,
                                          color: Colors.white, size: 12),
                                    ),
                                  ),
                                ),
                              ],
                            )),
                      ],
                    ),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 16),

            // ── PIÈCE D'IDENTITÉ ──────────────────────────
            _sectionCard(
              title: "Pièce d'identité",
              children: [
                _field(_idNumberCtrl, "Numéro de la pièce d'identité",
                    Icons.badge_rounded),
                const SizedBox(height: 14),
                GestureDetector(
                  onTap: _showIdPhotoSourceDialog,
                  child: Container(
                    height: 130,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _idPhotoFile != null ||
                                (_existingIdPhotoUrl?.isNotEmpty ?? false)
                            ? Colors.green
                            : const Color(0xFF1565C0).withValues(alpha: 0.4),
                        width: 2,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: _idPhotoFile != null
                          ? Image.file(_idPhotoFile!, fit: BoxFit.cover)
                          : (_existingIdPhotoUrl?.isNotEmpty ?? false)
                              ? Image.network(_existingIdPhotoUrl!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => _idPhotoHint())
                              : _idPhotoHint(),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── DISPONIBILITÉ ─────────────────────────────
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 8)
                ],
              ),
              child: SwitchListTile(
                title: const Text("Prestataire actif",
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle:
                    const Text("Visible par les clients dans l'application"),
                value: _isAvailable,
                onChanged: (v) => setState(() => _isAvailable = v),
                activeThumbColor: const Color(0xFF1565C0),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
            ),

            const SizedBox(height: 24),

            // ── BOUTON SAVE ───────────────────────────────
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ScaleButton(
                onPressed: _loading ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                child: _loading
                    ? const CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5)
                    : Text(
                        isEdit
                            ? "Enregistrer les modifications"
                            : "Ajouter le prestataire",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),

            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _sectionCard({required String title, required List<Widget> children}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8)
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Color(0xFF1565C0))),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType? type, int maxLines = 1}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      maxLines: maxLines,
      decoration: _inputDeco(label, icon),
    );
  }

  InputDecoration _inputDeco(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: const Color(0xFF1565C0), size: 20),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF1565C0), width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }

  Widget _idPhotoHint() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.credit_card_rounded,
            size: 36, color: const Color(0xFF1565C0).withValues(alpha: 0.4)),
        const SizedBox(height: 8),
        Text(
          "Photo de la pièce d'identité",
          style: TextStyle(
              color: const Color(0xFF1565C0).withValues(alpha: 0.7),
              fontSize: 12),
        ),
        Text(
          "Appuyez pour prendre ou importer",
          style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
        ),
      ],
    );
  }
}
