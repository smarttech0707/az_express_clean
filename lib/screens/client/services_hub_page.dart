import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../ekbine/screens/ek_home_screen.dart';
import '../../l10n/app_text.dart';
import 'service_providers_page.dart';
import 'service_provider_register_page.dart';

// ═══════════════════════════════════════════════════════════════════════════
// MODÈLES LOCAUX
// ═══════════════════════════════════════════════════════════════════════════

class _SubCat {
  final String id;
  final String labelKey;
  final IconData icon;
  const _SubCat(this.id, this.labelKey, this.icon);
}

class _Category {
  final String id;
  final String labelKey;
  final IconData icon;
  final List<Color> gradient;
  final Color color;
  final List<_SubCat> subs;
  const _Category({
    required this.id,
    required this.labelKey,
    required this.icon,
    required this.gradient,
    required this.color,
    required this.subs,
  });
}

const _categories = [
  _Category(
    id: 'real_estate',
    labelKey: 'cat_real_estate',
    icon: Icons.home_work_rounded,
    gradient: [Color(0xFF004D40), Color(0xFF00897B)],
    color: Color(0xFF00695C),
    subs: [
      _SubCat('location',          'sub_location', Icons.home_rounded),
      _SubCat('vente_maison',      'sub_vente',    Icons.sell_rounded),
      _SubCat('local_commercial',  'sub_local',    Icons.store_rounded),
      _SubCat('terrain',           'sub_terrain',  Icons.landscape_rounded),
    ],
  ),
  _Category(
    id: 'artisans',
    labelKey: 'cat_artisans',
    icon: Icons.construction_rounded,
    gradient: [Color(0xFF1565C0), Color(0xFF1E88E5)],
    color: Color(0xFF1565C0),
    subs: [
      _SubCat('macon',               'sub_macon',          Icons.domain_rounded),
      _SubCat('plombier',            'sub_plombier',        Icons.plumbing_rounded),
      _SubCat('electricien',         'sub_electricien',     Icons.electrical_services_rounded),
      _SubCat('ferronnier',          'sub_ferronnier',      Icons.hardware_rounded),
      _SubCat('menuisier',           'sub_menuisier',       Icons.carpenter_rounded),
      _SubCat('carreleur',           'sub_carreleur',       Icons.grid_on_rounded),
      _SubCat('peintre',             'sub_peintre',         Icons.format_paint_rounded),
      _SubCat('vitrier',             'sub_vitrier',         Icons.window_rounded),
      _SubCat('reparateur_tv',       'sub_reparateur_tv',   Icons.tv_rounded),
      _SubCat('installation_camera', 'sub_camera',          Icons.videocam_rounded),
      _SubCat('decoration',          'sub_decoration',      Icons.home_rounded),
      _SubCat('reparateur_portable',    'sub_reparateur',          Icons.phone_android_rounded),
      _SubCat('salon_coiffure_homme',   'sub_salon_homme',         Icons.content_cut_rounded),
      _SubCat('barber_shop',            'sub_barber_shop',         Icons.face_rounded),
      _SubCat('salon_coiffure_femme',   'sub_salon_femme',         Icons.face_retouching_natural_rounded),
      _SubCat('onglerie',               'sub_onglerie',            Icons.spa_rounded),
    ],
  ),
  _Category(
    id: 'mecanique',
    labelKey: 'cat_mecanique',
    icon: Icons.build_rounded,
    gradient: [Color(0xFFBF360C), Color(0xFFE64A19)],
    color: Color(0xFFBF360C),
    subs: [
      _SubCat('mecanicien_voiture', 'sub_meca_voiture', Icons.directions_car_rounded),
      _SubCat('mecanicien_moto',    'sub_meca_moto',    Icons.two_wheeler_rounded),
      _SubCat('electrique_auto',    'sub_elec_auto',    Icons.electrical_services_rounded),
      _SubCat('carrosserie',        'sub_carrosserie',  Icons.car_repair_rounded),
    ],
  ),
  _Category(
    id: 'materiaux',
    labelKey: 'cat_construction',
    icon: Icons.foundation_rounded,
    gradient: [Color(0xFF0277BD), Color(0xFF29B6F6)],
    color: Color(0xFF0277BD),
    subs: [
      _SubCat('eau_pack',       'sub_eau',    Icons.water_drop_rounded),
      _SubCat('ciment_briques', 'sub_ciment', Icons.foundation_rounded),
    ],
  ),
  _Category(
    id: 'telephonie',
    labelKey: 'cat_telephonie',
    icon: Icons.smartphone_rounded,
    gradient: [Color(0xFF6A1B9A), Color(0xFFAB47BC)],
    color: Color(0xFF6A1B9A),
    subs: [
      _SubCat('telephone',    'sub_telephone',    Icons.smartphone_rounded),
      _SubCat('accessoires',  'sub_accessoires',  Icons.headphones_rounded),
    ],
  ),
  _Category(
    id: 'cave',
    labelKey: 'cat_cave',
    icon: Icons.wine_bar_rounded,
    gradient: [Color(0xFF880E4F), Color(0xFFE91E63)],
    color: Color(0xFF880E4F),
    subs: [
      _SubCat('cave_vins',       'sub_cave_vins',       Icons.wine_bar_rounded),
      _SubCat('cave_bieres',     'sub_cave_bieres',     Icons.sports_bar_rounded),
      _SubCat('cave_sans_alcool','sub_cave_sans_alcool', Icons.local_drink_rounded),
    ],
  ),
];

// ═══════════════════════════════════════════════════════════════════════════
// PAGE PRINCIPALE
// ═══════════════════════════════════════════════════════════════════════════

class ServicesHubPage extends StatefulWidget {
  const ServicesHubPage({super.key});

  @override
  State<ServicesHubPage> createState() => _ServicesHubPageState();
}

class _ServicesHubPageState extends State<ServicesHubPage>
    with TickerProviderStateMixin {

  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  String  _query        = '';
  bool    _searchActive = false;

  // Animation d'entrée staggerée par catégorie
  late final List<AnimationController> _catCtrl;
  late final List<Animation<double>>   _catFade;
  late final List<Animation<Offset>>   _catSlide;

  @override
  void initState() {
    super.initState();
    _catCtrl = List.generate(_categories.length, (i) =>
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 450),
      )
    );
    _catFade  = _catCtrl.map((c) =>
      CurvedAnimation(parent: c, curve: Curves.easeOut)).toList();
    _catSlide = _catCtrl.map((c) =>
      Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
        .animate(CurvedAnimation(parent: c, curve: Curves.easeOutCubic))).toList();

    // Déclencher les animations en cascade
    for (var i = 0; i < _categories.length; i++) {
      Future.delayed(Duration(milliseconds: 80 * i), () {
        if (mounted) _catCtrl[i].forward();
      });
    }
  }

  @override
  void dispose() {
    for (final c in _catCtrl) {
      c.dispose();
    }
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── Résultats de recherche ────────────────────────────────────────────────
  List<({_SubCat sub, _Category cat})> get _searchResults {
    if (_query.isEmpty) return [];
    final q = _query.toLowerCase();
    final results = <({_SubCat sub, _Category cat})>[];
    for (final cat in _categories) {
      for (final sub in cat.subs) {
        // On cherche dans le texte traduit OU dans l'id
        if (sub.id.contains(q) || sub.labelKey.contains(q)) {
          results.add((sub: sub, cat: cat));
        }
      }
    }
    return results;
  }

  void _navigate(BuildContext context, _SubCat sub, _Category cat) {
    final label = context.tr(sub.labelKey);
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => ServiceProvidersPage(
        subcategory: sub.id,
        title:       label,
        color:       cat.color,
        gradient:    cat.gradient,
        icon:        sub.icon,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: const Color(0xFFF2F3F7),
      body: CustomScrollView(
        controller: _scrollCtrl,
        slivers: [
          // ── APP BAR ──────────────────────────────────────────────────────
          SliverAppBar(
            expandedHeight: (screenH * 0.18).clamp(130.0, 200.0),
            pinned: true,
            backgroundColor: const Color(0xFF1565C0),
            foregroundColor: Colors.white,
            elevation: 0,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF0D47A1), Color(0xFF1565C0), Color(0xFF1976D2)],
                    begin: Alignment.topLeft,
                    end:   Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 32),
                        Text(
                          context.tr('services_title'),
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          context.tr('services_sub'),
                          style: GoogleFonts.inter(
                              color: Colors.white70, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: AnimatedOpacity(
              opacity: _searchActive ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              child: Text(
                context.tr('services_title'),
                style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600),
              ),
            ),
            centerTitle: true,
          ),

          // ── BARRE DE RECHERCHE ────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _SearchBar(
                controller: _searchCtrl,
                onChanged: (v) => setState(() {
                  _query        = v.toLowerCase();
                  _searchActive = v.isNotEmpty;
                }),
                onClear: () => setState(() {
                  _searchCtrl.clear();
                  _query        = '';
                  _searchActive = false;
                }),
              ),
            ),
          ),

          // ── RÉSULTATS DE RECHERCHE ────────────────────────────────────────
          if (_searchActive) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(
                child: Text(
                  '${_searchResults.length} résultat(s) pour "$_query"',
                  style: GoogleFonts.inter(
                      fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
            ),
            if (_searchResults.isEmpty)
              SliverFillRemaining(
                child: _EmptySearch(query: _query),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      final r = _searchResults[i];
                      return _SearchResultTile(
                        sub:    r.sub,
                        cat:    r.cat,
                        label:  ctx.tr(r.sub.labelKey),
                        catLabel: ctx.tr(r.cat.labelKey),
                        onTap:  () => _navigate(ctx, r.sub, r.cat),
                      );
                    },
                    childCount: _searchResults.length,
                  ),
                ),
              ),
          ],

          // ── CONTENU NORMAL ────────────────────────────────────────────────
          if (!_searchActive) ...[
            // E-Kbine banner
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              sliver: SliverToBoxAdapter(child: _EkbineBanner()),
            ),

            // Bannière "Devenir prestataire"
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverToBoxAdapter(
                child: _BecomeProviderBanner(),
              ),
            ),

            // Catégories animées
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => FadeTransition(
                    opacity: _catFade[i],
                    child: SlideTransition(
                      position: _catSlide[i],
                      child: _CategorySection(
                        cat:      _categories[i],
                        onSubTap: (sub) =>
                            _navigate(ctx, sub, _categories[i]),
                      ),
                    ),
                  ),
                  childCount: _categories.length,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// BARRE DE RECHERCHE
// ═══════════════════════════════════════════════════════════════════════════

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  const _SearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withValues(alpha: 0.07),
            blurRadius: 10,
            offset:     const Offset(0, 3),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        onChanged:  onChanged,
        style:      GoogleFonts.inter(fontSize: 14),
        decoration: InputDecoration(
          hintText:  'Rechercher un service...',
          hintStyle: GoogleFonts.inter(fontSize: 14, color: Colors.grey),
          prefixIcon: const Icon(Icons.search_rounded,
              color: Color(0xFF1565C0), size: 22),
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.grey, size: 20),
                  onPressed: onClear,
                )
              : null,
          border:         InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// RÉSULTAT DE RECHERCHE
// ═══════════════════════════════════════════════════════════════════════════

class _SearchResultTile extends StatelessWidget {
  final _SubCat sub;
  final _Category cat;
  final String label;
  final String catLabel;
  final VoidCallback onTap;
  const _SearchResultTile({
    required this.sub,
    required this.cat,
    required this.label,
    required this.catLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color:      Colors.black.withValues(alpha: 0.05),
              blurRadius: 6,
              offset:     const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color:        cat.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(sub.icon, color: cat.color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: GoogleFonts.inter(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(cat.icon, size: 11, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Text(catLabel,
                          style: GoogleFonts.inter(
                              fontSize: 11, color: Colors.grey.shade500)),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded,
                size: 14, color: cat.color.withValues(alpha: 0.7)),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// ÉTAT VIDE RECHERCHE
// ═══════════════════════════════════════════════════════════════════════════

class _EmptySearch extends StatelessWidget {
  final String query;
  const _EmptySearch({required this.query});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off_rounded,
              size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            'Aucun résultat pour "$query"',
            style: GoogleFonts.inter(
                fontSize: 15, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Text(
            'Essayez : maçon, plombier, location...',
            style: GoogleFonts.inter(
                fontSize: 12, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SECTION CATÉGORIE
// ═══════════════════════════════════════════════════════════════════════════

class _CategorySection extends StatelessWidget {
  final _Category cat;
  final ValueChanged<_SubCat> onSubTap;
  const _CategorySection({required this.cat, required this.onSubTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── En-tête catégorie ─────────────────────────────────────────────
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            gradient:     LinearGradient(colors: cat.gradient),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color:      cat.color.withValues(alpha: 0.28),
                blurRadius: 12,
                offset:     const Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color:        Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(cat.icon, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr(cat.labelKey),
                      style: GoogleFonts.inter(
                        color:      Colors.white,
                        fontSize:   16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${cat.subs.length} services disponibles',
                      style: GoogleFonts.inter(
                          color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios_rounded,
                  color: Colors.white54, size: 14),
            ],
          ),
        ),

        // ── Grille sous-catégories ─────────────────────────────────────────
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount:  2,
            mainAxisSpacing:  8,
            crossAxisSpacing: 8,
            childAspectRatio: 2.6,
          ),
          itemCount: cat.subs.length,
          itemBuilder: (ctx, i) => _SubCatTile(
            sub:   cat.subs[i],
            label: ctx.tr(cat.subs[i].labelKey),
            color: cat.color,
            onTap: () => onSubTap(cat.subs[i]),
          ),
        ),

        const SizedBox(height: 20),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TUILE SOUS-CATÉGORIE
// ═══════════════════════════════════════════════════════════════════════════

class _SubCatTile extends StatefulWidget {
  final _SubCat sub;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _SubCatTile({
    required this.sub,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  State<_SubCatTile> createState() => _SubCatTileState();
}

class _SubCatTileState extends State<_SubCatTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) { setState(() => _pressed = false); widget.onTap(); },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale:    _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          decoration: BoxDecoration(
            color:        _pressed
                ? widget.color.withValues(alpha: 0.12)
                : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border:       Border.all(
                color: widget.color.withValues(alpha: _pressed ? 0.3 : 0.15),
                width: 1.5),
            boxShadow: _pressed ? [] : [
              BoxShadow(
                color:      Colors.black.withValues(alpha: 0.05),
                blurRadius: 6,
                offset:     const Offset(0, 2),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color:        widget.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(widget.sub.icon, color: widget.color, size: 17),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize:   11.5,
                    fontWeight: FontWeight.w600,
                    color:      Colors.black87,
                    height:     1.25,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 14,
                  color: widget.color.withValues(alpha: 0.5)),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// BANNIÈRE DEVENIR PRESTATAIRE
// ═══════════════════════════════════════════════════════════════════════════

class _BecomeProviderBanner extends StatefulWidget {
  @override
  State<_BecomeProviderBanner> createState() => _BecomeProviderBannerState();
}

class _BecomeProviderBannerState extends State<_BecomeProviderBanner> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) {
        setState(() => _pressed = false);
        Navigator.push(context,
            MaterialPageRoute(
                builder: (_) => const ServiceProviderRegisterPage()));
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale:    _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF5C1F6B), Color(0xFF9C27B0)],
              begin:  Alignment.centerLeft,
              end:    Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color:      const Color(0xFF7B1FA2).withValues(alpha: 0.3),
                blurRadius: 12,
                offset:     const Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color:        Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.storefront_rounded,
                    color: Colors.white, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Devenir prestataire',
                      style: GoogleFonts.inter(
                        color:      Colors.white,
                        fontSize:   15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Inscrivez votre activité sur AZ Express',
                      style: GoogleFonts.inter(
                          color: Colors.white70, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color:        Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                  border:       Border.all(
                      color: Colors.white.withValues(alpha: 0.3)),
                ),
                child: Text(
                  "S'inscrire",
                  style: GoogleFonts.inter(
                    color:      Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize:   12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// BANNIÈRE E-KBINE
// ═══════════════════════════════════════════════════════════════════════════

class _EkbineBanner extends StatefulWidget {
  @override
  State<_EkbineBanner> createState() => _EkbineBannerState();
}

class _EkbineBannerState extends State<_EkbineBanner> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) {
        setState(() => _pressed = false);
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const EkHomeScreen()));
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale:    _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF00695C), Color(0xFF00BFA5)],
              begin:  Alignment.centerLeft,
              end:    Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color:      const Color(0xFF00695C).withValues(alpha: 0.35),
                blurRadius: 14,
                offset:     const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color:        Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.sim_card_rounded,
                    color: Colors.white, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'E-Kbine Services',
                      style: GoogleFonts.inter(
                        color:      Colors.white,
                        fontSize:   16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.tr('ekbine_sub'),
                      style: GoogleFonts.inter(
                          color: Colors.white70, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color:        Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                  border:       Border.all(
                      color: Colors.white.withValues(alpha: 0.3)),
                ),
                child: Text(
                  'Ouvrir',
                  style: GoogleFonts.inter(
                    color:      Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize:   12.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
