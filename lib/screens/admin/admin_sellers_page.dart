import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/subscription_service.dart';
import '../../utils/partner_location_validator.dart';
import '../../widgets/partner_location_input.dart';

class AdminSellersPage extends StatelessWidget {
  const AdminSellersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        title: const Text("Comptes Vendeurs"),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const _SellerFormPage()),
        ),
        backgroundColor: const Color(0xFF1565C0),
        icon: const Icon(Icons.person_add_rounded, color: Colors.white),
        label: const Text("Nouveau vendeur",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('sellers')
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
                  Icon(Icons.storefront_outlined,
                      size: 72, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  const Text("Aucun compte vendeur",
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                  const SizedBox(height: 8),
                  const Text("Appuyez sur + pour créer un compte",
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                ],
              ),
            );
          }
          return ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            itemCount: docs.length,
            itemBuilder: (_, i) {
              final doc = docs[i];
              final data = doc.data() as Map<String, dynamic>;
              return _SellerCard(docId: doc.id, data: data);
            },
          );
        },
      ),
    );
  }
}

// ── CARTE VENDEUR ─────────────────────────────────────────────

class _SellerCard extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> data;
  const _SellerCard({required this.docId, required this.data});

  Future<void> _toggleActive() async {
    try {
      await FirebaseFirestore.instance
          .collection('sellers')
          .doc(docId)
          .update({'isActive': !(data['isActive'] ?? true)});
    } catch (_) {}
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Supprimer ce vendeur ?"),
        content: Text(
            "\"${data['name'] ?? ''}\" sera supprimé. Il ne pourra plus se connecter."),
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
          .collection('sellers')
          .doc(docId)
          .delete();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isActive = data['isActive'] ?? true;
    final name = data['name'] ?? 'Sans nom';
    final phone = data['phone'] ?? '';
    final type = data['type'] ?? '';
    final subStatus = data['subscriptionStatus'] as String? ?? 'active';
    final vipStatus = data['vipStatus'] as String? ?? 'none';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF1565C0).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.storefront_rounded,
              color: Color(0xFF1565C0), size: 24),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(name,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            // Subscription status dot
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: subStatus == 'active'
                    ? Colors.green
                    : subStatus == 'trial'
                        ? Colors.blue
                        : Colors.red,
                shape: BoxShape.circle,
              ),
            ),
            // VIP crown
            if (vipStatus == 'active')
              const Text('👑', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isActive
                    ? Colors.green.withValues(alpha: 0.1)
                    : Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                isActive ? "Actif" : "Inactif",
                style: TextStyle(
                  color: isActive ? Colors.green : Colors.red,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(phone,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            if (type.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF1565C0).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  "Type : $type",
                  style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF1565C0),
                      fontWeight: FontWeight.w500),
                ),
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'toggle') _toggleActive();
            if (v == 'delete') _delete(context);
            if (v == 'edit') {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => _SellerFormPage(docId: docId, existing: data),
                ),
              );
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'toggle',
              child: Row(
                children: [
                  Icon(
                    isActive ? Icons.block_rounded : Icons.check_circle_rounded,
                    color: isActive ? Colors.orange : Colors.green,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(isActive ? "Désactiver" : "Activer"),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'edit',
              child: Row(
                children: [
                  Icon(Icons.edit_rounded, color: Color(0xFF1565C0), size: 18),
                  SizedBox(width: 8),
                  Text("Modifier"),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete_outline_rounded,
                      color: Colors.red, size: 18),
                  SizedBox(width: 8),
                  Text("Supprimer", style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── FORMULAIRE CRÉATION / MODIFICATION ───────────────────────

class _SellerFormPage extends StatefulWidget {
  final String? docId;
  final Map<String, dynamic>? existing;
  const _SellerFormPage({this.docId, this.existing});

  @override
  State<_SellerFormPage> createState() => _SellerFormPageState();
}

class _SellerFormPageState extends State<_SellerFormPage> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();

  // Type prédéfinis + valeur libre
  String _type = 'boutique';
  static const _typeOptions = [
    'boutique',
    'restaurant',
    'pharmacie',
    'eau_boissons',
    'blanchisserie',
  ];

  bool _isActive = true;
  bool _saving = false;
  bool _showPass = false;
  bool get _isEditing => widget.docId != null;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final d = widget.existing!;
      _nameCtrl.text = d['name'] ?? '';
      _phoneCtrl.text = d['phone'] ?? '';
      _type = d['type'] ?? 'boutique';
      _isActive = d['isActive'] ?? true;
      _latCtrl.text = d['lat']?.toString() ?? '';
      _lngCtrl.text = d['lng']?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _passCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim().replaceAll(' ', '');
    final pass = _passCtrl.text;

    if (name.isEmpty || phone.isEmpty) {
      _snack("Nom et téléphone obligatoires");
      return;
    }
    if (!_isEditing && pass.length < 6) {
      _snack("Mot de passe minimum 6 caractères");
      return;
    }
    final locationError =
        PartnerLocationValidator.validateText(_latCtrl.text, _lngCtrl.text);
    if (locationError != null) {
      _snack(locationError);
      return;
    }

    setState(() => _saving = true);

    try {
      String uid;

      if (_isEditing) {
        uid = widget.docId!;
      } else {
        // Créer compte Firebase Auth
        final credential =
            await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: "$phone@az-seller.ci",
          password: pass,
        );
        uid = credential.user!.uid;
      }

      await FirebaseFirestore.instance.collection('sellers').doc(uid).set({
        'name': name,
        'phone': phone,
        'type': _type,
        'isActive': _isActive,
        'lat': double.parse(_latCtrl.text.trim()),
        'lng': double.parse(_lngCtrl.text.trim()),
        'wallet': 0,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isEditing
              ? "Vendeur modifié"
              : "Compte vendeur créé — ID: $phone / MDP: $pass"),
          backgroundColor: const Color(0xFF1565C0),
          duration: const Duration(seconds: 6),
        ),
      );
    } on FirebaseAuthException catch (e) {
      _snack(e.code == 'email-already-in-use'
          ? "Ce numéro a déjà un compte"
          : "Erreur Auth: ${e.message}");
    } catch (e) {
      _snack("Erreur: $e");
    }

    if (mounted) setState(() => _saving = false);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(_isEditing ? "Modifier vendeur" : "Nouveau vendeur"),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
        actions: [
          if (!_saving)
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
          // Infos
          _field(_nameCtrl, "Nom de la boutique / du vendeur *",
              Icons.store_rounded),
          const SizedBox(height: 12),
          _field(_phoneCtrl, "Téléphone (identifiant) *", Icons.phone_rounded,
              type: TextInputType.phone),
          const SizedBox(height: 12),
          PartnerLocationInput(
            latitudeController: _latCtrl,
            longitudeController: _lngCtrl,
          ),
          const SizedBox(height: 12),
          if (!_isEditing)
            TextField(
              controller: _passCtrl,
              obscureText: !_showPass,
              decoration: InputDecoration(
                labelText: "Mot de passe *",
                hintText: "Min. 6 caractères",
                prefixIcon:
                    const Icon(Icons.lock_rounded, color: Color(0xFF1565C0)),
                suffixIcon: IconButton(
                  icon: Icon(
                      _showPass ? Icons.visibility_off : Icons.visibility,
                      color: Colors.grey),
                  onPressed: () => setState(() => _showPass = !_showPass),
                ),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),

          const SizedBox(height: 20),

          // Type de service
          const Text("Type de service",
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _typeOptions.map((t) {
              final sel = _type == t;
              return GestureDetector(
                onTap: () => setState(() => _type = t),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: sel ? const Color(0xFF1565C0) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color:
                          sel ? const Color(0xFF1565C0) : Colors.grey.shade300,
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

          // Statut
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SwitchListTile(
              title: const Text("Compte actif",
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                  _isActive ? "Le vendeur peut se connecter" : "Accès bloqué"),
              value: _isActive,
              activeThumbColor: const Color(0xFF1565C0),
              onChanged: (v) => setState(() => _isActive = v),
            ),
          ),

          const SizedBox(height: 28),

          SizedBox(
            height: 54,
            child: ScaleButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: _saving
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Text(_isEditing ? "Enregistrer" : "Créer le compte",
                      style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white,
                          fontWeight: FontWeight.bold)),
            ),
          ),

          // ── Subscription management (edit mode only) ──────────────
          if (_isEditing && widget.docId != null) ...[
            const SizedBox(height: 24),
            _SubscriptionSection(
              collection: 'sellers',
              docId: widget.docId!,
              data: widget.existing ?? {},
            ),
          ],

          if (!_isEditing) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade100),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      color: Colors.blue.shade600, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Le vendeur se connecte avec son numéro de téléphone et le mot de passe défini ici.",
                      style:
                          TextStyle(color: Colors.blue.shade700, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {TextInputType? type}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: const Color(0xFF1565C0)),
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
}

// ── SECTION ABONNEMENT ────────────────────────────────────────

class _SubscriptionSection extends StatefulWidget {
  final String collection;
  final String docId;
  final Map<String, dynamic> data;

  const _SubscriptionSection({
    required this.collection,
    required this.docId,
    required this.data,
  });

  @override
  State<_SubscriptionSection> createState() => _SubscriptionSectionState();
}

class _SubscriptionSectionState extends State<_SubscriptionSection> {
  bool _loading = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _loading = true);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Opération réussie'),
              backgroundColor: Colors.green),
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
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection(widget.collection)
          .doc(widget.docId)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data() as Map<String, dynamic>? ?? widget.data;
        final subStatus = data['subscriptionStatus'] as String? ?? 'active';
        final subExpiry = data['subscriptionExpiresAt'];
        final vipStatus = data['vipStatus'] as String? ?? 'none';
        final vipExpiry = data['vipExpiresAt'];
        final wallet = (data['wallet'] as num? ?? 0).toInt();

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Gestion Abonnement',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Wallet : $wallet FCFA',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              const SizedBox(height: 12),

              // ── Abonnement standard ───────────────────────────────
              Row(children: [
                _StatusChip(
                  label: subStatus == 'active'
                      ? 'Actif'
                      : subStatus == 'trial'
                          ? 'Trial'
                          : 'Suspendu',
                  color: subStatus == 'active'
                      ? Colors.green
                      : subStatus == 'trial'
                          ? Colors.blue
                          : Colors.red,
                ),
                const SizedBox(width: 8),
                Text(
                  'Expire : ${SubscriptionService.formatExpiry(subExpiry)}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ]),
              const SizedBox(height: 8),
              _loading
                  ? const Center(child: CircularProgressIndicator())
                  : Wrap(spacing: 8, runSpacing: 6, children: [
                      _AdminBtn(
                        label: 'Activer abo (1 000 F)',
                        color: const Color(0xFF1565C0),
                        onTap: () => _run(() =>
                            SubscriptionService.adminActivateSubscription(
                                widget.collection, widget.docId,
                                chargeWallet: true)),
                      ),
                      _AdminBtn(
                        label: 'Gratuit',
                        color: Colors.green,
                        onTap: () => _run(() =>
                            SubscriptionService.adminActivateSubscription(
                                widget.collection, widget.docId,
                                chargeWallet: false)),
                      ),
                      _AdminBtn(
                        label: 'Suspendre',
                        color: Colors.red,
                        onTap: () => _run(() =>
                            SubscriptionService.adminSuspend(
                                widget.collection, widget.docId)),
                      ),
                    ]),

              const Divider(height: 20),

              // ── VIP ────────────────────────────────────────────────
              Row(children: [
                _StatusChip(
                  label: vipStatus == 'active'
                      ? '👑 VIP Actif'
                      : vipStatus == 'expired'
                          ? 'VIP Expiré'
                          : 'Aucun VIP',
                  color: vipStatus == 'active'
                      ? const Color(0xFFFFD700)
                      : vipStatus == 'expired'
                          ? Colors.orange
                          : Colors.grey,
                  textColor:
                      vipStatus == 'active' ? Colors.black87 : Colors.white,
                ),
                const SizedBox(width: 8),
                if (vipExpiry != null)
                  Text(
                    'Expire : ${SubscriptionService.formatExpiry(vipExpiry)}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 6, children: [
                _AdminBtn(
                  label: 'Activer VIP (2 000 F)',
                  color: const Color(0xFFFFD700),
                  textColor: Colors.black87,
                  onTap: () => _run(() => SubscriptionService.adminActivateVip(
                      widget.collection, widget.docId,
                      chargeWallet: true)),
                ),
                _AdminBtn(
                  label: 'VIP Gratuit',
                  color: Colors.amber,
                  textColor: Colors.black87,
                  onTap: () => _run(() => SubscriptionService.adminActivateVip(
                      widget.collection, widget.docId,
                      chargeWallet: false)),
                ),
                _AdminBtn(
                  label: 'Retirer VIP',
                  color: Colors.grey.shade600,
                  onTap: () => _run(() =>
                      SubscriptionService.adminDeactivateVip(
                          widget.collection, widget.docId)),
                ),
              ]),
            ],
          ),
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  const _StatusChip(
      {required this.label,
      required this.color,
      this.textColor = Colors.white});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.bold, color: textColor)),
    );
  }
}

class _AdminBtn extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback onTap;
  const _AdminBtn(
      {required this.label,
      required this.color,
      required this.onTap,
      this.textColor = Colors.white});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: textColor)),
      ),
    );
  }
}
