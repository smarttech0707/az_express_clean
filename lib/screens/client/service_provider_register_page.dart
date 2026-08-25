import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';

// Liste complète des sous-catégories disponibles à l'inscription
const _kSubcats = [
  // Artisans
  ('macon', 'Maçon', Icons.domain_rounded),
  ('plombier', 'Plombier', Icons.plumbing_rounded),
  ('electricien', 'Électricien', Icons.electrical_services_rounded),
  ('ferronnier', 'Ferronnier', Icons.hardware_rounded),
  ('menuisier', 'Menuisier', Icons.carpenter_rounded),
  ('carreleur', 'Carreleur', Icons.grid_on_rounded),
  ('peintre', 'Peintre', Icons.format_paint_rounded),
  ('vitrier', 'Vitrier', Icons.window_rounded),
  ('reparateur_tv', 'Réparateur TV', Icons.tv_rounded),
  ('installation_camera', 'Installation caméra', Icons.videocam_rounded),
  ('decoration', 'Décoration intérieure', Icons.home_rounded),
  ('reparateur_portable', 'Réparateur portable', Icons.phone_android_rounded),
  (
    'salon_coiffure_homme',
    'Salon de coiffure homme',
    Icons.content_cut_rounded
  ),
  ('barber_shop', 'Barber Shop', Icons.face_rounded),
  (
    'salon_coiffure_femme',
    'Salon de coiffure femme',
    Icons.face_retouching_natural_rounded
  ),
  ('onglerie', 'Onglerie', Icons.spa_rounded),
  // Mécanique
  ('mecanicien_voiture', 'Mécanicien voiture', Icons.directions_car_rounded),
  ('mecanicien_moto', 'Mécanicien moto', Icons.two_wheeler_rounded),
  (
    'electrique_auto',
    'Électricien automobile',
    Icons.electrical_services_rounded
  ),
  ('carrosserie', 'Carrosserie', Icons.car_repair_rounded),
  // Immobilier
  ('location', 'Location de maison', Icons.home_rounded),
  ('vente_maison', 'Vente de maison', Icons.sell_rounded),
  ('local_commercial', 'Local commercial', Icons.store_rounded),
  ('terrain', 'Terrain', Icons.landscape_rounded),
  // Construction
  ('eau_pack', 'Eau en pack', Icons.water_drop_rounded),
  ('ciment_briques', 'Ciment & Briques', Icons.foundation_rounded),
  // Téléphonie
  ('telephone', 'Téléphones portables', Icons.smartphone_rounded),
  ('accessoires', 'Accessoires téléphonie', Icons.headphones_rounded),
  // Cave
  ('cave_vins', 'Vins & Spiritueux', Icons.wine_bar_rounded),
  ('cave_bieres', 'Bières', Icons.sports_bar_rounded),
  ('cave_sans_alcool', 'Boissons sans alcool', Icons.local_drink_rounded),
];

String _catFor(String id) {
  const map = {
    'macon': 'artisans',
    'plombier': 'artisans',
    'electricien': 'artisans',
    'ferronnier': 'artisans',
    'menuisier': 'artisans',
    'carreleur': 'artisans',
    'peintre': 'artisans',
    'vitrier': 'artisans',
    'reparateur_tv': 'artisans',
    'installation_camera': 'artisans',
    'decoration': 'artisans',
    'reparateur_portable': 'artisans',
    'salon_coiffure_homme': 'artisans',
    'barber_shop': 'artisans',
    'salon_coiffure_femme': 'artisans',
    'onglerie': 'artisans',
    'mecanicien_voiture': 'mecanique',
    'mecanicien_moto': 'mecanique',
    'electrique_auto': 'mecanique',
    'carrosserie': 'mecanique',
    'location': 'immobilier',
    'vente_maison': 'immobilier',
    'local_commercial': 'immobilier',
    'terrain': 'immobilier',
    'eau_pack': 'construction',
    'ciment_briques': 'construction',
    'telephone': 'telephonie',
    'accessoires': 'telephonie',
    'cave_vins': 'cave',
    'cave_bieres': 'cave',
    'cave_sans_alcool': 'cave',
  };
  return map[id] ?? 'artisans';
}

class ServiceProviderRegisterPage extends StatefulWidget {
  const ServiceProviderRegisterPage({super.key});

  @override
  State<ServiceProviderRegisterPage> createState() =>
      _ServiceProviderRegisterPageState();
}

class _ServiceProviderRegisterPageState
    extends State<ServiceProviderRegisterPage> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  String _subcat = _kSubcats.first.$1;
  final List<File> _photos = [];
  bool _loading = false;
  bool _gpsLoading = false;
  double? _lat;
  double? _lng;
  bool _done = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _captureGps() async {
    setState(() => _gpsLoading = true);
    try {
      await Geolocator.requestPermission();
      final pos = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high));
      setState(() {
        _lat = pos.latitude;
        _lng = pos.longitude;
      });
      _snack('Position GPS capturée', Colors.green);
    } catch (_) {
      _snack('Impossible de capturer la position GPS', Colors.orange);
    }
    setState(() => _gpsLoading = false);
  }

  // Limite alignée sur celle du dashboard artisan (artisan_dashboard.dart
  // _maxPhotos) — les deux écrans écrivent le même champ Firestore `photos`,
  // une limite différente à l'inscription vs après approbation n'a pas de
  // justification métier.
  static const int _maxPhotos = 8;

  Future<void> _pickPhoto() async {
    if (_photos.length >= _maxPhotos) {
      _snack('Maximum $_maxPhotos photos', Colors.orange);
      return;
    }
    final src = await _pickSource();
    if (src == null) return;
    final picked = await ImagePicker()
        .pickImage(source: src, imageQuality: 75, maxWidth: 1200);
    if (picked != null) setState(() => _photos.add(File(picked.path)));
  }

  Future<ImageSource?> _pickSource() async {
    return showModalBottomSheet<ImageSource>(
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
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library, color: Color(0xFF1565C0)),
              title: const Text('Choisir depuis la galerie'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final address = _addressCtrl.text.trim();
    if (name.isEmpty || phone.isEmpty || address.isEmpty) {
      _snack('Nom, téléphone et adresse sont obligatoires', Colors.red);
      return;
    }

    setState(() => _loading = true);

    try {
      final docRef =
          FirebaseFirestore.instance.collection('service_providers').doc();
      final docId = docRef.id;

      // Upload photos
      final photoUrls = <String>[];
      for (int i = 0; i < _photos.length; i++) {
        try {
          final ref = FirebaseStorage.instance.ref(
              'service_providers/$docId/photo_${DateTime.now().millisecondsSinceEpoch}_$i.jpg');
          await ref.putFile(_photos[i]);
          photoUrls.add(await ref.getDownloadURL());
        } catch (_) {}
      }

      // Écriture via Cloud Function (Admin SDK) : `service_providers` n'autorise
      // l'écriture qu'à l'admin (allow write: if isAdmin();), sans exception de
      // création pour un prestataire s'inscrivant lui-même — une écriture
      // directe ici échouait toujours avec permission-denied.
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('submitServiceProviderApplication')
          .call({
        'docId': docId,
        'name': name,
        'phone': phone,
        'address': address,
        'description': _descCtrl.text.trim(),
        'subcategory': _subcat,
        'category': _catFor(_subcat),
        'photos': photoUrls,
        'lat': _lat ?? 0.0,
        'lng': _lng ?? 0.0,
      });

      setState(() {
        _loading = false;
        _done = true;
      });
    } catch (e) {
      setState(() => _loading = false);
      _snack('Erreur : $e', Colors.red);
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return _SuccessScreen(onBack: () => Navigator.pop(context));

    return Scaffold(
      backgroundColor: const Color(0xFFF2F3F7),
      appBar: AppBar(
        title: Text('Devenir prestataire',
            style: GoogleFonts.urbanist(
                color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Bannière info
            Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: const Color(0xFF1565C0).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: const Color(0xFF1565C0).withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1565C0),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.storefront_rounded,
                        color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Inscrivez votre activité',
                            style: GoogleFonts.urbanist(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: const Color(0xFF1565C0))),
                        Text(
                          'Votre demande sera examinée par notre équipe. '
                          'Vous serez contacté dans les 24h.',
                          style: GoogleFonts.urbanist(
                              fontSize: 11.5, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── TYPE DE SERVICE ───────────────────────────────────────────
            _card(
              title: 'Type de service',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Sélectionnez votre activité',
                      style: GoogleFonts.urbanist(
                          fontSize: 12, color: Colors.grey.shade600)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _subcat,
                    decoration: _deco('Activité', Icons.category_rounded),
                    isExpanded: true,
                    items: _kSubcats
                        .map((s) => DropdownMenuItem(
                              value: s.$1,
                              child: Row(children: [
                                Icon(s.$3,
                                    size: 16, color: const Color(0xFF1565C0)),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: Text(s.$2,
                                        style:
                                            GoogleFonts.urbanist(fontSize: 13),
                                        overflow: TextOverflow.ellipsis)),
                              ]),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _subcat = v);
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // ── INFORMATIONS ──────────────────────────────────────────────
            _card(
              title: 'Informations',
              child: Column(children: [
                _field(_nameCtrl, 'Nom du prestataire / magasin',
                    Icons.storefront_rounded),
                const SizedBox(height: 12),
                _field(_phoneCtrl, 'Numéro de téléphone', Icons.phone_rounded,
                    type: TextInputType.phone),
                const SizedBox(height: 12),
                _field(_addressCtrl, 'Adresse / Quartier',
                    Icons.location_on_rounded),
                const SizedBox(height: 12),
                _field(_descCtrl, 'Description de vos services (optionnel)',
                    Icons.description_rounded,
                    maxLines: 3),
              ]),
            ),

            const SizedBox(height: 14),

            // ── GPS ───────────────────────────────────────────────────────
            _card(
              title: 'Localisation GPS (optionnel)',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Partagez votre position pour que les clients puissent '
                    'vous trouver facilement sur la carte.',
                    style: GoogleFonts.urbanist(
                        fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _gpsLoading ? null : _captureGps,
                      icon: _gpsLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.my_location_rounded,
                              color: Colors.white, size: 18),
                      label: Text(
                        _lat != null
                            ? 'Position capturée ✓'
                            : _gpsLoading
                                ? 'Localisation…'
                                : 'Capturer ma position GPS',
                        style: GoogleFonts.urbanist(
                            color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _lat != null
                            ? Colors.green
                            : const Color(0xFF1565C0),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // ── PHOTOS ────────────────────────────────────────────────────
            _card(
              title: 'Photos de votre travail (optionnel)',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ajoutez jusqu\'à $_maxPhotos photos pour montrer votre travail.',
                    style: GoogleFonts.urbanist(
                        fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 10),
                  if (_photos.isNotEmpty) ...[
                    SizedBox(
                      height: 90,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: _photos.asMap().entries.map((e) {
                          return Stack(children: [
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
                              top: 3,
                              right: 11,
                              child: GestureDetector(
                                onTap: () =>
                                    setState(() => _photos.removeAt(e.key)),
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle),
                                  child: const Icon(Icons.close,
                                      color: Colors.white, size: 11),
                                ),
                              ),
                            ),
                          ]);
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (_photos.length < 5)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _pickPhoto,
                        icon: const Icon(Icons.add_a_photo_rounded,
                            color: Color(0xFF1565C0), size: 18),
                        label: Text('Ajouter une photo',
                            style: GoogleFonts.urbanist(
                                color: const Color(0xFF1565C0),
                                fontWeight: FontWeight.w600)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF1565C0)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ── BOUTON SOUMETTRE ──────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: _loading ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
                child: _loading
                    ? const CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5)
                    : Text('Envoyer ma demande',
                        style: GoogleFonts.urbanist(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _card({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: GoogleFonts.urbanist(
                  fontWeight: FontWeight.bold,
                  fontSize: 13.5,
                  color: const Color(0xFF1565C0))),
          const SizedBox(height: 12),
          child,
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
      style: GoogleFonts.urbanist(fontSize: 14),
      decoration: _deco(label, icon),
    );
  }

  InputDecoration _deco(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      labelStyle: GoogleFonts.urbanist(fontSize: 13),
      prefixIcon: Icon(icon, color: const Color(0xFF1565C0), size: 20),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF1565C0), width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }
}

// ── ÉCRAN DE SUCCÈS ────────────────────────────────────────────────────────

class _SuccessScreen extends StatelessWidget {
  final VoidCallback onBack;
  const _SuccessScreen({required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F3F7),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle_rounded,
                    color: Colors.green, size: 60),
              ),
              const SizedBox(height: 24),
              Text(
                'Demande envoyée !',
                style: GoogleFonts.urbanist(
                    fontSize: 22, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Votre demande d\'inscription a bien été reçue.\n'
                'Notre équipe va l\'examiner et vous contactera '
                'dans les 24 heures.',
                style: GoogleFonts.urbanist(
                    fontSize: 14, color: Colors.grey.shade600, height: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: onBack,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1565C0),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text('Retour',
                      style: GoogleFonts.urbanist(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
