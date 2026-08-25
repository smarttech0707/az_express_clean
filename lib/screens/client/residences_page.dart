import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_text.dart';

class ResidencesPage extends StatefulWidget {
  const ResidencesPage({super.key});

  @override
  State<ResidencesPage> createState() => _ResidencesPageState();
}

class _ResidencesPageState extends State<ResidencesPage> {
  final _searchCtrl = TextEditingController();
  String _search = '';
  String _filterType = 'tous';

  static const _types = [
    'tous',
    'Studio',
    '1 pièce',
    '2 pièces',
    '3 pièces',
    'Villa'
  ];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: CustomScrollView(
        slivers: [
          // ── HEADER ──────────────────────────────────────────
          SliverAppBar(
            expandedHeight:
                (MediaQuery.of(context).size.height * 0.22).clamp(150.0, 230.0),
            floating: false,
            pinned: true,
            backgroundColor: const Color(0xFF4A148C),
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF4A148C), Color(0xFF7B1FA2)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 44),
                        Text(
                          context.tr('furnished_title'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          context.tr('find_residence'),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: Text(context.tr('furnished_title'),
                style: const TextStyle(color: Colors.white, fontSize: 18)),
            centerTitle: true,
          ),

          // ── SEARCH ──────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _search = v.toLowerCase()),
                decoration: InputDecoration(
                  hintText: context.tr('search_residence'),
                  prefixIcon:
                      const Icon(Icons.search, color: Color(0xFF4A148C)),
                  suffixIcon: _search.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _search = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),

          // ── TYPE FILTER ─────────────────────────────────────
          SliverToBoxAdapter(
            child: SizedBox(
              height: 46,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                scrollDirection: Axis.horizontal,
                itemCount: _types.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final t = _types[i];
                  final selected = _filterType == t;
                  final label = t == 'tous' ? context.tr('all_types') : t;
                  return GestureDetector(
                    onTap: () => setState(() => _filterType = t),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      decoration: BoxDecoration(
                        color:
                            selected ? const Color(0xFF4A148C) : Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected
                              ? const Color(0xFF4A148C)
                              : Colors.grey.shade300,
                        ),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 12)),

          // ── LIST ────────────────────────────────────────────
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('residences')
                .where('isAvailable', isEqualTo: true)
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              final docs = snap.data?.docs ?? [];
              final filtered = docs.where((d) {
                final data = d.data() as Map<String, dynamic>;
                final title = (data['title'] ?? '').toLowerCase();
                final address = (data['address'] ?? '').toLowerCase();
                final type = data['type'] ?? '';
                final matchSearch = _search.isEmpty ||
                    title.contains(_search) ||
                    address.contains(_search);
                final matchType = _filterType == 'tous' || type == _filterType;
                return matchSearch && matchType;
              }).toList();

              if (filtered.isEmpty) {
                return SliverFillRemaining(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.apartment_outlined,
                          size: 72, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text(
                        _search.isEmpty
                            ? context.tr('no_residence')
                            : "${context.tr('no_result_for')} \"$_search\"",
                        style:
                            const TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                    ],
                  ),
                );
              }

              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final data = filtered[i].data() as Map<String, dynamic>;
                      return _FadeInItem(
                        index: i,
                        child: _ResidenceCard(
                          data: data,
                          onTap: () => _showDetail(context, data),
                        ),
                      );
                    },
                    childCount: filtered.length,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  void _showDetail(BuildContext context, Map<String, dynamic> data) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ResidenceDetail(data: data),
    );
  }
}

// ── CARD ──────────────────────────────────────────────────────

class _ResidenceCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  const _ResidenceCard({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final title = data['title'] ?? 'Sans titre';
    final address = data['address'] ?? '';
    final priceNight = data['priceNight'] as int?;
    final priceMonth = data['priceMonth'] as int?;
    final type = data['type'] ?? '';
    final photoUrl = data['photoUrl'] as String?;
    final amenities = (data['amenities'] as List?)?.cast<String>() ?? [];

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.07),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Photo
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
              child: SizedBox(
                height: 190,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    photoUrl != null && photoUrl.isNotEmpty
                        ? Image.network(photoUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _placeholder())
                        : _placeholder(),
                    // Type badge
                    if (type.isNotEmpty)
                      Positioned(
                        top: 12,
                        left: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4A148C),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            type,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.location_on,
                          size: 14, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          address,
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 13),
                        ),
                      ),
                    ],
                  ),

                  // Prices
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (priceNight != null && priceNight > 0) ...[
                        _priceChip('$priceNight FCFA', context.tr('per_night'),
                            const Color(0xFF4A148C)),
                        const SizedBox(width: 8),
                      ],
                      if (priceMonth != null && priceMonth > 0)
                        _priceChip('$priceMonth FCFA', context.tr('per_month'),
                            Colors.orange.shade700),
                    ],
                  ),

                  // Amenities
                  if (amenities.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: amenities.take(4).map((a) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF4A148C).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            a,
                            style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF4A148C),
                                fontWeight: FontWeight.w500),
                          ),
                        );
                      }).toList(),
                    ),
                  ],

                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF4A148C), Color(0xFF7B1FA2)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Text(
                        context.tr('see_details'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
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

  Widget _priceChip(String amount, String period, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: amount,
              style: TextStyle(
                  color: color, fontSize: 14, fontWeight: FontWeight.bold),
            ),
            TextSpan(
              text: period,
              style:
                  TextStyle(color: color.withValues(alpha: 0.7), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF4A148C), Color(0xFF7B1FA2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(Icons.apartment_rounded, size: 64, color: Colors.white24),
      ),
    );
  }
}

// ── DETAIL SHEET ──────────────────────────────────────────────

class _ResidenceDetail extends StatelessWidget {
  final Map<String, dynamic> data;
  const _ResidenceDetail({required this.data});

  @override
  Widget build(BuildContext context) {
    final title = data['title'] ?? 'Sans titre';
    final address = data['address'] ?? '';
    final priceNight = data['priceNight'] as int?;
    final priceMonth = data['priceMonth'] as int?;
    final type = data['type'] ?? '';
    final description = data['description'] ?? '';
    final photoUrl = data['photoUrl'] as String?;
    final phone = data['phone'] as String?;
    final amenities = (data['amenities'] as List?)?.cast<String>() ?? [];

    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: ListView(
          controller: scrollCtrl,
          children: [
            // Handle
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),

            // Photo
            if (photoUrl != null && photoUrl.isNotEmpty)
              SizedBox(
                height: 230,
                width: double.infinity,
                child: Image.network(photoUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _gradient()),
              )
            else
              SizedBox(height: 200, child: _gradient()),

            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Type badge + Title
                  if (type.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4A148C).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        type,
                        style: const TextStyle(
                            color: Color(0xFF4A148C),
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  Text(
                    title,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.location_on,
                          size: 16, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(address,
                            style: TextStyle(
                                color: Colors.grey.shade600, fontSize: 14)),
                      ),
                    ],
                  ),

                  // Prices
                  const SizedBox(height: 16),
                  if ((priceNight != null && priceNight > 0) ||
                      (priceMonth != null && priceMonth > 0))
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        if (priceNight != null && priceNight > 0)
                          _chip(
                            Icons.nightlight_round,
                            '$priceNight FCFA${context.tr('per_night')}',
                            const Color(0xFF4A148C),
                          ),
                        if (priceMonth != null && priceMonth > 0)
                          _chip(
                            Icons.calendar_month_rounded,
                            '$priceMonth FCFA${context.tr('per_month')}',
                            Colors.orange.shade700,
                          ),
                      ],
                    ),

                  // Amenities
                  if (amenities.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      context.tr('amenities'),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: amenities.map((a) {
                        final icon = _amenityIcon(a);
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF4A148C).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: const Color(0xFF4A148C)
                                    .withValues(alpha: 0.2)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon,
                                  size: 14, color: const Color(0xFF4A148C)),
                              const SizedBox(width: 5),
                              Text(
                                a,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF4A148C),
                                    fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ],

                  // Description
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      context.tr('description'),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      description,
                      style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 14,
                          height: 1.6),
                    ),
                  ],

                  const SizedBox(height: 28),

                  // Contact button
                  GestureDetector(
                    onTap: () async {
                      final number = phone ?? '';
                      if (number.isEmpty) return;
                      final uri = Uri.parse('tel:$number');
                      if (await canLaunchUrl(uri)) launchUrl(uri);
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF4A148C), Color(0xFF7B1FA2)],
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          const Icon(Icons.phone_rounded,
                              color: Colors.white, size: 24),
                          const SizedBox(height: 4),
                          Text(
                            context.tr('contact_residence'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            context.tr('contact_residence_sub'),
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _gradient() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF4A148C), Color(0xFF7B1FA2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(Icons.apartment_rounded, size: 80, color: Colors.white24),
      ),
    );
  }

  IconData _amenityIcon(String amenity) {
    final a = amenity.toLowerCase();
    if (a.contains('wifi') || a.contains('internet')) return Icons.wifi_rounded;
    if (a.contains('clim') || a.contains('ac')) return Icons.ac_unit_rounded;
    if (a.contains('tv') || a.contains('télé')) return Icons.tv_rounded;
    if (a.contains('cuisine') || a.contains('kitchen'))
      return Icons.kitchen_rounded;
    if (a.contains('parking') || a.contains('garage'))
      return Icons.local_parking_rounded;
    if (a.contains('eau') || a.contains('water'))
      return Icons.water_drop_rounded;
    if (a.contains('élec') || a.contains('electric')) return Icons.bolt_rounded;
    if (a.contains('sécur') || a.contains('guard'))
      return Icons.security_rounded;
    if (a.contains('piscine') || a.contains('pool')) return Icons.pool_rounded;
    return Icons.check_circle_outline_rounded;
  }
}

// ── FADE IN ITEM ──────────────────────────────────────────────

class _FadeInItem extends StatefulWidget {
  final int index;
  final Widget child;
  const _FadeInItem({required this.index, required this.child});

  @override
  State<_FadeInItem> createState() => _FadeInItemState();
}

class _FadeInItemState extends State<_FadeInItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350));
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    Future.delayed(Duration(milliseconds: widget.index * 60), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero)
            .animate(_anim),
        child: widget.child,
      ),
    );
  }
}
