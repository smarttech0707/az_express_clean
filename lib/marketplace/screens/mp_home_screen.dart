import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../mp_constants.dart';
import '../providers/mp_provider.dart';
import '../providers/mp_favorites_provider.dart';
import '../widgets/mp_product_card.dart';
import '../models/mp_product.dart';
import 'mp_search_screen.dart';
import 'mp_seller_screen.dart';
import 'mp_favorites_screen.dart';

class MpHomeScreen extends StatefulWidget {
  const MpHomeScreen({super.key});

  @override
  State<MpHomeScreen> createState() => _MpHomeScreenState();
}

class _MpHomeScreenState extends State<MpHomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<MpProvider>().ensureLoaded();
      context.read<MpFavoritesProvider>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kMpBg,
      body: CustomScrollView(
        slivers: [
          _buildAppBar(context),
          _buildCategories(),
          _buildBanner(),
          _buildSection('🆕  Nouveautés', context, selector: (p) => p.newProducts),
          _buildSection('✨  Quasi neufs', context, selector: (p) => p.likeNewProducts),
          _buildSection('💡  Bonnes affaires', context, selector: (p) => p.usedProducts),
          _buildAllGrid(),
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }

  // ── App bar ──────────────────────────────────────────────────────────────────
  SliverAppBar _buildAppBar(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      elevation: 0,
      backgroundColor: kMpOrange,
      expandedHeight: 120,
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFFF6D00), Color(0xFFFF8F00)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('AZ Market',
                        style: GoogleFonts.inter(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        )),
                    Text('Téléphones · Tablettes · Ordi',
                        style: GoogleFonts.inter(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.85))),
                  ],
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const MpFavoritesScreen())),
                  icon: const Icon(Icons.favorite_border_rounded,
                      color: Colors.white),
                ),
                IconButton(
                  onPressed: () {
                    final user = FirebaseAuth.instance.currentUser;
                    if (user == null || user.isAnonymous) {
                      _showAuthSnack(context);
                      return;
                    }
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const MpSellerScreen()));
                  },
                  icon: const Icon(Icons.storefront_rounded,
                      color: Colors.white),
                  tooltip: 'Mes annonces',
                ),
              ]),
            ),
          ),
        ),
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(52),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: GestureDetector(
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const MpSearchScreen())),
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x20000000),
                      blurRadius: 8,
                      offset: Offset(0, 2))
                ],
              ),
              child: Row(children: [
                const SizedBox(width: 14),
                const Icon(Icons.search_rounded, color: kMpMuted, size: 20),
                const SizedBox(width: 8),
                Text('iPhone, Samsung, HP...',
                    style: GoogleFonts.inter(
                        fontSize: 14, color: kMpMuted)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // ── Categories ────────────────────────────────────────────────────────────────
  SliverToBoxAdapter _buildCategories() {
    return SliverToBoxAdapter(
      child: Consumer<MpProvider>(builder: (_, mp, __) {
        return Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              _CatChip(
                emoji: '🔥',
                label: 'Tout',
                selected: mp.selectedCategory == 'all',
                onTap: () => mp.selectCategory('all'),
              ),
              ...mpCategories.map((c) => _CatChip(
                emoji: c['emoji']!,
                label: c['label']!,
                selected: mp.selectedCategory == c['id'],
                onTap: () => mp.selectCategory(c['id']!),
              )),
            ]),
          ),
        );
      }),
    );
  }

  // ── Promo banner ──────────────────────────────────────────────────────────────
  SliverToBoxAdapter _buildBanner() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1A1A2E), Color(0xFF16213E)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Vendez vos appareils',
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      )),
                  const SizedBox(height: 2),
                  Text('Publiez gratuitement en 2 min',
                      style: GoogleFonts.inter(
                        color: Colors.white70,
                        fontSize: 11,
                      )),
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: () {
                      final user = FirebaseAuth.instance.currentUser;
                      if (user == null || user.isAnonymous) {
                        _showAuthSnack(context);
                        return;
                      }
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const MpSellerScreen()));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: kMpOrange,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('Publier une annonce',
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          )),
                    ),
                  ),
                ],
              ),
            ),
            const Text('📱', style: TextStyle(fontSize: 44)),
          ]),
        ),
      ),
    );
  }

  // ── Section horizontale ───────────────────────────────────────────────────────
  SliverToBoxAdapter _buildSection(
    String title,
    BuildContext context, {
    required List<MpProduct> Function(MpProvider) selector,
  }) {
    return SliverToBoxAdapter(
      child: Consumer<MpProvider>(builder: (_, mp, __) {
        final items = selector(mp);
        if (items.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 20, 14, 10),
              child: Row(children: [
                Text(title,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: kMpText,
                    )),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const MpSearchScreen())),
                  child: Text('Voir tout',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          color: kMpOrange,
                          fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
            SizedBox(
              height: 215,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, i) => MpProductTile(product: items[i]),
              ),
            ),
          ],
        );
      }),
    );
  }

  // ── All products grid ─────────────────────────────────────────────────────────
  Widget _buildAllGrid() {
    return Consumer<MpProvider>(builder: (_, mp, __) {
      if (mp.loading) {
        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Column(children: [
                const CircularProgressIndicator(color: kMpOrange),
                const SizedBox(height: 12),
                Text('Chargement...', style: GoogleFonts.inter(color: kMpMuted)),
              ]),
            ),
          ),
        );
      }
      if (mp.products.isEmpty) {
        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Column(children: [
                const Icon(Icons.devices_rounded, size: 56, color: kMpMuted),
                const SizedBox(height: 12),
                Text('Aucun produit disponible',
                    style: GoogleFonts.inter(color: kMpMuted, fontSize: 15)),
              ]),
            ),
          ),
        );
      }
      return SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 20, 12, 0),
        sliver: SliverGrid(
          delegate: SliverChildBuilderDelegate(
            (_, i) => MpProductCard(product: mp.products[i]),
            childCount: mp.products.length,
          ),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.68,
          ),
        ),
      );
    });
  }

  void _showAuthSnack(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Connectez-vous pour vendre',
            style: GoogleFonts.inter(color: Colors.white)),
        backgroundColor: kMpOrange,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

// ── Category chip ──────────────────────────────────────────────────────────────
class _CatChip extends StatelessWidget {
  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CatChip({
    required this.emoji,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? kMpOrange : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? kMpOrange : const Color(0xFFE0E0E0),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(emoji, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : kMpText,
            ),
          ),
        ]),
      ),
    );
  }
}
