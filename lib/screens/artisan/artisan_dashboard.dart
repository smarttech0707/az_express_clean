import 'dart:io';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/auth_service.dart';

class ArtisanDashboard extends StatefulWidget {
  final String docId;
  final Map<String, dynamic> initialData;

  const ArtisanDashboard({
    super.key,
    required this.docId,
    required this.initialData,
  });

  @override
  State<ArtisanDashboard> createState() => _ArtisanDashboardState();
}

class _ArtisanDashboardState extends State<ArtisanDashboard> {
  late List<String> _photos;
  bool _uploading = false;
  static const int _maxPhotos = 8;

  @override
  void initState() {
    super.initState();
    _photos = (widget.initialData['photos'] as List?)?.cast<String>() ?? [];
  }

  Future<void> _pickAndUpload(ImageSource source) async {
    if (_photos.length >= _maxPhotos) {
      _snack("Maximum $_maxPhotos photos autorisées", Colors.orange);
      return;
    }
    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: source, imageQuality: 75, maxWidth: 1280);
    if (picked == null) return;

    setState(() => _uploading = true);
    try {
      final file = File(picked.path);
      final ref = FirebaseStorage.instance.ref(
          'service_providers/${widget.docId}/photo_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await ref.putFile(file);
      final url = await ref.getDownloadURL();
      final updated = [..._photos, url];
      await FirebaseFirestore.instance
          .collection('service_providers')
          .doc(widget.docId)
          .update({'photos': updated});
      setState(() => _photos = updated);
      _snack("Photo ajoutée avec succès !", Colors.green);
    } catch (e) {
      _snack("Erreur upload : $e", Colors.red);
    }
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _deletePhoto(int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Supprimer la photo"),
        content: const Text("Voulez-vous supprimer cette photo de votre profil ?"),
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
    if (confirmed != true) return;

    setState(() => _uploading = true);
    try {
      // Delete from Storage
      try {
        await FirebaseStorage.instance.refFromURL(_photos[index]).delete();
      } catch (_) {}
      final updated = [..._photos]..removeAt(index);
      await FirebaseFirestore.instance
          .collection('service_providers')
          .doc(widget.docId)
          .update({'photos': updated});
      setState(() => _photos = updated);
      _snack("Photo supprimée", Colors.green);
    } catch (e) {
      _snack("Erreur : $e", Colors.red);
    }
    if (mounted) setState(() => _uploading = false);
  }

  void _showPhotoSourceSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Text("Ajouter une photo",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.camera_alt,
                  color: Color(0xFF1565C0)),
              title: const Text("Prendre une photo"),
              onTap: () {
                Navigator.pop(context);
                _pickAndUpload(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library,
                  color: Color(0xFF1565C0)),
              title: const Text("Choisir depuis la galerie"),
              onTap: () {
                Navigator.pop(context);
                _pickAndUpload(ImageSource.gallery);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showFullPhoto(int index) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            InteractiveViewer(
              child: Center(
                child: Image.network(_photos[index],
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image,
                            color: Colors.white, size: 64)),
              ),
            ),
            Positioned(
              top: 40,
              right: 16,
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(
                      color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(Icons.close,
                      color: Colors.white, size: 22),
                ),
              ),
            ),
            Positioned(
              bottom: 40,
              right: 16,
              child: GestureDetector(
                onTap: () {
                  Navigator.pop(context);
                  _deletePhoto(index);
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.85),
                      shape: BoxShape.circle),
                  child: const Icon(Icons.delete_outline,
                      color: Colors.white, size: 22),
                ),
              ),
            ),
          ],
        ),
      ),
    );
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

  Future<void> _logout() async {
    AuthService().logAuthEvent('logout', 'artisan');
    await FirebaseAuth.instance.signOut();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.initialData['name'] as String? ?? 'Mon profil';
    final address = widget.initialData['address'] as String? ?? '';
    final subcat = widget.initialData['subcategory'] as String? ?? '';
    final isAvailable = widget.initialData['isAvailable'] as bool? ?? true;
    final remaining = _maxPhotos - _photos.length;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(name,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
            tooltip: "Déconnexion",
          ),
        ],
      ),
      body: _uploading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFF1565C0)),
                  SizedBox(height: 16),
                  Text("Traitement en cours...",
                      style: TextStyle(color: Colors.grey)),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Carte profil ──────────────────────────
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 10,
                            offset: const Offset(0, 4))
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: const BoxDecoration(
                            color: Color(0xFFE3F2FD),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.handyman_rounded,
                              color: Color(0xFF1565C0), size: 30),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                              if (subcat.isNotEmpty)
                                Text(subcat,
                                    style: const TextStyle(
                                        color: Color(0xFF1565C0),
                                        fontSize: 13)),
                              if (address.isNotEmpty)
                                Row(children: [
                                  Icon(Icons.location_on,
                                      size: 12,
                                      color: Colors.grey.shade500),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      address,
                                      style: TextStyle(
                                          color: Colors.grey.shade600,
                                          fontSize: 12),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ]),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isAvailable
                                ? Colors.green.shade50
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: isAvailable
                                    ? Colors.green
                                    : Colors.grey),
                          ),
                          child: Text(
                            isAvailable ? "Actif" : "Masqué",
                            style: TextStyle(
                                color: isAvailable
                                    ? Colors.green
                                    : Colors.grey,
                                fontSize: 11,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ── En-tête photos ────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "Mes photos (${_photos.length}/$_maxPhotos)",
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      if (remaining > 0)
                        Text(
                          "$remaining emplacement${remaining > 1 ? 's' : ''} libre${remaining > 1 ? 's' : ''}",
                          style: TextStyle(
                              color: Colors.grey.shade500, fontSize: 12),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    "Ajoutez des photos de vos réalisations pour attirer plus de clients.",
                    style:
                        TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),

                  const SizedBox(height: 16),

                  // ── Grille de photos ──────────────────────
                  if (_photos.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 48),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: const Color(0xFF1565C0).withValues(alpha: 0.2),
                            width: 1.5),
                      ),
                      child: Column(
                        children: [
                          Icon(Icons.add_photo_alternate_outlined,
                              size: 72, color: Colors.grey.shade300),
                          const SizedBox(height: 12),
                          Text("Aucune photo pour le moment",
                              style: TextStyle(
                                  color: Colors.grey.shade500, fontSize: 15)),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: _showPhotoSourceSheet,
                            icon: const Icon(Icons.add_a_photo,
                                color: Colors.white),
                            label: const Text("Ajouter ma première photo",
                                style: TextStyle(color: Colors.white)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1565C0),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      itemCount: _photos.length +
                          (_photos.length < _maxPhotos ? 1 : 0),
                      itemBuilder: (context, i) {
                        // Bouton "Ajouter" en dernière position
                        if (i == _photos.length) {
                          return GestureDetector(
                            onTap: _showPhotoSourceSheet,
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFFE3F2FD),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: const Color(0xFF1565C0),
                                    width: 1.5),
                              ),
                              child: const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_a_photo,
                                      color: Color(0xFF1565C0), size: 28),
                                  SizedBox(height: 6),
                                  Text("Ajouter",
                                      style: TextStyle(
                                          color: Color(0xFF1565C0),
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                          );
                        }
                        return Stack(
                          children: [
                            GestureDetector(
                              onTap: () => _showFullPhoto(i),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.network(
                                  _photos[i],
                                  width: double.infinity,
                                  height: double.infinity,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    color: Colors.grey.shade200,
                                    child: const Icon(Icons.broken_image,
                                        color: Colors.grey),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: GestureDetector(
                                onTap: () => _deletePhoto(i),
                                child: Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: Colors.red.withValues(alpha: 0.85),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.delete_outline,
                                      color: Colors.white, size: 14),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),

                  const SizedBox(height: 30),

                  // ── Bouton ajouter en bas si déjà des photos ──
                  if (_photos.isNotEmpty && _photos.length < _maxPhotos)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _showPhotoSourceSheet,
                        icon: const Icon(Icons.add_a_photo,
                            color: Color(0xFF1565C0)),
                        label: const Text("Ajouter une photo",
                            style: TextStyle(color: Color(0xFF1565C0))),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF1565C0)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),

                  const SizedBox(height: 16),
                ],
              ),
            ),
    );
  }
}

