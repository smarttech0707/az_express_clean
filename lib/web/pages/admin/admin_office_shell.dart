import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../web_theme.dart';
import '../../widgets/az_logo.dart';

/// Une section de la sidebar du Bureau Web.
///
/// `available` indique si la section a un vrai contenu en Phase 1. Une
/// section non disponible reste visible (transparence sur la feuille de
/// route demandée par le cahier des charges) mais ouvre un état "en
/// préparation" honnête ([AdminSectionUnavailable]), jamais une
/// fonctionnalité inventée.
class AdminSidebarSection {
  final String id;
  final String label;
  final IconData icon;
  final bool available;
  const AdminSidebarSection({
    required this.id,
    required this.label,
    required this.icon,
    this.available = true,
  });
}

/// Les 9 sections demandées, dans l'ordre demandé. Ne pas en ajouter ou
/// retirer sans décision explicite : c'est la structure validée par
/// l'utilisateur pour la Phase 1.
const officeSidebarSections = <AdminSidebarSection>[
  AdminSidebarSection(
      id: 'dashboard', label: 'Tableau de bord', icon: Icons.dashboard_rounded),
  AdminSidebarSection(
      id: 'orders', label: 'Commandes', icon: Icons.receipt_long_rounded),
  AdminSidebarSection(
      id: 'drivers',
      label: 'Livreurs et flottes',
      icon: Icons.delivery_dining_rounded,
      available: false),
  AdminSidebarSection(
      id: 'partners',
      label: 'Partenaires',
      icon: Icons.storefront_rounded,
      available: false),
  AdminSidebarSection(
      id: 'requests', label: 'Centre de demandes', icon: Icons.inbox_rounded),
  AdminSidebarSection(
      id: 'finance',
      label: 'Finances',
      icon: Icons.account_balance_wallet_rounded,
      available: false),
  AdminSidebarSection(
      id: 'services', label: 'Services', icon: Icons.construction_rounded),
  AdminSidebarSection(
      id: 'employees', label: 'Employés', icon: Icons.badge_rounded),
  AdminSidebarSection(
      id: 'security',
      label: 'Sécurité et paramètres',
      icon: Icons.security_rounded),
];

AdminSidebarSection officeSectionById(String id) => officeSidebarSections
    .firstWhere((s) => s.id == id, orElse: () => officeSidebarSections.first);

/// Coquille "bureau professionnel" : sidebar rétractable sur ordinateur,
/// tiroir (hamburger) sur tablette/petit écran, barre de titre reprenant la
/// section active. Ne contient aucune logique métier : `body` est fourni
/// par l'appelant pour chaque section.
class AdminOfficeShell extends StatefulWidget {
  final String selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onLogout;
  final Widget body;

  const AdminOfficeShell({
    super.key,
    required this.selectedId,
    required this.onSelect,
    required this.onLogout,
    required this.body,
  });

  @override
  State<AdminOfficeShell> createState() => _AdminOfficeShellState();
}

class _AdminOfficeShellState extends State<AdminOfficeShell> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktop(context);
    final section = officeSectionById(widget.selectedId);

    return Scaffold(
      backgroundColor: kBg,
      drawer: desktop
          ? null
          : _MobileDrawer(
              selectedId: widget.selectedId,
              onSelect: (id) {
                widget.onSelect(id);
                Navigator.of(context).maybePop();
              },
              onLogout: widget.onLogout,
            ),
      appBar: AppBar(
        backgroundColor: kCard,
        elevation: 0,
        foregroundColor: kText,
        iconTheme: const IconThemeData(color: kText),
        title: Text(section.label,
            style: GoogleFonts.inter(
                fontSize: 17, fontWeight: FontWeight.w700, color: kText)),
        actions: [
          if (desktop)
            IconButton(
              tooltip: _collapsed ? 'Déplier le menu' : 'Réduire le menu',
              icon: Icon(
                  _collapsed ? Icons.menu_open_rounded : Icons.menu_rounded),
              onPressed: () => setState(() => _collapsed = !_collapsed),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: desktop
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Sidebar(
                  selectedId: widget.selectedId,
                  collapsed: _collapsed,
                  width: _collapsed ? 76 : 248,
                  onSelect: widget.onSelect,
                  onLogout: widget.onLogout,
                ),
                Expanded(child: widget.body),
              ],
            )
          : widget.body,
    );
  }
}

class _MobileDrawer extends StatelessWidget {
  final String selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onLogout;
  const _MobileDrawer(
      {required this.selectedId,
      required this.onSelect,
      required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: _Sidebar(
          selectedId: selectedId,
          collapsed: false,
          width: 280,
          onSelect: onSelect,
          onLogout: onLogout,
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final String selectedId;
  final bool collapsed;
  final double width;
  final ValueChanged<String> onSelect;
  final VoidCallback onLogout;
  const _Sidebar({
    required this.selectedId,
    required this.collapsed,
    required this.width,
    required this.onSelect,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: width,
      decoration: const BoxDecoration(
        color: kCard,
        border: Border(right: BorderSide(color: kDivider)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Row(
              children: [
                const AzLogo(size: 32),
                if (!collapsed) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Bureau AZ Express',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: kText),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: kDivider),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final s in officeSidebarSections)
                  _SidebarItem(
                    section: s,
                    selected: s.id == selectedId,
                    collapsed: collapsed,
                    onTap: () => onSelect(s.id),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: kDivider),
          _AdminFooter(collapsed: collapsed, onLogout: onLogout),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final AdminSidebarSection section;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;
  const _SidebarItem({
    required this.section,
    required this.selected,
    required this.collapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? kOrange : kTextMuted;
    final item = Material(
      color: selected ? kOrangeBg : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(section.icon, size: 20, color: color),
              if (!collapsed) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    section.label,
                    // Libellé toujours en texte foncé (même non sélectionné) :
                    // seule l'icône porte la nuance orange/grise, le texte
                    // doit rester lisible sans dépendre de la sélection.
                    style: GoogleFonts.inter(
                        fontSize: 13.5,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: kText),
                  ),
                ),
                if (!section.available)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: kTextMuted.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('Bientôt',
                        style: GoogleFonts.inter(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: kTextMuted)),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: collapsed
          ? Tooltip(message: section.label, child: item)
          : item,
    );
  }
}

class _AdminFooter extends StatelessWidget {
  final bool collapsed;
  final VoidCallback onLogout;
  const _AdminFooter({required this.collapsed, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    final initial = email.isNotEmpty ? email[0].toUpperCase() : 'A';
    return Padding(
      padding: const EdgeInsets.all(12),
      child: collapsed
          ? IconButton(
              tooltip: 'Déconnexion',
              onPressed: onLogout,
              icon: const Icon(Icons.logout_rounded, color: kTextMuted),
            )
          : Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: kOrangeBg,
                  child: Text(initial,
                      style: GoogleFonts.inter(
                          fontWeight: FontWeight.w800, color: kOrange)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: kText)),
                      Text('Administrateur principal',
                          style:
                              GoogleFonts.inter(fontSize: 10, color: kTextMuted)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Déconnexion',
                  onPressed: onLogout,
                  icon: const Icon(Icons.logout_rounded,
                      size: 18, color: kTextMuted),
                ),
              ],
            ),
    );
  }
}

/// État honnête pour une section pas encore développée : jamais de données
/// ou de fonctionnalités simulées.
class AdminSectionUnavailable extends StatelessWidget {
  final String title;
  final String? note;
  const AdminSectionUnavailable({super.key, required this.title, this.note});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.construction_rounded,
                size: 56, color: kTextMuted.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text('$title — en préparation',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 16, fontWeight: FontWeight.w700, color: kText)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                note ??
                    'Ce module sera développé dans une prochaine phase du '
                        'Bureau Web. Il reste disponible dès maintenant depuis '
                        'l\'application mobile administrateur.',
                textAlign: TextAlign.center,
                style:
                    GoogleFonts.inter(fontSize: 13, color: kTextMuted, height: 1.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rangée de pastilles pour naviguer entre les sous-pages d'une section qui
/// regroupe plusieurs modules existants (ex. Centre de demandes).
class AdminSectionSubNav extends StatelessWidget {
  final List<String> labels;
  final List<IconData> icons;
  final int selected;
  final ValueChanged<int> onSelect;
  const AdminSectionSubNav({
    super.key,
    required this.labels,
    required this.icons,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (var i = 0; i < labels.length; i++)
            GestureDetector(
              onTap: () => onSelect(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                decoration: BoxDecoration(
                  color: selected == i ? kOrange : kCard,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                      color: selected == i ? kOrange : kDivider),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icons[i],
                      size: 15, color: selected == i ? Colors.white : kText),
                  const SizedBox(width: 6),
                  // Onglet actif : orange + texte blanc (conservé tel quel).
                  // Onglet inactif : texte foncé `kText` plutôt que
                  // `kTextMuted`, pour rester lisible sur fond clair.
                  Text(labels[i],
                      style: GoogleFonts.inter(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: selected == i ? Colors.white : kText)),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bandeau d'information honnête au sommet d'une section partiellement
/// développée (certains modules présents, d'autres pas encore).
class AdminSectionNote extends StatelessWidget {
  final String text;
  const AdminSectionNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kOrangeBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kOrange.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, color: kOrange, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: GoogleFonts.inter(fontSize: 12, color: kText, height: 1.5)),
          ),
        ],
      ),
    );
  }
}
