import 'dart:io';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import '../../utils/storage_cleanup.dart';

class AdminResidencesPage extends StatelessWidget {
  const AdminResidencesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        title: const Text("Résidences Meublées"),
        backgroundColor: const Color(0xFF4A148C),
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const _ResidenceFormPage()),
        ),
        backgroundColor: const Color(0xFF4A148C),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text("Ajouter",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('residences')
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.apartment_outlined,
                      size: 72, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  const Text("Aucune résidence",
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                  const SizedBox(height: 8),
                  const Text("Appuyez sur + pour ajouter",
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                ],
              ),
            );
          }
          return ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final doc = docs[i];
              final data = doc.data() as Map<String, dynamic>;
              return _ResidenceAdminCard(docId: doc.id, data: data);
            },
          );
        },
      ),
    );
  }
}

// ── CARTE ADMIN ───────────────────────────────────────────────

class _ResidenceAdminCard extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> data;
  const _ResidenceAdminCard({required this.docId, required this.data});

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Supprimer cette résidence ?"),
        content:
            Text("\"${data['title'] ?? ''}\" sera supprimée définitivement."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Annuler")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text("Supprimer"),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await FirebaseFirestore.instance
          .collection('residences')
          .doc(docId)
          .delete();
      await deleteStorageUrls([
        data['photoUrl'] as String?,
        data['idPhotoUrl'] as String?,
      ]);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur : $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _toggle() async {
    try {
      await FirebaseFirestore.instance
          .collection('residences')
          .doc(docId)
          .update({'isAvailable': !(data['isAvailable'] ?? true)});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isAvailable = data['isAvailable'] ?? true;
    final photoUrl = data['photoUrl'] as String?;
    final title = data['title'] ?? 'Sans titre';
    final type = data['type'] ?? '';
    final address = data['address'] ?? '';
    final priceNight = data['priceNight'];
    final priceMonth = data['priceMonth'];
    final amenities = (data['amenities'] as List?)?.cast<String>() ?? [];

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.07),
              blurRadius: 12,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Photo
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            child: SizedBox(
              height: 150,
              width: double.infinity,
              child: photoUrl != null && photoUrl.isNotEmpty
                  ? Image.network(photoUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _placeholder())
                  : _placeholder(),
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 16)),
                          if (type.isNotEmpty)
                            Text(type,
                                style: TextStyle(
                                    color: const Color(0xFF4A148C)
                                        .withValues(alpha: 0.8),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: isAvailable
                            ? Colors.green.withValues(alpha: 0.1)
                            : Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        isAvailable ? "Disponible" : "Indisponible",
                        style: TextStyle(
                          color: isAvailable ? Colors.green : Colors.red,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (address.isNotEmpty)
                  Row(
                    children: [
                      Icon(Icons.location_on,
                          size: 14, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(address,
                            style: TextStyle(
                                color: Colors.grey.shade600, fontSize: 13)),
                      ),
                    ],
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (priceNight != null && priceNight > 0) ...[
                      const Icon(Icons.nightlight_round,
                          size: 13, color: Color(0xFF4A148C)),
                      const SizedBox(width: 3),
                      Text("$priceNight FCFA/nuit",
                          style: const TextStyle(
                              color: Color(0xFF4A148C),
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(width: 12),
                    ],
                    if (priceMonth != null && priceMonth > 0) ...[
                      Icon(Icons.calendar_month_rounded,
                          size: 13, color: Colors.orange.shade700),
                      const SizedBox(width: 3),
                      Text("$priceMonth FCFA/mois",
                          style: TextStyle(
                              color: Colors.orange.shade700,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
                if (amenities.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(amenities.take(3).join(' · '),
                      style:
                          TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _toggle,
                        icon: Icon(
                          isAvailable ? Icons.visibility_off : Icons.visibility,
                          size: 16,
                          color: isAvailable ? Colors.orange : Colors.green,
                        ),
                        label: Text(
                          isAvailable ? "Marquer indispo" : "Marquer dispo",
                          style: TextStyle(
                              fontSize: 12,
                              color:
                                  isAvailable ? Colors.orange : Colors.green),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                              color:
                                  isAvailable ? Colors.orange : Colors.green),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => _ResidenceFormPage(
                            docId: docId,
                            existing: data,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.edit_rounded,
                          color: Color(0xFF4A148C)),
                      tooltip: "Modifier",
                    ),
                    IconButton(
                      onPressed: () => _delete(context),
                      icon: const Icon(Icons.delete_outline_rounded,
                          color: Colors.red),
                      tooltip: "Supprimer",
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

  Widget _placeholder() {
    return Container(
      color: const Color(0xFF4A148C).withValues(alpha: 0.1),
      child: const Center(
        child:
            Icon(Icons.apartment_rounded, size: 60, color: Color(0xFF4A148C)),
      ),
    );
  }
}

// ── FORMULAIRE ADD / EDIT ─────────────────────────────────────

class _ResidenceFormPage extends StatefulWidget {
  final String? docId;
  final Map<String, dynamic>? existing;
  const _ResidenceFormPage({this.docId, this.existing});

  @override
  State<_ResidenceFormPage> createState() => _ResidenceFormPageState();
}

class _ResidenceFormPageState extends State<_ResidenceFormPage> {
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceNightCtrl = TextEditingController();
  final _priceMonthCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _amenityCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();
  final _idNumberCtrl = TextEditingController();

  String _type = 'Studio';
  final List<String> _amenities = [];
  File? _pickedImage;
  String? _existingPhotoUrl;
  File? _idPhotoFile;
  String? _existingIdPhotoUrl;
  bool _isAvailable = true;
  bool _saving = false;
  bool _gpsLoading = false;

  static const _types = ['Studio', '1 pièce', '2 pièces', '3 pièces', 'Villa'];
  static const _suggestedAmenities = [
    'Wifi',
    'Climatisé',
    'TV',
    'Cuisine équipée',
    'Parking',
    'Eau courante',
    'Électricité',
    'Sécurité gardée',
    'Piscine',
    'Terrasse',
  ];

  bool get _isEditing => widget.docId != null;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final d = widget.existing!;
      _titleCtrl.text = d['title'] ?? '';
      _descCtrl.text = d['description'] ?? '';
      _priceNightCtrl.text = '${d['priceNight'] ?? ''}';
      _priceMonthCtrl.text = '${d['priceMonth'] ?? ''}';
      _addressCtrl.text = d['address'] ?? '';
      _phoneCtrl.text = d['phone'] ?? '';
      _type = d['type'] ?? 'Studio';
      _isAvailable = d['isAvailable'] ?? true;
      _existingPhotoUrl = d['photoUrl'];
      _existingIdPhotoUrl = d['idPhotoUrl'];
      _idNumberCtrl.text = d['idNumber'] ?? '';
      final savedAmenities = (d['amenities'] as List?)?.cast<String>() ?? [];
      _amenities.addAll(savedAmenities);
      final lat = (d['lat'] as num?)?.toDouble() ?? 0.0;
      final lng = (d['lng'] as num?)?.toDouble() ?? 0.0;
      if (lat != 0.0) _latCtrl.text = lat.toString();
      if (lng != 0.0) _lngCtrl.text = lng.toString();
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _priceNightCtrl.dispose();
    _priceMonthCtrl.dispose();
    _addressCtrl.dispose();
    _phoneCtrl.dispose();
    _amenityCtrl.dispose();
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Position capturée automatiquement"),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("Erreur GPS : $e"), backgroundColor: Colors.red));
      }
    }
    setState(() => _gpsLoading = false);
  }

  Future<void> _pickImage() async {
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
              leading: const Icon(Icons.camera_alt, color: Color(0xFF4A148C)),
              title: const Text("Prendre une photo"),
              onTap: () async {
                Navigator.pop(context);
                final picked = await ImagePicker()
                    .pickImage(source: ImageSource.camera, imageQuality: 75);
                if (picked != null)
                  setState(() => _pickedImage = File(picked.path));
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, color: Color(0xFF4A148C)),
              title: const Text("Choisir depuis la galerie"),
              onTap: () async {
                Navigator.pop(context);
                final picked = await ImagePicker()
                    .pickImage(source: ImageSource.gallery, imageQuality: 75);
                if (picked != null)
                  setState(() => _pickedImage = File(picked.path));
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
              leading: const Icon(Icons.camera_alt, color: Color(0xFF4A148C)),
              title: const Text("Photographier la pièce d'identité"),
              onTap: () {
                Navigator.pop(context);
                _pickIdPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, color: Color(0xFF4A148C)),
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
    if (_pickedImage == null) return _existingPhotoUrl;
    try {
      final ref = FirebaseStorage.instance.ref('residences/$docId/photo.jpg');
      final snap = await ref.putFile(_pickedImage!);
      if (snap.state == TaskState.success) return await ref.getDownloadURL();
    } catch (_) {}
    return _existingPhotoUrl;
  }

  Future<String?> _uploadIdPhoto(String docId) async {
    if (_idPhotoFile == null) return _existingIdPhotoUrl;
    try {
      final ref =
          FirebaseStorage.instance.ref('residences/$docId/id_photo.jpg');
      await ref.putFile(_idPhotoFile!);
      return await ref.getDownloadURL();
    } catch (_) {}
    return _existingIdPhotoUrl;
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _snack("Le titre est obligatoire");
      return;
    }
    setState(() => _saving = true);

    final docId = _isEditing
        ? widget.docId!
        : FirebaseFirestore.instance.collection('residences').doc().id;

    final photoUrl = await _uploadPhoto(docId);
    final idPhotoUrl = await _uploadIdPhoto(docId);
    final priceNight = int.tryParse(_priceNightCtrl.text.trim()) ?? 0;
    final priceMonth = int.tryParse(_priceMonthCtrl.text.trim()) ?? 0;

    final payload = {
      'title': title,
      'description': _descCtrl.text.trim(),
      'address': _addressCtrl.text.trim(),
      'phone': _phoneCtrl.text.trim(),
      'type': _type,
      'priceNight': priceNight,
      'priceMonth': priceMonth,
      'amenities': _amenities,
      'photoUrl': photoUrl ?? '',
      'isAvailable': _isAvailable,
      'lat': double.tryParse(_latCtrl.text.trim()) ?? 0.0,
      'lng': double.tryParse(_lngCtrl.text.trim()) ?? 0.0,
      'idNumber': _idNumberCtrl.text.trim(),
      'idPhotoUrl': idPhotoUrl ?? '',
      'updatedAt': FieldValue.serverTimestamp(),
      if (!_isEditing) 'createdAt': FieldValue.serverTimestamp(),
    };

    try {
      await FirebaseFirestore.instance
          .collection('residences')
          .doc(docId)
          .set(payload, SetOptions(merge: true));
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(_isEditing ? "Résidence modifiée" : "Résidence ajoutée"),
            backgroundColor: const Color(0xFF4A148C),
          ),
        );
      }
    } catch (e) {
      _snack("Erreur : $e");
    }
    if (mounted) setState(() => _saving = false);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _addAmenity(String a) {
    final v = a.trim();
    if (v.isEmpty || _amenities.contains(v)) return;
    setState(() => _amenities.add(v));
    _amenityCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title:
            Text(_isEditing ? "Modifier la résidence" : "Nouvelle résidence"),
        backgroundColor: const Color(0xFF4A148C),
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2),
                ),
              ),
            )
          else
            TextButton(
              onPressed: _save,
              child: const Text("Enregistrer",
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          // ── PHOTO ─────────────────────────────────────────
          GestureDetector(
            onTap: _pickImage,
            child: Container(
              height: 180,
              decoration: BoxDecoration(
                color: const Color(0xFF4A148C).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: const Color(0xFF4A148C).withValues(alpha: 0.2)),
              ),
              child: _pickedImage != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.file(_pickedImage!, fit: BoxFit.cover),
                    )
                  : _existingPhotoUrl != null && _existingPhotoUrl!.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.network(_existingPhotoUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _photoHint()),
                        )
                      : _photoHint(),
            ),
          ),

          const SizedBox(height: 16),

          // ── INFORMATIONS ──────────────────────────────────
          _section("Informations"),
          const SizedBox(height: 10),
          _field(_titleCtrl, "Titre *", Icons.apartment_rounded),
          const SizedBox(height: 10),
          _field(_addressCtrl, "Adresse / Quartier", Icons.location_on_rounded),
          const SizedBox(height: 10),
          _field(_phoneCtrl, "Téléphone contact", Icons.phone_rounded,
              type: TextInputType.phone),

          const SizedBox(height: 16),

          // ── TYPE ──────────────────────────────────────────
          _section("Type de logement"),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _types.map((t) {
              final sel = _type == t;
              return GestureDetector(
                onTap: () => setState(() => _type = t),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: sel ? const Color(0xFF4A148C) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color:
                          sel ? const Color(0xFF4A148C) : Colors.grey.shade300,
                    ),
                  ),
                  child: Text(
                    t,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: sel ? Colors.white : Colors.black87),
                  ),
                ),
              );
            }).toList(),
          ),

          const SizedBox(height: 16),

          // ── PRIX ──────────────────────────────────────────
          _section("Prix"),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _field(_priceNightCtrl, "Prix / nuit (FCFA)",
                    Icons.nightlight_round,
                    type: TextInputType.number),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _field(_priceMonthCtrl, "Prix / mois (FCFA)",
                    Icons.calendar_month_rounded,
                    type: TextInputType.number),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ── ÉQUIPEMENTS ───────────────────────────────────
          _section("Équipements"),
          const SizedBox(height: 10),
          // Suggestions rapides
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _suggestedAmenities.map((a) {
              final added = _amenities.contains(a);
              return GestureDetector(
                onTap: () {
                  if (added) {
                    setState(() => _amenities.remove(a));
                  } else {
                    _addAmenity(a);
                  }
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: added ? const Color(0xFF4A148C) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: added
                          ? const Color(0xFF4A148C)
                          : Colors.grey.shade300,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (added) ...[
                        const Icon(Icons.check, size: 12, color: Colors.white),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        a,
                        style: TextStyle(
                            fontSize: 12,
                            color: added ? Colors.white : Colors.black87,
                            fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          // Champ libre
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _amenityCtrl,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: "Autre équipement…",
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: _addAmenity,
                ),
              ),
              const SizedBox(width: 8),
              ScaleButton(
                onPressed: () => _addAmenity(_amenityCtrl.text),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4A148C),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
                child: const Icon(Icons.add, color: Colors.white),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ── GPS ───────────────────────────────────────────
          _section("Position GPS"),
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
                _gpsLoading
                    ? "Récupération…"
                    : "Capturer ma position GPS automatiquement",
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A148C),
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
                Text("GPS : ${_latCtrl.text}, ${_lngCtrl.text}",
                    style: const TextStyle(fontSize: 11, color: Colors.green)),
              ],
            ),
          ],

          const SizedBox(height: 16),

          // ── PIÈCE D'IDENTITÉ PROPRIÉTAIRE ─────────────────
          _section("Pièce d'identité du propriétaire"),
          const SizedBox(height: 10),
          _field(_idNumberCtrl, "Numéro de la pièce d'identité",
              Icons.badge_rounded),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: _showIdPhotoSource,
            child: Container(
              height: 120,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _idPhotoFile != null ||
                          (_existingIdPhotoUrl?.isNotEmpty ?? false)
                      ? Colors.green
                      : const Color(0xFF4A148C).withValues(alpha: 0.3),
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
                            errorBuilder: (_, __, ___) => _idHint())
                        : _idHint(),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── DESCRIPTION ───────────────────────────────────
          _section("Description"),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: TextField(
              controller: _descCtrl,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: "Décrivez la résidence…",
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── DISPONIBILITÉ ─────────────────────────────────
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SwitchListTile(
              title: const Text("Disponible à la location",
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(_isAvailable
                  ? "Visible par les clients"
                  : "Masquée aux clients"),
              value: _isAvailable,
              activeThumbColor: const Color(0xFF4A148C),
              onChanged: (v) => setState(() => _isAvailable = v),
            ),
          ),

          const SizedBox(height: 28),

          SizedBox(
            height: 54,
            child: ScaleButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4A148C),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: _saving
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Text(
                      _isEditing
                          ? "Enregistrer les modifications"
                          : "Ajouter la résidence",
                      style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white,
                          fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 18,
          decoration: BoxDecoration(
            color: const Color(0xFF4A148C),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.black87)),
      ],
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType? type}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: const Color(0xFF4A148C)),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _photoHint() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.add_photo_alternate_rounded,
            size: 42, color: const Color(0xFF4A148C).withValues(alpha: 0.5)),
        const SizedBox(height: 8),
        Text("Appuyez pour ajouter une photo",
            style: TextStyle(
                color: const Color(0xFF4A148C).withValues(alpha: 0.6),
                fontSize: 13)),
      ],
    );
  }

  Widget _idHint() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.credit_card_rounded,
            size: 32, color: const Color(0xFF4A148C).withValues(alpha: 0.4)),
        const SizedBox(height: 6),
        Text("Photo de la pièce d'identité",
            style: TextStyle(
                color: const Color(0xFF4A148C).withValues(alpha: 0.7),
                fontSize: 12)),
        Text("Appuyez pour prendre ou importer",
            style: TextStyle(color: Colors.grey.shade400, fontSize: 11)),
      ],
    );
  }
}
