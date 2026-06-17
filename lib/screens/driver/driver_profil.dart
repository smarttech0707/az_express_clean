import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../services/auth_service.dart';

class DriverProfil extends StatefulWidget {
  final String driverId;
  final String driverName;

  const DriverProfil({
    super.key,
    required this.driverId,
    required this.driverName,
  });

  @override
  State<DriverProfil> createState() => _DriverProfilState();
}

class _DriverProfilState extends State<DriverProfil> {
  final _emailCtrl = TextEditingController();
  String? _createdAt;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('livreurs')
          .doc(widget.driverId)
          .get();
      if (doc.exists && mounted) {
        final ts = doc.data()?['createdAt'];
        String? created;
        if (ts is Timestamp) {
          final d = ts.toDate();
          created =
              '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
        }
        setState(() {
          _emailCtrl.text = doc.data()?['email'] as String? ?? '';
          _createdAt = created;
        });
      }
    } catch (_) {}
  }

  // ── Dialogues sécurité ───────────────────────────────────────────────────

  void _showChangePassword() {
    final curCtrl  = TextEditingController();
    final newCtrl  = TextEditingController();
    final confCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        bool loading = false;
        return StatefulBuilder(
          builder: (ctx, setS) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Text('Changer le mot de passe'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                _SecField(ctrl: curCtrl,  label: 'Mot de passe actuel'),
                const SizedBox(height: 10),
                _SecField(ctrl: newCtrl,  label: 'Nouveau mot de passe'),
                const SizedBox(height: 10),
                _SecField(ctrl: confCtrl, label: 'Confirmer'),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Annuler')),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF7A1A)),
                  onPressed: loading
                      ? null
                      : () async {
                          final err =
                              AuthService.validatePassword(newCtrl.text);
                          if (err != null) {
                            if (ctx.mounted) { ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                content: Text(err),
                                backgroundColor: Colors.orange)); }
                            return;
                          }
                          if (newCtrl.text != confCtrl.text) {
                            if (ctx.mounted) { ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Les mots de passe ne correspondent pas'),
                                    backgroundColor: Colors.red)); }
                            return;
                          }
                          setS(() => loading = true);
                          try {
                            await AuthService().updatePassword(
                                currentPassword: curCtrl.text,
                                newPassword: newCtrl.text);
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Mot de passe mis à jour'),
                                      backgroundColor: Colors.green));
                            }
                          } catch (e) {
                            setS(() => loading = false);
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                  content: Text('Erreur : $e'),
                                  backgroundColor: Colors.red));
                            }
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
    final passCtrl  = TextEditingController();
    final emailCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        bool loading = false;
        return StatefulBuilder(
          builder: (ctx, setS) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Text('Modifier l\'email'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                _SecField(ctrl: passCtrl,  label: 'Mot de passe actuel'),
                const SizedBox(height: 10),
                _SecField(ctrl: emailCtrl, label: 'Nouvel email', isEmail: true),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Annuler')),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF7A1A)),
                  onPressed: loading
                      ? null
                      : () async {
                          if (!AuthService.isValidEmail(emailCtrl.text)) {
                            if (ctx.mounted) { ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                    content: Text('Email invalide'),
                                    backgroundColor: Colors.orange)); }
                            return;
                          }
                          setS(() => loading = true);
                          try {
                            await AuthService().updateEmail(
                                currentPassword: passCtrl.text,
                                newEmail: emailCtrl.text,
                                collection: 'livreurs');
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Un lien de vérification a été envoyé à votre nouvel email'),
                                      backgroundColor: Colors.green,
                                      duration: Duration(seconds: 4)));
                            }
                          } catch (e) {
                            setS(() => loading = false);
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                  content: Text('Erreur : $e'),
                                  backgroundColor: Colors.red));
                            }
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
    final passCtrl  = TextEditingController();
    final phoneCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        bool loading = false;
        return StatefulBuilder(
          builder: (ctx, setS) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Text('Modifier le téléphone'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                _SecField(ctrl: passCtrl,  label: 'Mot de passe actuel'),
                const SizedBox(height: 10),
                _SecField(ctrl: phoneCtrl, label: 'Nouveau numéro', isPhone: true),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Annuler')),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF7A1A)),
                  onPressed: loading
                      ? null
                      : () async {
                          if (!AuthService.isValidPhone(phoneCtrl.text)) {
                            if (ctx.mounted) { ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                    content: Text('Numéro invalide'),
                                    backgroundColor: Colors.orange)); }
                            return;
                          }
                          setS(() => loading = true);
                          try {
                            await AuthService().updatePhone(
                                currentPassword: passCtrl.text,
                                newPhone: phoneCtrl.text,
                                collection: 'livreurs');
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Numéro mis à jour'),
                                      backgroundColor: Colors.green));
                            }
                          } catch (e) {
                            setS(() => loading = false);
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                  content: Text('Erreur : $e'),
                                  backgroundColor: Colors.red));
                            }
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

  void _showLegal(BuildContext context, String title, String content) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(title, style: const TextStyle(fontSize: 15)),
            backgroundColor: const Color(0xFFFF7A1A),
            foregroundColor: Colors.white,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Text(content,
                style: const TextStyle(fontSize: 14, height: 1.8)),
          ),
        ),
      ),
    );
  }

  void _showSignOutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("Se déconnecter"),
        content: const Text(
            "Vous serez déconnecté de l'application livreur."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Annuler")),
          ScaleButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF7A1A),
                foregroundColor: Colors.white),
            onPressed: () async {
              await FirebaseFirestore.instance
                  .collection("livreurs")
                  .doc(widget.driverId)
                  .update({"isOnline": false});
              await FirebaseAuth.instance.signOut();
              if (ctx.mounted) {
                Navigator.of(ctx).popUntil((route) => route.isFirst);
              }
            },
            child: const Text("Se déconnecter"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection("livreurs")
            .doc(widget.driverId)
            .snapshots(),
        builder: (context, snap) {
          final data =
              snap.hasData && snap.data!.exists
                  ? snap.data!.data() as Map<String, dynamic>
                  : <String, dynamic>{};
          final photoUrl = data["photoUrl"] as String?;
          final wallet = data["wallet"] ?? 0;
          final deliveries = data["deliveries"] ?? 0;
          final rating = data["rating"] ?? 0.0;

          return CustomScrollView(
            slivers: [
              // ── APP BAR ───────────────────────────────────
              SliverAppBar(
                expandedHeight: 220,
                pinned: true,
                backgroundColor: const Color(0xFFFF7A1A),
                foregroundColor: Colors.white,
                flexibleSpace: FlexibleSpaceBar(
                  background: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFFE65100), Color(0xFFFF7A1A)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: SafeArea(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(height: 30),
                          CircleAvatar(
                            radius: 44,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.25),
                            backgroundImage: photoUrl != null
                                ? NetworkImage(photoUrl)
                                : null,
                            child: photoUrl == null
                                ? const Icon(Icons.person,
                                    color: Colors.white, size: 44)
                                : null,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            widget.driverName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold),
                          ),
                          Container(
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text("Livreur AZ Express",
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                title: const Text("Mon profil"),
                centerTitle: true,
              ),

              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── STATS ────────────────────────────────
                      Row(
                        children: [
                          _statCard("Solde", "$wallet FCFA",
                              Icons.account_balance_wallet,
                              const Color(0xFFFF7A1A)),
                          const SizedBox(width: 10),
                          _statCard("Livraisons", "$deliveries",
                              Icons.delivery_dining, Colors.green),
                          const SizedBox(width: 10),
                          _statCard(
                              "Note", "$rating ★", Icons.star, Colors.amber),
                        ],
                      ),

                      const SizedBox(height: 24),

                      // ── INFORMATIONS ──────────────────────────
                      if (_emailCtrl.text.isNotEmpty || _createdAt != null) ...[
                        _sectionTitle("Informations du compte"),
                        const SizedBox(height: 10),
                        _infoCard([
                          if (_emailCtrl.text.isNotEmpty)
                            _readOnlyField(
                                'Email', _emailCtrl.text, Icons.email_outlined),
                          if (_emailCtrl.text.isNotEmpty && _createdAt != null)
                            const Divider(height: 1),
                          if (_createdAt != null)
                            _readOnlyField('Membre depuis', _createdAt!,
                                Icons.calendar_today_outlined),
                        ]),
                        const SizedBox(height: 24),
                      ],

                      // ── SÉCURITÉ ─────────────────────────────
                      _sectionTitle("Sécurité du compte"),
                      const SizedBox(height: 10),
                      _infoCard([
                        _menuItem(
                          context,
                          Icons.lock_outline,
                          "Modifier le mot de passe",
                          "Changer votre mot de passe actuel",
                          _showChangePassword,
                        ),
                        const Divider(height: 1),
                        _menuItem(
                          context,
                          Icons.email_outlined,
                          "Modifier l'email",
                          "Mettre à jour votre adresse email",
                          _showChangeEmail,
                        ),
                        const Divider(height: 1),
                        _menuItem(
                          context,
                          Icons.phone_android_outlined,
                          "Modifier le téléphone",
                          "Mettre à jour votre numéro",
                          _showChangePhone,
                        ),
                      ]),

                      const SizedBox(height: 24),

                      // ── LÉGAL ────────────────────────────────
                      _sectionTitle("Règles & Rémunération"),
                      const SizedBox(height: 10),
                      _infoCard([
                        _menuItem(
                          context,
                          Icons.gavel_outlined,
                          "Conditions livreurs",
                          "Vos droits et obligations",
                          () => _showLegal(context, "Conditions livreurs",
                              _termsDriver),
                        ),
                        const Divider(height: 1),
                        _menuItem(
                          context,
                          Icons.payments_outlined,
                          "Rémunération",
                          "Comment sont calculés vos gains",
                          () => _showLegal(context,
                              "Rémunération des livreurs", _remuneration),
                        ),
                      ]),

                      const SizedBox(height: 16),

                      // ── À PROPOS ─────────────────────────────
                      _infoCard([
                        _menuItem(
                          context,
                          Icons.info_outline,
                          "À propos de AZ Express",
                          "Version 1.0.0",
                          () => _showAbout(context),
                        ),
                      ]),

                      const SizedBox(height: 16),

                      // ── DÉCONNEXION ──────────────────────────
                      _infoCard([
                        _menuItem(
                          context,
                          Icons.logout,
                          "Se déconnecter",
                          "Quitter l'application",
                          () => _showSignOutDialog(context),
                          color: Colors.red,
                        ),
                      ]),

                      const SizedBox(height: 30),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String t) => Text(t,
      style: const TextStyle(
          fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey));

  Widget _infoCard(List<Widget> children) => Container(
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
                      style:
                          const TextStyle(color: Colors.grey, fontSize: 11)),
                  const SizedBox(height: 2),
                  Text(value,
                      style: const TextStyle(
                          fontSize: 15, color: Colors.black87)),
                ],
              ),
            ),
          ),
        ],
      ),
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
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 6),
            Text(value,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.bold)),
            Text(label,
                style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _menuItem(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap, {
    Color? color,
  }) {
    return ListTile(
      leading:
          Icon(icon, color: color ?? const Color(0xFFFF7A1A), size: 22),
      title: Text(title,
          style: TextStyle(
              color: color ?? Colors.black87,
              fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle,
          style: const TextStyle(fontSize: 11, color: Colors.grey)),
      trailing:
          const Icon(Icons.arrow_forward_ios, size: 13, color: Colors.grey),
      onTap: onTap,
    );
  }

  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFFE65100), Color(0xFFFF7A1A)]),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.delivery_dining,
                  color: Colors.white, size: 40),
            ),
            const SizedBox(height: 14),
            const Text("AZ Express",
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text("Version 1.0.0",
                style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 12),
            const Text(
              "Application de livraison rapide à Abengourou.\n\n"
              "Support livreurs : znm0905@gmail.com",
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, color: Colors.black87, height: 1.5),
            ),
            const SizedBox(height: 12),
            const Text("© 2026 AZ Express — Tous droits réservés",
                style: TextStyle(color: Colors.grey, fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Fermer"))
        ],
      ),
    );
  }

  static const String _termsDriver =
      """CONDITIONS D'UTILISATION DES LIVREURS — AZ Express

Dernière mise à jour : 2026

Les présentes conditions définissent les règles applicables aux livreurs utilisant l'application AZ Express.

1. INSCRIPTION

Le livreur doit :
• Fournir des informations exactes
• Avoir un numéro de téléphone valide
• Disposer d'un moyen de déplacement (moto, vélo, voiture)

2. ACCEPTATION DES COURSES

• Le livreur est libre d'accepter ou refuser une course
• Une fois acceptée, il doit effectuer la livraison correctement

3. OBLIGATIONS DU LIVREUR

Le livreur s'engage à :
• Être ponctuel
• Respecter les clients
• Ne pas annuler abusivement les commandes
• Livrer les produits en bon état

4. COMPORTEMENT INTERDIT

Il est interdit de :
• Voler ou détourner une commande
• Demander un paiement supplémentaire non autorisé
• Fournir de fausses informations

5. PAIEMENT DES LIVREURS

• Les gains sont calculés selon les livraisons effectuées
• Le paiement peut se faire selon les modalités définies par AZ Express

6. SUSPENSION DU COMPTE

AZ Express peut suspendre un livreur en cas de :
• Mauvais comportement
• Fraude
• Non-respect des règles

7. RESPONSABILITÉ

Le livreur est responsable de ses actions pendant les livraisons.""";

  static const String _remuneration =
      """RÉMUNÉRATION DES LIVREURS — AZ Express

PRINCIPE

Le livreur reçoit une commission sur chaque livraison effectuée avec succès.

MOYENS DE PAIEMENT

• En espèces (remise directe)
• Via Mobile Money (Orange Money, MTN MoMo…)

COMMISSION

AZ Express peut prélever une commission sur chaque course. Le montant net perçu par le livreur est affiché dans son portefeuille.

CALENDRIER DE PAIEMENT

Les paiements sont effectués selon un calendrier défini :
• Journalier (selon activité)
• Hebdomadaire
• Sur demande du livreur

RETARDS

En cas de retard de paiement, le livreur peut contacter le support :
Email : znm0905@gmail.com

SUIVI DES GAINS

Consultez votre solde et l'historique de vos livraisons en temps réel dans la section "Portefeuille" de l'application.""";
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
