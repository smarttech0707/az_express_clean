import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import '../../utils/storage_cleanup.dart';

class AdminLocationsPage extends StatelessWidget {
  const AdminLocationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        title: const Text("Maisons à louer"),
        backgroundColor: const Color(0xFF00695C),
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const _LocationFormPage()),
        ),
        backgroundColor: const Color(0xFF00695C),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text("Ajouter",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection("locations")
            .orderBy("createdAt", descending: true)
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
                  Icon(Icons.home_outlined,
                      size: 72, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  const Text("Aucune annonce",
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
              return _LocationAdminCard(docId: doc.id, data: data);
            },
          );
        },
      ),
    );
  }
}

// ── CARTE ADMIN ───────────────────────────────────────────────

class _LocationAdminCard extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> data;
  const _LocationAdminCard({required this.docId, required this.data});

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Supprimer cette annonce ?"),
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
    final photos = (data['photos'] as List?)?.cast<String>() ?? const [];
    await FirebaseFirestore.instance
        .collection("locations")
        .doc(docId)
        .delete();
    await deleteStorageUrls([data['photoUrl'] as String?, ...photos]);
  }

  Future<void> _toggleAvailability() async {
    await FirebaseFirestore.instance
        .collection("locations")
        .doc(docId)
        .update({"isAvailable": !(data["isAvailable"] ?? true)});
  }

  @override
  Widget build(BuildContext context) {
    final isAvailable = data["isAvailable"] ?? true;
    final photoUrl = data["photoUrl"] as String?;
    final title = data["title"] ?? "Sans titre";
    final price = data["price"] ?? 0;
    final rooms = data["rooms"] ?? 1;
    final address = data["address"] ?? "";

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
              height: 160,
              width: double.infinity,
              child: photoUrl != null && photoUrl.isNotEmpty
                  ? Image.network(photoUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _photoPlaceholder())
                  : _photoPlaceholder(),
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
                      child: Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
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
                    Icon(Icons.bed_rounded,
                        size: 14, color: Colors.grey.shade500),
                    const SizedBox(width: 4),
                    Text("$rooms pièce${rooms > 1 ? 's' : ''}",
                        style: TextStyle(
                            color: Colors.grey.shade600, fontSize: 13)),
                    const SizedBox(width: 16),
                    const Icon(Icons.payments_rounded,
                        size: 14, color: Color(0xFF00695C)),
                    const SizedBox(width: 4),
                    Text("$price FCFA/mois",
                        style: const TextStyle(
                            color: Color(0xFF00695C),
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    // Toggle disponibilité
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _toggleAvailability,
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
                    // Modifier
                    IconButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => _LocationFormPage(
                            docId: docId,
                            existing: data,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.edit_rounded,
                          color: Color(0xFF00695C)),
                      tooltip: "Modifier",
                    ),
                    // Supprimer
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

  Widget _photoPlaceholder() {
    return Container(
      color: const Color(0xFF00695C).withValues(alpha: 0.12),
      child: const Center(
        child: Icon(Icons.home_rounded, size: 60, color: Color(0xFF00695C)),
      ),
    );
  }
}

// ── FORMULAIRE ADD / EDIT ─────────────────────────────────────

class _LocationFormPage extends StatefulWidget {
  final String? docId;
  final Map<String, dynamic>? existing;
  const _LocationFormPage({this.docId, this.existing});

  @override
  State<_LocationFormPage> createState() => _LocationFormPageState();
}

class _LocationFormPageState extends State<_LocationFormPage> {
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _roomsCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();
  final _idNumberCtrl = TextEditingController();

  File? _pickedImage;
  String? _existingPhotoUrl;
  File? _idPhotoFile;
  String? _existingIdPhotoUrl;
  bool _isAvailable = true;
  bool _saving = false;
  bool _gpsLoading = false;

  // Master Prompt "photos manquantes" — galerie multi-photo additive :
  // `photoUrl` (couverture, ci-dessus) reste inchangé pour compatibilité
  // avec locations_page.dart, qui l'affiche toujours comme photo unique.
  // `photos` (nouveau champ, tableau d'URLs) porte les photos supplémentaires.
  final List<XFile> _pickedGalleryFiles = [];
  final List<String> _existingGalleryUrls = [];
  final List<String> _removedGalleryUrls = [];
  String? _galleryUploadStatus;

  bool get _isEditing => widget.docId != null;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final d = widget.existing!;
      _titleCtrl.text = d["title"] ?? "";
      _descCtrl.text = d["description"] ?? "";
      _priceCtrl.text = "${d["price"] ?? ""}";
      _addressCtrl.text = d["address"] ?? "";
      _roomsCtrl.text = "${d["rooms"] ?? ""}";
      _phoneCtrl.text = d["phone"] ?? "";
      _isAvailable = d["isAvailable"] ?? true;
      _existingPhotoUrl = d["photoUrl"];
      _existingIdPhotoUrl = d["idPhotoUrl"];
      _existingGalleryUrls
          .addAll((d["photos"] as List?)?.map((e) => e.toString()) ?? const []);
      _idNumberCtrl.text = d["idNumber"] ?? "";
      final lat = (d["lat"] as num?)?.toDouble() ?? 0.0;
      final lng = (d["lng"] as num?)?.toDouble() ?? 0.0;
      if (lat != 0.0) _latCtrl.text = lat.toString();
      if (lng != 0.0) _lngCtrl.text = lng.toString();
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _addressCtrl.dispose();
    _roomsCtrl.dispose();
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
              leading: const Icon(Icons.camera_alt, color: Color(0xFF00695C)),
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
                  const Icon(Icons.photo_library, color: Color(0xFF00695C)),
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

  Future<void> _pickGalleryPhotos() async {
    try {
      final files =
          await ImagePicker().pickMultiImage(imageQuality: 70, maxWidth: 1600);
      if (files.isEmpty) return;
      final remaining =
          10 - _existingGalleryUrls.length - _pickedGalleryFiles.length;
      if (remaining <= 0) return;
      setState(() => _pickedGalleryFiles.addAll(files.take(remaining)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("Impossible d'accéder à la galerie."),
              backgroundColor: Colors.red),
        );
      }
    }
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
              leading: const Icon(Icons.camera_alt, color: Color(0xFF00695C)),
              title: const Text("Photographier la pièce d'identité"),
              onTap: () {
                Navigator.pop(context);
                _pickIdPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, color: Color(0xFF00695C)),
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
      final ref = FirebaseStorage.instance.ref("locations/$docId/photo.jpg");
      final snap = await ref.putFile(_pickedImage!);
      if (snap.state == TaskState.success) return await ref.getDownloadURL();
    } catch (_) {}
    return _existingPhotoUrl;
  }

  Future<String?> _uploadIdPhoto(String docId) async {
    if (_idPhotoFile == null) return _existingIdPhotoUrl;
    try {
      final ref = FirebaseStorage.instance.ref("locations/$docId/id_photo.jpg");
      await ref.putFile(_idPhotoFile!);
      return await ref.getDownloadURL();
    } catch (_) {}
    return _existingIdPhotoUrl;
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    final desc = _descCtrl.text.trim();
    final price = int.tryParse(_priceCtrl.text.trim()) ?? 0;
    final address = _addressCtrl.text.trim();
    final rooms = int.tryParse(_roomsCtrl.text.trim()) ?? 1;

    if (title.isEmpty || address.isEmpty || price == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Titre, adresse et prix sont obligatoires")),
      );
      return;
    }

    setState(() => _saving = true);

    final db = FirebaseFirestore.instance;
    final docId =
        _isEditing ? widget.docId! : db.collection("locations").doc().id;

    final photoUrl = await _uploadPhoto(docId);
    final idPhotoUrl = await _uploadIdPhoto(docId);

    final galleryUrls = [..._existingGalleryUrls];
    for (var i = 0; i < _pickedGalleryFiles.length; i++) {
      if (mounted) {
        setState(() => _galleryUploadStatus =
            "Envoi de la galerie ${i + 1}/${_pickedGalleryFiles.length}…");
      }
      try {
        final ref = FirebaseStorage.instance.ref(
            "locations/$docId/gallery_${DateTime.now().millisecondsSinceEpoch}_$i.jpg");
        final snap = await ref.putFile(File(_pickedGalleryFiles[i].path));
        if (snap.state == TaskState.success) {
          galleryUrls.add(await ref.getDownloadURL());
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _galleryUploadStatus = null);

    final data = {
      "title": title,
      "description": desc,
      "price": price,
      "address": address,
      "rooms": rooms,
      "phone": _phoneCtrl.text.trim(),
      "isAvailable": _isAvailable,
      "photoUrl": photoUrl,
      "photos": galleryUrls,
      "lat": double.tryParse(_latCtrl.text.trim()) ?? 0.0,
      "lng": double.tryParse(_lngCtrl.text.trim()) ?? 0.0,
      "idNumber": _idNumberCtrl.text.trim(),
      "idPhotoUrl": idPhotoUrl ?? "",
      "createdAt": _isEditing
          ? (widget.existing!["createdAt"] ?? Timestamp.now())
          : Timestamp.now(),
    };

    await db.collection("locations").doc(docId).set(data);

    // Nettoyage Storage des photos de galerie retirées pendant l'édition —
    // fait seulement maintenant que la sauvegarde a réellement réussi,
    // jamais au moment du retrait dans la liste locale (voir onTap ci-dessus).
    if (_removedGalleryUrls.isNotEmpty) {
      unawaited(deleteStorageUrls(_removedGalleryUrls));
    }

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(_isEditing ? "Annonce modifiée ✓" : "Annonce ajoutée ✓"),
          backgroundColor: const Color(0xFF00695C),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        title: Text(_isEditing ? "Modifier l'annonce" : "Nouvelle annonce"),
        backgroundColor: const Color(0xFF00695C),
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          // ── PHOTO ────────────────────────────────────────
          GestureDetector(
            onTap: _pickImage,
            child: Container(
              height: 200,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: const Color(0xFF00695C).withValues(alpha: 0.3),
                    width: 2),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: _pickedImage != null
                    ? Image.file(_pickedImage!, fit: BoxFit.cover)
                    : (_existingPhotoUrl != null &&
                            _existingPhotoUrl!.isNotEmpty)
                        ? Image.network(_existingPhotoUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _photoHint())
                        : _photoHint(),
              ),
            ),
          ),

          const SizedBox(height: 20),

          _field(_titleCtrl, "Titre de l'annonce", Icons.title,
              hint: "ex: Villa F3 Abengourou centre"),
          const SizedBox(height: 14),
          _field(_addressCtrl, "Adresse / Quartier", Icons.location_on,
              hint: "ex: Quartier Morafou"),
          const SizedBox(height: 14),
          _field(_phoneCtrl, "Téléphone du propriétaire", Icons.phone_rounded,
              type: TextInputType.phone, hint: "ex: 0700000000"),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _field(
                    _priceCtrl, "Prix FCFA/mois", Icons.payments_rounded,
                    type: TextInputType.number, hint: "ex: 50000"),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _field(_roomsCtrl, "Nbre de pièces", Icons.bed_rounded,
                    type: TextInputType.number, hint: "ex: 3"),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
              ],
            ),
            child: TextField(
              controller: _descCtrl,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: "Description",
                hintText: "Décrivez la maison : état, équipements, conditions…",
                hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                prefixIcon: const Padding(
                  padding: EdgeInsets.only(bottom: 60),
                  child:
                      Icon(Icons.description_rounded, color: Color(0xFF00695C)),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 14),

          // ── GPS AUTOMATIQUE ───────────────────────────
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
                backgroundColor: const Color(0xFF00695C),
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
                Text("GPS enregistré : ${_latCtrl.text}, ${_lngCtrl.text}",
                    style: const TextStyle(fontSize: 11, color: Colors.green)),
              ],
            ),
          ],

          const SizedBox(height: 14),

          // ── PIÈCE D'IDENTITÉ PROPRIÉTAIRE ─────────────
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Pièce d'identité du propriétaire",
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Color(0xFF00695C)),
                ),
                const SizedBox(height: 12),
                _field(_idNumberCtrl, "Numéro de la pièce d'identité",
                    Icons.badge_rounded),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: _showIdPhotoSource,
                  child: Container(
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _idPhotoFile != null ||
                                (_existingIdPhotoUrl?.isNotEmpty ?? false)
                            ? Colors.green
                            : const Color(0xFF00695C).withValues(alpha: 0.3),
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
          ),

          const SizedBox(height: 14),

          // ── GALERIE PHOTOS SUPPLÉMENTAIRES (additif, photoUrl inchangé) ──
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Galerie (${_existingGalleryUrls.length + _pickedGalleryFiles.length}/10)",
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Color(0xFF00695C)),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 84,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (var i = 0; i < _existingGalleryUrls.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Stack(children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.network(_existingGalleryUrls[i],
                                  width: 84, height: 84, fit: BoxFit.cover),
                            ),
                            Positioned(
                              top: 2,
                              right: 2,
                              child: GestureDetector(
                                onTap: () => setState(() {
                                  // Le fichier Storage n'est nettoyé qu'à la
                                  // sauvegarde réelle (_save()), jamais ici —
                                  // sinon annuler l'édition sans enregistrer
                                  // supprimerait quand même le fichier alors
                                  // que le document Firestore le référence
                                  // toujours (image cassée sans raison).
                                  _removedGalleryUrls
                                      .add(_existingGalleryUrls[i]);
                                  _existingGalleryUrls.removeAt(i);
                                }),
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle),
                                  child: const Icon(Icons.close_rounded,
                                      size: 16, color: Colors.white),
                                ),
                              ),
                            ),
                          ]),
                        ),
                      for (var i = 0; i < _pickedGalleryFiles.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Stack(children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.file(
                                  File(_pickedGalleryFiles[i].path),
                                  width: 84,
                                  height: 84,
                                  fit: BoxFit.cover),
                            ),
                            Positioned(
                              top: 2,
                              right: 2,
                              child: GestureDetector(
                                onTap: () => setState(
                                    () => _pickedGalleryFiles.removeAt(i)),
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle),
                                  child: const Icon(Icons.close_rounded,
                                      size: 16, color: Colors.white),
                                ),
                              ),
                            ),
                          ]),
                        ),
                      if (_existingGalleryUrls.length +
                              _pickedGalleryFiles.length <
                          10)
                        GestureDetector(
                          onTap: _pickGalleryPhotos,
                          child: Container(
                            width: 84,
                            height: 84,
                            decoration: BoxDecoration(
                              color: const Color(0xFF00695C)
                                  .withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: const Color(0xFF00695C)
                                      .withValues(alpha: 0.3)),
                            ),
                            child: const Icon(Icons.add_a_photo_rounded,
                                color: Color(0xFF00695C)),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_galleryUploadStatus != null) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text(_galleryUploadStatus!,
                        style: const TextStyle(fontSize: 12)),
                  ]),
                ],
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Disponibilité
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
              ],
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle_outline_rounded,
                    color: Color(0xFF00695C)),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text("Disponible à la location",
                      style: TextStyle(fontWeight: FontWeight.w500)),
                ),
                Switch(
                  value: _isAvailable,
                  onChanged: (v) => setState(() => _isAvailable = v),
                  activeThumbColor: const Color(0xFF00695C),
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          SizedBox(
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00695C),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 4,
              ),
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.save_rounded, color: Colors.white),
              label: Text(
                _saving
                    ? "Enregistrement…"
                    : (_isEditing ? "Modifier l'annonce" : "Publier l'annonce"),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ),

          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _photoHint() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.add_photo_alternate_rounded,
            size: 48, color: const Color(0xFF00695C).withValues(alpha: 0.5)),
        const SizedBox(height: 8),
        Text("Appuyez pour ajouter une photo",
            style: TextStyle(
                color: const Color(0xFF00695C).withValues(alpha: 0.7),
                fontSize: 13)),
      ],
    );
  }

  Widget _idPhotoHint() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.credit_card_rounded,
            size: 32, color: const Color(0xFF00695C).withValues(alpha: 0.4)),
        const SizedBox(height: 6),
        Text("Photo de la pièce d'identité",
            style: TextStyle(
                color: const Color(0xFF00695C).withValues(alpha: 0.7),
                fontSize: 12)),
        Text("Appuyez pour prendre ou importer",
            style: TextStyle(color: Colors.grey.shade400, fontSize: 11)),
      ],
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType? type, String? hint}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
        ],
      ),
      child: TextField(
        controller: ctrl,
        keyboardType: type,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
          prefixIcon: Icon(icon, color: const Color(0xFF00695C)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
    );
  }
}
