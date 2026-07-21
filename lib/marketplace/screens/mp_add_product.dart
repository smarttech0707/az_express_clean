import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:typed_data';
import '../mp_constants.dart';
import '../models/mp_product.dart';
import '../services/mp_service.dart';

class MpAddProductScreen extends StatefulWidget {
  final MpProduct? editProduct; // null = new product
  const MpAddProductScreen({super.key, this.editProduct});

  @override
  State<MpAddProductScreen> createState() => _MpAddProductScreenState();
}

class _MpAddProductScreenState extends State<MpAddProductScreen> {
  final _formKey = GlobalKey<FormState>();

  // Controllers
  final _titleCtrl   = TextEditingController();
  final _descCtrl    = TextEditingController();
  final _priceCtrl   = TextEditingController();
  final _batteryCtrl = TextEditingController();

  // Selections
  String _category  = 'phones';
  String _condition = 'used';
  String _brand     = '';
  String? _storage;
  String? _ram;
  String? _color;
  String _city      = 'Abengourou';

  // Images
  final List<XFile>  _newImages   = [];
  final List<String> _existingUrls = [];
  final _picker = ImagePicker();
  bool _uploading = false;

  bool get _isEdit => widget.editProduct != null;

  @override
  void initState() {
    super.initState();
    final p = widget.editProduct;
    if (p != null) {
      _titleCtrl.text   = p.title;
      _descCtrl.text    = p.description;
      _priceCtrl.text   = p.price.toString();
      _batteryCtrl.text = p.battery ?? '';
      _category  = p.category;
      _condition = p.condition;
      _brand     = p.brand;
      _storage   = p.storage;
      _ram       = p.ram;
      _color     = p.color;
      _city      = p.city;
      _existingUrls.addAll(p.images);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _batteryCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImages() async {
    final picked = await _picker.pickMultiImage(imageQuality: 75);
    if (picked.isNotEmpty) {
      final total = _existingUrls.length + _newImages.length + picked.length;
      if (total > 6) {
        _snack('Maximum 6 photos', Colors.orange);
        return;
      }
      setState(() => _newImages.addAll(picked));
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_brand.isEmpty) {
      _snack('Sélectionnez une marque', Colors.orange);
      return;
    }
    if (_existingUrls.isEmpty && _newImages.isEmpty) {
      _snack('Ajoutez au moins une photo', Colors.orange);
      return;
    }

    setState(() => _uploading = true);

    try {
      final user = FirebaseAuth.instance.currentUser!;
      // Get seller info
      String sellerName  = user.displayName ?? 'Vendeur';
      String sellerPhone = '';
      try {
        final doc = await FirebaseFirestore.instance
            .collection('clients').doc(user.uid).get();
        if (doc.exists) {
          sellerName  = doc.data()?['name'] ?? sellerName;
          sellerPhone = doc.data()?['phone'] ?? '';
        }
      } catch (_) {}

      final productId = _isEdit ? widget.editProduct!.id : '';

      // Upload new images
      List<String> uploadedUrls = [];
      if (_newImages.isNotEmpty) {
        final id = _isEdit ? productId : 'tmp_${DateTime.now().millisecondsSinceEpoch}';
        uploadedUrls = await MpService.uploadImages(_newImages, id);
      }

      final allImages = [..._existingUrls, ...uploadedUrls];

      final data = MpProduct(
        id: productId,
        sellerId:      user.uid,
        sellerName:    sellerName,
        sellerPhone:   sellerPhone,
        sellerCity:    _city,
        sellerVerified: false,
        title:       _titleCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        price:       int.parse(_priceCtrl.text.trim().replaceAll(' ', '')),
        category:    _category,
        brand:       _brand,
        condition:   _condition,
        storage:     _storage,
        ram:         _ram,
        color:       _color,
        battery:     _batteryCtrl.text.trim().isEmpty
            ? null
            : _batteryCtrl.text.trim(),
        images:      allImages,
        city:        _city,
        status:      'active',
      ).toMap();

      if (_isEdit) {
        // For edits, don't overwrite createdAt
        final updateData = Map<String, dynamic>.from(data)
          ..remove('createdAt')
          ..remove('views')
          ..remove('favoritesCount')
          ..['images'] = allImages;
        await MpService.updateProduct(productId, updateData);
      } else {
        await MpService.addProduct(data);
      }

      if (!mounted) return;
      _snack(
          _isEdit ? 'Annonce mise à jour !' : 'Annonce publiée ! 🎉',
          Colors.green);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _snack('Erreur : $e', Colors.red);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kMpBg,
      appBar: AppBar(
        title: Text(
          _isEdit ? 'Modifier l\'annonce' : 'Nouvelle annonce',
          style: GoogleFonts.urbanist(
              fontSize: 16, fontWeight: FontWeight.w700, color: kMpText),
        ),
        backgroundColor: Colors.white,
        foregroundColor: kMpText,
        elevation: 0,
        centerTitle: true,
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Photos
              _Section(
                title: 'Photos',
                child: Column(
                  children: [
                    if (_existingUrls.isNotEmpty || _newImages.isNotEmpty)
                      SizedBox(
                        height: 90,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            ..._existingUrls.asMap().entries.map((e) => _ImgThumb(
                              networkUrl: e.value,
                              onRemove: () =>
                                  setState(() => _existingUrls.removeAt(e.key)),
                            )),
                            ..._newImages.asMap().entries.map((e) => _ImgThumbLocal(
                              xfile: e.value,
                              onRemove: () =>
                                  setState(() => _newImages.removeAt(e.key)),
                            )),
                          ],
                        ),
                      ),
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: _pickImages,
                      child: Container(
                        height: 52,
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: kMpOrange,
                              style: BorderStyle.solid),
                          borderRadius: BorderRadius.circular(12),
                          color: kMpOrange.withValues(alpha: 0.05),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.add_photo_alternate_rounded,
                                color: kMpOrange),
                            const SizedBox(width: 8),
                            Text('Ajouter des photos',
                                style: GoogleFonts.urbanist(
                                    color: kMpOrange,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_existingUrls.length + _newImages.length}/6 photos  •  Première photo = couverture',
                      style: GoogleFonts.urbanist(
                          fontSize: 11, color: kMpMuted),
                    ),
                  ],
                ),
              ),

              // Category
              _Section(
                title: 'Catégorie',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: mpCategories
                      .map((c) => _SelChip(
                            label: '${c['emoji']} ${c['label']}',
                            selected: _category == c['id'],
                            onTap: () => setState(() {
                              _category = c['id']!;
                              _brand = '';
                            }),
                          ))
                      .toList(),
                ),
              ),

              // Brand
              _Section(
                title: 'Marque',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: brandsForCategory(_category)
                      .map((b) => _SelChip(
                            label: b,
                            selected: _brand == b,
                            onTap: () => setState(() => _brand = b),
                          ))
                      .toList(),
                ),
              ),

              // Condition
              _Section(
                title: 'État du produit',
                child: Row(
                  children: mpConditions
                      .map((c) => Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => _condition = c['id'] as String),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                margin: const EdgeInsets.only(right: 8),
                                padding: const EdgeInsets.symmetric(
                                    vertical: 12),
                                decoration: BoxDecoration(
                                  color: _condition == c['id']
                                      ? Color(c['color']! as int)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: _condition == c['id']
                                        ? Color(c['color']! as int)
                                        : kMpDivider,
                                  ),
                                ),
                                child: Column(children: [
                                  Text(
                                    c['id'] == 'new'
                                        ? '🌟'
                                        : c['id'] == 'like_new'
                                            ? '✨'
                                            : '💡',
                                    style: const TextStyle(fontSize: 20),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    c['label']! as String,
                                    style: GoogleFonts.urbanist(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: _condition == c['id']
                                          ? Colors.white
                                          : kMpText,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ]),
                              ),
                            ),
                          ))
                      .toList(),
                ),
              ),

              // Title
              _Section(
                title: 'Titre de l\'annonce',
                child: TextFormField(
                  controller: _titleCtrl,
                  validator: (v) =>
                      (v?.trim().isEmpty ?? true) ? 'Obligatoire' : null,
                  decoration: _deco('Ex: iPhone 13 Pro Max 256Go Blanc',
                      Icons.title_rounded),
                  style: GoogleFonts.urbanist(fontSize: 14, color: kMpText),
                ),
              ),

              // Price
              _Section(
                title: 'Prix (FCFA)',
                child: TextFormField(
                  controller: _priceCtrl,
                  keyboardType: TextInputType.number,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Obligatoire';
                    final n = int.tryParse(v.trim().replaceAll(' ', ''));
                    if (n == null || n <= 0) return 'Prix invalide';
                    return null;
                  },
                  decoration: _deco('Ex: 150000', Icons.payments_rounded),
                  style: GoogleFonts.urbanist(fontSize: 14, color: kMpText),
                ),
              ),

              // Description
              _Section(
                title: 'Description',
                child: TextFormField(
                  controller: _descCtrl,
                  maxLines: 4,
                  validator: (v) =>
                      (v?.trim().isEmpty ?? true) ? 'Obligatoire' : null,
                  decoration: _deco(
                      'Décrivez l\'état, les accessoires inclus...',
                      Icons.description_rounded),
                  style: GoogleFonts.urbanist(fontSize: 14, color: kMpText),
                ),
              ),

              // Specs (optional)
              _Section(
                title: 'Spécifications (optionnel)',
                child: Column(
                  children: [
                    _dropRow('Stockage', storageOptions, _storage,
                        (v) => setState(() => _storage = v)),
                    const SizedBox(height: 10),
                    _dropRow('RAM', ramOptions, _ram,
                        (v) => setState(() => _ram = v)),
                    const SizedBox(height: 10),
                    _dropRow('Couleur', deviceColors, _color,
                        (v) => setState(() => _color = v)),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _batteryCtrl,
                      decoration: _deco('Batterie (ex: 4500 mAh)',
                          Icons.battery_full_rounded),
                      style: GoogleFonts.urbanist(fontSize: 14, color: kMpText),
                    ),
                  ],
                ),
              ),

              // City
              _Section(
                title: 'Ville',
                child: DropdownButtonFormField<String>(
                  initialValue: _city,
                  items: mpCities
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) => setState(() => _city = v ?? _city),
                  decoration: _deco('Votre ville', Icons.location_city_rounded),
                  style: GoogleFonts.urbanist(fontSize: 14, color: kMpText),
                ),
              ),

              const SizedBox(height: 24),

              // Submit
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ScaleButton(
                  onPressed: _uploading ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kMpOrange,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    elevation: 4,
                  ),
                  child: _uploading
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2),
                            ),
                            SizedBox(width: 10),
                            Text('Publication en cours...'),
                          ],
                        )
                      : Text(
                          _isEdit ? 'Mettre à jour' : 'Publier l\'annonce',
                          style: GoogleFonts.urbanist(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _deco(String hint, IconData icon) => InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.urbanist(color: kMpMuted, fontSize: 13),
        prefixIcon: Icon(icon, color: kMpOrange, size: 20),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kMpDivider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kMpDivider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kMpOrange, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      );

  Widget _dropRow(String label, List<String> options, String? selectedValue,
      ValueChanged<String?> onChanged) {
    return DropdownButtonFormField<String>(
      initialValue: selectedValue,
      hint: Text('$label (optionnel)',
          style: GoogleFonts.urbanist(color: kMpMuted, fontSize: 13)),
      items: options
          .map((o) => DropdownMenuItem(
                value: o,
                child:
                    Text(o, style: GoogleFonts.urbanist(fontSize: 14, color: kMpText)),
              ))
          .toList(),
      onChanged: onChanged,
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kMpDivider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kMpDivider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: kMpOrange, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.urbanist(color: Colors.white)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: GoogleFonts.urbanist(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: kMpText)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _SelChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SelChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? kMpOrange : kMpBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected ? kMpOrange : kMpDivider),
        ),
        child: Text(label,
            style: GoogleFonts.urbanist(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : kMpText,
            )),
      ),
    );
  }
}

class _ImgThumb extends StatelessWidget {
  final String networkUrl;
  final VoidCallback onRemove;
  const _ImgThumb({required this.networkUrl, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          width: 80,
          height: 80,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            image: DecorationImage(
              image: NetworkImage(networkUrl),
              fit: BoxFit.cover,
            ),
          ),
        ),
        Positioned(
          top: 2,
          right: 10,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(
                  color: Colors.red, shape: BoxShape.circle),
              child: const Icon(Icons.close_rounded,
                  color: Colors.white, size: 12),
            ),
          ),
        ),
      ],
    );
  }
}

class _ImgThumbLocal extends StatelessWidget {
  final XFile xfile;
  final VoidCallback onRemove;
  const _ImgThumbLocal({required this.xfile, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: xfile.readAsBytes(),
      builder: (_, snap) {
        return Stack(
          children: [
            Container(
              width: 80,
              height: 80,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: kMpBg,
                image: snap.hasData
                    ? DecorationImage(
                        image: MemoryImage(snap.data!),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: snap.hasData
                  ? null
                  : const Center(
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: kMpOrange))),
            ),
            Positioned(
              top: 2,
              right: 10,
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  child: const Icon(Icons.close_rounded,
                      color: Colors.white, size: 12),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

