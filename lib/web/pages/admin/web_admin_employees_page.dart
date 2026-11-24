import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../web_theme.dart';
import '../../../screens/admin/admin_permission_catalog.dart';
import '../../../widgets/stream_error_state.dart';
import 'web_admin_dashboard.dart'
    show firestoreStreamErrorMessage, firestoreStreamErrorIcon;

/// Section « Employés » du Bureau Web (Phase 2).
///
/// Porte au Web le système de sous-administrateurs déjà en production sur
/// Android (`admin_sub_admins_page.dart`) sans en dupliquer la logique
/// métier : création/suppression passent par les Cloud Functions existantes
/// (`createSubAdmin`/`deleteSubAdmin`, qui exigent déjà `requireSuperAdmin`
/// et journalisent via `logAudit`) ; activer/désactiver et modifier les
/// permissions utilisent la même écriture Firestore directe que le mobile,
/// déjà le seul mécanisme existant et déjà sécurisée par `firestore.rules`
/// (`admins/{adminId}` : seul `isSuperAdmin()` peut modifier `isActive` ou
/// `permissions`, un sous-admin ne peut toucher que `fcmToken`/`photoUrl`).
/// Cette page n'ajoute donc aucune nouvelle Cloud Function ni règle.
class WebAdminEmployeesPage extends StatefulWidget {
  const WebAdminEmployeesPage({super.key});

  @override
  State<WebAdminEmployeesPage> createState() => _WebAdminEmployeesPageState();
}

/// Filtre pur (nom/email + permission) — testable sans Firebase, même
/// approche que `filterAndSortArtisans` (web_artisans_page.dart).
List<Map<String, dynamic>> filterEmployees(
  List<Map<String, dynamic>> employees, {
  String query = '',
  String? permission,
}) {
  final q = query.trim().toLowerCase();
  return employees.where((e) {
    if (permission != null) {
      final perms = (e['permissions'] as List?)?.cast<String>() ?? const [];
      if (!perms.contains(permission)) return false;
    }
    if (q.isEmpty) return true;
    final name = (e['name'] as String? ?? '').toLowerCase();
    final email = (e['email'] as String? ?? '').toLowerCase();
    return name.contains(q) || email.contains(q);
  }).toList();
}

Future<void> _logAdminAuditEvent(String action, String targetId,
    [Map<String, dynamic>? metadata]) async {
  try {
    await FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable('logAdminAuditEvent')
        .call({
      'action': action,
      'targetId': targetId,
      if (metadata != null) 'metadata': metadata,
    });
  } catch (_) {
    // Best-effort, comme côté mobile : ne doit jamais bloquer l'action déjà faite.
  }
}

class _WebAdminEmployeesPageState extends State<WebAdminEmployeesPage> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String? _permissionFilter;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _openCreateDialog() {
    showDialog(context: context, builder: (_) => const _CreateEmployeeDialog());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Employés',
                        style: GoogleFonts.inter(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: kText)),
                    const SizedBox(height: 4),
                    Text(
                      'Sous-administrateurs — création, permissions et accès '
                      'gérés exactement comme sur l\'application mobile.',
                      style: GoogleFonts.inter(fontSize: 12, color: kTextMuted),
                    ),
                  ],
                ),
              ),
              ElevatedButton.icon(
                onPressed: _openCreateDialog,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kOrange,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.person_add_rounded, size: 18),
                label: const Text('Nouvel employé'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v),
            style: GoogleFonts.inter(color: kText, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Rechercher un employé (nom, email)…',
              hintStyle: GoogleFonts.inter(color: kTextMuted),
              prefixIcon: const Icon(Icons.search_rounded, color: kTextMuted),
              filled: true,
              fillColor: kCard,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: kDivider),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: kDivider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: kOrange, width: 2),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _FilterChip(
                  label: 'Toutes les permissions',
                  selected: _permissionFilter == null,
                  onTap: () => setState(() => _permissionFilter = null),
                ),
                for (final entry in adminPermissionCatalog)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _FilterChip(
                      label: entry.$2,
                      selected: _permissionFilter == entry.$1,
                      onTap: () =>
                          setState(() => _permissionFilter = entry.$1),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('admins')
                .where('role', isEqualTo: 'sub')
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return StreamErrorState(
                  message: firestoreStreamErrorMessage(snap.error),
                  icon: firestoreStreamErrorIcon(snap.error),
                  onRetry: () => setState(() {}),
                );
              }
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(
                    child: CircularProgressIndicator(color: kOrange));
              }
              final all = (snap.data?.docs ?? []).map((d) {
                final data = Map<String, dynamic>.from(
                    d.data() as Map<String, dynamic>);
                data['_id'] = d.id;
                return data;
              }).toList();
              final filtered = filterEmployees(all,
                  query: _query, permission: _permissionFilter);
              if (all.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.badge_outlined,
                          size: 56, color: kTextMuted.withValues(alpha: 0.4)),
                      const SizedBox(height: 12),
                      Text('Aucun employé pour le moment.',
                          style:
                              GoogleFonts.inter(fontSize: 15, color: kTextMuted)),
                    ],
                  ),
                );
              }
              if (filtered.isEmpty) {
                return Center(
                  child: Text('Aucun résultat pour ce filtre.',
                      style: GoogleFonts.inter(fontSize: 14, color: kTextMuted)),
                );
              }
              return LayoutBuilder(builder: (context, box) {
                final cols = box.maxWidth >= 1024
                    ? 3
                    : (box.maxWidth >= 600 ? 2 : 1);
                const gap = 14.0;
                final itemWidth = (box.maxWidth - gap * (cols - 1)) / cols;
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final e in filtered)
                        SizedBox(width: itemWidth, child: _EmployeeCard(data: e)),
                    ],
                  ),
                );
              });
            },
          ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? kOrange : kCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? kOrange : kDivider),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: GoogleFonts.inter(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : kText)),
      ),
    );
  }
}

// ── Carte employé ───────────────────────────────────────────────────────────
class _EmployeeCard extends StatefulWidget {
  final Map<String, dynamic> data;
  const _EmployeeCard({required this.data});

  @override
  State<_EmployeeCard> createState() => _EmployeeCardState();
}

class _EmployeeCardState extends State<_EmployeeCard> {
  bool _busy = false;

  String get _id => widget.data['_id'] as String;
  String get _name => widget.data['name'] as String? ?? '—';
  String get _email => widget.data['email'] as String? ?? '—';
  String get _phone => widget.data['phone'] as String? ?? '';
  bool get _isActive => widget.data['isActive'] as bool? ?? true;
  List<String> get _perms =>
      (widget.data['permissions'] as List?)?.cast<String>() ?? const [];

  Future<void> _toggleActive() async {
    final nextActive = !_isActive;
    final confirm = await _confirm(
      title: nextActive ? 'Réactiver cet employé ?' : 'Désactiver cet employé ?',
      message: nextActive
          ? '$_name pourra de nouveau se connecter.'
          : '$_name ne pourra plus se connecter tant que le compte reste désactivé.',
      confirmLabel: nextActive ? 'Réactiver' : 'Désactiver',
      destructive: !nextActive,
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance
          .collection('admins')
          .doc(_id)
          .update({'isActive': nextActive});
      await _logAdminAuditEvent(
          nextActive ? 'admin_activated' : 'admin_deactivated', _id);
    } catch (e) {
      if (mounted) _snack(context, 'Erreur : $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirm = await _confirm(
      title: 'Supprimer définitivement cet employé ?',
      message:
          'Le compte de "$_name" sera supprimé (connexion et accès). Action irréversible.',
      confirmLabel: 'Supprimer',
      destructive: true,
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('deleteSubAdmin')
          .call({'uid': _id});
      if (mounted) _snack(context, 'Employé supprimé', isError: false);
    } catch (e) {
      if (mounted) _snack(context, 'Erreur : $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _editPermissions() {
    showDialog(
      context: context,
      builder: (_) =>
          _EditPermissionsDialog(docId: _id, name: _name, currentPerms: _perms),
    );
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    required bool destructive,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title,
            style: GoogleFonts.inter(fontWeight: FontWeight.w700, color: kText)),
        content: Text(message, style: GoogleFonts.inter(color: kTextMuted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Annuler', style: GoogleFonts.inter(color: kTextMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel,
                style: GoogleFonts.inter(
                    color: destructive ? Colors.red : kOrange,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  void _snack(BuildContext context, String msg, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red : kSuccess,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _isActive ? kDivider : Colors.red.withValues(alpha: 0.3)),
        boxShadow: const [
          BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: _isActive ? kOrangeBg : kBg,
                child: Text(
                  _name.isNotEmpty ? _name[0].toUpperCase() : '?',
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.w800,
                      color: _isActive ? kOrange : kTextMuted),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                            fontWeight: FontWeight.w700, fontSize: 14, color: kText)),
                    Text(_email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(fontSize: 12, color: kTextMuted)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (_isActive ? kSuccess : Colors.red).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(_isActive ? 'Actif' : 'Désactivé',
                    style: GoogleFonts.inter(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: _isActive ? kSuccess : Colors.red)),
              ),
            ],
          ),
          if (_phone.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Tél. : $_phone', style: GoogleFonts.inter(fontSize: 12, color: kTextMuted)),
          ],
          const SizedBox(height: 10),
          Text('${_perms.length} permission${_perms.length > 1 ? 's' : ''}',
              style: GoogleFonts.inter(
                  fontSize: 11, fontWeight: FontWeight.w600, color: kTextMuted)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _perms.isEmpty
                ? [Text('Aucune', style: GoogleFonts.inter(fontSize: 11, color: kTextMuted))]
                : _perms.map((p) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                      decoration: BoxDecoration(
                        color: kOrangeBg,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(adminPermissionLabel(p),
                          style: GoogleFonts.inter(
                              fontSize: 10.5, color: kOrange, fontWeight: FontWeight.w600)),
                    );
                  }).toList(),
          ),
          const SizedBox(height: 12),
          if (_busy)
            const Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kOrange)))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ActionBtn(
                    icon: Icons.edit_rounded,
                    label: 'Permissions',
                    color: kBlue,
                    onTap: _editPermissions),
                _ActionBtn(
                    icon: _isActive ? Icons.block_rounded : Icons.check_circle_rounded,
                    label: _isActive ? 'Désactiver' : 'Activer',
                    color: _isActive ? Colors.orange.shade800 : kSuccess,
                    onTap: _toggleActive),
                _ActionBtn(
                    icon: Icons.delete_outline_rounded,
                    label: 'Supprimer',
                    color: Colors.red,
                    onTap: _delete),
              ],
            ),
        ],
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionBtn(
      {required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 6),
          Text(label,
              style: GoogleFonts.inter(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

// ── Pastilles de sélection de permissions (création/édition) ───────────────
class _PermissionsPicker extends StatelessWidget {
  final Set<String> selected;
  final void Function(String) onToggle;
  const _PermissionsPicker({required this.selected, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: adminPermissionCatalog.map((entry) {
        final (key, label, icon) = entry;
        final on = selected.contains(key);
        return GestureDetector(
          onTap: () => onToggle(key),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: on ? kOrange : kBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: on ? kOrange : kDivider),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 14, color: on ? Colors.white : kTextMuted),
              const SizedBox(width: 5),
              Text(label,
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: on ? Colors.white : kText)),
            ]),
          ),
        );
      }).toList(),
    );
  }
}

// ── Dialogue : créer un employé ─────────────────────────────────────────────
class _CreateEmployeeDialog extends StatefulWidget {
  const _CreateEmployeeDialog();

  @override
  State<_CreateEmployeeDialog> createState() => _CreateEmployeeDialogState();
}

class _CreateEmployeeDialogState extends State<_CreateEmployeeDialog> {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  Set<String> _selected = {};
  bool _loading = false;
  bool _showPass = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text;
    if (name.isEmpty || email.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Nom, email et mot de passe requis.');
      return;
    }
    if (_selected.isEmpty) {
      setState(() => _error = 'Sélectionnez au moins une permission.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('createSubAdmin')
          .call({
        'name': name,
        'email': email,
        'password': pass,
        'phone': _phoneCtrl.text.trim(),
        'permissions': _selected.toList(),
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Erreur : $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Hauteur bornée pour que le pied (résumé + bouton « Créer l'employé »)
    // reste toujours visible pendant que les champs/permissions défilent —
    // au lieu de tout mettre dans un seul SingleChildScrollView où le
    // bouton pouvait sortir de l'écran sur une longue liste de permissions.
    final maxH = (MediaQuery.of(context).size.height * 0.85).clamp(420.0, 680.0);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 12, 0),
              child: Row(children: [
                Expanded(
                  child: Text('Nouvel employé',
                      style: GoogleFonts.inter(
                          fontSize: 17, fontWeight: FontWeight.w700, color: kText)),
                ),
                IconButton(
                    icon: const Icon(Icons.close_rounded, color: kTextMuted),
                    onPressed: () => Navigator.pop(context)),
              ]),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _field(_nameCtrl, 'Nom complet', onChanged: (_) => setState(() {})),
                    const SizedBox(height: 10),
                    _field(_emailCtrl, 'Adresse email',
                        type: TextInputType.emailAddress,
                        onChanged: (_) => setState(() {})),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _passCtrl,
                      obscureText: !_showPass,
                      style: GoogleFonts.inter(color: kText),
                      decoration: InputDecoration(
                        labelText: 'Mot de passe',
                        labelStyle: GoogleFonts.inter(color: kTextMuted),
                        suffixIcon: IconButton(
                          icon: Icon(
                              _showPass ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                              color: kTextMuted),
                          onPressed: () => setState(() => _showPass = !_showPass),
                        ),
                        filled: true,
                        fillColor: kCard,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _field(_phoneCtrl, 'Téléphone (optionnel)', type: TextInputType.phone),
                    const SizedBox(height: 18),
                    Text('Permissions',
                        style: GoogleFonts.inter(
                            fontWeight: FontWeight.w700, fontSize: 13, color: kText)),
                    const SizedBox(height: 8),
                    _CategorizedPermissionsPicker(
                      selected: _selected,
                      onChanged: (next) => setState(() => _selected = next),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: kDivider)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _summary(),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: GoogleFonts.inter(color: Colors.red, fontSize: 12.5)),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _create,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kOrange,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child:
                                  CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                          : Text('Créer l\'employé',
                              style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Résumé avant création : nom, email, nombre et répartition des
  /// permissions — permet de vérifier les droits sans ajouter une étape
  /// séparée (confirmation existante, simplement enrichie).
  Widget _summary() {
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: kOrangeBg, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Résumé avant création',
              style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w700, color: kOrange)),
          const SizedBox(height: 4),
          Text('Nom : ${name.isEmpty ? '—' : name}',
              style: GoogleFonts.inter(fontSize: 12.5, color: kText)),
          Text('Email : ${email.isEmpty ? '—' : email}',
              style: GoogleFonts.inter(fontSize: 12.5, color: kText)),
          const SizedBox(height: 2),
          Text(
            '${_selected.length} permission${_selected.length > 1 ? 's' : ''} : '
            '${summarizeSelectedPermissions(_selected)}',
            style: GoogleFonts.inter(fontSize: 11.5, color: kTextMuted),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label,
      {TextInputType type = TextInputType.text, ValueChanged<String>? onChanged}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      onChanged: onChanged,
      style: GoogleFonts.inter(color: kText),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.inter(color: kTextMuted),
        filled: true,
        fillColor: kCard,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }
}

// ── Pastilles de permissions organisées par catégorie (repliables) ─────────
// Remplace `_PermissionsPicker` (liste plate de 29 pastilles) uniquement
// dans le formulaire de création — l'édition des permissions d'un employé
// existant garde volontairement l'ancien sélecteur, hors périmètre de cette
// amélioration UX ciblée.
class _CategorizedPermissionsPicker extends StatefulWidget {
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  const _CategorizedPermissionsPicker({required this.selected, required this.onChanged});

  @override
  State<_CategorizedPermissionsPicker> createState() =>
      _CategorizedPermissionsPickerState();
}

class _CategorizedPermissionsPickerState extends State<_CategorizedPermissionsPicker> {
  // Catégories repliées par défaut : la liste à plat était justement le
  // problème signalé (« dense »), donc on commence compact.
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final total = adminPermissionCatalog.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('${widget.selected.length}/$total sélectionnée${widget.selected.length > 1 ? 's' : ''}',
                style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700, color: kText)),
            const Spacer(),
            TextButton(
              onPressed: () => widget.onChanged(selectAllPermissions()),
              child: Text('Tout sélectionner',
                  style:
                      GoogleFonts.inter(fontSize: 12, color: kOrange, fontWeight: FontWeight.w600)),
            ),
            TextButton(
              onPressed: () => widget.onChanged(deselectAllPermissions()),
              child: Text('Tout désélectionner',
                  style: GoogleFonts.inter(
                      fontSize: 12, color: kTextMuted, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final cat in adminPermissionCategories) _categoryTile(cat),
      ],
    );
  }

  Widget _categoryTile(AdminPermissionCategory cat) {
    final selectedCount = cat.keys.where(widget.selected.contains).length;
    final allSelected = selectedCount == cat.keys.length;
    final expanded = _expanded.contains(cat.label);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kDivider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() {
              if (expanded) {
                _expanded.remove(cat.label);
              } else {
                _expanded.add(cat.label);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Icon(cat.icon, size: 18, color: kOrange),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(cat.label,
                      style: GoogleFonts.inter(
                          fontSize: 13, fontWeight: FontWeight.w700, color: kText)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: selectedCount > 0 ? kOrangeBg : kCard,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('$selectedCount/${cat.keys.length}',
                      style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: selectedCount > 0 ? kOrange : kTextMuted)),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: allSelected
                      ? 'Désélectionner la catégorie'
                      : 'Sélectionner toute la catégorie',
                  child: GestureDetector(
                    onTap: () => widget.onChanged(toggleCategorySelection(widget.selected, cat)),
                    child: Icon(
                      allSelected
                          ? Icons.check_box_rounded
                          : (selectedCount > 0
                              ? Icons.indeterminate_check_box_rounded
                              : Icons.check_box_outline_blank_rounded),
                      size: 20,
                      color: selectedCount > 0 ? kOrange : kTextMuted,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 20, color: kTextMuted),
              ]),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: cat.keys.map((key) {
                  final on = widget.selected.contains(key);
                  return GestureDetector(
                    onTap: () => widget.onChanged(togglePermission(widget.selected, key)),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: on ? kOrange : kCard,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: on ? kOrange : kDivider),
                      ),
                      child: Text(adminPermissionLabel(key),
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: on ? Colors.white : kText)),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Dialogue : modifier les permissions ─────────────────────────────────────
class _EditPermissionsDialog extends StatefulWidget {
  final String docId;
  final String name;
  final List<String> currentPerms;
  const _EditPermissionsDialog(
      {required this.docId, required this.name, required this.currentPerms});

  @override
  State<_EditPermissionsDialog> createState() => _EditPermissionsDialogState();
}

class _EditPermissionsDialogState extends State<_EditPermissionsDialog> {
  late Set<String> _selected;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.currentPerms);
  }

  Future<void> _save() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await FirebaseFirestore.instance
          .collection('admins')
          .doc(widget.docId)
          .update({'permissions': _selected.toList()});
      await _logAdminAuditEvent(
          'permissions_changed', widget.docId, {'permissions': _selected.toList()});
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Erreur : $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text('Permissions de ${widget.name}',
                      style: GoogleFonts.inter(
                          fontSize: 16, fontWeight: FontWeight.w700, color: kText)),
                ),
                IconButton(
                    icon: const Icon(Icons.close_rounded, color: kTextMuted),
                    onPressed: () => Navigator.pop(context)),
              ]),
              Text('${_selected.length} permission(s) sélectionnée(s)',
                  style: GoogleFonts.inter(fontSize: 12, color: kTextMuted)),
              const SizedBox(height: 14),
              _PermissionsPicker(
                selected: _selected,
                onToggle: (key) => setState(() {
                  if (_selected.contains(key)) {
                    _selected.remove(key);
                  } else {
                    _selected.add(key);
                  }
                }),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: GoogleFonts.inter(color: Colors.red, fontSize: 12.5)),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _loading ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kOrange,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _loading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                      : Text('Enregistrer', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
