import 'dart:io';
import '../../widgets/scale_button.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

class AdminBoutiquePage extends StatefulWidget {
  const AdminBoutiquePage({super.key});

  @override
  State<AdminBoutiquePage> createState() => _AdminBoutiquePageState();
}

class _AdminBoutiquePageState extends State<AdminBoutiquePage>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  void _showPaymentConfig(BuildContext context) async {
    final doc = await FirebaseFirestore.instance
        .collection("app_config")
        .doc("payment")
        .get();
    final waveCtrl = TextEditingController(
        text: doc.data()?["waveNumber"] ?? "");
    final orangeCtrl = TextEditingController(
        text: doc.data()?["orangeNumber"] ?? "");
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("Numéros de paiement"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Les clients enverront leur recharge à ces numéros.",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: waveCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: "Numéro Wave",
                prefixIcon: const Icon(Icons.bolt, color: Color(0xFF1565C0)),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: orangeCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: "Numéro Orange Money",
                prefixIcon:
                    const Icon(Icons.phone_android, color: Colors.orange),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Annuler")),
          ScaleButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6D00),
                foregroundColor: Colors.white),
            onPressed: () async {
              await FirebaseFirestore.instance
                  .collection("app_config")
                  .doc("payment")
                  .set({
                "waveNumber": waveCtrl.text.trim(),
                "orangeNumber": orangeCtrl.text.trim(),
              }, SetOptions(merge: true));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text("Enregistrer"),
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
        title: const Text("Boutique"),
        backgroundColor: const Color(0xFFFF6D00),
        foregroundColor: Colors.white,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _showPaymentConfig(context),
            tooltip: "Numéros Wave/Orange",
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(text: "Produits"),
            Tab(text: "Commandes"),
            Tab(text: "Recharges"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: const [
          _ProductsAdminTab(),
          _OrdersAdminTab(),
          _RechargesAdminTab(),
        ],
      ),
    );
  }
}

// ── ONGLET PRODUITS ───────────────────────────────────────────────

class _ProductsAdminTab extends StatelessWidget {
  const _ProductsAdminTab();

  void _showAddProduct(BuildContext context, [DocumentSnapshot? existing]) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _AddProductPage(existing: existing),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFFFF6D00),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text("Ajouter"),
        onPressed: () => _showAddProduct(context),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection("boutique_products")
            .orderBy("createdAt", descending: true)
            .snapshots(),
        builder: (context, snap) {
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(
              child: Text("Aucun produit",
                  style: TextStyle(color: Colors.grey)),
            );
          }
          return ListView.builder(
            physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final doc = docs[i];
              final data = doc.data() as Map<String, dynamic>;
              final isAvailable = data["isAvailable"] ?? true;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: isAvailable
                      ? Border.all(
                          color: const Color(0xFFFF6D00).withValues(alpha: 0.3))
                      : null,
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 6)
                  ],
                ),
                child: ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: (data["imageUrl"] ?? "").isNotEmpty
                        ? Image.network(
                            data["imageUrl"],
                            width: 46,
                            height: 46,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _productIcon(),
                          )
                        : _productIcon(),
                  ),
                  title: Text(data["name"] ?? "—",
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    "${data['price']} FCFA  •  Stock : ${data['stock']}  •  ${data['category'] ?? ''}",
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: isAvailable,
                        activeThumbColor: const Color(0xFFFF6D00),
                        onChanged: (_) => doc.reference
                            .update({"isAvailable": !isAvailable}),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined,
                            size: 20, color: Colors.grey),
                        onPressed: () => _showAddProduct(context, doc),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            size: 20, color: Colors.red),
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

Widget _productIcon() => Container(
      width: 46,
      height: 46,
      color: const Color(0xFFFF6D00).withValues(alpha: 0.1),
      child: const Icon(Icons.shopping_bag,
          color: Color(0xFFFF6D00), size: 22),
    );

// ── PAGE AJOUT / MODIFICATION PRODUIT ────────────────────────────

class _AddProductPage extends StatefulWidget {
  final DocumentSnapshot? existing;
  const _AddProductPage({this.existing});

  @override
  State<_AddProductPage> createState() => _AddProductPageState();
}

class _AddProductPageState extends State<_AddProductPage> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _stockCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  bool _isAvailable = true;
  File? _imageFile;
  String? _existingImageUrl;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final data = widget.existing!.data() as Map<String, dynamic>;
      _nameCtrl.text = data["name"] ?? "";
      _descCtrl.text = data["description"] ?? "";
      _priceCtrl.text = "${data['price'] ?? ''}";
      _stockCtrl.text = "${data['stock'] ?? ''}";
      _categoryCtrl.text = data["category"] ?? "";
      _isAvailable = data["isAvailable"] ?? true;
      _existingImageUrl = data["imageUrl"];
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _stockCtrl.dispose();
    _categoryCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    final img = await ImagePicker().pickImage(
      source: source,
      imageQuality: 80,
    );
    if (img != null && mounted) {
      setState(() => _imageFile = File(img.path));
    }
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
                  color: const Color(0xFFFF6D00).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.camera_alt,
                    color: Color(0xFFFF6D00)),
              ),
              title: const Text("Prendre une photo",
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text("Appareil photo"),
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
                child: Icon(Icons.photo_library,
                    color: Colors.blue.shade700),
              ),
              title: const Text("Choisir depuis la galerie",
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text("Vos photos"),
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

  Future<String?> _uploadImage(String productId) async {
    if (_imageFile == null) return _existingImageUrl;
    final ref = FirebaseStorage.instance
        .ref()
        .child("boutique_products/$productId.jpg");
    await ref.putFile(_imageFile!);
    return await ref.getDownloadURL();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final price = int.tryParse(_priceCtrl.text.trim()) ?? 0;
    final stock = int.tryParse(_stockCtrl.text.trim()) ?? 0;
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
      final productId = widget.existing?.id ??
          FirebaseFirestore.instance
              .collection("boutique_products")
              .doc()
              .id;

      final imageUrl = await _uploadImage(productId);

      final data = <String, dynamic>{
        "name": name,
        "description": _descCtrl.text.trim(),
        "price": price,
        "stock": stock,
        "category": _categoryCtrl.text.trim().isEmpty
            ? "Général"
            : _categoryCtrl.text.trim(),
        "imageUrl": imageUrl ?? "",
        "isAvailable": _isAvailable,
        "updatedAt": FieldValue.serverTimestamp(),
      };

      if (widget.existing != null) {
        await widget.existing!.reference.update(data);
      } else {
        data["createdAt"] = FieldValue.serverTimestamp();
        await FirebaseFirestore.instance
            .collection("boutique_products")
            .doc(productId)
            .set(data);
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
        title: Text(widget.existing != null
            ? "Modifier le produit"
            : "Ajouter un produit"),
        backgroundColor: const Color(0xFFFF6D00),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── PHOTO ─────────────────────────────────────
            _sectionLabel("Photo du produit"),
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
                        ? const Color(0xFFFF6D00)
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
                            child: Image.network(
                              _existingImageUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  _emptyPhotoPlaceholder(),
                            ),
                          )
                        : _emptyPhotoPlaceholder(),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton.icon(
                onPressed: _showImageOptions,
                icon: Icon(
                    hasImage ? Icons.edit : Icons.add_a_photo,
                    size: 16),
                label:
                    Text(hasImage ? "Changer la photo" : "Ajouter une photo"),
                style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFFF6D00)),
              ),
            ),

            const SizedBox(height: 20),

            // ── INFOS ──────────────────────────────────────
            _sectionLabel("Informations du produit"),
            const SizedBox(height: 10),
            _card([
              _tf(_nameCtrl, "Nom du produit *", Icons.shopping_bag),
              const Divider(height: 1),
              _tf(_categoryCtrl, "Catégorie", Icons.category),
              const Divider(height: 1),
              _tf(_priceCtrl, "Prix (FCFA) *", Icons.payments,
                  type: TextInputType.number),
              const Divider(height: 1),
              _tf(_stockCtrl, "Stock *", Icons.inventory,
                  type: TextInputType.number),
            ]),

            const SizedBox(height: 14),

            _card([
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: TextField(
                  controller: _descCtrl,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: "Description",
                    prefixIcon: Icon(Icons.description_outlined,
                        color: Colors.grey.shade400),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                ),
              ),
            ]),

            const SizedBox(height: 14),

            _card([
              SwitchListTile(
                value: _isAvailable,
                onChanged: (v) => setState(() => _isAvailable = v),
                title: const Text("Disponible à la vente",
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  _isAvailable
                      ? "Visible dans la boutique"
                      : "Masqué aux clients",
                  style: TextStyle(
                      color: _isAvailable ? Colors.green : Colors.grey,
                      fontSize: 12),
                ),
                activeThumbColor: const Color(0xFFFF6D00),
              ),
            ]),

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
                          : "Ajouter le produit",
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6D00),
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

  Widget _emptyPhotoPlaceholder() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add_a_photo_outlined,
              size: 52, color: Colors.grey.shade400),
          const SizedBox(height: 10),
          Text(
            "Appuyez pour ajouter une photo",
            style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            "Caméra ou Galerie",
            style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
          ),
        ],
      );

  Widget _sectionLabel(String t) => Text(t,
      style: const TextStyle(
          fontWeight: FontWeight.bold, fontSize: 14, color: Colors.grey));

  Widget _card(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
          ],
        ),
        child: Column(children: children),
      );

  Widget _tf(TextEditingController ctrl, String label, IconData icon,
      {TextInputType? type}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon:
            Icon(icon, size: 20, color: Colors.grey.shade500),
        border: InputBorder.none,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}

// ── ONGLET COMMANDES ──────────────────────────────────────────────

class _OrdersAdminTab extends StatelessWidget {
  const _OrdersAdminTab();

  void _updateStatus(DocumentSnapshot doc, String newStatus) {
    doc.reference.update({"status": newStatus});
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection("boutique_orders")
          .orderBy("createdAt", descending: true)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Center(
            child: Text("Aucune commande",
                style: TextStyle(color: Colors.grey)),
          );
        }
        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final doc = docs[i];
            final data = doc.data() as Map<String, dynamic>;
            final status = data["status"] ?? "paid";
            final deadline =
                (data["deliveryDeadline"] as Timestamp?)?.toDate();
            final isLate = deadline != null &&
                DateTime.now().isAfter(deadline) &&
                status == "paid";

            final statusColors = {
              "paid": Colors.orange,
              "preparing": Colors.blue,
              "shipped": const Color(0xFF1565C0),
              "delivered": Colors.green,
              "refunded": Colors.purple,
            };
            final statusLabels = {
              "paid": "En attente",
              "preparing": "En préparation",
              "shipped": "En livraison",
              "delivered": "Livré",
              "refunded": "Remboursé",
            };
            final color = statusColors[status] ?? Colors.grey;

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: isLate
                    ? Border.all(color: Colors.red.shade300)
                    : null,
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 6)
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(data["productName"] ?? "—",
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            statusLabels[status] ?? status,
                            style: TextStyle(
                                color: color,
                                fontSize: 11,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "Qté : ${data['qty']}  •  ${data['totalPrice']} FCFA",
                      style: const TextStyle(
                          color: Colors.grey, fontSize: 13),
                    ),
                    Text(
                      "Client ID : ${(data['clientId'] ?? '').toString().substring(0, 8)}...",
                      style: const TextStyle(
                          color: Colors.grey, fontSize: 11),
                    ),
                    if (isLate)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text("⚠ Délai 48h dépassé",
                            style: TextStyle(
                                color: Colors.red,
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                      ),
                    if (status != "delivered" &&
                        status != "refunded") ...[
                      const SizedBox(height: 10),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            if (status == "paid")
                              _actionBtn("En préparation", Colors.blue,
                                  () => _updateStatus(doc, "preparing")),
                            if (status == "preparing")
                              _actionBtn("Expédier", const Color(0xFF1565C0),
                                  () => _updateStatus(doc, "shipped")),
                            if (status == "shipped")
                              _actionBtn("Livré ✓", Colors.green,
                                  () => _updateStatus(doc, "delivered")),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _actionBtn(String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12)),
      ),
    );
  }
}

// ── ONGLET RECHARGES ──────────────────────────────────────────────

class _RechargesAdminTab extends StatelessWidget {
  const _RechargesAdminTab();

  Future<void> _approve(BuildContext context, DocumentSnapshot doc) async {
    final data = doc.data() as Map<String, dynamic>;
    final clientId = data["clientId"] as String;
    final amount = (data["amount"] as num? ?? 0).toInt();
    final method = data["method"] ?? "wave";

    final clientRef =
        FirebaseFirestore.instance.collection("clients").doc(clientId);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(clientRef);
      final wallet = (snap.data()?["wallet"] as num? ?? 0).toInt();
      tx.update(clientRef, {"wallet": wallet + amount});
      tx.update(doc.reference, {
        "status": "approved",
        "approvedAt": Timestamp.now(),
      });
    });

    await FirebaseFirestore.instance
        .collection("clients")
        .doc(clientId)
        .collection("wallet_transactions")
        .add({
      "type": "recharge",
      "amount": amount,
      "description":
          "Recharge ${method == 'wave' ? 'Wave' : 'Orange Money'} — $amount FCFA",
      "createdAt": Timestamp.now(),
    });

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("$amount FCFA crédités au client"),
            backgroundColor: Colors.green),
      );
    }
  }

  Future<void> _reject(DocumentSnapshot doc) async {
    await doc.reference.update({
      "status": "rejected",
      "rejectedAt": Timestamp.now(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection("recharge_requests")
          .orderBy("createdAt", descending: true)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        final pending =
            docs.where((d) => (d.data() as Map)["status"] == "pending").toList();
        final done =
            docs.where((d) => (d.data() as Map)["status"] != "pending").toList();

        if (docs.isEmpty) {
          return const Center(
            child: Text("Aucune demande de recharge",
                style: TextStyle(color: Colors.grey)),
          );
        }

        return ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (pending.isNotEmpty) ...[
              _sectionTitle("En attente (${pending.length})"),
              const SizedBox(height: 8),
              ...pending.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                return _RechargeCard(
                  data: data,
                  isPending: true,
                  onApprove: () => _approve(context, doc),
                  onReject: () => _reject(doc),
                );
              }),
              const SizedBox(height: 16),
            ],
            if (done.isNotEmpty) ...[
              _sectionTitle("Traitées"),
              const SizedBox(height: 8),
              ...done.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                return _RechargeCard(
                    data: data, isPending: false,
                    onApprove: () {}, onReject: () {});
              }),
            ],
          ],
        );
      },
    );
  }

  Widget _sectionTitle(String t) => Text(t,
      style: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 14,
          color: Colors.grey));
}

class _RechargeCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isPending;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _RechargeCard({
    required this.data,
    required this.isPending,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final status = data["status"] ?? "pending";
    final method = data["method"] ?? "wave";
    final amount = data["amount"] ?? 0;
    final ts = data["createdAt"] as Timestamp?;
    final date = ts?.toDate();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: isPending
            ? Border.all(color: Colors.orange.shade300)
            : null,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05), blurRadius: 6)
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: method == "wave"
                        ? const Color(0xFF1565C0).withValues(alpha: 0.1)
                        : Colors.orange.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    method == "wave" ? Icons.bolt : Icons.phone_android,
                    color: method == "wave"
                        ? const Color(0xFF1565C0)
                        : Colors.orange,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "$amount FCFA — ${method == 'wave' ? 'Wave' : 'Orange Money'}",
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      if (date != null)
                        Text(
                          "${date.day.toString().padLeft(2, '0')}/"
                          "${date.month.toString().padLeft(2, '0')}/"
                          "${date.year}",
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 11),
                        ),
                    ],
                  ),
                ),
                if (!isPending)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: status == "approved"
                          ? Colors.green.shade50
                          : Colors.red.shade50,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      status == "approved" ? "Approuvé" : "Rejeté",
                      style: TextStyle(
                          color: status == "approved"
                              ? Colors.green
                              : Colors.red,
                          fontWeight: FontWeight.bold,
                          fontSize: 11),
                    ),
                  ),
              ],
            ),
            if (isPending) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onReject,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text("Rejeter"),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ScaleButton(
                      onPressed: onApprove,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text("Approuver"),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

