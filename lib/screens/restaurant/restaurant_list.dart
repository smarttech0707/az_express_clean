import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';
import 'restaurant_menu.dart';

enum _RestaurantFilter { all, open }

String? restaurantCoverUrl(Map<String, dynamic> data) {
  for (final value in [
    data['coverImageUrl'],
    data['coverUrl'],
    data['imageUrl']
  ]) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  final images = data['images'];
  if (images is Iterable) {
    for (final value in images) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
  }
  return null;
}

class RestaurantList extends StatefulWidget {
  const RestaurantList({super.key});
  @override
  State<RestaurantList> createState() => _RestaurantListState();
}

class _RestaurantListState extends State<RestaurantList> {
  final _searchCtrl = TextEditingController();
  String _search = '';
  _RestaurantFilter _filter = _RestaurantFilter.all;
  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.bg,
        body: CustomScrollView(slivers: [
          SliverToBoxAdapter(child: _header(context)),
          SliverToBoxAdapter(child: _searchBar()),
          SliverToBoxAdapter(child: _filters()),
          SliverToBoxAdapter(child: _promo()),
          _restaurants(),
        ]),
      );

  Widget _header(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      height: top + 174,
      padding: EdgeInsets.fromLTRB(20, top + 18, 20, 24),
      decoration: const BoxDecoration(
          gradient:
              LinearGradient(colors: [AppColors.blueDark, AppColors.blue]),
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(30))),
      child: Stack(children: [
        Positioned(
            right: -30,
            top: -48,
            child: _orb(154, Colors.white.withValues(alpha: .08))),
        Positioned(
            left: 92,
            bottom: -54,
            child: _orb(126, AppColors.primary.withValues(alpha: .20))),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Spacer(),
          Text('Restaurants',
              style: GoogleFonts.urbanist(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          Text('Commandez vos plats préférés',
              style: GoogleFonts.urbanist(
                  color: Colors.white.withValues(alpha: .88),
                  fontSize: 14,
                  fontWeight: FontWeight.w500)),
        ]),
        Positioned(
            top: 0,
            right: 0,
            child: Semantics(
                label: 'Panier',
                child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .16),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.white.withValues(alpha: .3))),
                    child: const Icon(Icons.shopping_bag_outlined,
                        color: Colors.white)))),
      ]),
    );
  }

  Widget _orb(double size, Color color) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle));

  Widget _searchBar() => Transform.translate(
      offset: const Offset(0, -22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Container(
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x1A0F172A),
                    blurRadius: 20,
                    offset: Offset(0, 8))
              ]),
          child: TextField(
              controller: _searchCtrl,
              onChanged: (v) =>
                  setState(() => _search = v.trim().toLowerCase()),
              style: GoogleFonts.urbanist(color: AppColors.text, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Rechercher un restaurant, un plat...',
                hintStyle: GoogleFonts.urbanist(
                    color: AppColors.textLight, fontSize: 13),
                prefixIcon:
                    const Icon(Icons.search_rounded, color: AppColors.blue),
                filled: true,
                fillColor: Colors.white,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 17),
                suffixIcon: _search.isEmpty
                    ? const Icon(Icons.tune_rounded, color: AppColors.textMuted)
                    : IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _search = '');
                        }),
              )),
        ),
      ));

  Widget _filters() => Transform.translate(
      offset: const Offset(0, -14),
      child: SizedBox(
          height: 44,
          child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _Filter(
                    label: 'Tous',
                    icon: Icons.restaurant_menu_rounded,
                    selected: _filter == _RestaurantFilter.all,
                    onTap: () =>
                        setState(() => _filter = _RestaurantFilter.all)),
                const SizedBox(width: 9),
                _Filter(
                    label: 'Ouverts',
                    icon: Icons.schedule_rounded,
                    selected: _filter == _RestaurantFilter.open,
                    onTap: () =>
                        setState(() => _filter = _RestaurantFilter.open)),
              ])));

  Widget _promo() => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
      child: Container(
        padding: const EdgeInsets.all(18),
        constraints: const BoxConstraints(minHeight: 142),
        decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [Color(0xFFFFF4E8), Color(0xFFFFE4C4)]),
            borderRadius: BorderRadius.circular(24)),
        child: Stack(children: [
          Positioned(
              right: -12,
              top: -18,
              child: Icon(Icons.delivery_dining_rounded,
                  size: 118, color: AppColors.primary.withValues(alpha: .15))),
          ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 235),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Livraison rapide 🚀',
                        style: GoogleFonts.urbanist(
                            color: AppColors.primaryDark,
                            fontSize: 13,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text('Vos plats préférés, livrés simplement.',
                        style: GoogleFonts.urbanist(
                            color: AppColors.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 13),
                    FilledButton(
                        onPressed: () =>
                            setState(() => _filter = _RestaurantFilter.open),
                        style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 38),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                        child: Text('Commander maintenant',
                            style: GoogleFonts.urbanist(
                                fontSize: 12, fontWeight: FontWeight.w700))),
                  ])),
        ]),
      ));

  Widget _restaurants() => StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('restaurants')
            .orderBy('name')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverToBoxAdapter(child: _Skeletons()));
          }
          final docs = (snapshot.data?.docs ?? []).where((d) {
            final x = d.data() as Map<String, dynamic>;
            return x['subscriptionStatus'] != 'suspended';
          }).toList()
            ..sort((a, b) => ((b.data() as Map)['vipStatus'] == 'active'
                    ? 1
                    : 0)
                .compareTo((a.data() as Map)['vipStatus'] == 'active' ? 1 : 0));
          final filtered = docs.where((d) {
            final x = d.data() as Map<String, dynamic>;
            final text =
                '${x['name'] ?? ''} ${x['category'] ?? ''}'.toLowerCase();
            return text.contains(_search) &&
                (_filter == _RestaurantFilter.all || x['isOpen'] == true);
          }).toList();
          if (filtered.isEmpty) {
            return SliverFillRemaining(
                hasScrollBody: false,
                child: _Empty(
                    search: _search,
                    openOnly: _filter == _RestaurantFilter.open));
          }
          final fees = filtered
              .map((d) => (d.data() as Map<String, dynamic>)['minDelivery'])
              .whereType<num>()
              .map((e) => e.toInt())
              .toList();
          final min =
              fees.isEmpty ? null : fees.reduce((a, b) => a < b ? a : b);
          return SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
              sliver: SliverMainAxisGroup(slivers: [
                SliverToBoxAdapter(
                    child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  _filter == _RestaurantFilter.open
                                      ? 'Restaurants ouverts'
                                      : 'Restaurants',
                                  style: GoogleFonts.urbanist(
                                      color: AppColors.text,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(height: 3),
                              Text(
                                  min == null
                                      ? 'Choisissez votre restaurant'
                                      : 'Livraison à partir de $min FCFA',
                                  style: GoogleFonts.urbanist(
                                      color: AppColors.textMuted,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500)),
                            ]))),
                SliverList.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final d = filtered[i];
                      final x = d.data() as Map<String, dynamic>;
                      return _Fade(
                          index: i,
                          child: _Card(
                              id: d.id,
                              name: x['name'] as String? ?? 'Restaurant',
                              address: x['address'] as String? ?? '',
                              category:
                                  x['category'] as String? ?? 'Cuisine locale',
                              coverUrl: restaurantCoverUrl(x),
                              logoUrl: x['logoUrl'] as String?,
                              open: x['isOpen'] as bool? ?? true,
                              min: (x['minDelivery'] as num?)?.toInt() ?? 500,
                              vip: x['vipStatus'] == 'active',
                              rating: (x['avgRating'] as num?)?.toDouble(),
                              count: (x['ratingCount'] as num?)?.toInt() ?? 0));
                    }),
              ]));
        },
      );
}

class _Filter extends StatelessWidget {
  const _Filter(
      {required this.label,
      required this.icon,
      required this.selected,
      required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
      color: Colors.transparent,
      child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              decoration: BoxDecoration(
                  color: selected ? AppColors.blue : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: selected ? AppColors.blue : AppColors.border)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon,
                    size: 16,
                    color: selected ? Colors.white : AppColors.textMuted),
                const SizedBox(width: 6),
                Text(label,
                    style: GoogleFonts.urbanist(
                        color: selected ? Colors.white : AppColors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700))
              ]))));
}

class _Card extends StatelessWidget {
  const _Card(
      {required this.id,
      required this.name,
      required this.address,
      required this.category,
      required this.coverUrl,
      required this.logoUrl,
      required this.open,
      required this.min,
      required this.vip,
      required this.rating,
      required this.count});
  final String id, name, address, category;
  final String? coverUrl;
  final String? logoUrl;
  final bool open, vip;
  final int min, count;
  final double? rating;
  @override
  Widget build(BuildContext context) {
    final hasCover = coverUrl?.trim().isNotEmpty == true;
    final hasLogo = logoUrl?.trim().isNotEmpty == true;
    final hasRating = rating != null && rating! > 0 && count > 0;
    return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: open
                  ? () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => RestaurantMenu(
                          restaurantId: id, restaurantName: name)))
                  : null,
              child: Ink(
                  decoration: BoxDecoration(
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x100F172A),
                            blurRadius: 18,
                            offset: Offset(0, 7))
                      ]),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                            height: 146,
                            width: double.infinity,
                            child: Stack(fit: StackFit.expand, children: [
                              hasCover
                                  ? CachedNetworkImage(
                                      imageUrl: coverUrl!,
                                      fit: BoxFit.cover,
                                      placeholder: (_, __) =>
                                          _RestaurantCoverFallback(
                                              name: name,
                                              logoUrl:
                                                  hasLogo ? logoUrl : null),
                                      errorWidget: (_, __, ___) =>
                                          _RestaurantCoverFallback(
                                              name: name,
                                              logoUrl:
                                                  hasLogo ? logoUrl : null))
                                  : _RestaurantCoverFallback(
                                      name: name,
                                      logoUrl: hasLogo ? logoUrl : null),
                              if (hasCover && hasLogo)
                                Positioned(
                                    left: 14,
                                    bottom: 14,
                                    child: _RestaurantLogo(url: logoUrl!)),
                              Positioned(
                                  top: 12,
                                  right: 12,
                                  child: _Status(open: open)),
                              if (vip)
                                Positioned(
                                    top: 12,
                                    left: 12,
                                    child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 9, vertical: 5),
                                        decoration: BoxDecoration(
                                            color: Colors.white
                                                .withValues(alpha: .92),
                                            borderRadius:
                                                BorderRadius.circular(20)),
                                        child: Text('VIP',
                                            style: GoogleFonts.urbanist(
                                                color: AppColors.primaryDark,
                                                fontWeight: FontWeight.w800,
                                                fontSize: 11)))),
                            ])),
                        Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.urbanist(
                                          color: AppColors.text,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 18)),
                                  const SizedBox(height: 5),
                                  Text(category,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.urbanist(
                                          color: AppColors.blue,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12)),
                                  if (address.trim().isNotEmpty) ...[
                                    const SizedBox(height: 7),
                                    Row(children: [
                                      const Icon(Icons.location_on_outlined,
                                          color: AppColors.textLight, size: 16),
                                      const SizedBox(width: 5),
                                      Expanded(
                                          child: Text(address,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: GoogleFonts.urbanist(
                                                  color: AppColors.textMuted,
                                                  fontSize: 12)))
                                    ])
                                  ],
                                  const SizedBox(height: 12),
                                  Wrap(spacing: 12, runSpacing: 8, children: [
                                    if (hasRating)
                                      _Tag(
                                          icon: Icons.star_rounded,
                                          color: const Color(0xFFF59E0B),
                                          label:
                                              '${rating!.toStringAsFixed(1)} ($count avis)'),
                                    _Tag(
                                        icon: Icons.delivery_dining_rounded,
                                        color: AppColors.primary,
                                        label: 'Livraison min : $min FCFA')
                                  ]),
                                ])),
                      ])),
            )));
  }
}

class _RestaurantCoverFallback extends StatelessWidget {
  const _RestaurantCoverFallback({required this.name, this.logoUrl});
  final String name;
  final String? logoUrl;
  @override
  Widget build(BuildContext context) => DecoratedBox(
      decoration: const BoxDecoration(
          gradient: LinearGradient(
              colors: [AppColors.blueDark, AppColors.blue],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight)),
      child: Stack(children: [
        Positioned(
            right: -12,
            top: -28,
            child: Icon(Icons.restaurant_rounded,
                size: 132, color: Colors.white.withValues(alpha: 0.10))),
        Align(
            alignment: Alignment.center,
            child: logoUrl == null
                ? _RestaurantInitial(name: name)
                : _RestaurantLogo(url: logoUrl!)),
        Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.urbanist(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800))),
      ]));
}

class _RestaurantLogo extends StatelessWidget {
  const _RestaurantLogo({required this.url});
  final String url;
  @override
  Widget build(BuildContext context) => Container(
      width: 58,
      height: 58,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(color: Color(0x33000000), blurRadius: 10)
          ]),
      child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) =>
              const Icon(Icons.restaurant_rounded, color: AppColors.blue)));
}

class _RestaurantInitial extends StatelessWidget {
  const _RestaurantInitial({required this.name});
  final String name;
  @override
  Widget build(BuildContext context) => Container(
      width: 58,
      height: 58,
      alignment: Alignment.center,
      decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.38))),
      child: Text(name.trim().isEmpty ? 'R' : name.trim()[0].toUpperCase(),
          style: GoogleFonts.urbanist(
              color: Colors.white, fontSize: 25, fontWeight: FontWeight.w800)));
}

class _Status extends StatelessWidget {
  const _Status({required this.open});
  final bool open;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: open ? AppColors.success : AppColors.error,
          borderRadius: BorderRadius.circular(20)),
      child: Text(open ? 'Ouvert' : 'Fermé',
          style: GoogleFonts.urbanist(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)));
}

class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.color, required this.label});
  final IconData icon;
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: GoogleFonts.urbanist(
                color: AppColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600))
      ]);
}

class _Empty extends StatelessWidget {
  const _Empty({required this.search, required this.openOnly});
  final String search;
  final bool openOnly;
  @override
  Widget build(BuildContext context) => Center(
      child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 76,
                height: 76,
                decoration: const BoxDecoration(
                    color: AppColors.primaryBg, shape: BoxShape.circle),
                child: const Icon(Icons.restaurant_outlined,
                    color: AppColors.primary, size: 36)),
            const SizedBox(height: 16),
            Text(
                openOnly
                    ? 'Aucun restaurant ouvert pour le moment'
                    : search.isEmpty
                        ? 'Aucun restaurant disponible'
                        : 'Aucun résultat pour "$search"',
                textAlign: TextAlign.center,
                style: GoogleFonts.urbanist(
                    color: AppColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700))
          ])));
}

class _Skeletons extends StatelessWidget {
  const _Skeletons();
  @override
  Widget build(BuildContext context) => Column(
      children: List.generate(
          3,
          (_) => Container(
              height: 220,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(22)),
              child: const _Pulse())));
}

class _Pulse extends StatefulWidget {
  const _Pulse();
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Opacity(
          opacity: .48 + _c.value * .30,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(height: 118, color: AppColors.border),
            Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                          height: 16, width: 150, color: AppColors.border),
                      const SizedBox(height: 10),
                      Container(
                          height: 12, width: 100, color: AppColors.border),
                      const SizedBox(height: 14),
                      Container(height: 12, width: 180, color: AppColors.border)
                    ]))
          ])));
}

class _Fade extends StatefulWidget {
  const _Fade({required this.index, required this.child});
  final int index;
  final Widget child;
  @override
  State<_Fade> createState() => _FadeState();
}

class _FadeState extends State<_Fade> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 300));
  @override
  void initState() {
    super.initState();
    Future<void>.delayed(
        Duration(milliseconds: widget.index.clamp(0, 6).toInt() * 50), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
      opacity: CurvedAnimation(parent: _c, curve: Curves.easeOut),
      child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, .06), end: Offset.zero)
              .animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic)),
          child: widget.child));
}
