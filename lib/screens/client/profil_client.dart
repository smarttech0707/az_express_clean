import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../l10n/app_text.dart';
import '../../services/account_deletion_service.dart';
import '../../services/auth_service.dart';
import '../auth/client_auth_page.dart';
import '../support/support_screen.dart';
import '../../theme/app_theme.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/glass_kit.dart';
import '../../widgets/single_photo_editor.dart';

class ProfilClient extends StatefulWidget {
  const ProfilClient({super.key});

  @override
  State<ProfilClient> createState() => _ProfilClientState();
}

class _ProfilClientState extends State<ProfilClient> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  String? _createdAt;
  String? _photoUrl;
  bool _editing = false;
  bool _saving = false;

  int _totalOrders = 0;
  int _deliveredOrders = 0;
  int _pendingOrders = 0;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadOrderStats();
  }

  Future<void> _loadOrderStats() async {
    final uid = _uid;
    if (uid == null) return;
    final col = FirebaseFirestore.instance
        .collection("orders")
        .where("clientId", isEqualTo: uid);
    try {
      final results = await Future.wait([
        col.count().get(),
        col.where("status", isEqualTo: "delivered").count().get(),
        col.where("status", isEqualTo: "pending").count().get(),
      ]);
      if (!mounted) return;
      setState(() {
        _totalOrders = results[0].count ?? 0;
        _deliveredOrders = results[1].count ?? 0;
        _pendingOrders = results[2].count ?? 0;
      });
    } catch (_) {}
  }

  Future<void> _loadProfile() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final doc =
          await FirebaseFirestore.instance.collection("clients").doc(uid).get();
      if (doc.exists && mounted) {
        final ts = doc.data()?['createdAt'];
        String? created;
        if (ts is Timestamp) {
          final d = ts.toDate();
          created =
              '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
        }
        setState(() {
          _nameCtrl.text = doc['name'] ?? '';
          _phoneCtrl.text = doc['phone'] ?? '';
          _emailCtrl.text = doc['email'] ?? '';
          _createdAt = created;
          _photoUrl = doc.data()?['photoUrl'] as String?;
        });
      }
    } catch (_) {}
  }

  Future<void> _saveProfile() async {
    String? uid = _uid;
    if (uid == null) {
      try {
        final cred = await FirebaseAuth.instance.signInAnonymously();
        uid = cred.user?.uid;
      } on FirebaseAuthException catch (e) {
        if (!mounted) return;
        final msg = e.code == 'operation-not-allowed'
            ? "Activez la connexion anonyme dans Firebase Console → Authentication → Sign-in method → Anonyme"
            : "Erreur Firebase : ${e.code}";
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(msg),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 6)),
        );
        return;
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur : $e"), backgroundColor: Colors.red),
        );
        return;
      }
    }

    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();

    if (name.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(context.tr('enter_name')),
            backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      await FirebaseFirestore.instance.collection("clients").doc(uid).set({
        "name": name,
        "phone": phone,
        "updatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      setState(() {
        _saving = false;
        _editing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(context.tr('profile_updated')),
            backgroundColor: Colors.green),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("Erreur : ${e.toString()}"),
            backgroundColor: Colors.red),
      );
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  // ── Dialogues de sécurité ────────────────────────────────────────────────

  void _showChangePassword() {
    final curCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        bool loading = false;
        return StatefulBuilder(
          builder: (ctx, setS) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Text('Changer le mot de passe'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                _SecField(ctrl: curCtrl, label: 'Mot de passe actuel'),
                const SizedBox(height: 10),
                _SecField(ctrl: newCtrl, label: 'Nouveau mot de passe'),
                const SizedBox(height: 10),
                _SecField(ctrl: confCtrl, label: 'Confirmer'),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Annuler')),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary),
                  onPressed: loading
                      ? null
                      : () async {
                          final err =
                              AuthService.validatePassword(newCtrl.text);
                          if (err != null) {
                            if (ctx.mounted)
                              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                  content: Text(err),
                                  backgroundColor: Colors.orange));
                            return;
                          }
                          if (newCtrl.text != confCtrl.text) {
                            if (ctx.mounted)
                              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                                  content: Text(
                                      'Les mots de passe ne correspondent pas'),
                                  backgroundColor: Colors.red));
                            return;
                          }
                          setS(() => loading = true);
                          try {
                            await AuthService().updatePassword(
                                currentPassword: curCtrl.text,
                                newPassword: newCtrl.text);
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted)
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Mot de passe mis à jour'),
                                      backgroundColor: Colors.green));
                          } catch (e) {
                            setS(() => loading = false);
                            if (ctx.mounted)
                              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                  content: Text('Erreur : $e'),
                                  backgroundColor: Colors.red));
                          }
                        },
                  child: const Text('Enregistrer',
                      style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showChangeEmail() {
    final passCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        bool loading = false;
        return StatefulBuilder(
          builder: (ctx, setS) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Text('Modifier l\'email'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                _SecField(ctrl: passCtrl, label: 'Mot de passe actuel'),
                const SizedBox(height: 10),
                _SecField(
                    ctrl: emailCtrl, label: 'Nouvel email', isEmail: true),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Annuler')),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary),
                  onPressed: loading
                      ? null
                      : () async {
                          if (!AuthService.isValidEmail(emailCtrl.text)) {
                            if (ctx.mounted)
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                      content: Text('Email invalide'),
                                      backgroundColor: Colors.orange));
                            return;
                          }
                          setS(() => loading = true);
                          try {
                            await AuthService().updateEmail(
                                currentPassword: passCtrl.text,
                                newEmail: emailCtrl.text,
                                collection: 'clients');
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted)
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Un lien de vérification a été envoyé à votre nouvel email'),
                                      backgroundColor: Colors.green,
                                      duration: Duration(seconds: 4)));
                          } catch (e) {
                            setS(() => loading = false);
                            if (ctx.mounted)
                              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                  content: Text('Erreur : $e'),
                                  backgroundColor: Colors.red));
                          }
                        },
                  child: const Text('Envoyer la vérification',
                      style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showChangePhone() {
    final passCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        bool loading = false;
        return StatefulBuilder(
          builder: (ctx, setS) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Text('Modifier le téléphone'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                _SecField(ctrl: passCtrl, label: 'Mot de passe actuel'),
                const SizedBox(height: 10),
                _SecField(
                    ctrl: phoneCtrl, label: 'Nouveau numéro', isPhone: true),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Annuler')),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary),
                  onPressed: loading
                      ? null
                      : () async {
                          if (!AuthService.isValidPhone(phoneCtrl.text)) {
                            if (ctx.mounted)
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                      content: Text('Numéro invalide'),
                                      backgroundColor: Colors.orange));
                            return;
                          }
                          setS(() => loading = true);
                          try {
                            await AuthService().updatePhone(
                                currentPassword: passCtrl.text,
                                newPhone: phoneCtrl.text,
                                collection: 'clients');
                            if (mounted)
                              setState(() =>
                                  _phoneCtrl.text = phoneCtrl.text.trim());
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted)
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Numéro mis à jour'),
                                      backgroundColor: Colors.green));
                          } catch (e) {
                            setS(() => loading = false);
                            if (ctx.mounted)
                              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                  content: Text('Erreur : $e'),
                                  backgroundColor: Colors.red));
                          }
                        },
                  child: const Text('Enregistrer',
                      style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight:
                (MediaQuery.of(context).size.height * 0.25).clamp(180.0, 260.0),
            pinned: true,
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.primary, Color(0xFFFFB300)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 40),
                      if (_uid != null)
                        SinglePhotoEditor(
                          photoUrl: _photoUrl,
                          storagePath: 'client_photos/$_uid/profile.jpg',
                          size: 80,
                          onUploaded: (url) async {
                            await FirebaseFirestore.instance
                                .collection('clients')
                                .doc(_uid)
                                .set(
                                    {'photoUrl': url}, SetOptions(merge: true));
                            if (mounted) setState(() => _photoUrl = url);
                          },
                          onDeleted: () async {
                            await FirebaseFirestore.instance
                                .collection('clients')
                                .doc(_uid)
                                .update({'photoUrl': FieldValue.delete()});
                            if (mounted) setState(() => _photoUrl = null);
                          },
                        )
                      else
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.25),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.person,
                              color: Colors.white, size: 44),
                        ),
                      const SizedBox(height: 10),
                      Text(
                        _nameCtrl.text.isEmpty
                            ? context.tr('my_profile')
                            : _nameCtrl.text,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            title: Text(context.tr('my_profile'),
                style: const TextStyle(color: Colors.white)),
            centerTitle: true,
            actions: [
              IconButton(
                icon: Icon(_editing ? Icons.close : Icons.edit,
                    color: Colors.white),
                onPressed: () => setState(() => _editing = !_editing),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── INFOS PERSONNELLES ──────────────────────
                  _sectionTitle(context.tr('personal_info')),
                  const SizedBox(height: 10),
                  _infoCard(
                    children: [
                      _infoField(_nameCtrl, context.tr('full_name'),
                          Icons.person, _editing),
                      const Divider(height: 1),
                      _infoField(_phoneCtrl, context.tr('phone'), Icons.phone,
                          _editing,
                          type: TextInputType.phone),
                      const Divider(height: 1),
                      _infoField(
                          _emailCtrl, 'Email', Icons.email_outlined, false),
                      if (_createdAt != null) ...[
                        const Divider(height: 1),
                        _readOnlyField('Membre depuis', _createdAt!,
                            Icons.calendar_today_outlined),
                      ],
                    ],
                  ),

                  if (_editing) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ScaleButton(
                        onPressed: _saving ? null : _saveProfile,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: _saving
                            ? const CircularProgressIndicator(
                                color: Colors.white)
                            : Text(context.tr('save'),
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 16)),
                      ),
                    ),
                  ],

                  const SizedBox(height: 24),

                  // ── SÉCURITÉ ─────────────────────────────────
                  _sectionTitle('Sécurité du compte'),
                  const SizedBox(height: 10),
                  _infoCard(
                    children: [
                      _menuItem(Icons.lock_outline, 'Modifier le mot de passe',
                          _showChangePassword),
                      const Divider(height: 1),
                      _menuItem(Icons.email_outlined, 'Modifier l\'email',
                          _showChangeEmail),
                      const Divider(height: 1),
                      _menuItem(Icons.phone_android_outlined,
                          'Modifier le téléphone', _showChangePhone),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // ── STATISTIQUES ────────────────────────────
                  _sectionTitle(context.tr('my_orders')),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _statCard(context.tr('total_orders'), "$_totalOrders",
                          Icons.receipt_long, AppColors.primary),
                      const SizedBox(width: 10),
                      _statCard(
                          context.tr('delivered_orders'),
                          "$_deliveredOrders",
                          Icons.check_circle,
                          Colors.green),
                      const SizedBox(width: 10),
                      _statCard(context.tr('pending_orders'), "$_pendingOrders",
                          Icons.hourglass_top, Colors.orange),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // ── DERNIÈRES COMMANDES ─────────────────────
                  _sectionTitle('Dernières commandes'),
                  const SizedBox(height: 10),
                  if (_uid != null) _RecentOrders(uid: _uid!),

                  const SizedBox(height: 24),

                  // ── SUPPORT ──────────────────────────────────
                  _sectionTitle('Aide & Support'),
                  const SizedBox(height: 10),
                  _infoCard(
                    children: [
                      _menuItem(
                        Icons.support_agent_rounded,
                        'Aide & Support',
                        () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const SupportScreen())),
                        color: AppColors.primary,
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // ── LÉGAL ───────────────────────────────────
                  _sectionTitle(context.tr('legal_info')),
                  const SizedBox(height: 10),
                  _infoCard(
                    children: [
                      _menuItem(
                          Icons.privacy_tip_outlined,
                          context.tr('privacy'),
                          () => _showLegal(
                              context, context.tr('privacy'), _privacy)),
                      const Divider(height: 1),
                      _menuItem(
                          Icons.gavel_outlined,
                          context.tr('terms'),
                          () =>
                              _showLegal(context, context.tr('terms'), _terms)),
                      const Divider(height: 1),
                      _menuItem(
                          Icons.local_shipping_outlined,
                          context.tr('delivery_policy'),
                          () => _showLegal(context,
                              context.tr('delivery_policy'), _delivery)),
                      const Divider(height: 1),
                      _menuItem(
                          Icons.payments_outlined,
                          context.tr('payment_policy'),
                          () => _showLegal(
                              context, context.tr('payment_policy'), _payment)),
                      const Divider(height: 1),
                      _menuItem(Icons.info_outline, context.tr('about'),
                          () => _showAbout(context)),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // ── DÉCONNEXION ─────────────────────────────
                  _infoCard(
                    children: [
                      _menuItem(Icons.logout, context.tr('logout'),
                          () => _showLogout(context),
                          color: Colors.orange.shade800),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // ── DANGER ──────────────────────────────────
                  _infoCard(
                    children: [
                      _menuItem(
                          Icons.delete_forever_outlined,
                          context.tr('delete_account'),
                          () => _showDeleteAccount(context),
                          color: Colors.red),
                    ],
                  ),

                  // Espace pour la navigation flottante
                  SizedBox(height: MediaQuery.of(context).padding.bottom + 100),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) => Text(
        title,
        style: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey),
      );

  Widget _infoCard({required List<Widget> children}) => Container(
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

  Widget _infoField(
      TextEditingController ctrl, String label, IconData icon, bool editable,
      {TextInputType? type}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey),
          const SizedBox(width: 12),
          Expanded(
            child: editable
                ? TextField(
                    controller: ctrl,
                    keyboardType: type,
                    decoration: InputDecoration(
                      labelText: label,
                      border: InputBorder.none,
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 11)),
                        const SizedBox(height: 2),
                        Text(
                          ctrl.text.isEmpty
                              ? context.tr('not_provided')
                              : ctrl.text,
                          style: TextStyle(
                            fontSize: 15,
                            color: ctrl.text.isEmpty
                                ? Colors.grey.shade400
                                : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _menuItem(IconData icon, String title, VoidCallback onTap,
      {Color? color}) {
    return ListTile(
      leading: Icon(icon, color: color ?? AppColors.primary, size: 22),
      title: Text(title,
          style: TextStyle(
              color: color ?? Colors.black87, fontWeight: FontWeight.w500)),
      trailing:
          const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey),
      onTap: onTap,
    );
  }

  Widget _statCard(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)
          ],
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 6),
            Text(value,
                style: TextStyle(
                    color: color, fontSize: 20, fontWeight: FontWeight.bold)),
            Text(label,
                style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _readOnlyField(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(color: Colors.grey, fontSize: 11)),
                  const SizedBox(height: 2),
                  Text(value,
                      style:
                          const TextStyle(fontSize: 15, color: Colors.black87)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showLegal(BuildContext context, String title, String content) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(title),
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Text(content,
                style: const TextStyle(fontSize: 14, height: 1.7)),
          ),
        ),
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [AppColors.primary, Color(0xFFFFB300)]),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.delivery_dining,
                  color: Colors.white, size: 40),
            ),
            const SizedBox(height: 14),
            const Text("AZ Express",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text("Version 1.0.0",
                style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 12),
            Text(
              context.tr('about_app_text'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13, color: Colors.black87, height: 1.5),
            ),
            const SizedBox(height: 12),
            Text(context.tr('copyright'),
                style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.tr('close')))
        ],
      ),
    );
  }

  void _showLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(context.tr('logout')),
        content: Text(
          context.tr('logout_confirm'),
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(context.tr('cancel'))),
          ScaleButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange.shade800,
                foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(ctx);
              AuthService().logAuthEvent('logout', 'client');
              await FirebaseAuth.instance.signOut();
              try {
                await FirebaseAuth.instance.signInAnonymously();
              } catch (_) {}
              if (context.mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const ClientAuthPage()),
                  (route) => false,
                );
              }
            },
            child: Text(context.tr('logout')),
          ),
        ],
      ),
    );
  }

  void _showDeleteAccount(BuildContext context) {
    final passCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.warning_rounded, color: Colors.red, size: 22),
          SizedBox(width: 8),
          Text('Supprimer mon compte', style: TextStyle(fontSize: 16)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Cette action est irréversible. Toutes tes données seront supprimées.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            const Text('Confirme avec ton mot de passe :',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'Mot de passe',
                prefixIcon: Icon(Icons.lock_outline, size: 18),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () {
                passCtrl.dispose();
                Navigator.pop(ctx);
              },
              child: const Text('Annuler')),
          ScaleButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              final password = passCtrl.text.trim();
              if (password.isEmpty) return;
              Navigator.pop(ctx);
              await _deleteAccount(context, password);
              passCtrl.dispose();
            },
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteAccount(BuildContext context, String password) async {
    try {
      if (FirebaseAuth.instance.currentUser == null) return;

      // Ré-authentification + suppression Firestore/Auth déléguées au flux
      // unique partagé par les 9 rôles (voir AccountDeletionService) —
      // comportement inchangé pour le client, seulement extrait pour être
      // réutilisable.
      await AccountDeletionService.deleteClientAccountNow(password: password);

      // Reconnecter en anonyme
      await FirebaseAuth.instance.signInAnonymously();

      if (!context.mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ClientAuthPage()),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      if (!context.mounted) return;
      String msg = 'Erreur lors de la suppression';
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
        msg = 'Mot de passe incorrect';
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: Colors.red,
      ));
    } on StateError catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.message),
        backgroundColor: Colors.red,
      ));
    }
  }

  static const String _privacy = """POLITIQUE DE CONFIDENTIALITÉ — AZ Express

Dernière mise à jour : 2026

AZ Express est une application de livraison permettant aux utilisateurs de commander des courses et de se faire livrer des produits.

1. DONNÉES COLLECTÉES

Nous collectons les informations suivantes :
• Nom et prénom
• Numéro de téléphone
• Adresse de livraison
• Localisation GPS
• Informations liées aux commandes

2. UTILISATION DES DONNÉES

Les données sont utilisées pour :
• Traiter et livrer les commandes
• Mettre en relation clients et livreurs
• Améliorer l'application
• Assurer la sécurité des utilisateurs

3. PARTAGE DES DONNÉES

Nous pouvons partager certaines informations avec :
• Les livreurs (pour effectuer la livraison)
• Nos services techniques (Firebase, etc.)

Nous ne vendons aucune donnée personnelle.

4. SÉCURITÉ

Nous mettons en place des mesures de sécurité pour protéger vos informations personnelles.

5. VOS DROITS

Vous pouvez :
• Modifier vos informations (section "Mon profil")
• Demander la suppression de votre compte

6. CONTACT

Pour toute question :
Email : znm0905@gmail.com""";

  static const String _terms = """CONDITIONS D'UTILISATION — AZ Express

En utilisant AZ Express, vous acceptez les conditions suivantes :

1. UTILISATION DE L'APPLICATION

L'utilisateur s'engage à :
• Fournir des informations correctes
• Ne pas faire de fausses commandes

2. COMPTES

• Chaque utilisateur est responsable de son compte
• AZ Express peut suspendre un compte en cas d'abus

3. RESPONSABILITÉ

AZ Express agit comme intermédiaire entre client et livreur. Nous ne sommes pas responsables des marchandises transportées.

4. MODIFICATIONS

Nous pouvons modifier ces conditions à tout moment. Les utilisateurs seront informés des changements importants.""";

  static const String _delivery = """POLITIQUE DE LIVRAISON — AZ Express

ZONES DESSERVIES
Abengourou et ses environs.

TARIFICATION

• 1 à 3,5 km    →  500 FCFA
• 3,5 à 4,5 km  →  600 FCFA
• 5 km          →  800 FCFA
• Plus de 5 km  →  1 000 FCFA
• À partir de 7 km  →  1 500 à 2 000 FCFA

DÉLAIS

Les livraisons sont effectuées selon la disponibilité des livreurs. Aucun délai fixe garanti.

ANNULATION

Une commande peut être annulée avant sa prise en charge par un livreur. Après assignation, l'annulation peut entraîner des frais.""";

  static const String _payment = r"""POLITIQUE DE PAIEMENT — AZ Express

MOYENS DE PAIEMENT

• Paiement via Mobile Money (Orange Money, MTN MoMo…)
• Paiement en espèces à la livraison

SÉCURITÉ

Les paiements électroniques sont traités de manière sécurisée. AZ Express ne conserve aucune donnée bancaire.

REMBOURSEMENTS

Aucun remboursement n'est effectué après la livraison, sauf en cas d'erreur avérée de notre part.

LITIGES

En cas de problème avec votre paiement, contactez notre support :
Email : znm0905@gmail.com""";
}

// ─────────────────────────────────────────────────────────────────────────────
// CHAMP SÉCURITÉ (réutilisé dans les dialogues)
// ─────────────────────────────────────────────────────────────────────────────

class _SecField extends StatefulWidget {
  final TextEditingController ctrl;
  final String label;
  final bool isEmail;
  final bool isPhone;
  const _SecField({
    required this.ctrl,
    required this.label,
    this.isEmail = false,
    this.isPhone = false,
  });

  @override
  State<_SecField> createState() => _SecFieldState();
}

class _SecFieldState extends State<_SecField> {
  bool _obscure = true;

  bool get _isPassword => !widget.isEmail && !widget.isPhone;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.ctrl,
      obscureText: _isPassword && _obscure,
      keyboardType: widget.isEmail
          ? TextInputType.emailAddress
          : widget.isPhone
              ? TextInputType.phone
              : TextInputType.text,
      decoration: InputDecoration(
        labelText: widget.label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        isDense: true,
        suffixIcon: _isPassword
            ? IconButton(
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
                    size: 18),
                onPressed: () => setState(() => _obscure = !_obscure),
              )
            : null,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WIDGET HISTORIQUE COMMANDES
// ─────────────────────────────────────────────────────────────────────────────

class _RecentOrders extends StatelessWidget {
  final String uid;
  const _RecentOrders({required this.uid});

  Color _statusColor(String status) {
    switch (status) {
      case 'delivered':
        return Colors.green;
      case 'cancelled':
        return Colors.red;
      case 'pending':
        return Colors.orange;
      case 'accepted':
      case 'picked_up':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'delivered':
        return 'Livré';
      case 'cancelled':
        return 'Annulé';
      case 'pending':
        return 'En attente';
      case 'assigned':
        return 'Assigné';
      case 'accepted':
        return 'En route';
      case 'picked_up':
        return 'En livraison';
      default:
        return status;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'delivered':
        return Icons.check_circle_rounded;
      case 'cancelled':
        return Icons.cancel_rounded;
      case 'pending':
        return Icons.hourglass_top_rounded;
      default:
        return Icons.local_shipping_rounded;
    }
  }

  String _formatDate(Timestamp? ts) {
    if (ts == null) return '—';
    final d = ts.toDate();
    return '${d.day}/${d.month}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('orders')
          .where('clientId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(6)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Impossible de charger vos dernières commandes.',
                style: TextStyle(color: Colors.grey)),
          );
        }
        if (!snap.hasData) {
          // Master Prompt 124 — squelette shimmer plutôt qu'un spinner nu.
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: AppColors.card,
              borderRadius: AppRadius.cardR,
              boxShadow: AppShadow.card,
            ),
            child: Column(
              children: List.generate(
                  3,
                  (i) => Padding(
                        padding: EdgeInsets.only(bottom: i == 2 ? 0 : 12),
                        child: const AzShimmerRow(iconSize: 42, maxWidth: 180),
                      )),
            ),
          );
        }

        final docs = snap.data!.docs;

        if (docs.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: AppColors.card,
              borderRadius: AppRadius.cardR,
              boxShadow: AppShadow.card,
            ),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.receipt_long_rounded,
                      size: 40, color: Colors.grey.shade300),
                  const SizedBox(height: 8),
                  Text('Aucune commande',
                      style: GoogleFonts.urbanist(
                          color: Colors.grey, fontSize: 13)),
                ],
              ),
            ),
          );
        }

        return Container(
          decoration: const BoxDecoration(
            color: AppColors.card,
            borderRadius: AppRadius.cardR,
            boxShadow: AppShadow.card,
          ),
          child: Column(
            children: docs.asMap().entries.map((entry) {
              final i = entry.key;
              final doc = entry.value;
              final data = doc.data() as Map<String, dynamic>;
              final status = data['status'] as String? ?? 'pending';
              final desc = data['description'] as String? ?? '—';
              final budget = (data['budget'] as num? ?? 0).toInt();
              final ts = data['createdAt'] as Timestamp?;
              final color = _statusColor(status);
              final rating = data['rating'] as int?;

              return FadeSlideIn(
                index: i,
                child: Column(
                  children: [
                    if (i > 0) const Divider(height: 1, indent: 16),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      leading: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child:
                            Icon(_statusIcon(status), color: color, size: 20),
                      ),
                      title: Text(
                        desc,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.urbanist(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.text,
                        ),
                      ),
                      subtitle: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _statusLabel(status),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: color,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _formatDate(ts),
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade400),
                          ),
                          if (rating != null) ...[
                            const SizedBox(width: 6),
                            ...List.generate(
                              5,
                              (j) => Icon(
                                j < rating
                                    ? Icons.star_rounded
                                    : Icons.star_outline_rounded,
                                color: Colors.amber,
                                size: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                      trailing: Text(
                        '$budget F',
                        style: GoogleFonts.urbanist(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: const Color(0xFFFF5A3C),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}
