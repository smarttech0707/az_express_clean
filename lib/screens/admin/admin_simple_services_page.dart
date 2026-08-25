import 'dart:io';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

const _serviceTypes = [
  {
    "id": "tricycle",
    "label": "Location de tricycle",
    "icon": Icons.electric_rickshaw_rounded
  },
  {
    "id": "taxi_nuit",
    "label": "Taxi de nuit",
    "icon": Icons.local_taxi_rounded
  },
];

class AdminSimpleServicesPage extends StatefulWidget {
  const AdminSimpleServicesPage({super.key});

  @override
  State<AdminSimpleServicesPage> createState() =>
      _AdminSimpleServicesPageState();
}

class _AdminSimpleServicesPageState extends State<AdminSimpleServicesPage> {
  String _filter = "tous";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 130,
            pinned: true,
            backgroundColor: const Color(0xFF37474F),
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF263238), Color(0xFF546E7A)],
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
                        Text("Tricycle & Taxi de nuit",
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold)),
                        Text("Gérer les prestataires",
                            style:
                                TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: const Text("Tricycle & Taxi de nuit",
                style: TextStyle(color: Colors.white)),
            centerTitle: true,
          ),

          // Filtre
          SliverToBoxAdapter(
            child: SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                children: [
                  _Chip(
                    label: "Tous",
                    selected: _filter == "tous",
                    onTap: () => setState(() => _filter = "tous"),
                  ),
                  ..._serviceTypes.map((s) => _Chip(
                        label: s["label"] as String,
                        selected: _filter == s["id"],
                        onTap: () =>
                            setState(() => _filter = s["id"] as String),
                      )),
                ],
              ),
            ),
          ),

          // Liste
          StreamBuilder<QuerySnapshot>(
            stream: _filter == "tous"
                ? FirebaseFirestore.instance
                    .collection("simple_services")
                    .orderBy("createdAt", descending: true)
                    .snapshots()
                : FirebaseFirestore.instance
                    .collection("simple_services")
                    .where("serviceType", isEqualTo: _filter)
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
                        const Icon(Icons.local_taxi_outlined,
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
                            backgroundColor: const Color(0xFF37474F),
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
                      return _ProviderTile(
                        docId: doc.id,
                        data: data,
                        onEdit: () =>
                            _openForm(context, docId: doc.id, data: data),
                        onDelete: () =>
                            _confirmDelete(context, doc.id, data["name"] ?? ""),
                        onToggle: () async {
                          try {
                            await FirebaseFirestore.instance
                                .collection("simple_services")
                                .doc(doc.id)
                                .update({
                              "isAvailable": !(data["isAvailable"] ?? true)
                            });
                          } catch (_) {}
                        },
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
        backgroundColor: const Color(0xFF37474F),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text("Ajouter",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, String docId, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("Supprimer"),
        content: Text("Supprimer \"$name\" ?"),
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
    if (ok == true) {
      await FirebaseFirestore.instance
          .collection("simple_services")
          .doc(docId)
          .delete();
    }
  }

  void _openForm(BuildContext context,
      {String? docId, Map<String, dynamic>? data}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SimpleServiceForm(docId: docId, existing: data),
      ),
    );
  }
}

// ── TUILE PRESTATAIRE ─────────────────────────────────────────

class _ProviderTile extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> data;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onToggle;

  const _ProviderTile({
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
    final type = data["serviceType"] ?? "";
    final isAvailable = data["isAvailable"] ?? true;
    final label = (_serviceTypes.firstWhere(
          (s) => s["id"] == type,
          orElse: () => {"label": type},
        )["label"] as String?) ??
        type;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 6)
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // Infos
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 4),
                  Text(phone,
                      style: const TextStyle(color: Colors.grey, fontSize: 13)),
                  const SizedBox(height: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF37474F).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      label,
                      style: const TextStyle(
                          color: Color(0xFF37474F),
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),

            // Actions
            Column(
              children: [
                GestureDetector(
                  onTap: onToggle,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isAvailable
                          ? Colors.green.shade50
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: isAvailable ? Colors.green : Colors.grey),
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
                const SizedBox(height: 8),
                Row(
                  children: [
                    GestureDetector(
                      onTap: onEdit,
                      child: const Icon(Icons.edit,
                          size: 20, color: Color(0xFF37474F)),
                    ),
                    const SizedBox(width: 14),
                    GestureDetector(
                      onTap: onDelete,
                      child: const Icon(Icons.delete_outline,
                          size: 20, color: Colors.red),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── CHIP FILTRE ───────────────────────────────────────────────

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(
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
          color: selected ? const Color(0xFF37474F) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected ? const Color(0xFF37474F) : Colors.grey.shade300),
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

// ── FORMULAIRE ────────────────────────────────────────────────

class _SimpleServiceForm extends StatefulWidget {
  final String? docId;
  final Map<String, dynamic>? existing;
  const _SimpleServiceForm({this.docId, this.existing});

  @override
  State<_SimpleServiceForm> createState() => _SimpleServiceFormState();
}

class _SimpleServiceFormState extends State<_SimpleServiceForm> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();
  final _idNumberCtrl = TextEditingController();
  String _serviceType = "tricycle";
  bool _isAvailable = true;
  bool _loading = false;
  bool _gpsLoading = false;
  File? _photoFile;
  String? _existingPhotoUrl;
  File? _idPhotoFile;
  String? _existingIdPhotoUrl;

  @override
  void initState() {
    super.initState();
    final d = widget.existing;
    if (d != null) {
      _nameCtrl.text = d["name"] ?? "";
      _phoneCtrl.text = d["phone"] ?? "";
      _serviceType = d["serviceType"] ?? "tricycle";
      _isAvailable = d["isAvailable"] ?? true;
      _existingPhotoUrl = d["photoUrl"];
      _existingIdPhotoUrl = d["idPhotoUrl"];
      _idNumberCtrl.text = d["idNumber"] ?? "";
      final lat = (d["lat"] as num?)?.toDouble() ?? 0.0;
      final lng = (d["lng"] as num?)?.toDouble() ?? 0.0;
      if (lat != 0.0) _latCtrl.text = lat.toString();
      if (lng != 0.0) _lngCtrl.text = lng.toString();
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    _idNumberCtrl.dispose();
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
      _snack("Position capturée", Colors.green);
    } catch (e) {
      _snack("Erreur GPS : $e", Colors.red);
    }
    setState(() => _gpsLoading = false);
  }

  Future<void> _pickPhoto(ImageSource source) async {
    final picked =
        await ImagePicker().pickImage(source: source, imageQuality: 75);
    if (picked != null) setState(() => _photoFile = File(picked.path));
  }

  void _showPhotoSource() {
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
              leading: const Icon(Icons.camera_alt, color: Color(0xFF37474F)),
              title: const Text("Prendre une photo"),
              onTap: () {
                Navigator.pop(context);
                _pickPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, color: Color(0xFF37474F)),
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
    final picked =
        await ImagePicker().pickImage(source: source, imageQuality: 80);
    if (picked != null) setState(() => _idPhotoFile = File(picked.path));
  }

  void _showIdPhotoSource() {
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
              leading: const Icon(Icons.camera_alt, color: Color(0xFF37474F)),
              title: const Text("Photographier la pièce d'identité"),
              onTap: () {
                Navigator.pop(context);
                _pickIdPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, color: Color(0xFF37474F)),
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

  Future<String?> _uploadPhoto(String docId) async {
    if (_photoFile == null) return _existingPhotoUrl;
    try {
      final ref =
          FirebaseStorage.instance.ref("simple_services/$docId/photo.jpg");
      await ref.putFile(_photoFile!);
      return await ref.getDownloadURL();
    } catch (_) {}
    return _existingPhotoUrl;
  }

  Future<String?> _uploadIdPhoto(String docId) async {
    if (_idPhotoFile == null) return _existingIdPhotoUrl;
    try {
      final ref =
          FirebaseStorage.instance.ref("simple_services/$docId/id_photo.jpg");
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
      _snack("Le numéro est obligatoire", Colors.orange);
      return;
    }

    setState(() => _loading = true);

    final docId = widget.docId ??
        FirebaseFirestore.instance.collection("simple_services").doc().id;

    final photoUrl = await _uploadPhoto(docId);
    final idPhotoUrl = await _uploadIdPhoto(docId);

    final payload = {
      "name": _nameCtrl.text.trim(),
      "phone": _phoneCtrl.text.trim(),
      "serviceType": _serviceType,
      "isAvailable": _isAvailable,
      "photoUrl": photoUrl ?? "",
      "lat": double.tryParse(_latCtrl.text.trim()) ?? 0.0,
      "lng": double.tryParse(_lngCtrl.text.trim()) ?? 0.0,
      "idNumber": _idNumberCtrl.text.trim(),
      "idPhotoUrl": idPhotoUrl ?? "",
    };

    try {
      if (widget.docId != null) {
        await FirebaseFirestore.instance
            .collection("simple_services")
            .doc(docId)
            .update(payload);
        if (mounted) _snack("Mis à jour", Colors.green);
      } else {
        payload["createdAt"] = FieldValue.serverTimestamp();
        await FirebaseFirestore.instance
            .collection("simple_services")
            .doc(docId)
            .set(payload);
        if (mounted) _snack("Ajouté avec succès", Colors.green);
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
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        title: Text(
            widget.docId != null ? "Modifier" : "Ajouter un prestataire",
            style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF37474F),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04), blurRadius: 8)
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Type de service
              const Text("Type de service",
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Color(0xFF37474F))),
              const SizedBox(height: 10),
              Row(
                children: _serviceTypes.map((s) {
                  final selected = _serviceType == s["id"];
                  return Expanded(
                    child: GestureDetector(
                      onTap: () =>
                          setState(() => _serviceType = s["id"] as String),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: EdgeInsets.only(
                            right: s == _serviceTypes.last ? 0 : 10),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFF37474F)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: selected
                                ? const Color(0xFF37474F)
                                : Colors.grey.shade300,
                          ),
                        ),
                        child: Column(
                          children: [
                            Icon(
                              s["icon"] as IconData,
                              color: selected
                                  ? Colors.white
                                  : Colors.grey.shade600,
                              size: 24,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              (s["label"] as String)
                                  .split(" ")
                                  .take(2)
                                  .join(" "),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: selected ? Colors.white : Colors.black87,
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),

              const SizedBox(height: 20),

              // Nom
              TextField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: "Nom du prestataire",
                  prefixIcon: const Icon(Icons.person_outline,
                      color: Color(0xFF37474F)),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: Color(0xFF37474F), width: 2),
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // Téléphone
              TextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: "Numéro de téléphone",
                  prefixIcon: const Icon(Icons.phone_outlined,
                      color: Color(0xFF37474F)),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: Color(0xFF37474F), width: 2),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ── PHOTO DU PRESTATAIRE ──────────────────
              _sectionLabel("Photo du prestataire"),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: _showPhotoSource,
                child: Container(
                  height: 160,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _photoFile != null ||
                              (_existingPhotoUrl?.isNotEmpty ?? false)
                          ? Colors.green
                          : const Color(0xFF37474F).withValues(alpha: 0.3),
                      width: 2,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _photoFile != null
                        ? Image.file(_photoFile!, fit: BoxFit.cover)
                        : (_existingPhotoUrl?.isNotEmpty ?? false)
                            ? Image.network(_existingPhotoUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _photoHint(
                                    Icons.person_rounded,
                                    "Photo du prestataire"))
                            : _photoHint(
                                Icons.person_rounded, "Photo du prestataire"),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ── POSITION GPS ──────────────────────────
              _sectionLabel("Position GPS"),
              const SizedBox(height: 10),
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
                    _gpsLoading ? "Récupération…" : "Capturer ma position GPS",
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF37474F),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              if (_latCtrl.text.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.gps_fixed, size: 13, color: Colors.green),
                    const SizedBox(width: 4),
                    Text(
                      "Lat: ${_latCtrl.text}  Lng: ${_lngCtrl.text}",
                      style: const TextStyle(fontSize: 11, color: Colors.green),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 20),

              // ── PIÈCE D'IDENTITÉ ──────────────────────
              _sectionLabel("Pièce d'identité"),
              const SizedBox(height: 10),
              TextField(
                controller: _idNumberCtrl,
                decoration: InputDecoration(
                  labelText: "Numéro de la pièce d'identité",
                  prefixIcon:
                      const Icon(Icons.badge_rounded, color: Color(0xFF37474F)),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: Color(0xFF37474F), width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              GestureDetector(
                onTap: _showIdPhotoSource,
                child: Container(
                  height: 130,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _idPhotoFile != null ||
                              (_existingIdPhotoUrl?.isNotEmpty ?? false)
                          ? Colors.green
                          : const Color(0xFF37474F).withValues(alpha: 0.3),
                      width: 2,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _idPhotoFile != null
                        ? Image.file(_idPhotoFile!, fit: BoxFit.cover)
                        : (_existingIdPhotoUrl?.isNotEmpty ?? false)
                            ? Image.network(_existingIdPhotoUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _photoHint(
                                    Icons.credit_card_rounded,
                                    "Photo de la pièce d'identité"))
                            : _photoHint(Icons.credit_card_rounded,
                                "Photo de la pièce d'identité"),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Disponibilité
              SwitchListTile(
                title: const Text("Actif",
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text("Visible dans l'application"),
                value: _isAvailable,
                onChanged: (v) => setState(() => _isAvailable = v),
                activeThumbColor: const Color(0xFF37474F),
                contentPadding: EdgeInsets.zero,
              ),

              const SizedBox(height: 20),

              // Bouton save
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ScaleButton(
                  onPressed: _loading ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF37474F),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _loading
                      ? const CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5)
                      : Text(
                          widget.docId != null
                              ? "Enregistrer"
                              : "Ajouter le prestataire",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
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

  Widget _sectionLabel(String title) {
    return Text(
      title,
      style: const TextStyle(
          fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF37474F)),
    );
  }

  Widget _photoHint(IconData icon, String label) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon,
            size: 32, color: const Color(0xFF37474F).withValues(alpha: 0.4)),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
              color: const Color(0xFF37474F).withValues(alpha: 0.7),
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
