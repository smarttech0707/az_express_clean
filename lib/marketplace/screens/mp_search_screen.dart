import 'package:flutter/material.dart';
import '../../widgets/scale_button.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../mp_constants.dart';
import '../providers/mp_provider.dart';
import '../widgets/mp_product_card.dart';

class MpSearchScreen extends StatefulWidget {
  final String? initialQuery;
  const MpSearchScreen({super.key, this.initialQuery});

  @override
  State<MpSearchScreen> createState() => _MpSearchScreenState();
}

class _MpSearchScreenState extends State<MpSearchScreen> {
  late final TextEditingController _queryCtrl;
  String? _category;
  String? _condition;
  String? _brand;
  int?    _minPrice;
  int?    _maxPrice;

  final _suggestions = [
    'iPhone 13 Pro',
    'Samsung S24',
    'MacBook Pro',
    'HP EliteBook',
    'AirPods',
    'Xiaomi Redmi',
    'iPad',
    'Dell XPS',
  ];

  @override
  void initState() {
    super.initState();
    _queryCtrl = TextEditingController(text: widget.initialQuery ?? '');
    if (widget.initialQuery != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    await context.read<MpProvider>().search(
      query: _queryCtrl.text,
      category: _category,
      condition: _condition,
      brand: _brand,
      minPrice: _minPrice,
      maxPrice: _maxPrice,
    );
  }

  void _clearFilters() {
    setState(() {
      _category  = null;
      _condition = null;
      _brand     = null;
      _minPrice  = null;
      _maxPrice  = null;
    });
    _search();
  }

  bool get _hasFilters =>
      _category != null ||
      _condition != null ||
      _brand != null ||
      _minPrice != null ||
      _maxPrice != null;

  @override
  Widget build(BuildContext context) {
    final mp = context.watch<MpProvider>();
    final hasResults = mp.searchResults.isNotEmpty;
    final isSearched = mp.searchResults.isNotEmpty || mp.searching;

    return Scaffold(
      backgroundColor: kMpBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 0,
        leading: IconButton(
          onPressed: () {
            context.read<MpProvider>().clearSearch();
            Navigator.pop(context);
          },
          icon: const Icon(Icons.arrow_back_rounded, color: kMpText),
        ),
        title: TextField(
          controller: _queryCtrl,
          autofocus: widget.initialQuery == null,
          decoration: InputDecoration(
            hintText: 'Rechercher un produit...',
            hintStyle: GoogleFonts.inter(color: kMpMuted, fontSize: 15),
            border: InputBorder.none,
          ),
          style: GoogleFonts.inter(fontSize: 15, color: kMpText),
          onSubmitted: (_) => _search(),
          textInputAction: TextInputAction.search,
        ),
        actions: [
          if (_hasFilters)
            IconButton(
              onPressed: _clearFilters,
              icon: const Icon(Icons.filter_alt_off_rounded, color: Colors.red),
              tooltip: 'Effacer filtres',
            ),
          IconButton(
            onPressed: () => _showFilters(context),
            icon: Badge(
              isLabelVisible: _hasFilters,
              child: const Icon(Icons.tune_rounded, color: kMpText),
            ),
          ),
          IconButton(
            onPressed: _search,
            icon: const Icon(Icons.search_rounded, color: kMpOrange),
          ),
        ],
      ),
      body: Column(
        children: [
          // Active filter chips
          if (_hasFilters)
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    if (_category != null)
                      _FilterChip(
                          label: _catLabel(_category!),
                          onRemove: () {
                            setState(() => _category = null);
                            _search();
                          }),
                    if (_condition != null)
                      _FilterChip(
                          label: conditionLabel(_condition!),
                          onRemove: () {
                            setState(() => _condition = null);
                            _search();
                          }),
                    if (_brand != null)
                      _FilterChip(
                          label: _brand!,
                          onRemove: () {
                            setState(() => _brand = null);
                            _search();
                          }),
                    if (_minPrice != null || _maxPrice != null)
                      _FilterChip(
                          label: _priceLabel(),
                          onRemove: () {
                            setState(() {
                              _minPrice = null;
                              _maxPrice = null;
                            });
                            _search();
                          }),
                  ],
                ),
              ),
            ),

          // Body
          Expanded(
            child: mp.searching
                ? const Center(
                    child: CircularProgressIndicator(color: kMpOrange))
                : !isSearched
                    ? _buildSuggestions()
                    : !hasResults
                        ? _buildEmpty()
                        : _buildResults(mp),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestions() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tendances',
              style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: kMpText)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _suggestions
                .map((s) => GestureDetector(
                      onTap: () {
                        _queryCtrl.text = s;
                        _search();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: kMpDivider),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.trending_up_rounded,
                              size: 14, color: kMpOrange),
                          const SizedBox(width: 6),
                          Text(s,
                              style: GoogleFonts.inter(
                                  fontSize: 13, color: kMpText)),
                        ]),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 24),
          Text('Catégories',
              style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: kMpText)),
          const SizedBox(height: 12),
          ...mpCategories.map((c) => ListTile(
                onTap: () {
                  setState(() => _category = c['id']);
                  _search();
                },
                leading: Text(c['emoji']!,
                    style: const TextStyle(fontSize: 22)),
                title: Text(c['label']!,
                    style: GoogleFonts.inter(
                        fontSize: 14, fontWeight: FontWeight.w600,
                        color: kMpText)),
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: kMpMuted),
                contentPadding: EdgeInsets.zero,
                dense: true,
              )),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.search_off_rounded, size: 64, color: kMpMuted),
        const SizedBox(height: 12),
        Text('Aucun résultat',
            style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: kMpText)),
        const SizedBox(height: 6),
        Text('Essayez d\'autres mots-clés ou filtres',
            style: GoogleFonts.inter(fontSize: 13, color: kMpMuted)),
      ]),
    );
  }

  Widget _buildResults(MpProvider mp) {
    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Text(
              '${mp.searchResults.length} résultat${mp.searchResults.length > 1 ? 's' : ''}',
              style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: kMpMuted),
            ),
          ]),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate:
                const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 0.68,
            ),
            itemCount: mp.searchResults.length,
            itemBuilder: (_, i) =>
                MpProductCard(product: mp.searchResults[i]),
          ),
        ),
      ],
    );
  }

  String _priceLabel() {
    if (_minPrice != null && _maxPrice != null) {
      return '${_fmtShort(_minPrice!)} – ${_fmtShort(_maxPrice!)}';
    }
    if (_minPrice != null) return '> ${_fmtShort(_minPrice!)}';
    return '< ${_fmtShort(_maxPrice!)}';
  }

  String _fmtShort(int v) =>
      v >= 1000 ? '${(v / 1000).toStringAsFixed(0)}k' : '$v';

  String _catLabel(String c) {
    switch (c) {
      case 'phones':      return 'Téléphones';
      case 'tablets':     return 'Tablettes';
      case 'computers':   return 'Ordinateurs';
      case 'accessories': return 'Accessoires';
      default: return c;
    }
  }

  // ── Filters bottom sheet ─────────────────────────────────────────────────────
  void _showFilters(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, ctrl) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: StatefulBuilder(builder: (ctx, setS) {
            return Column(
              children: [
                // Handle
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: kMpDivider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Row(children: [
                    Text('Filtres',
                        style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: kMpText)),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _category  = null;
                          _condition = null;
                          _brand     = null;
                          _minPrice  = null;
                          _maxPrice  = null;
                        });
                        Navigator.pop(ctx);
                      },
                      child: Text('Réinitialiser',
                          style: GoogleFonts.inter(
                              color: Colors.red,
                              fontWeight: FontWeight.w600)),
                    ),
                  ]),
                ),
                Expanded(
                  child: ListView(
                    controller: ctrl,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    children: [
                      // Category
                      _FilterSection(
                        title: 'Catégorie',
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ...mpCategories.map((c) => _ChoiceChip(
                              label: '${c['emoji']} ${c['label']}',
                              selected: _category == c['id'],
                              onTap: () => setS(() =>
                                  _category = _category == c['id'] ? null : c['id']),
                            )),
                          ],
                        ),
                      ),

                      // Condition
                      _FilterSection(
                        title: 'État',
                        child: Wrap(
                          spacing: 8,
                          children: mpConditions.map((c) => _ChoiceChip(
                            label: c['label']! as String,
                            selected: _condition == c['id'],
                            onTap: () => setS(() =>
                                _condition = _condition == c['id'] ? null : c['id'] as String),
                            color: Color(c['color']! as int),
                          )).toList(),
                        ),
                      ),

                      // Price range
                      _FilterSection(
                        title: 'Budget maximum',
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            50000, 100000, 200000, 500000, 1000000,
                          ].map((v) => _ChoiceChip(
                            label: v >= 1000000
                                ? '${v ~/ 1000000}M FCFA'
                                : '${v ~/ 1000}k FCFA',
                            selected: _maxPrice == v,
                            onTap: () => setS(() =>
                                _maxPrice = _maxPrice == v ? null : v),
                          )).toList(),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: ScaleButton(
                    onPressed: () {
                      setState(() {}); // sync outer state
                      Navigator.pop(ctx);
                      _search();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kMpOrange,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 52),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text('Appliquer les filtres',
                        style: GoogleFonts.inter(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;
  const _FilterChip({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: kMpOrange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kMpOrange.withValues(alpha: 0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 12,
                color: kMpOrange,
                fontWeight: FontWeight.w600)),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: onRemove,
          child: const Icon(Icons.close_rounded, size: 14, color: kMpOrange),
        ),
      ]),
    );
  }
}

class _FilterSection extends StatelessWidget {
  final String title;
  final Widget child;
  const _FilterSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: kMpMuted,
                  letterSpacing: 0.5)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? kMpOrange;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? c : kMpDivider),
        ),
        child: Text(label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : kMpText,
            )),
      ),
    );
  }
}

