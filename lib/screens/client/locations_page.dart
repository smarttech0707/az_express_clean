import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_text.dart';

class LocationsPage extends StatefulWidget {
  const LocationsPage({super.key});

  @override
  State<LocationsPage> createState() => _LocationsPageState();
}

class _LocationsPageState extends State<LocationsPage> {
  final _searchCtrl = TextEditingController();
  String _search = '';

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
          // ── HEADER ───────────────────────────────────────
          SliverAppBar(
            expandedHeight:
                (MediaQuery.of(context).size.height * 0.20).clamp(140.0, 220.0),
            floating: false,
            pinned: true,
            backgroundColor: const Color(0xFF00695C),
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF004D40), Color(0xFF00897B)],
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
                          context.tr('houses_title'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          context.tr('find_home'),
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: Text(context.tr('houses_title'),
                style: const TextStyle(color: Colors.white, fontSize: 18)),
            centerTitle: true,
          ),

          // ── SEARCH ───────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) =>
                    setState(() => _search = v.toLowerCase()),
                decoration: InputDecoration(
                  hintText: context.tr('search_house'),
                  prefixIcon:
                      const Icon(Icons.search, color: Color(0xFF00695C)),
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
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 14),
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

          // ── LIST ─────────────────────────────────────────
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection("locations")
                .where("isAvailable", isEqualTo: true)
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              final docs = snap.data?.docs ?? [];
              final filtered = _search.isEmpty
                  ? docs
                  : docs.where((d) {
                      final data = d.data() as Map;
                      final title =
                          (data["title"] ?? "").toLowerCase();
                      final address =
                          (data["address"] ?? "").toLowerCase();
                      return title.contains(_search) ||
                          address.contains(_search);
                    }).toList();

              if (filtered.isEmpty) {
                return SliverFillRemaining(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.home_outlined,
                          size: 72, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text(
                        _search.isEmpty
                            ? context.tr('no_house')
                            : "${context.tr('no_result_for')} \"$_search\"",
                        style: const TextStyle(
                            fontSize: 16, color: Colors.grey),
                      ),
                    ],
                  ),
                );
              }

              return SliverPadding(
                padding:
                    const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final doc = filtered[i];
                      final data =
                          doc.data() as Map<String, dynamic>;
                      return _FadeInItem(
                        index: i,
                        child: _LocationCard(
                          data: data,
                          onTap: () =>
                              _showDetail(context, data),
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

  void _showDetail(
      BuildContext context, Map<String, dynamic> data) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LocationDetail(data: data),
    );
  }
}

// ── CARTE CLIENT ──────────────────────────────────────────────

class _LocationCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  const _LocationCard({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final title = data["title"] ?? "Sans titre";
    final address = data["address"] ?? "";
    final price = data["price"] ?? 0;
    final rooms = data["rooms"] ?? 1;
    final photoUrl = data["photoUrl"] as String?;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
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
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20)),
              child: SizedBox(
                height: 180,
                width: double.infinity,
                child: photoUrl != null && photoUrl.isNotEmpty
                    ? Image.network(photoUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            _placeholder())
                    : _placeholder(),
              ),
            ),

            // Infos
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.location_on,
                          size: 14,
                          color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          address,
                          style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00695C)
                              .withValues(alpha: 0.1),
                          borderRadius:
                              BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.bed_rounded,
                                size: 14,
                                color: Color(0xFF00695C)),
                            const SizedBox(width: 4),
                            Text(
                              "$rooms ${context.tr('rooms_label')}${rooms > 1 ? 's' : ''}",
                              style: const TextStyle(
                                color: Color(0xFF00695C),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Text(
                        "$price FCFA",
                        style: const TextStyle(
                          color: Color(0xFF00695C),
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        context.tr('per_month'),
                        style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00695C),
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

  Widget _placeholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF004D40), Color(0xFF00897B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(Icons.home_rounded,
            size: 64, color: Colors.white38),
      ),
    );
  }
}

// ── FICHE DÉTAIL ──────────────────────────────────────────────

class _LocationDetail extends StatelessWidget {
  final Map<String, dynamic> data;
  const _LocationDetail({required this.data});

  @override
  Widget build(BuildContext context) {
    final title = data["title"] ?? "Sans titre";
    final address = data["address"] ?? "";
    final price = data["price"] ?? 0;
    final rooms = data["rooms"] ?? 1;
    final description = data["description"] ?? "";
    final photoUrl = data["photoUrl"] as String?;
    final phone = data["phone"] as String?;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(24)),
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
              ClipRRect(
                borderRadius: BorderRadius.zero,
                child: SizedBox(
                  height: 220,
                  width: double.infinity,
                  child: Image.network(photoUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          _buildGradient()),
                ),
              )
            else
              SizedBox(height: 180, child: _buildGradient()),

            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.location_on,
                          size: 16,
                          color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(address,
                            style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 14)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _infoChip(
                          Icons.bed_rounded,
                          "$rooms ${context.tr('rooms_label')}${rooms > 1 ? 's' : ''}",
                          const Color(0xFF00695C)),
                      const SizedBox(width: 10),
                      _infoChip(Icons.payments_rounded,
                          "$price FCFA${context.tr('per_month')}",
                          Colors.orange.shade700),
                    ],
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      context.tr('description'),
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
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
                  GestureDetector(
                    onTap: () async {
                      final number = phone ?? '';
                      if (number.isEmpty) return;
                      final uri = Uri.parse('tel:$number');
                      if (await canLaunchUrl(uri)) launchUrl(uri);
                    },
                    child: Container(
                      width: double.infinity,
                      padding:
                          const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xFF004D40),
                            Color(0xFF00897B)
                          ],
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          const Icon(Icons.phone_rounded,
                              color: Colors.white, size: 24),
                          const SizedBox(height: 4),
                          Text(
                            context.tr('contact_visit'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            (phone == null || phone.isEmpty)
                                ? context.tr('contact_owner')
                                : phone,
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

  Widget _infoChip(IconData icon, String label, Color color) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildGradient() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF004D40), Color(0xFF00897B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(Icons.home_rounded,
            size: 80, color: Colors.white24),
      ),
    );
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
        vsync: this,
        duration: const Duration(milliseconds: 350));
    _anim =
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    Future.delayed(
        Duration(milliseconds: widget.index * 60), () {
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
        position: Tween<Offset>(
          begin: const Offset(0, 0.15),
          end: Offset.zero,
        ).animate(_anim),
        child: widget.child,
      ),
    );
  }
}
