import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Journalise un changement de rôle/permission dans `audit_logs` via le CF
/// `logAdminAuditEvent` — best-effort, ne doit jamais bloquer l'action admin
/// déjà effectuée (écriture Firestore directe) si la journalisation échoue.
Future<void> _logAdminAuditEvent(String action, String targetId, [Map<String, dynamic>? metadata]) async {
  try {
    await FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('logAdminAuditEvent')
        .call({'action': action, 'targetId': targetId, if (metadata != null) 'metadata': metadata});
  } catch (_) {
    // Non-bloquant.
  }
}

// Toutes les sections disponibles avec leur libellé et icône
const _kSections = [
  ('livreurs',             'Livreurs',             Icons.delivery_dining_rounded),
  ('commandes',            'Commandes',            Icons.receipt_long_rounded),
  ('gains',                'Gains',                Icons.bar_chart_rounded),
  ('classement',           'Classement',           Icons.emoji_events_rounded),
  ('carte',                'Carte live',           Icons.map_rounded),
  ('demandes',             'Demandes livreurs',    Icons.person_add_rounded),
  ('restaurants',          'Restaurants',          Icons.restaurant_rounded),
  ('demandes_resto',       'Dem. Restos',          Icons.store_mall_directory_rounded),
  ('demandes_vendeurs',    'Dem. Vendeurs',        Icons.storefront_rounded),
  ('demandes_boulangeries','Dem. Boulangeries',    Icons.bakery_dining_rounded),
  ('demandes_pharmacies',  'Dem. Pharmacies',      Icons.local_pharmacy_rounded),
  ('pharmacies',           'Pharmacies',           Icons.local_pharmacy_rounded),
  ('boutique',             'Boutique',             Icons.storefront_rounded),
  ('recharges',            'Recharges',            Icons.account_balance_wallet_rounded),
  ('flottes',              'Flottes',              Icons.motorcycle_rounded),
  ('locations',            'Locations',            Icons.home_rounded),
  ('residences',           'Résidences',           Icons.apartment_rounded),
  ('services',             'Services',             Icons.construction_rounded),
  ('tricycle',             'Tricycle & Taxi',      Icons.local_taxi_rounded),
  ('sos',                  'Alertes SOS',          Icons.sos_rounded),
  ('anti_fraude',          'Anti-fraude',          Icons.gpp_bad_rounded),
  ('cash_marchand',        'Cash à régler',        Icons.payments_rounded),
  ('support',              'Support & Signalements', Icons.support_agent_rounded),
  ('ai_dashboard',         'Tableau de bord IA',    Icons.smart_toy_rounded),
  ('boulangeries',         'Boulangeries',         Icons.bakery_dining_rounded),
  ('zones',                'Zones Géo',            Icons.add_location_alt_rounded),
  ('ekbine',               'Agents E-Kbine',       Icons.sim_card_rounded),
  ('purger',               'Purger',               Icons.delete_sweep_rounded),
];

class AdminSubAdminsPage extends StatelessWidget {
  const AdminSubAdminsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        title: const Text('Gestion des admins'),
        backgroundColor: const Color(0xFF880E4F),
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('admins')
            .where('role', isEqualTo: 'sub')
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.manage_accounts, size: 64,
                      color: Colors.grey.shade300),
                  const SizedBox(height: 12),
                  const Text('Aucun sous-admin pour le moment',
                      style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, i) =>
                _SubAdminCard(doc: docs[i]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateDialog(context),
        backgroundColor: const Color(0xFF880E4F),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add),
        label: const Text('Nouveau sous-admin'),
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const _CreateSubAdminDialog(),
    );
  }
}

// ── CARTE D'UN SOUS-ADMIN ─────────────────────────────────────────────────

class _SubAdminCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _SubAdminCard({required this.doc});

  Map<String, dynamic> get data => doc.data() as Map<String, dynamic>;
  List<String> get perms => List<String>.from(data['permissions'] ?? []);
  bool get isActive => data['isActive'] as bool? ?? true;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // En-tête
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isActive
                  ? const Color(0xFF880E4F).withValues(alpha: 0.08)
                  : Colors.grey.shade100,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: isActive
                      ? const Color(0xFF880E4F)
                      : Colors.grey,
                  child: Text(
                    _initial(data['name'] as String? ?? '?'),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            data['name'] as String? ?? '—',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (!isActive)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.red.shade100,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text('DÉSACTIVÉ',
                                  style: TextStyle(
                                      color: Colors.red,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)),
                            ),
                        ],
                      ),
                      Text(data['email'] as String? ?? '—',
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 12)),
                      if ((data['phone'] as String? ?? '').isNotEmpty)
                        Text(data['phone'] as String,
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) => _onAction(context, v),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'edit',
                      child: Row(children: [
                        Icon(Icons.edit, size: 18),
                        SizedBox(width: 8),
                        Text('Modifier permissions'),
                      ]),
                    ),
                    PopupMenuItem(
                      value: isActive ? 'deactivate' : 'activate',
                      child: Row(children: [
                        Icon(isActive ? Icons.block : Icons.check_circle,
                            size: 18,
                            color: isActive ? Colors.orange : Colors.green),
                        const SizedBox(width: 8),
                        Text(isActive ? 'Désactiver' : 'Activer'),
                      ]),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(children: [
                        Icon(Icons.delete, size: 18, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Supprimer',
                            style: TextStyle(color: Colors.red)),
                      ]),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Permissions
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${perms.length} section${perms.length > 1 ? 's' : ''}',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.black54),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: perms.map((p) {
                    final matching = _kSections.where((s) => s.$1 == p);
                  final sec = matching.isEmpty ? null : matching.first;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF880E4F).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        sec?.$2 ?? p,
                        style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF880E4F),
                            fontWeight: FontWeight.w600),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _initial(String name) {
    final parts = name.trim().split(' ');
    if (parts.isEmpty || parts[0].isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  Future<void> _onAction(BuildContext context, String action) async {
    switch (action) {
      case 'edit':
        showDialog(
          context: context,
          builder: (_) => _EditPermissionsDialog(
            docId: doc.id,
            currentPerms: perms,
            name: data['name'] as String? ?? '',
          ),
        );
      case 'deactivate':
        await FirebaseFirestore.instance
            .collection('admins')
            .doc(doc.id)
            .update({'isActive': false});
        _logAdminAuditEvent('admin_deactivated', doc.id);
      case 'activate':
        await FirebaseFirestore.instance
            .collection('admins')
            .doc(doc.id)
            .update({'isActive': true});
        _logAdminAuditEvent('admin_activated', doc.id);
      case 'delete':
        final confirm = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Supprimer ce sous-admin ?'),
            content: Text(
                'Le compte de "${data['name']}" sera définitivement supprimé.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Annuler')),
              TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('Supprimer')),
            ],
          ),
        );
        if (confirm == true && context.mounted) {
          await _deleteSubAdmin(context, doc.id);
        }
    }
  }

  Future<void> _deleteSubAdmin(BuildContext context, String uid) async {
    try {
      final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('deleteSubAdmin');
      await fn.call({'uid': uid});
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Sous-admin supprimé'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur : $e'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }
}

// ── DIALOG : CRÉER UN SOUS-ADMIN ─────────────────────────────────────────

class _CreateSubAdminDialog extends StatefulWidget {
  const _CreateSubAdminDialog();

  @override
  State<_CreateSubAdminDialog> createState() => _CreateSubAdminDialogState();
}

class _CreateSubAdminDialogState extends State<_CreateSubAdminDialog> {
  final _nameCtrl  = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final Set<String> _selected = {};
  bool _loading = false;
  bool _showPass = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name  = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final pass  = _passCtrl.text;
    if (name.isEmpty || email.isEmpty || pass.isEmpty) {
      _snack('Nom, email et mot de passe requis', Colors.red);
      return;
    }
    if (_selected.isEmpty) {
      _snack('Sélectionnez au moins une section', Colors.orange);
      return;
    }
    setState(() => _loading = true);
    try {
      final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('createSubAdmin');
      await fn.call({
        'name':        name,
        'email':       email,
        'password':    pass,
        'phone':       _phoneCtrl.text.trim(),
        'permissions': _selected.toList(),
      });
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Sous-admin créé avec succès'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      setState(() => _loading = false);
      _snack('Erreur : $e', Colors.red);
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: color));
  }

  void _selectAll()   => setState(() => _selected.addAll(_kSections.map((s) => s.$1)));
  void _clearAll()    => setState(() => _selected.clear());

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFF880E4F),
                  child: Icon(Icons.person_add, color: Colors.white),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Nouveau sous-admin',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Champs
            _field(_nameCtrl, 'Nom complet', Icons.badge),
            const SizedBox(height: 10),
            _field(_emailCtrl, 'Adresse email', Icons.email,
                type: TextInputType.emailAddress),
            const SizedBox(height: 10),
            TextField(
              controller: _passCtrl,
              obscureText: !_showPass,
              decoration: InputDecoration(
                labelText: 'Mot de passe',
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon: Icon(
                      _showPass ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPass = !_showPass),
                ),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 14),
              ),
            ),
            const SizedBox(height: 10),
            _field(_phoneCtrl, 'Téléphone (optionnel + 2FA)', Icons.phone,
                type: TextInputType.phone),
            const SizedBox(height: 18),

            // Permissions
            Row(
              children: [
                const Text('Sections autorisées',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14)),
                const Spacer(),
                TextButton(
                    onPressed: _selectAll,
                    child: const Text('Tout',
                        style: TextStyle(fontSize: 12))),
                TextButton(
                    onPressed: _clearAll,
                    child: const Text('Aucun',
                        style: TextStyle(fontSize: 12))),
              ],
            ),
            const SizedBox(height: 8),
            _PermissionsGrid(
              selected: _selected,
              onToggle: (key) => setState(() {
                if (_selected.contains(key)) {
                  _selected.remove(key);
                } else {
                  _selected.add(key);
                }
              }),
            ),
            const SizedBox(height: 20),

            // Bouton créer
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _loading ? null : _create,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF880E4F),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5))
                    : const Text('Créer le sous-admin',
                        style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    TextInputType type = TextInputType.text,
  }) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border:
            OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
    );
  }
}

// ── DIALOG : MODIFIER LES PERMISSIONS ────────────────────────────────────

class _EditPermissionsDialog extends StatefulWidget {
  final String docId;
  final List<String> currentPerms;
  final String name;
  const _EditPermissionsDialog({
    required this.docId,
    required this.currentPerms,
    required this.name,
  });

  @override
  State<_EditPermissionsDialog> createState() =>
      _EditPermissionsDialogState();
}

class _EditPermissionsDialogState extends State<_EditPermissionsDialog> {
  late Set<String> _selected;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.currentPerms);
  }

  Future<void> _save() async {
    setState(() => _loading = true);
    try {
      await FirebaseFirestore.instance
          .collection('admins')
          .doc(widget.docId)
          .update({'permissions': _selected.toList()});
      _logAdminAuditEvent('permissions_changed', widget.docId, {'permissions': _selected.toList()});
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Permissions mises à jour'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur : $e'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFF880E4F),
                  child: Icon(Icons.edit, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Permissions de ${widget.name}',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('${_selected.length} section(s) sélectionnée(s)',
                style:
                    const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => setState(() =>
                      _selected.addAll(_kSections.map((s) => s.$1))),
                  child: const Text('Tout', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => _selected.clear()),
                  child:
                      const Text('Aucun', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            _PermissionsGrid(
              selected: _selected,
              onToggle: (key) => setState(() {
                if (_selected.contains(key)) {
                  _selected.remove(key);
                } else {
                  _selected.add(key);
                }
              }),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _loading ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF880E4F),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5))
                    : const Text('Enregistrer',
                        style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── GRILLE DE PERMISSIONS ─────────────────────────────────────────────────

class _PermissionsGrid extends StatelessWidget {
  final Set<String> selected;
  final void Function(String) onToggle;
  const _PermissionsGrid({required this.selected, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _kSections.map((sec) {
        final (key, label, icon) = sec;
        final on = selected.contains(key);
        return GestureDetector(
          onTap: () => onToggle(key),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: on
                  ? const Color(0xFF880E4F)
                  : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: on
                    ? const Color(0xFF880E4F)
                    : Colors.grey.shade300,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 14,
                    color: on ? Colors.white : Colors.grey.shade600),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: on ? Colors.white : Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
