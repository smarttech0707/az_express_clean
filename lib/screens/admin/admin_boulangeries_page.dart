import 'dart:math';
import '../../widgets/scale_button.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/subscription_service.dart';

class AdminBoulangeriesPage extends StatelessWidget {
  const AdminBoulangeriesPage({super.key});

  // ── Génère un mot de passe temporaire sécurisé ────────────────────
  static String _generatePassword() {
    const chars =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
    final rand = Random.secure();
    return List.generate(8, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  static Widget _field(
    TextEditingController c,
    String label,
    IconData icon, {
    TextInputType type = TextInputType.text,
  }) =>
      TextField(
        controller: c,
        keyboardType: type,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, size: 20),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      );

  // ── Dialogue ajouter / modifier boulangerie ───────────────────────
  void _showForm(BuildContext context, {DocumentSnapshot? existing}) {
    final data = existing?.data() as Map<String, dynamic>?;
    final nameCtrl    = TextEditingController(text: data?['name']      ?? '');
    final addressCtrl = TextEditingController(text: data?['address']   ?? '');
    final phoneCtrl   = TextEditingController(text: data?['phone']     ?? '');
    final openCtrl    = TextEditingController(text: data?['openTime']  ?? '06:00');
    final closeCtrl   = TextEditingController(text: data?['closeTime'] ?? '13:00');
    final passCtrl    = TextEditingController(
        text: existing == null ? _generatePassword() : '');
    bool showPass = existing == null;
    bool saving   = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(existing == null
              ? 'Ajouter une boulangerie'
              : 'Modifier la boulangerie'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _field(nameCtrl, 'Nom', Icons.bakery_dining_rounded),
                const SizedBox(height: 10),
                _field(addressCtrl, 'Adresse / Quartier', Icons.location_on_outlined),
                const SizedBox(height: 10),
                _field(phoneCtrl, 'Téléphone', Icons.phone_outlined,
                    type: TextInputType.phone),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _field(openCtrl, 'Ouverture', Icons.wb_sunny_outlined)),
                  const SizedBox(width: 8),
                  Expanded(child: _field(closeCtrl, 'Fermeture', Icons.nights_stay_outlined)),
                ]),
                const SizedBox(height: 10),

                // ── Mot de passe ─────────────────────────────────────
                TextField(
                  controller: passCtrl,
                  obscureText: !showPass,
                  decoration: InputDecoration(
                    labelText: existing == null
                        ? 'Mot de passe temporaire'
                        : 'Nouveau mot de passe (laisser vide = inchangé)',
                    prefixIcon: const Icon(Icons.lock_outline, size: 20),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(showPass
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined),
                          onPressed: () => setS(() => showPass = !showPass),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy_outlined),
                          tooltip: 'Copier',
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: passCtrl.text));
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(
                                  content: Text('Mot de passe copié'),
                                  duration: Duration(seconds: 2)),
                            );
                          },
                        ),
                      ],
                    ),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
                if (existing == null) ...[
                  const SizedBox(height: 6),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Régénérer', style: TextStyle(fontSize: 12)),
                    onPressed: () =>
                        setS(() => passCtrl.text = _generatePassword()),
                  ),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.amber.shade200),
                    ),
                    child: Row(children: [
                      Icon(Icons.info_outline,
                          size: 16, color: Colors.amber.shade800),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Copiez ce mot de passe et partagez-le avec la boulangerie.',
                          style: TextStyle(
                              fontSize: 11, color: Colors.amber.shade800),
                        ),
                      ),
                    ]),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler'),
            ),
            ScaleButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.brown.shade700,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: saving
                  ? null
                  : () async {
                      final name    = nameCtrl.text.trim();
                      final address = addressCtrl.text.trim();
                      final phone   = phoneCtrl.text.trim();
                      if (name.isEmpty || phone.isEmpty) {
                        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                            content: Text('Nom et téléphone obligatoires')));
                        return;
                      }
                      setS(() => saving = true);
                      try {
                        final db  = FirebaseFirestore.instance;
                        final pass = passCtrl.text.trim();

                        if (existing == null) {
                          // Créer compte Firebase Auth
                          final email = '$phone@az-boulangerie.ci';
                          final cred = await FirebaseAuth.instance
                              .createUserWithEmailAndPassword(
                                  email: email, password: pass);
                          // Restaurer la session anonyme
                          await FirebaseAuth.instance.signOut();
                          try {
                            await FirebaseAuth.instance.signInAnonymously();
                          } catch (_) {}

                          await db
                              .collection('boulangeries')
                              .doc(cred.user!.uid)
                              .set({
                            'name':      name,
                            'address':   address,
                            'phone':     phone,
                            'openTime':  openCtrl.text.trim(),
                            'closeTime': closeCtrl.text.trim(),
                            'isOpen':    false,
                            'wallet':    0,
                            'isActive':  true,
                            'createdAt': FieldValue.serverTimestamp(),
                          });
                        } else {
                          final Map<String, dynamic> updates = {
                            'name':      name,
                            'address':   address,
                            'phone':     phone,
                            'openTime':  openCtrl.text.trim(),
                            'closeTime': closeCtrl.text.trim(),
                          };
                          if (pass.isNotEmpty) {
                            await FirebaseAuth.instance
                                .signInWithEmailAndPassword(
                                    email: '$phone@az-boulangerie.ci',
                                    password: pass)
                                .then((_) async {
                              await FirebaseAuth.instance.currentUser
                                  ?.updatePassword(pass);
                              await FirebaseAuth.instance.signOut();
                              try {
                                await FirebaseAuth.instance
                                    .signInAnonymously();
                              } catch (_) {}
                            }).catchError((_) {});
                          }
                          await db
                              .collection('boulangeries')
                              .doc(existing.id)
                              .update(updates);
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setS(() => saving = false);
                        if (!ctx.mounted) return;
                        ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text('Erreur : $e')));
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : Text(existing == null ? 'Créer' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Dialogue gestion du menu ──────────────────────────────────────
  void _showMenu(BuildContext context, DocumentSnapshot bakery) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _BoulangerieMenuPage(
          boulangerieId: bakery.id,
          boulangerieName:
              (bakery.data() as Map<String, dynamic>)['name'] ?? '',
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, String id, String name) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Supprimer'),
        content: Text('Supprimer "$name" ? Cette action est irréversible.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          ScaleButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white),
            onPressed: () async {
              await FirebaseFirestore.instance
                  .collection('boulangeries')
                  .doc(id)
                  .delete();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Supprimer'),
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
        title: const Text('Boulangeries & Cafés'),
        backgroundColor: Colors.brown.shade700,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.brown.shade700,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Ajouter'),
        onPressed: () => _showForm(context),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('boulangeries')
            .orderBy('name')
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
                  Icon(Icons.bakery_dining_rounded,
                      size: 72, color: Colors.brown.shade200),
                  const SizedBox(height: 16),
                  const Text('Aucune boulangerie',
                      style:
                          TextStyle(color: Colors.grey, fontSize: 16)),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final doc  = docs[i];
              final data = doc.data() as Map<String, dynamic>;
              final name     = data['name']    ?? '—';
              final address  = data['address'] ?? '—';
              final phone    = data['phone']   ?? '—';
              final openTime  = data['openTime']  ?? '—';
              final closeTime = data['closeTime'] ?? '—';
              final isOpen    = data['isOpen'] == true;
              final wallet    = (data['wallet'] as num?)?.toInt() ?? 0;
              final subStatus = data['subscriptionStatus'] as String? ?? 'active';
              final vipStatus = data['vipStatus'] as String? ?? 'none';

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 8)
                  ],
                ),
                child: Column(
                  children: [
                    ListTile(
                      contentPadding:
                          const EdgeInsets.fromLTRB(16, 10, 12, 4),
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: isOpen
                              ? Colors.green.shade50
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.bakery_dining_rounded,
                          color: isOpen
                              ? Colors.green.shade700
                              : Colors.grey,
                          size: 26,
                        ),
                      ),
                      title: Row(children: [
                        Expanded(
                          child: Text(name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15)),
                        ),
                        // Subscription dot
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
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Text('👑', style: TextStyle(fontSize: 13)),
                          ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isOpen
                                ? Colors.green.shade50
                                : Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            isOpen ? 'Ouvert' : 'Fermé',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isOpen
                                    ? Colors.green.shade700
                                    : Colors.red.shade700),
                          ),
                        ),
                      ]),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('$address · $phone',
                              style: const TextStyle(fontSize: 12)),
                          Text('$openTime – $closeTime',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.brown.shade400)),
                          Text('Wallet : $wallet FCFA',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.green.shade700,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton.icon(
                            icon: const Icon(Icons.menu_book_rounded,
                                size: 16),
                            label: const Text('Menu',
                                style: TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.brown.shade700),
                            onPressed: () => _showMenu(context, doc),
                          ),
                        ),
                        Expanded(
                          child: TextButton.icon(
                            icon: const Icon(Icons.workspace_premium_rounded,
                                size: 16),
                            label: const Text('Abo',
                                style: TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.amber.shade700),
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => _BoulangerieSubPage(
                                  docId: doc.id,
                                  data: data,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: TextButton.icon(
                            icon: const Icon(Icons.edit_outlined, size: 16),
                            label: const Text('Modifier',
                                style: TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.blue.shade700),
                            onPressed: () =>
                                _showForm(context, existing: doc),
                          ),
                        ),
                        Expanded(
                          child: TextButton.icon(
                            icon: const Icon(Icons.delete_outline, size: 16),
                            label: const Text('Supprimer',
                                style: TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.red.shade700),
                            onPressed: () =>
                                _confirmDelete(context, doc.id, name),
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

// ═══════════════════════════════════════════════════════════════════════
// PAGE GESTION DU MENU
// ═══════════════════════════════════════════════════════════════════════

class _BoulangerieMenuPage extends StatelessWidget {
  final String boulangerieId;
  final String boulangerieName;

  const _BoulangerieMenuPage({
    required this.boulangerieId,
    required this.boulangerieName,
  });

  static const _categories = [
    'Pains',
    'Viennoiseries',
    'Gâteaux',
    'Boissons',
    'Formules',
    'Autres',
  ];

  void _showItemForm(BuildContext context, {DocumentSnapshot? existing}) {
    final data       = existing?.data() as Map<String, dynamic>?;
    final nameCtrl   = TextEditingController(text: data?['name']        ?? '');
    final priceCtrl  = TextEditingController(
        text: data?['price']?.toString() ?? '');
    final descCtrl   = TextEditingController(text: data?['description'] ?? '');
    String category  = data?['category'] ?? _categories.first;
    bool available   = data?['isAvailable'] ?? true;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(existing == null ? 'Ajouter un article' : 'Modifier'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: 'Nom de l\'article',
                    prefixIcon:
                        const Icon(Icons.fastfood_rounded, size: 20),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: priceCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Prix (FCFA)',
                    prefixIcon:
                        const Icon(Icons.attach_money_rounded, size: 20),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: descCtrl,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Description (optionnel)',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: InputDecoration(
                    labelText: 'Catégorie',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  items: _categories
                      .map((c) =>
                          DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) => setS(() => category = v!),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  title: const Text('Disponible'),
                  subtitle: Text(
                      available ? 'En stock' : 'Rupture de stock',
                      style: const TextStyle(fontSize: 11)),
                  value: available,
                  activeThumbColor: Colors.green,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setS(() => available = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Annuler')),
            ScaleButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.brown.shade700,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                final name  = nameCtrl.text.trim();
                final price = int.tryParse(priceCtrl.text.trim()) ?? 0;
                if (name.isEmpty || price <= 0) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                      content: Text('Nom et prix obligatoires')));
                  return;
                }
                final ref = FirebaseFirestore.instance
                    .collection('boulangeries')
                    .doc(boulangerieId)
                    .collection('menu_items');
                final payload = {
                  'name':        name,
                  'price':       price,
                  'description': descCtrl.text.trim(),
                  'category':    category,
                  'isAvailable': available,
                  'updatedAt':   FieldValue.serverTimestamp(),
                };
                if (existing == null) {
                  await ref.add({
                    ...payload,
                    'createdAt': FieldValue.serverTimestamp(),
                  });
                } else {
                  await ref.doc(existing.id).update(payload);
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: Text(existing == null ? 'Ajouter' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('Menu — $boulangerieName',
            overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.brown.shade700,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.brown.shade700,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Article'),
        onPressed: () => _showItemForm(context),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('boulangeries')
            .doc(boulangerieId)
            .collection('menu_items')
            .orderBy('category')
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(
                child: Text('Aucun article. Appuyez sur + pour ajouter.',
                    style: TextStyle(color: Colors.grey)));
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final doc  = docs[i];
              final d    = doc.data() as Map<String, dynamic>;
              final name  = d['name']        ?? '—';
              final price = (d['price'] as num?)?.toInt() ?? 0;
              final cat   = d['category']    ?? '—';
              final avail = d['isAvailable'] ?? true;

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: avail
                          ? Colors.transparent
                          : Colors.red.shade100),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 6)
                  ],
                ),
                child: ListTile(
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.brown.shade50,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.bakery_dining_rounded,
                        color: Colors.brown.shade400, size: 22),
                  ),
                  title: Text(name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14)),
                  subtitle: Text('$cat · $price FCFA',
                      style: const TextStyle(fontSize: 12)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: avail
                              ? Colors.green.shade50
                              : Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          avail ? 'Dispo' : 'Rupture',
                          style: TextStyle(
                              fontSize: 10,
                              color: avail
                                  ? Colors.green.shade700
                                  : Colors.red.shade700),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        color: Colors.blue.shade600,
                        onPressed: () =>
                            _showItemForm(context, existing: doc),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        color: Colors.red.shade400,
                        onPressed: () async {
                          await FirebaseFirestore.instance
                              .collection('boulangeries')
                              .doc(boulangerieId)
                              .collection('menu_items')
                              .doc(doc.id)
                              .delete();
                        },
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

// ── PAGE ABONNEMENT BOULANGERIE ─────────────────────────────────────────────────

class _BoulangerieSubPage extends StatefulWidget {
  final String docId;
  final Map<String, dynamic> data;
  const _BoulangerieSubPage({required this.docId, required this.data});

  @override
  State<_BoulangerieSubPage> createState() => _BoulangerieSubPageState();
}

class _BoulangerieSubPageState extends State<_BoulangerieSubPage> {
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
        backgroundColor: Colors.brown.shade700,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('boulangeries')
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
                  _buildChip(
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
                        _buildBtn('Activer (1 000 F)', Colors.brown.shade700, () => _run(() =>
                            SubscriptionService.adminActivateSubscription('boulangeries', widget.docId, chargeWallet: true))),
                        _buildBtn('Gratuit', Colors.green, () => _run(() =>
                            SubscriptionService.adminActivateSubscription('boulangeries', widget.docId, chargeWallet: false))),
                        _buildBtn('Suspendre', Colors.red, () => _run(() =>
                            SubscriptionService.adminSuspend('boulangeries', widget.docId))),
                      ]),

                const Divider(height: 28),

                // VIP
                const Text('Abonnement VIP (2 000 F/mois)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 8),
                Row(children: [
                  _buildChip(
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
                      () => _run(() => SubscriptionService.adminActivateVip('boulangeries', widget.docId, chargeWallet: true)),
                      textColor: Colors.black87),
                  _buildBtn('VIP Gratuit', Colors.amber,
                      () => _run(() => SubscriptionService.adminActivateVip('boulangeries', widget.docId, chargeWallet: false)),
                      textColor: Colors.black87),
                  _buildBtn('Retirer VIP', Colors.grey.shade600,
                      () => _run(() => SubscriptionService.adminDeactivateVip('boulangeries', widget.docId))),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildChip({required String label, required Color color, Color textColor = Colors.white}) {
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
