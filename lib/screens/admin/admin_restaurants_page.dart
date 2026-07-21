import 'dart:io';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/subscription_service.dart';

class AdminRestaurantsPage extends StatelessWidget {
  const AdminRestaurantsPage({super.key});

  void _showAddRestaurant(BuildContext context) {
    final nameCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final categoryCtrl = TextEditingController();
    final minCtrl = TextEditingController(text: "500");
    final latCtrl = TextEditingController();
    final lngCtrl = TextEditingController();
    bool isOpen = true;
    bool gpsLoading = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text("Ajouter un restaurant"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dialogField(nameCtrl, "Nom du restaurant", Icons.store),
                const SizedBox(height: 10),
                _dialogField(addressCtrl, "Adresse", Icons.location_on),
                const SizedBox(height: 10),
                _dialogField(categoryCtrl, "Catégorie (ex: Ivoirien, Fast food)",
                    Icons.category),
                const SizedBox(height: 10),
                _dialogField(minCtrl, "Livraison min (FCFA)", Icons.delivery_dining,
                    type: TextInputType.number),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _dialogField(
                        latCtrl,
                        "Latitude",
                        Icons.gps_fixed,
                        type: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _dialogField(
                        lngCtrl,
                        "Longitude",
                        Icons.gps_not_fixed,
                        type: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: gpsLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location, size: 18),
                    label: Text(
                        gpsLoading ? "Localisation..." : "Ma position GPS"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1565C0),
                      side: const BorderSide(color: Color(0xFF1565C0)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: gpsLoading
                        ? null
                        : () async {
                            setS(() => gpsLoading = true);
                            try {
                              bool svc =
                                  await Geolocator.isLocationServiceEnabled();
                              if (!svc) {
                                setS(() => gpsLoading = false);
                                return;
                              }
                              LocationPermission perm =
                                  await Geolocator.checkPermission();
                              if (perm == LocationPermission.denied) {
                                perm =
                                    await Geolocator.requestPermission();
                                if (perm == LocationPermission.denied) {
                                  setS(() => gpsLoading = false);
                                  return;
                                }
                              }
                              final pos =
                                  await Geolocator.getCurrentPosition();
                              setS(() {
                                latCtrl.text =
                                    pos.latitude.toStringAsFixed(6);
                                lngCtrl.text =
                                    pos.longitude.toStringAsFixed(6);
                                gpsLoading = false;
                              });
                            } catch (_) {
                              setS(() => gpsLoading = false);
                            }
                          },
                  ),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  value: isOpen,
                  onChanged: (v) => setS(() => isOpen = v),
                  title: const Text("Ouvert"),
                  activeThumbColor: Colors.green,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Annuler"),
            ),
            ScaleButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                await FirebaseFirestore.instance
                    .collection("restaurants")
                    .add({
                  "name": name,
                  "address": addressCtrl.text.trim(),
                  "category": categoryCtrl.text.trim().isEmpty
                      ? "Cuisine locale"
                      : categoryCtrl.text.trim(),
                  "minDelivery":
                      int.tryParse(minCtrl.text.trim()) ?? 500,
                  "isOpen": isOpen,
                  "lat": double.tryParse(latCtrl.text.trim()) ?? 0.0,
                  "lng": double.tryParse(lngCtrl.text.trim()) ?? 0.0,
                  "createdAt": Timestamp.now(),
                });
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text("Ajouter"),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleOpen(DocumentSnapshot doc, bool current) {
    doc.reference.update({"isOpen": !current});
  }

  void _deleteRestaurant(BuildContext context, DocumentSnapshot doc) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Supprimer ?"),
        content: Text(
            "Supprimer \"${(doc.data() as Map)['name']}\" et tous ses plats ?"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Annuler")),
          ScaleButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(ctx);
              // supprimer les plats
              final menus = await FirebaseFirestore.instance
                  .collection("restaurants")
                  .doc(doc.id)
                  .collection("menu")
                  .get();
              for (final m in menus.docs) {
                await m.reference.delete();
              }
              await doc.reference.delete();
            },
            child: const Text("Supprimer"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text("Restaurants"),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text("Ajouter"),
        onPressed: () => _showAddRestaurant(context),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection("restaurants")
            .orderBy("name")
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.restaurant_outlined,
                      size: 72, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  const Text(
                    "Aucun restaurant",
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "Appuyez sur + pour en ajouter un",
                    style: TextStyle(color: Colors.grey),
                  ),
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
              final isOpen = data["isOpen"] ?? true;
              final subStatus = data["subscriptionStatus"] as String? ?? 'active';
              final vipStatus = data["vipStatus"] as String? ?? 'none';

              return Container(
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.07),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      leading: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1565C0).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(Icons.restaurant,
                            color: Color(0xFF1565C0), size: 26),
                      ),
                      title: Row(children: [
                        Expanded(
                          child: Text(
                            data["name"] ?? "—",
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                        Container(
                          width: 10, height: 10,
                          margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            color: subStatus == 'active' ? Colors.green
                                : subStatus == 'trial' ? Colors.blue
                                : Colors.red,
                            shape: BoxShape.circle,
                          ),
                        ),
                        if (vipStatus == 'active')
                          const Text('👑', style: TextStyle(fontSize: 13)),
                      ]),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(data["address"] ?? "",
                              style: const TextStyle(fontSize: 12)),
                          const SizedBox(height: 2),
                          Text(
                            data["category"] ?? "",
                            style: TextStyle(
                                color: Colors.blue.shade700, fontSize: 12),
                          ),
                        ],
                      ),
                      trailing: Switch(
                        value: isOpen,
                        onChanged: (_) => _toggleOpen(doc, isOpen),
                        activeThumbColor: Colors.green,
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    // Boutons actions
                    Row(
                      children: [
                        // Gérer le menu
                        Expanded(
                          child: TextButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => _MenuManagePage(
                                  restaurantId: doc.id,
                                  restaurantName: data["name"] ?? "",
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.menu_book,
                                size: 18, color: Color(0xFF1565C0)),
                            label: const Text(
                              "Menu",
                              style: TextStyle(color: Color(0xFF1565C0)),
                            ),
                          ),
                        ),
                        // Abonnement
                        Expanded(
                          child: TextButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => _RestaurantSubPage(
                                  docId: doc.id,
                                  data: data,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.workspace_premium_rounded,
                                size: 18, color: Colors.amber),
                            label: const Text(
                              "Abo",
                              style: TextStyle(color: Colors.amber),
                            ),
                          ),
                        ),
                        // Supprimer
                        Expanded(
                          child: TextButton.icon(
                            onPressed: () =>
                                _deleteRestaurant(context, doc),
                            icon: const Icon(Icons.delete_outline,
                                size: 18, color: Colors.red),
                            label: const Text(
                              "Supprimer",
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ── PAGE GESTION MENU DU RESTAURANT ──────────────────────────

class _MenuManagePage extends StatelessWidget {
  final String restaurantId;
  final String restaurantName;

  const _MenuManagePage({
    required this.restaurantId,
    required this.restaurantName,
  });

  void _goToAddItem(BuildContext context, [DocumentSnapshot? existing]) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _AddMenuItemPage(
          restaurantId: restaurantId,
          existing: existing,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(restaurantName),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text("Ajouter un plat"),
        onPressed: () => _goToAddItem(context),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection("restaurants")
            .doc(restaurantId)
            .collection("menu")
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.no_food, size: 72, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  const Text("Aucun plat",
                      style: TextStyle(fontSize: 16, color: Colors.grey)),
                  const SizedBox(height: 8),
                  const Text("Appuyez sur + pour ajouter des plats",
                      style: TextStyle(color: Colors.grey)),
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
              final imageUrl = (data["imageUrl"] as String?) ?? "";

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: imageUrl.isNotEmpty
                        ? Image.network(
                            imageUrl,
                            width: 54,
                            height: 54,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _menuIcon(),
                          )
                        : _menuIcon(),
                  ),
                  title: Text(
                    data["name"] ?? "—",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: data["description"] != null &&
                          (data["description"] as String).isNotEmpty
                      ? Text(data["description"],
                          style: const TextStyle(fontSize: 12))
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "${data['price'] ?? 0} FCFA",
                        style: const TextStyle(
                          color: Color(0xFF1565C0),
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined,
                            color: Colors.grey, size: 20),
                        onPressed: () => _goToAddItem(context, doc),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.red, size: 20),
                        onPressed: () => doc.reference.delete(),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ── PAGE AJOUT / MODIFICATION PLAT ───────────────────────────

class _AddMenuItemPage extends StatefulWidget {
  final String restaurantId;
  final DocumentSnapshot? existing;

  const _AddMenuItemPage({required this.restaurantId, this.existing});

  @override
  State<_AddMenuItemPage> createState() => _AddMenuItemPageState();
}

class _AddMenuItemPageState extends State<_AddMenuItemPage> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  File? _imageFile;
  String? _existingImageUrl;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final d = widget.existing!.data() as Map<String, dynamic>;
      _nameCtrl.text = d["name"] ?? "";
      _descCtrl.text = d["description"] ?? "";
      _priceCtrl.text = "${d['price'] ?? ''}";
      _existingImageUrl = d["imageUrl"];
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource src) async {
    final img = await ImagePicker().pickImage(source: src, imageQuality: 80);
    if (img != null && mounted) setState(() => _imageFile = File(img.path));
  }

  void _showImageOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF1565C0).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.camera_alt, color: Color(0xFF1565C0)),
              ),
              title: const Text("Prendre une photo",
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.photo_library, color: Colors.blue.shade700),
              ),
              title: const Text("Choisir depuis la galerie",
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _uploadImage(String docId) async {
    if (_imageFile == null) return _existingImageUrl;
    final ref =
        FirebaseStorage.instance.ref("restaurant_menus/$docId.jpg");
    await ref.putFile(_imageFile!);
    return await ref.getDownloadURL();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final price = int.tryParse(_priceCtrl.text.trim()) ?? 0;
    if (name.isEmpty || price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Nom et prix obligatoires"),
            backgroundColor: Colors.red),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final menuRef = FirebaseFirestore.instance
          .collection("restaurants")
          .doc(widget.restaurantId)
          .collection("menu");
      final docId = widget.existing?.id ?? menuRef.doc().id;
      final imageUrl = await _uploadImage(docId);
      final payload = <String, dynamic>{
        "name": name,
        "description": _descCtrl.text.trim(),
        "price": price,
        "imageUrl": imageUrl ?? "",
        "updatedAt": FieldValue.serverTimestamp(),
      };
      if (widget.existing != null) {
        await widget.existing!.reference.update(payload);
      } else {
        payload["createdAt"] = FieldValue.serverTimestamp();
        await menuRef.doc(docId).set(payload);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text("Erreur : $e"),
              backgroundColor: Colors.red),
        );
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasImage =
        _imageFile != null || (_existingImageUrl ?? "").isNotEmpty;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(
            widget.existing != null ? "Modifier le plat" : "Ajouter un plat"),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Photo du plat",
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.grey)),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: _showImageOptions,
              child: Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: hasImage
                        ? const Color(0xFF1565C0)
                        : Colors.grey.shade300,
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 8)
                  ],
                ),
                child: _imageFile != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.file(_imageFile!, fit: BoxFit.cover),
                      )
                    : (_existingImageUrl ?? "").isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Image.network(_existingImageUrl!,
                                fit: BoxFit.cover),
                          )
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.add_a_photo_outlined,
                                  size: 52, color: Colors.grey.shade400),
                              const SizedBox(height: 10),
                              Text("Appuyez pour ajouter une photo",
                                  style: TextStyle(
                                      color: Colors.grey.shade500,
                                      fontSize: 13)),
                              const SizedBox(height: 4),
                              Text("Caméra ou Galerie",
                                  style: TextStyle(
                                      color: Colors.grey.shade400,
                                      fontSize: 11)),
                            ],
                          ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton.icon(
                onPressed: _showImageOptions,
                icon: Icon(hasImage ? Icons.edit : Icons.add_a_photo,
                    size: 16),
                label:
                    Text(hasImage ? "Changer la photo" : "Ajouter une photo"),
                style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF1565C0)),
              ),
            ),
            const SizedBox(height: 20),
            const Text("Informations du plat",
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.grey)),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 8)
                ],
              ),
              child: Column(
                children: [
                  _tf(_nameCtrl, "Nom du plat *", Icons.fastfood),
                  const Divider(height: 1),
                  _tf(_priceCtrl, "Prix (FCFA) *", Icons.payments,
                      type: TextInputType.number),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                    child: TextField(
                      controller: _descCtrl,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: "Description (optionnel)",
                        prefixIcon: Icon(Icons.description_outlined,
                            color: Colors.grey.shade400),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _save,
                icon: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.save, color: Colors.white),
                label: Text(
                  _loading
                      ? "Enregistrement..."
                      : widget.existing != null
                          ? "Enregistrer les modifications"
                          : "Ajouter le plat",
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _tf(TextEditingController ctrl, String label, IconData icon,
      {TextInputType? type}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20, color: Colors.grey.shade500),
        border: InputBorder.none,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}

// ── HELPER ──────────────────────────────────────────────────

// ── PAGE ABONNEMENT RESTAURANT ───────────────────────────────

class _RestaurantSubPage extends StatefulWidget {
  final String docId;
  final Map<String, dynamic> data;
  const _RestaurantSubPage({required this.docId, required this.data});

  @override
  State<_RestaurantSubPage> createState() => _RestaurantSubPageState();
}

class _RestaurantSubPageState extends State<_RestaurantSubPage> {
  bool _loading = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _loading = true);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Opération réussie'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString().contains('SOLDE_INSUFFISANT')
            ? 'Solde insuffisant'
            : 'Erreur : $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Gestion Abonnement'),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('restaurants')
            .doc(widget.docId)
            .snapshots(),
        builder: (context, snap) {
          final data = snap.data?.data() as Map<String, dynamic>? ?? widget.data;
          final subStatus = data['subscriptionStatus'] as String? ?? 'active';
          final subExpiry = data['subscriptionExpiresAt'];
          final vipStatus = data['vipStatus'] as String? ?? 'none';
          final vipExpiry = data['vipExpiresAt'];
          final wallet = (data['wallet'] as num? ?? 0).toInt();

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Wallet : $wallet FCFA',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 14)),
                const SizedBox(height: 16),

                // Subscription
                const Text('Abonnement Standard (1 000 F/mois)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 8),
                Row(children: [
                  _buildStatusChip(
                    label: subStatus == 'active' ? 'Actif'
                        : subStatus == 'trial' ? 'Trial'
                        : 'Suspendu',
                    color: subStatus == 'active' ? Colors.green
                        : subStatus == 'trial' ? Colors.blue
                        : Colors.red,
                  ),
                  const SizedBox(width: 10),
                  Text('Expire : ${SubscriptionService.formatExpiry(subExpiry)}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ]),
                const SizedBox(height: 10),
                _loading
                    ? const Center(child: CircularProgressIndicator())
                    : Wrap(spacing: 8, runSpacing: 8, children: [
                        _buildBtn('Activer (1 000 F)', const Color(0xFF1565C0), () => _run(() =>
                            SubscriptionService.adminActivateSubscription('restaurants', widget.docId, chargeWallet: true))),
                        _buildBtn('Gratuit', Colors.green, () => _run(() =>
                            SubscriptionService.adminActivateSubscription('restaurants', widget.docId, chargeWallet: false))),
                        _buildBtn('Suspendre', Colors.red, () => _run(() =>
                            SubscriptionService.adminSuspend('restaurants', widget.docId))),
                      ]),

                const Divider(height: 28),

                // VIP
                const Text('Abonnement VIP (2 000 F/mois)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 8),
                Row(children: [
                  _buildStatusChip(
                    label: vipStatus == 'active' ? '👑 VIP Actif'
                        : vipStatus == 'expired' ? 'VIP Expiré'
                        : 'Aucun VIP',
                    color: vipStatus == 'active' ? const Color(0xFFFFD700)
                        : vipStatus == 'expired' ? Colors.orange
                        : Colors.grey,
                    textColor: vipStatus == 'active' ? Colors.black87 : Colors.white,
                  ),
                  const SizedBox(width: 10),
                  if (vipExpiry != null)
                    Text('Expire : ${SubscriptionService.formatExpiry(vipExpiry)}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ]),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _buildBtn('Activer VIP (2 000 F)', const Color(0xFFFFD700),
                      () => _run(() => SubscriptionService.adminActivateVip('restaurants', widget.docId, chargeWallet: true)),
                      textColor: Colors.black87),
                  _buildBtn('VIP Gratuit', Colors.amber,
                      () => _run(() => SubscriptionService.adminActivateVip('restaurants', widget.docId, chargeWallet: false)),
                      textColor: Colors.black87),
                  _buildBtn('Retirer VIP', Colors.grey.shade600,
                      () => _run(() => SubscriptionService.adminDeactivateVip('restaurants', widget.docId))),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatusChip({required String label, required Color color, Color textColor = Colors.white}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildBtn(String label, Color color, VoidCallback onTap, {Color textColor = Colors.white}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
        child: Text(label, style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

Widget _menuIcon() => Container(
      width: 54,
      height: 54,
      color: const Color(0xFF1565C0).withValues(alpha: 0.1),
      child: const Icon(Icons.fastfood_rounded,
          color: Color(0xFF1565C0), size: 26),
    );

Widget _dialogField(
  TextEditingController ctrl,
  String label,
  IconData icon, {
  TextInputType? type,
}) {
  return TextField(
    controller: ctrl,
    keyboardType: type,
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
  );
}
