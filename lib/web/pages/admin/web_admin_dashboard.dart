import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../web_theme.dart';
import '../../admin_auth_service.dart';
import '../../../event/screens/admin_event_screen.dart';
import '../../../widgets/stream_error_state.dart';
import 'admin_office_shell.dart';
import 'ai_tool_executions_panel.dart';
import 'web_admin_employees_page.dart';

/// Message d'erreur lisible pour un flux Firestore en échec, sans jamais
/// présenter un refus de permission comme une liste vide (correction P0,
/// audit admin Android/Web : un sous-admin ou un compte dont le rôle a
/// changé voyait silencieusement "Aucune entrée" au lieu d'un vrai message).
String firestoreStreamErrorMessage(Object? error) {
  if (error is FirebaseException) {
    switch (error.code) {
      case 'permission-denied':
        return 'Accès refusé par les règles de sécurité Firestore pour '
            'votre compte. Contactez un administrateur principal si cela '
            'ne devrait pas être le cas.';
      case 'unavailable':
      case 'deadline-exceeded':
      case 'network-request-failed':
        return 'Connexion au serveur indisponible. Vérifiez votre connexion '
            'puis réessayez.';
    }
  }
  return 'Impossible de charger ces données pour le moment.';
}

IconData firestoreStreamErrorIcon(Object? error) {
  if (error is FirebaseException && error.code == 'permission-denied') {
    return Icons.lock_outline_rounded;
  }
  return Icons.wifi_off_rounded;
}

class WebAdminDashboard extends StatefulWidget {
  const WebAdminDashboard({super.key});

  @override
  State<WebAdminDashboard> createState() => _WebAdminDashboardState();
}

class _WebAdminDashboardState extends State<WebAdminDashboard> {
  String _section = 'dashboard';

  @override
  void initState() {
    super.initState();
    // Vérifier auth au démarrage
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!AdminAuthService.instance.isAdmin) {
        context.go('/admin/login');
      }
    });
  }

  Future<void> _logout() async {
    await AdminAuthService.instance.signOut();
    if (mounted) context.go('/admin/login');
  }

  @override
  Widget build(BuildContext context) {
    return AdminOfficeShell(
      selectedId: _section,
      onSelect: (id) => setState(() => _section = id),
      onLogout: _logout,
      body: _sectionBody(_section),
    );
  }

  Widget _sectionBody(String id) {
    switch (id) {
      case 'dashboard':
        return const _DashboardSection();
      case 'orders':
        return const _OrdersSection();
      case 'requests':
        return const _RequestsSection();
      case 'services':
        return const _ServicesSection();
      case 'security':
        return const _SecuritySection();
      case 'drivers':
        return const AdminSectionUnavailable(title: 'Livreurs et flottes');
      case 'partners':
        return const AdminSectionUnavailable(title: 'Partenaires');
      case 'finance':
        return const AdminSectionUnavailable(title: 'Finances');
      case 'employees':
        return const WebAdminEmployeesPage();
      default:
        return const _DashboardSection();
    }
  }
}

// ── Section : Tableau de bord ───────────────────────────────────────────────
class _DashboardSection extends StatefulWidget {
  const _DashboardSection();

  @override
  State<_DashboardSection> createState() => _DashboardSectionState();
}

class _DashboardSectionState extends State<_DashboardSection> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminSectionSubNav(
          labels: const ['Vue d\'ensemble', 'Exécutions IA'],
          icons: const [Icons.dashboard_rounded, Icons.smart_toy_rounded],
          selected: _tab,
          onSelect: (i) => setState(() => _tab = i),
        ),
        Expanded(
          child: _tab == 0
              ? const _OverviewPane()
              : const AiToolExecutionsPanel(),
        ),
      ],
    );
  }
}

class _OverviewPane extends StatelessWidget {
  const _OverviewPane();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Chiffres en direct',
              style: GoogleFonts.inter(
                  fontSize: 15, fontWeight: FontWeight.w700, color: kText)),
          const SizedBox(height: 4),
          Text(
            'Comptages réels lus depuis Firestore — aucune donnée estimée '
            'ou inventée.',
            style: GoogleFonts.inter(fontSize: 12, color: kTextMuted),
          ),
          const SizedBox(height: 16),
          _StatsBar(),
        ],
      ),
    );
  }
}

// ── Section : Commandes ─────────────────────────────────────────────────────
class _OrdersSection extends StatelessWidget {
  const _OrdersSection();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminSectionNote(
          'Seules les alertes SOS sont disponibles ici pour le moment. '
          'Carte live, zones géographiques et anti-fraude seront ajoutées '
          'dans une phase dédiée.',
        ),
        Expanded(child: _SosList()),
      ],
    );
  }
}

// ── Section : Centre de demandes ────────────────────────────────────────────
class _RequestsSection extends StatefulWidget {
  const _RequestsSection();

  @override
  State<_RequestsSection> createState() => _RequestsSectionState();
}

class _RequestsSectionState extends State<_RequestsSection> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminSectionSubNav(
          labels: const ['Livreurs', 'Commerçants', 'Messages'],
          icons: const [
            Icons.delivery_dining_rounded,
            Icons.storefront_rounded,
            Icons.mail_rounded,
          ],
          selected: _tab,
          onSelect: (i) => setState(() => _tab = i),
        ),
        Expanded(
          child: switch (_tab) {
            0 => const _ApplicationsList(
                collection: 'driver_applications', type: 'driver'),
            1 => const _ApplicationsList(
                collection: 'partner_applications', type: 'partner'),
            _ => const _ApplicationsList(
                collection: 'contact_messages', type: 'message'),
          },
        ),
      ],
    );
  }
}

// ── Section : Services ──────────────────────────────────────────────────────
// Cause réelle du manque de contraste observé dans Événementiel : le thème
// Web global (`lib/web/web_app.dart`) est un `ColorScheme.dark(surface: kNavy)`
// où `kNavy` est en réalité un alias clair (`kNavy = kBg`, gris très clair).
// Les widgets du Bureau écrits pour cette mission (sidebar, stats, etc.)
// n'en souffrent pas : ils fixent leurs couleurs explicitement (`kText`,
// `kTextMuted`...). Mais `AdminEventScreen` (écran PARTAGÉ avec l'app
// Android, ne pas modifier) s'appuie sur les couleurs par défaut dérivées de
// ce ColorScheme — `onSurface`/`onSurfaceVariant` d'un schéma "dark" sont
// claires, posées ici sur un fond réellement clair : texte quasi blanc sur
// quasi blanc. Le thème clair complet ci-dessous corrige ce mélange,
// uniquement pour cette intégration Bureau Web (ni l'app Android, ni les
// autres pages Web, qui ne passent pas par ce widget, ne sont affectées).
class _ServicesSection extends StatelessWidget {
  const _ServicesSection();

  static const _titleColor = Color(0xFF202124);
  static const _subtitleColor = Color(0xFF333333);
  static const _secondaryColor = Color(0xFF666666);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AdminSectionNote(
          'Seul l\'événementiel est disponible ici pour le moment. '
          'Tricycle & Taxi et Artisans & Commerces seront ajoutés dans une '
          'phase dédiée.',
        ),
        Expanded(
          child: Theme(
            data: ThemeData(
              useMaterial3: true,
              brightness: Brightness.light,
              scaffoldBackgroundColor: kBg,
              cardColor: kCard,
              dividerColor: kDivider,
              colorScheme: const ColorScheme.light(
                primary: kOrange,
                onPrimary: Colors.white,
                secondary: kBlue,
                onSecondary: Colors.white,
                surface: kCard,
                onSurface: _titleColor,
                onSurfaceVariant: _secondaryColor,
                error: Colors.red,
                onError: Colors.white,
              ),
              // Barre orange foncée — contraste blanc testé (≥4,5:1) pour
              // `AzTabBar`, le composant d'onglets partagé avec les écrans
              // d'administration Android : ses libellés actif/inactif sont
              // blancs par conception (pas pilotés par le thème), donc la
              // vraie correction est de leur redonner le fond orange foncé
              // prévu, plutôt que d'essayer de les foncer un par un.
              appBarTheme: const AppBarTheme(
                backgroundColor: kOrangeD,
                foregroundColor: Colors.white,
                elevation: 0,
                iconTheme: IconThemeData(color: Colors.white),
                titleTextStyle: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700),
              ),
              textTheme: GoogleFonts.interTextTheme().copyWith(
                titleLarge: GoogleFonts.inter(
                    color: _titleColor, fontWeight: FontWeight.w700),
                titleMedium: GoogleFonts.inter(
                    color: _titleColor, fontWeight: FontWeight.w600),
                titleSmall: GoogleFonts.inter(
                    color: _titleColor, fontWeight: FontWeight.w600),
                bodyLarge: GoogleFonts.inter(color: _subtitleColor),
                bodyMedium: GoogleFonts.inter(color: _subtitleColor),
                bodySmall: GoogleFonts.inter(color: _secondaryColor),
                labelLarge: GoogleFonts.inter(
                    color: _titleColor, fontWeight: FontWeight.w600),
                labelMedium: GoogleFonts.inter(color: _secondaryColor),
                labelSmall: GoogleFonts.inter(color: _secondaryColor),
              ),
            ),
            child: const AdminEventScreen(),
          ),
        ),
      ],
    );
  }
}

// ── Section : Sécurité et paramètres ────────────────────────────────────────
class _SecuritySection extends StatelessWidget {
  const _SecuritySection();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminSectionNote(
          'Seules les demandes de réinitialisation de mot de passe sont '
          'disponibles ici. Journal de sécurité et gestion des employés '
          'seront ajoutés dans une phase dédiée.',
        ),
        Expanded(child: _PasswordResetList()),
      ],
    );
  }
}

// ── Stats bar ─────────────────────────────────────────────────────────────────
// Grille responsive (et non une simple Row) : une Row de 5 pastilles à
// largeur naturelle déborde horizontalement dès que la fenêtre est plus
// étroite que la somme de leurs largeurs (observé sur écran réel en
// résolution tablette/petit bureau). Ici, chaque pastille reçoit une largeur
// calculée selon le nombre de colonnes de la résolution courante, et un Wrap
// passe à la ligne suivante sans jamais dépasser la largeur disponible.
class _StatsBar extends StatelessWidget {
  static const _chips = <Widget>[
    _StatChip('driver_applications', 'Livreurs', kOrange),
    _StatChip('partner_applications', 'Commerçants', kBlue),
    _StatChip('contact_messages', 'Messages', kSuccess),
    _StatChip('sos_alerts', 'SOS actifs', Colors.red, filter: 'active'),
    _StatChip('event_providers', 'Événementiel', Color(0xFF8E24AA),
        filter: 'pending'),
  ];

  @override
  Widget build(BuildContext context) {
    const gap = 12.0;
    return Container(
      color: kCard,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: LayoutBuilder(
        builder: (context, box) {
          final cols = box.maxWidth >= 1024
              ? _chips.length
              : (box.maxWidth >= 600 ? 2 : 1);
          final itemWidth = (box.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final chip in _chips)
                SizedBox(width: itemWidth, child: chip),
            ],
          );
        },
      ),
    );
  }
}

class _StatChip extends StatefulWidget {
  final String collection;
  final String label;
  final Color color;
  final String filter;
  const _StatChip(this.collection, this.label, this.color,
      {this.filter = 'unread'});

  @override
  State<_StatChip> createState() => _StatChipState();
}

class _StatChipState extends State<_StatChip> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(widget.collection)
          .where('status', isEqualTo: widget.filter)
          .snapshots(),
      builder: (_, snap) {
        if (snap.hasError) {
          return Tooltip(
            message: firestoreStreamErrorMessage(snap.error),
            child: GestureDetector(
              onTap: () => setState(() {}),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.error_outline_rounded,
                      color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  Text(widget.label,
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          color: Colors.red,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          );
        }
        final count = snap.data?.docs.length ?? 0;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: count > 0 ? widget.color.withValues(alpha: 0.1) : kBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color:
                    count > 0 ? widget.color.withValues(alpha: 0.3) : kDivider),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: count > 0
                    ? widget.color
                    : kTextMuted.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              child: Center(
                  child: Text('$count',
                      style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Colors.white))),
            ),
            const SizedBox(width: 8),
            Text(widget.label,
                style: GoogleFonts.inter(
                    fontSize: 13,
                    color: count > 0 ? widget.color : kTextMuted,
                    fontWeight: FontWeight.w600)),
          ]),
        );
      },
    );
  }
}

// ── Applications list ─────────────────────────────────────────────────────────
class _ApplicationsList extends StatefulWidget {
  final String collection;
  final String type;
  const _ApplicationsList({required this.collection, required this.type});

  @override
  State<_ApplicationsList> createState() => _ApplicationsListState();
}

class _ApplicationsListState extends State<_ApplicationsList> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(widget.collection)
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (_, snap) {
        if (snap.hasError) {
          return StreamErrorState(
            message: firestoreStreamErrorMessage(snap.error),
            icon: firestoreStreamErrorIcon(snap.error),
            onRetry: () => setState(() {}),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: kOrange));
        }
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return Center(
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.inbox_rounded,
                  size: 56, color: kTextMuted.withValues(alpha: 0.4)),
              const SizedBox(height: 12),
              Text('Aucune entrée pour le moment.',
                  style: GoogleFonts.inter(fontSize: 15, color: kTextMuted)),
            ]),
          );
        }
        final docs = snap.data!.docs;
        return ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: docs.length,
          itemBuilder: (_, i) => _EntryCard(
            doc: docs[i],
            collection: widget.collection,
            type: widget.type,
          ),
        );
      },
    );
  }
}

// ── Entry card ────────────────────────────────────────────────────────────────
class _EntryCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  final String collection;
  final String type;
  const _EntryCard(
      {required this.doc, required this.collection, required this.type});

  Future<void> _markAs(String status) async {
    await FirebaseFirestore.instance
        .collection(collection)
        .doc(doc.id)
        .update({'status': status});
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Confirmer',
            style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        content: Text('Supprimer définitivement cette entrée ?',
            style: GoogleFonts.inter()),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child:
                  const Text('Supprimer', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) {
      await FirebaseFirestore.instance
          .collection(collection)
          .doc(doc.id)
          .delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final status = data['status'] as String? ?? 'unread';
    final ts = data['createdAt'] as Timestamp?;
    final date = ts != null
        ? '${ts.toDate().day.toString().padLeft(2, '0')}/${ts.toDate().month.toString().padLeft(2, '0')}/${ts.toDate().year}  ${ts.toDate().hour.toString().padLeft(2, '0')}h${ts.toDate().minute.toString().padLeft(2, '0')}'
        : '—';

    Color statusColor;
    String statusLabel;
    switch (status) {
      case 'treated':
        statusColor = kSuccess;
        statusLabel = 'Traité';
        break;
      case 'in_progress':
        statusColor = kBlue;
        statusLabel = 'En cours';
        break;
      default:
        statusColor = kOrange;
        statusLabel = 'Nouveau';
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color:
                status == 'unread' ? kOrange.withValues(alpha: 0.3) : kDivider),
        boxShadow: const [
          BoxShadow(
              color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2))
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_typeIcon(), color: statusColor, size: 20),
          ),
          title: Text(
            data['name'] ?? data['fullName'] ?? 'Sans nom',
            style: GoogleFonts.inter(
                fontSize: 15, fontWeight: FontWeight.w600, color: kText),
          ),
          subtitle: Text(date,
              style: GoogleFonts.inter(fontSize: 12, color: kTextMuted)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(statusLabel,
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      color: statusColor,
                      fontWeight: FontWeight.w700)),
            ),
            const Icon(Icons.expand_more_rounded, color: kTextMuted),
          ]),
          children: [
            // Détails
            _detailRows(data),
            const SizedBox(height: 12),
            // Actions
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (status != 'treated')
                  _ActionBtn(
                    icon: Icons.check_circle_rounded,
                    label: 'Marquer traité',
                    color: kSuccess,
                    onTap: () => _markAs('treated'),
                  ),
                if (status == 'unread')
                  _ActionBtn(
                    icon: Icons.timelapse_rounded,
                    label: 'En cours',
                    color: kBlue,
                    onTap: () => _markAs('in_progress'),
                  ),
                if (_phone(data) != null)
                  _ActionBtn(
                    icon: Icons.chat_bubble_rounded,
                    label: 'WhatsApp',
                    color: const Color(0xFF25D366),
                    onTap: () => launchUrl(Uri.parse(
                        'https://wa.me/${_phone(data)!.replaceAll(RegExp(r'[^0-9]'), '')}')),
                  ),
                if (_email(data) != null)
                  _ActionBtn(
                    icon: Icons.email_rounded,
                    label: 'Email',
                    color: kOrange,
                    onTap: () => launchUrl(Uri.parse('mailto:${_email(data)}')),
                  ),
                _ActionBtn(
                  icon: Icons.delete_outline_rounded,
                  label: 'Supprimer',
                  color: Colors.red,
                  onTap: () => _delete(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _typeIcon() {
    switch (type) {
      case 'driver':
        return Icons.delivery_dining_rounded;
      case 'partner':
        return Icons.storefront_rounded;
      default:
        return Icons.mail_rounded;
    }
  }

  String? _phone(Map<String, dynamic> d) =>
      d['phone'] as String? ?? d['whatsapp'] as String?;

  String? _email(Map<String, dynamic> d) =>
      (d['email'] as String?)?.isNotEmpty == true ? d['email'] as String : null;

  Widget _detailRows(Map<String, dynamic> data) {
    final rows = <(String, String?)>[];
    void add(String k, String? v) {
      if (v != null && v.isNotEmpty) rows.add((k, v));
    }

    add('Téléphone', _phone(data));
    add('Email', _email(data));
    add('Ville', data['city'] as String?);
    add('Vehicule', data['vehicle'] as String?);
    add('Type', data['businessType'] as String?);
    add('Activité', data['activity'] as String?);
    add('Sujet', data['subject'] as String?);
    add('Message', data['message'] as String?);
    add('Description', data['description'] as String?);

    if (rows.isEmpty) {
      return Text('Aucun détail supplémentaire.',
          style: GoogleFonts.inter(fontSize: 13, color: kTextMuted));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows
          .map((r) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 100,
                        child: Text(r.$1,
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                color: kTextMuted,
                                fontWeight: FontWeight.w600)),
                      ),
                      Expanded(
                          child: Text(r.$2!,
                              style: GoogleFonts.inter(
                                  fontSize: 13, color: kText, height: 1.5))),
                    ]),
              ))
          .toList(),
    );
  }
}

// ── Password reset list ───────────────────────────────────────────────────────
class _PasswordResetList extends StatefulWidget {
  const _PasswordResetList();

  @override
  State<_PasswordResetList> createState() => _PasswordResetListState();
}

class _PasswordResetListState extends State<_PasswordResetList> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('password_reset_requests')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (_, snap) {
        if (snap.hasError) {
          return StreamErrorState(
            message: firestoreStreamErrorMessage(snap.error),
            icon: firestoreStreamErrorIcon(snap.error),
            onRetry: () => setState(() {}),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: kOrange));
        }
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return Center(
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.lock_open_rounded,
                  size: 56, color: kTextMuted.withValues(alpha: 0.4)),
              const SizedBox(height: 12),
              Text('Aucune demande de réinitialisation.',
                  style: GoogleFonts.inter(fontSize: 15, color: kTextMuted)),
            ]),
          );
        }

        return Column(
          children: [
            // Bandeau d'instructions
            Container(
              margin: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF9C27B0).withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFF9C27B0).withValues(alpha: 0.2)),
              ),
              child: Row(children: [
                const Icon(Icons.info_outline_rounded,
                    color: Color(0xFF9C27B0), size: 20),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(
                  'Pour réinitialiser : allez sur Firebase Console → Authentication → trouvez l\'utilisateur par UID → "Reset password". Ensuite contactez l\'utilisateur sur WhatsApp avec son nouveau mot de passe.',
                  style: GoogleFonts.inter(
                      fontSize: 12, color: kTextMuted, height: 1.5),
                )),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(20),
                itemCount: snap.data!.docs.length,
                itemBuilder: (_, i) {
                  final doc = snap.data!.docs[i];
                  final data = doc.data() as Map<String, dynamic>;
                  final status = data['status'] as String? ?? 'unread';
                  final ts = data['createdAt'] as Timestamp?;
                  final date = ts != null
                      ? '${ts.toDate().day.toString().padLeft(2, '0')}/${ts.toDate().month.toString().padLeft(2, '0')}/${ts.toDate().year}'
                      : '—';

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: kCard,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: status == 'unread'
                              ? const Color(0xFF9C27B0).withValues(alpha: 0.3)
                              : kDivider),
                    ),
                    child: Row(children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFF9C27B0).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.lock_reset_rounded,
                            color: Color(0xFF9C27B0), size: 20),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                          child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(data['name'] ?? 'Client',
                              style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: kText)),
                          Text('📞 ${data['phone'] ?? '—'}  •  $date',
                              style: GoogleFonts.inter(
                                  fontSize: 12, color: kTextMuted)),
                          if (data['uid'] != null)
                            Text('UID: ${data['uid']}',
                                style: GoogleFonts.inter(
                                    fontSize: 10, color: kTextMuted)),
                        ],
                      )),
                      const SizedBox(width: 8),
                      Column(children: [
                        if (status != 'treated')
                          _ActionBtn(
                            icon: Icons.check_circle_rounded,
                            label: 'Traité',
                            color: kSuccess,
                            onTap: () => FirebaseFirestore.instance
                                .collection('password_reset_requests')
                                .doc(doc.id)
                                .update({'status': 'treated'}),
                          ),
                        const SizedBox(height: 6),
                        if (data['phone'] != null)
                          _ActionBtn(
                            icon: Icons.chat_bubble_rounded,
                            label: 'WhatsApp',
                            color: const Color(0xFF25D366),
                            onTap: () => launchUrl(Uri.parse(
                                'https://wa.me/${(data['phone'] as String).replaceAll(RegExp(r'[^0-9]'), '')}')),
                          ),
                      ]),
                    ]),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── SOS list ──────────────────────────────────────────────────────────────────
class _SosList extends StatefulWidget {
  const _SosList();

  @override
  State<_SosList> createState() => _SosListState();
}

class _SosListState extends State<_SosList> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('sos_alerts')
          .orderBy('timestamp', descending: true)
          .snapshots(),
      builder: (_, snap) {
        if (snap.hasError) {
          return StreamErrorState(
            message: firestoreStreamErrorMessage(snap.error),
            icon: firestoreStreamErrorIcon(snap.error),
            onRetry: () => setState(() {}),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
              child: CircularProgressIndicator(color: Colors.red));
        }
        if (!snap.hasData || snap.data!.docs.isEmpty) {
          return Center(
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.sos_rounded,
                  size: 56, color: kTextMuted.withValues(alpha: 0.4)),
              const SizedBox(height: 12),
              Text('Aucune alerte SOS.',
                  style: GoogleFonts.inter(fontSize: 15, color: kTextMuted)),
            ]),
          );
        }
        final docs = snap.data!.docs;
        return ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: docs.length,
          itemBuilder: (_, i) => _SosCard(doc: docs[i]),
        );
      },
    );
  }
}

class _SosCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _SosCard({required this.doc});

  Future<void> _resolve() async {
    await FirebaseFirestore.instance
        .collection('sos_alerts')
        .doc(doc.id)
        .update({'status': 'resolved'});
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Confirmer',
            style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        content:
            Text('Supprimer cette alerte SOS ?', style: GoogleFonts.inter()),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child:
                  const Text('Supprimer', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) {
      await FirebaseFirestore.instance
          .collection('sos_alerts')
          .doc(doc.id)
          .delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final status = data['status'] as String? ?? 'active';
    final isActive = status == 'active';
    final name = data['clientName'] as String? ??
        data['driverName'] as String? ??
        'Inconnu';
    final type = data['type'] as String? ?? 'client';
    final lat = data['lat'] as num? ?? 0;
    final lng = data['lng'] as num? ?? 0;
    final hasGps = lat != 0 || lng != 0;
    final phone = data['phone'] as String?;
    final ts = data['timestamp'] as Timestamp?;
    final date = ts != null
        ? '${ts.toDate().day.toString().padLeft(2, '0')}/${ts.toDate().month.toString().padLeft(2, '0')}/${ts.toDate().year}  ${ts.toDate().hour.toString().padLeft(2, '0')}h${ts.toDate().minute.toString().padLeft(2, '0')}'
        : '—';

    final cardColor = isActive ? Colors.red : kSuccess;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: cardColor.withValues(alpha: isActive ? 0.4 : 0.2)),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: Colors.red.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                )
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: cardColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.sos_rounded, color: cardColor, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: kText)),
                Text('${type == 'driver' ? 'Livreur' : 'Client'}  •  $date',
                    style: GoogleFonts.inter(fontSize: 12, color: kTextMuted)),
              ],
            )),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: cardColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                isActive ? 'ACTIF' : 'Résolu',
                style: GoogleFonts.inter(
                    fontSize: 11,
                    color: cardColor,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5),
              ),
            ),
          ]),
          if (hasGps) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () =>
                  launchUrl(Uri.parse('https://maps.google.com/?q=$lat,$lng')),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF4285F4).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: const Color(0xFF4285F4).withValues(alpha: 0.2)),
                ),
                child: Row(children: [
                  const Icon(Icons.location_on_rounded,
                      color: Color(0xFF4285F4), size: 16),
                  const SizedBox(width: 8),
                  Text(
                    'GPS: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}  — Ouvrir Maps',
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFF4285F4),
                        fontWeight: FontWeight.w600),
                  ),
                ]),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (isActive)
              _ActionBtn(
                icon: Icons.check_circle_rounded,
                label: 'Résoudre',
                color: kSuccess,
                onTap: _resolve,
              ),
            if (phone != null)
              _ActionBtn(
                icon: Icons.chat_bubble_rounded,
                label: 'WhatsApp',
                color: const Color(0xFF25D366),
                onTap: () => launchUrl(Uri.parse(
                    'https://wa.me/${phone.replaceAll(RegExp(r'[^0-9]'), '')}')),
              ),
            _ActionBtn(
              icon: Icons.delete_outline_rounded,
              label: 'Supprimer',
              color: Colors.red,
              onTap: () => _delete(context),
            ),
          ]),
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
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 15),
          const SizedBox(width: 6),
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 12, color: color, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
