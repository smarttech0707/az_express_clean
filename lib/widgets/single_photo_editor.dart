import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../theme/app_theme.dart';

/// Avatar/photo unique avec ajout, remplacement et barre de progression
/// réelle pendant l'upload — un seul widget, réutilisé par chaque rôle qui a
/// besoin d'une photo de profil/logo unique (client, vendeur, restaurant,
/// pharmacie, boulangerie, agent E-Kbine), cohérent avec le pattern déjà
/// établi par `showPartnerAccountSheet`/`showLogoutConfirmDialog` (jamais
/// dupliqué par écran).
///
/// Ce widget ne fait que l'upload Storage + le rendu — l'écriture Firestore
/// (quel champ, quelle collection, quelle preuve de propriété) reste dans
/// [onUploaded], propre à chaque appelant : les règles de sécurité diffèrent
/// trop d'un rôle à l'autre (ex. pharmacie utilise `currentUid`, pas
/// `request.auth.uid == docId`) pour être généralisées ici sans risque.
class SinglePhotoEditor extends StatefulWidget {
  final String? photoUrl;
  final String storagePath;
  final double size;
  final IconData placeholderIcon;

  /// Appelé après un upload Storage réussi, avec l'URL de téléchargement —
  /// doit faire l'écriture Firestore (peut lever une exception : dans ce
  /// cas l'erreur est affichée et la photo locale n'est pas mise à jour).
  final Future<void> Function(String url) onUploaded;

  const SinglePhotoEditor({
    super.key,
    required this.photoUrl,
    required this.storagePath,
    required this.onUploaded,
    this.size = 84,
    this.placeholderIcon = Icons.person_rounded,
  });

  @override
  State<SinglePhotoEditor> createState() => _SinglePhotoEditorState();
}

class _SinglePhotoEditorState extends State<SinglePhotoEditor> {
  bool _uploading = false;
  double _progress = 0;
  String? _localUrl;

  String? get _displayUrl => _localUrl ?? widget.photoUrl;

  Future<void> _pickAndUpload(ImageSource source) async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: source,
        imageQuality: 70,
        maxWidth: 1024,
      );
    } catch (e) {
      _snack('Impossible d\'accéder à la caméra/galerie.', Colors.red);
      return;
    }
    if (picked == null) return;

    setState(() {
      _uploading = true;
      _progress = 0;
    });

    try {
      final file = File(picked.path);
      final ref = FirebaseStorage.instance.ref(widget.storagePath);
      final task = ref.putFile(
        file,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      task.snapshotEvents.listen((snap) {
        if (!mounted || snap.totalBytes <= 0) return;
        setState(() => _progress = snap.bytesTransferred / snap.totalBytes);
      });
      await task;
      final url = await ref.getDownloadURL();

      await widget.onUploaded(url);

      if (!mounted) return;
      setState(() => _localUrl = url);
      _snack('Photo mise à jour !', Colors.green);
    } on FirebaseException catch (e) {
      _snack(
        e.code == 'unauthorized'
            ? 'Vous n\'êtes pas autorisé à modifier cette photo.'
            : 'Erreur réseau — vérifiez votre connexion et réessayez.',
        Colors.red,
      );
    } catch (e) {
      _snack('Erreur lors de l\'envoi de la photo.', Colors.red);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  void _showSourceSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded),
              title: const Text('Prendre une photo'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndUpload(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Choisir dans la galerie'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndUpload(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = _displayUrl;
    return GestureDetector(
      onTap: _uploading ? null : _showSourceSheet,
      child: Semantics(
        button: true,
        label: url != null ? 'Modifier la photo' : 'Ajouter une photo',
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: widget.size / 2,
                backgroundColor: AppColors.primaryBg,
                backgroundImage:
                    url != null ? NetworkImage(url) : null,
                child: url == null
                    ? Icon(widget.placeholderIcon,
                        size: widget.size * 0.5, color: AppColors.primary)
                    : null,
              ),
              if (_uploading)
                Positioned.fill(
                  child: CircleAvatar(
                    backgroundColor: Colors.black.withValues(alpha: 0.45),
                    child: SizedBox(
                      width: widget.size * 0.5,
                      height: widget.size * 0.5,
                      child: CircularProgressIndicator(
                        value: _progress > 0 ? _progress : null,
                        strokeWidth: 3,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              if (!_uploading)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(Icons.camera_alt_rounded,
                        size: 14, color: Colors.white),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
