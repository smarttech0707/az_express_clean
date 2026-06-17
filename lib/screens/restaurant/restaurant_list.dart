import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'restaurant_menu.dart';

class RestaurantList extends StatefulWidget {
  const RestaurantList({super.key});

  @override
  State<RestaurantList> createState() => _RestaurantListState();
}

class _RestaurantListState extends State<RestaurantList> {
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
          // ── HEADER GRADIENT ──────────────────────────────
          SliverAppBar(
            expandedHeight: (MediaQuery.of(context).size.height * 0.20).clamp(140.0, 220.0),
            floating: false,
            pinned: true,
            backgroundColor: const Color(0xFF1565C0),
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF1565C0), Color(0xFF1E88E5)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const SafeArea(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(height: 44),
                        Text(
                          "Restaurants",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          "Commandez vos plats préférés",
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: const Text("Restaurants",
                style: TextStyle(color: Colors.white, fontSize: 18)),
            centerTitle: true,
          ),

          // ── SEARCH BAR ──────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _search = v.toLowerCase()),
                decoration: InputDecoration(
                  hintText: "Chercher un restaurant...",
                  prefixIcon: const Icon(Icons.search, color: Color(0xFF1565C0)),
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

          // ── RESTAURANT LIST ─────────────────────────────
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection("restaurants")
                .orderBy("name")
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              final rawDocs = snapshot.data?.docs ?? [];

              // Filter out suspended restaurants
              final docs = rawDocs.where((d) {
                final data = d.data() as Map<String, dynamic>;
                return data['subscriptionStatus'] != 'suspended';
              }).toList();

              // Sort: VIP first
              docs.sort((a, b) {
                final aVip = (a.data() as Map)['vipStatus'] == 'active';
                final bVip = (b.data() as Map)['vipStatus'] == 'active';
                if (aVip && !bVip) return -1;
                if (!aVip && bVip) return 1;
                return 0;
              });

              final filtered = _search.isEmpty
                  ? docs
                  : docs.where((d) {
                      final name =
                          ((d.data() as Map)["name"] ?? "").toLowerCase();
                      return name.contains(_search);
                    }).toList();

              if (filtered.isEmpty) {
                return SliverFillRemaining(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.restaurant_outlined,
                          size: 72, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text(
                        _search.isEmpty
                            ? "Aucun restaurant disponible"
                            : "Aucun résultat pour \"$_search\"",
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
                      final doc = filtered[i];
                      final data = doc.data() as Map<String, dynamic>;
                      return _FadeInItem(
                        index: i,
                        child: _RestaurantCard(
                          id: doc.id,
                          name: data["name"] ?? "Restaurant",
                          address: data["address"] ?? "",
                          category: data["category"] ?? "Cuisine locale",
                          isOpen: data["isOpen"] ?? true,
                          minDelivery: data["minDelivery"] ?? 500,
                          isVip: data["vipStatus"] == "active",
                          avgRating: (data["avgRating"] as num?)?.toDouble(),
                          ratingCount: (data["ratingCount"] as num?)?.toInt() ?? 0,
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
}

class _RestaurantCard extends StatelessWidget {
  final String id;
  final String name;
  final String address;
  final String category;
  final bool isOpen;
  final int minDelivery;
  final bool isVip;
  final double? avgRating;
  final int ratingCount;

  const _RestaurantCard({
    required this.id,
    required this.name,
    required this.address,
    required this.category,
    required this.isOpen,
    required this.minDelivery,
    this.isVip = false,
    this.avgRating,
    this.ratingCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isOpen
          ? () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      RestaurantMenu(restaurantId: id, restaurantName: name),
                ),
              )
          : null,
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
            // Image placeholder avec gradient
            Container(
              height: 130,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isOpen
                      ? [const Color(0xFF1565C0), const Color(0xFF42A5F5)]
                      : [Colors.grey.shade400, Colors.grey.shade300],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Icon(
                      Icons.restaurant,
                      size: 60,
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ),
                  // Badge ouvert/fermé
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: isOpen ? Colors.green : Colors.red.shade400,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        isOpen ? "Ouvert" : "Fermé",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  // VIP badge
                  if (isVip)
                    Positioned(
                      top: 12,
                      left: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFD700),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text('👑 VIP',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: Colors.black87)),
                      ),
                    ),
                ],
              ),
            ),

            // Infos
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 17,
                          ),
                        ),
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 110),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1565C0).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            category,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF1565C0),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
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
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.delivery_dining,
                          size: 14, color: Colors.orange.shade600),
                      const SizedBox(width: 4),
                      Text(
                        "Livraison min : $minDelivery FCFA",
                        style: TextStyle(
                            color: Colors.orange.shade700,
                            fontSize: 12,
                            fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                  if (avgRating != null && avgRating! > 0) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        ...List.generate(
                          5,
                          (i) => Icon(
                            i < avgRating!.round()
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                            color: Colors.amber,
                            size: 14,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          "${avgRating!.toStringAsFixed(1)}  ($ratingCount avis)",
                          style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
        position: Tween<Offset>(
          begin: const Offset(0, 0.15),
          end: Offset.zero,
        ).animate(_anim),
        child: widget.child,
      ),
    );
  }
}