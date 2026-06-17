import 'dart:async';
import '../../widgets/scale_button.dart';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_text.dart';
import '../../models/service_provider_model.dart';

// ═══════════════════════════════════════════════════════════════════════════
// ENUMS
// ═══════════════════════════════════════════════════════════════════════════

enum _SortBy { distance, rating, name }

// ═══════════════════════════════════════════════════════════════════════════
// PAGE PRINCIPALE
// ═══════════════════════════════════════════════════════════════════════════

class ServiceProvidersPage extends StatefulWidget {
  final String subcategory;
  final String title;
  final Color color;
  final List<Color> gradient;
  final IconData icon;

  const ServiceProvidersPage({
    super.key,
    required this.subcategory,
    required this.title,
    required this.color,
    required this.gradient,
    required this.icon,
  });

  @override
  State<ServiceProvidersPage> createState() => _ServiceProvidersPageState();
}

class _ServiceProvidersPageState extends State<ServiceProvidersPage> {
  final _searchCtrl = TextEditingController();
  String   _search     = '';
  _SortBy  _sortBy     = _SortBy.distance;
  double?  _userLat;
  double?  _userLng;
  Set<String> _favorites = {};

  // Filtres
  double _minRating    = 0;
  bool   _gpsOnly      = false;
  bool   _availableOnly = true;

  final String? _uid = FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _loadUserPosition();
    _loadFavorites();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Géolocalisation ────────────────────────────────────────────────────────
  Future<void> _loadUserPosition() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy:  LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
      if (mounted) {
        setState(() {
          _userLat = pos.latitude;
          _userLng = pos.longitude;
        });
      }
    } catch (_) {}
  }

  double? _distanceTo(ServiceProvider p) {
    if (_userLat == null || _userLng == null) return null;
    if (!p.hasGps) return null;
    return _calcDistance(_userLat!, _userLng!, p.lat, p.lng);
  }

  double _calcDistance(double lat1, double lng1, double lat2, double lng2) {
    const r   = 6371.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) *
            sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  // ── Favoris ────────────────────────────────────────────────────────────────
  Future<void> _loadFavorites() async {
    if (_uid == null) return;
    final snap = await FirebaseFirestore.instance
        .collection('clients')
        .doc(_uid)
        .collection('favorite_providers')
        .get();
    if (mounted) {
      setState(() => _favorites = snap.docs.map((d) => d.id).toSet());
    }
  }

  Future<void> _toggleFavorite(String providerId) async {
    if (_uid == null) return;
    final ref = FirebaseFirestore.instance
        .collection('clients')
        .doc(_uid)
        .collection('favorite_providers')
        .doc(providerId);

    if (_favorites.contains(providerId)) {
      await ref.delete();
      setState(() => _favorites.remove(providerId));
    } else {
      await ref.set({'addedAt': FieldValue.serverTimestamp()});
      setState(() => _favorites.add(providerId));
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────────
  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:${phone.replaceAll(RegExp(r'[\s\-()]'), '')}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _whatsapp(String phone, String name) async {
    var p = phone.replaceAll(RegExp(r'[\s\-()]'), '');
    if (p.startsWith('0')) p = p.substring(1);
    if (!p.startsWith('225')) p = '225$p';
    final msg = Uri.encodeComponent(
        'Bonjour $name, je vous contacte via AZ Express.');
    final uri = Uri.parse('https://wa.me/$p?text=$msg');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _openMaps(double lat, double lng) async {
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ── Traitement des données ─────────────────────────────────────────────────
  List<ServiceProvider> _process(List<DocumentSnapshot> docs) {
    final list = docs
        .where((d) {
          final data = d.data() as Map<String, dynamic>?;
          final status = data?['status'] as String?;
          // Hide pending and rejected self-registrations; show admin-created (no status)
          return status == null || status == 'approved';
        })
        .map((d) {
          final p = ServiceProvider.fromFirestore(d);
          p.distanceKm = _distanceTo(p);
          return p;
        })
        .toList();

    // Filtres
    final filtered = list.where((p) {
      if (_availableOnly && !p.isAvailable) return false;
      if (_minRating > 0 && p.rating < _minRating) return false;
      if (_gpsOnly   && !p.hasGps) return false;
      if (_search.isNotEmpty) {
        final q = _search.toLowerCase();
        if (!p.name.toLowerCase().contains(q) &&
            !p.address.toLowerCase().contains(q) &&
            !p.description.toLowerCase().contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();

    // Tri
    filtered.sort((a, b) {
      switch (_sortBy) {
        case _SortBy.distance:
          final da = a.distanceKm ?? 999999;
          final db = b.distanceKm ?? 999999;
          return da.compareTo(db);
        case _SortBy.rating:
          return b.rating.compareTo(a.rating);
        case _SortBy.name:
          return a.name.compareTo(b.name);
      }
    });

    return filtered;
  }

  // ── BUILD ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F3F7),
      body: CustomScrollView(
        slivers: [
          // ── APP BAR ──────────────────────────────────────────────────────
          SliverAppBar(
            expandedHeight:
                (MediaQuery.of(context).size.height * 0.20).clamp(140.0, 200.0),
            pinned: true,
            backgroundColor: widget.color,
            foregroundColor: Colors.white,
            elevation: 0,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: widget.gradient,
                    begin:  Alignment.topLeft,
                    end:    Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(widget.icon,
                                color: Colors.white70, size: 26),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                widget.title,
                                style: GoogleFonts.inter(
                                  color:      Colors.white,
                                  fontSize:   20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          context.tr('providers_in'),
                          style: GoogleFonts.inter(
                              color: Colors.white70, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: Text(
              widget.title,
              style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
            centerTitle: true,
            actions: [
              IconButton(
                icon: const Icon(Icons.tune_rounded),
                tooltip: 'Filtres',
                onPressed: _showFilters,
              ),
            ],
          ),

          // ── SEARCH + TRI ──────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Column(
                children: [
                  // Barre de recherche
                  Container(
                    decoration: BoxDecoration(
                      color:        Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color:      Colors.black.withValues(alpha: 0.06),
                          blurRadius: 8,
                          offset:     const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged:  (v) => setState(() => _search = v),
                      style:      GoogleFonts.inter(fontSize: 13.5),
                      decoration: InputDecoration(
                        hintText:  context.tr('search_provider'),
                        hintStyle: GoogleFonts.inter(
                            fontSize: 13.5, color: Colors.grey),
                        prefixIcon: Icon(Icons.search_rounded,
                            color: widget.color, size: 20),
                        suffixIcon: _search.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _search = '');
                                },
                              )
                            : null,
                        border:         InputBorder.none,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // Chips de tri
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _SortChip(
                          label: 'Distance',
                          icon:  Icons.near_me_rounded,
                          active: _sortBy == _SortBy.distance,
                          color:  widget.color,
                          onTap: () =>
                              setState(() => _sortBy = _SortBy.distance),
                        ),
                        const SizedBox(width: 8),
                        _SortChip(
                          label: 'Note',
                          icon:  Icons.star_rounded,
                          active: _sortBy == _SortBy.rating,
                          color:  widget.color,
                          onTap: () =>
                              setState(() => _sortBy = _SortBy.rating),
                        ),
                        const SizedBox(width: 8),
                        _SortChip(
                          label: 'Nom A-Z',
                          icon:  Icons.sort_by_alpha_rounded,
                          active: _sortBy == _SortBy.name,
                          color:  widget.color,
                          onTap: () =>
                              setState(() => _sortBy = _SortBy.name),
                        ),
                        if (_minRating > 0 || _gpsOnly) ...[
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () => setState(() {
                              _minRating = 0;
                              _gpsOnly   = false;
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color:        Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(20),
                                border:       Border.all(
                                    color: Colors.orange.shade300),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.filter_list_off_rounded,
                                      size: 14,
                                      color: Colors.orange.shade700),
                                  const SizedBox(width: 4),
                                  Text('Effacer filtres',
                                      style: GoogleFonts.inter(
                                          fontSize: 11.5,
                                          color:     Colors.orange.shade700,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── LISTE DES PRESTATAIRES ────────────────────────────────────────
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('service_providers')
                .where('subcategory', isEqualTo: widget.subcategory)
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const SliverFillRemaining(
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                );
              }

              final docs = snap.data?.docs ?? [];
              final providers = _process(docs);

              if (providers.isEmpty) {
                return SliverFillRemaining(
                  child: _EmptyState(
                    icon:   widget.icon,
                    search: _search,
                  ),
                );
              }

              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      final p = providers[i];
                      return _ProviderCard(
                        provider:    p,
                        color:       widget.color,
                        gradient:    widget.gradient,
                        isFavorite:  _favorites.contains(p.id),
                        onFavorite:  () => _toggleFavorite(p.id),
                        onCall:      () => _call(p.phone),
                        onWhatsApp:  () => _whatsapp(p.phone, p.name),
                        onGps:       () => _openMaps(p.lat, p.lng),
                        onTap:       () => _showDetail(ctx, p),
                      );
                    },
                    childCount: providers.length,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Feuille de filtres ─────────────────────────────────────────────────────
  void _showFilters() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _FilterSheet(
        color:        widget.color,
        minRating:    _minRating,
        gpsOnly:      _gpsOnly,
        availableOnly: _availableOnly,
        onApply: (minR, gps, avail) {
          setState(() {
            _minRating     = minR;
            _gpsOnly       = gps;
            _availableOnly = avail;
          });
        },
      ),
    );
  }

  // ── Détail prestataire ─────────────────────────────────────────────────────
  void _showDetail(BuildContext context, ServiceProvider p) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ProviderDetailPage(
          provider:   p,
          color:      widget.color,
          gradient:   widget.gradient,
          icon:       widget.icon,
          isFavorite: _favorites.contains(p.id),
          onFavorite: () => _toggleFavorite(p.id),
          onCall:     () => _call(p.phone),
          onWhatsApp: () => _whatsapp(p.phone, p.name),
          onGps:      () => _openMaps(p.lat, p.lng),
          onRate:     (r, c) => _submitReview(p, r, c),
        ),
      ),
    );
  }

  // ── Soumettre un avis ──────────────────────────────────────────────────────
  Future<void> _submitReview(
      ServiceProvider p, double rating, String comment) async {
    if (_uid == null) return;
    final db = FirebaseFirestore.instance;

    // Vérifier si déjà noté
    final existing = await db
        .collection('service_reviews')
        .where('providerId', isEqualTo: p.id)
        .where('clientId', isEqualTo: _uid)
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Vous avez déjà noté ce prestataire.'),
          backgroundColor: Colors.orange,
        ));
      }
      return;
    }

    // Ajouter l'avis
    await db.collection('service_reviews').add({
      'providerId':  p.id,
      'clientId':    _uid,
      'rating':      rating,
      'comment':     comment,
      'createdAt':   FieldValue.serverTimestamp(),
    });

    // Mettre à jour la moyenne (transaction atomique)
    await db.runTransaction((tx) async {
      final ref  = db.collection('service_providers').doc(p.id);
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final d    = snap.data()!;
      final cnt  = ((d['ratingCount'] as num?)?.toInt() ?? 0) + 1;
      final avg  = ((d['rating']      as num?)?.toDouble() ?? 0) *
              (cnt - 1) / cnt +
          rating / cnt;
      tx.update(ref, {
        'rating':      double.parse(avg.toStringAsFixed(1)),
        'ratingCount': cnt,
      });
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Merci pour votre avis !'),
        backgroundColor: widget.color,
      ));
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CHIP DE TRI
// ═══════════════════════════════════════════════════════════════════════════

class _SortChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final Color color;
  final VoidCallback onTap;
  const _SortChip({
    required this.label,
    required this.icon,
    required this.active,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color:        active ? color : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border:       Border.all(
              color: active ? color : Colors.grey.shade300),
          boxShadow: active
              ? [BoxShadow(
                  color:      color.withValues(alpha: 0.3),
                  blurRadius: 6,
                  offset:     const Offset(0, 2))]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size:  14,
                color: active ? Colors.white : Colors.grey.shade600),
            const SizedBox(width: 5),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize:   12,
                fontWeight: FontWeight.w600,
                color:      active ? Colors.white : Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CARTE PRESTATAIRE
// ═══════════════════════════════════════════════════════════════════════════

class _ProviderCard extends StatelessWidget {
  final ServiceProvider provider;
  final Color color;
  final List<Color> gradient;
  final bool isFavorite;
  final VoidCallback onFavorite;
  final VoidCallback onCall;
  final VoidCallback onWhatsApp;
  final VoidCallback onGps;
  final VoidCallback onTap;

  const _ProviderCard({
    required this.provider,
    required this.color,
    required this.gradient,
    required this.isFavorite,
    required this.onFavorite,
    required this.onCall,
    required this.onWhatsApp,
    required this.onGps,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = provider;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color:      Colors.black.withValues(alpha: 0.07),
              blurRadius: 12,
              offset:     const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Photo ──────────────────────────────────────────────────────
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20)),
              child: Stack(
                children: [
                  SizedBox(
                    height: 150,
                    width:  double.infinity,
                    child:  p.photos.isNotEmpty
                        ? Image.network(
                            p.photos.first,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                _GradientPlaceholder(
                                  gradient: gradient,
                                  icon: Icons.storefront_rounded,
                                ),
                          )
                        : _GradientPlaceholder(
                            gradient: gradient,
                            icon: Icons.storefront_rounded,
                          ),
                  ),

                  // Badge favori
                  Positioned(
                    top: 10, right: 10,
                    child: GestureDetector(
                      onTap: onFavorite,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 36, height: 36,
                        decoration: BoxDecoration(
                          color: isFavorite
                              ? Colors.red
                              : Colors.black.withValues(alpha: 0.35),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ),

                  // Badge vérifié
                  if (p.isVerified)
                    Positioned(
                      top: 10, left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color:        Colors.green.shade600,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.verified_rounded,
                                color: Colors.white, size: 11),
                            const SizedBox(width: 3),
                            Text('Vérifié',
                                style: GoogleFonts.inter(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),

                  // Distance
                  if (p.distanceStr.isNotEmpty)
                    Positioned(
                      bottom: 8, left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color:        Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.near_me_rounded,
                                color: Colors.white, size: 11),
                            const SizedBox(width: 3),
                            Text(p.distanceStr,
                                style: GoogleFonts.inter(
                                    color: Colors.white,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // ── Infos ───────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          p.name,
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.bold,
                            fontSize:   15,
                            color:      Colors.black87,
                          ),
                        ),
                      ),

                      // Note
                      if (p.ratingCount > 0) ...[
                        const SizedBox(width: 8),
                        _RatingBadge(
                            rating: p.rating, count: p.ratingCount),
                      ],
                    ],
                  ),

                  if (p.address.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Icon(Icons.location_on_rounded,
                            size: 12, color: Colors.grey.shade500),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            p.address,
                            style: GoogleFonts.inter(
                                color: Colors.grey.shade600, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],

                  if (p.description.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      p.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          color:  Colors.grey.shade600,
                          fontSize: 12,
                          height: 1.4),
                    ),
                  ],

                  const SizedBox(height: 12),

                  // ── Boutons ──────────────────────────────────────────────
                  Row(
                    children: [
                      if (p.phone.isNotEmpty) ...[
                        Expanded(
                          child: _ActionBtn(
                            label: context.tr('call'),
                            icon:  Icons.phone_rounded,
                            color: Colors.green,
                            onTap: onCall,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ActionBtn(
                            label: 'WhatsApp',
                            icon:  Icons.chat_rounded,
                            color: const Color(0xFF25D366),
                            onTap: onWhatsApp,
                          ),
                        ),
                      ],
                      if (p.hasGps) ...[
                        if (p.phone.isNotEmpty) const SizedBox(width: 8),
                        Expanded(
                          child: _ActionBtn(
                            label: context.tr('get_directions'),
                            icon:  Icons.navigation_rounded,
                            color: color,
                            onTap: onGps,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PAGE DÉTAIL PRESTATAIRE
// ═══════════════════════════════════════════════════════════════════════════

class _ProviderDetailPage extends StatefulWidget {
  final ServiceProvider provider;
  final Color color;
  final List<Color> gradient;
  final IconData icon;
  final bool isFavorite;
  final VoidCallback onFavorite;
  final VoidCallback onCall;
  final VoidCallback onWhatsApp;
  final VoidCallback onGps;
  final Future<void> Function(double rating, String comment) onRate;

  const _ProviderDetailPage({
    required this.provider,
    required this.color,
    required this.gradient,
    required this.icon,
    required this.isFavorite,
    required this.onFavorite,
    required this.onCall,
    required this.onWhatsApp,
    required this.onGps,
    required this.onRate,
  });

  @override
  State<_ProviderDetailPage> createState() => _ProviderDetailPageState();
}

class _ProviderDetailPageState extends State<_ProviderDetailPage> {
  int    _photoIndex = 0;
  bool   _isFav     = false;

  @override
  void initState() {
    super.initState();
    _isFav = widget.isFavorite;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    return Scaffold(
      backgroundColor: const Color(0xFFF2F3F7),
      body: CustomScrollView(
        slivers: [
          // ── Hero photo ────────────────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            backgroundColor: widget.color,
            foregroundColor: Colors.white,
            elevation: 0,
            actions: [
              IconButton(
                icon: Icon(
                  _isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  color: _isFav ? Colors.red.shade300 : Colors.white,
                ),
                onPressed: () {
                  setState(() => _isFav = !_isFav);
                  widget.onFavorite();
                },
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (p.photos.isNotEmpty)
                    PageView.builder(
                      itemCount: p.photos.length,
                      onPageChanged: (i) =>
                          setState(() => _photoIndex = i),
                      itemBuilder: (_, i) => Image.network(
                        p.photos[i],
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _GradientPlaceholder(
                          gradient: widget.gradient,
                          icon: widget.icon,
                        ),
                      ),
                    )
                  else
                    _GradientPlaceholder(
                      gradient: widget.gradient,
                      icon: widget.icon,
                    ),

                  if (p.photos.length > 1)
                    Positioned(
                      bottom: 12,
                      left:   0,
                      right:  0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(p.photos.length, (i) =>
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width:  i == _photoIndex ? 18 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: i == _photoIndex
                                  ? Colors.white
                                  : Colors.white54,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // ── Infos ─────────────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.name,
                              style: GoogleFonts.inter(
                                fontSize:   22,
                                fontWeight: FontWeight.bold,
                                color:      Colors.black87,
                              ),
                            ),
                            if (p.address.isNotEmpty) ...[
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  Icon(Icons.location_on_rounded,
                                      size: 14,
                                      color: Colors.grey.shade500),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: Text(
                                      p.address,
                                      style: GoogleFonts.inter(
                                          color:    Colors.grey.shade600,
                                          fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),

                      // Note
                      if (p.ratingCount > 0)
                        Column(
                          children: [
                            _RatingBadge(
                                rating: p.rating, count: p.ratingCount),
                            const SizedBox(height: 4),
                            Text(
                              '${p.ratingCount} avis',
                              style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: Colors.grey.shade500),
                            ),
                          ],
                        ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Boutons d'action
                  if (p.phone.isNotEmpty) ...[
                    Row(children: [
                      Expanded(
                        child: _BigActionBtn(
                          label:    context.tr('call'),
                          subtitle: p.phone,
                          icon:     Icons.phone_rounded,
                          color:    Colors.green,
                          onTap:    widget.onCall,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _BigActionBtn(
                          label:    'WhatsApp',
                          subtitle: p.phone,
                          icon:     Icons.chat_rounded,
                          color:    const Color(0xFF25D366),
                          onTap:    widget.onWhatsApp,
                        ),
                      ),
                    ]),
                  ],
                  if (p.hasGps) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: _BigActionBtn(
                        label:    context.tr('get_directions'),
                        subtitle: context.tr('gps_maps'),
                        icon:     Icons.navigation_rounded,
                        color:    widget.color,
                        onTap:    widget.onGps,
                      ),
                    ),
                  ],

                  if (p.description.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      context.tr('about_provider'),
                      style: GoogleFonts.inter(
                          fontSize:   16,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      p.description,
                      style: GoogleFonts.inter(
                          color:    Colors.grey.shade700,
                          fontSize: 14,
                          height:   1.6),
                    ),
                  ],

                  if (p.distanceStr.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(Icons.near_me_rounded,
                            color: widget.color, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          'À ${p.distanceStr} de vous',
                          style: GoogleFonts.inter(
                              fontSize:   13,
                              color:      widget.color,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),

          // ── Avis ─────────────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.only(top: 8),
              color:  Colors.white,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Avis clients',
                        style: GoogleFonts.inter(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            _showRateDialog(context, p),
                        icon: const Icon(Icons.star_rounded,
                            size: 16, color: Color(0xFFFF6D00)),
                        label: Text(
                          'Laisser un avis',
                          style: GoogleFonts.inter(
                              color: const Color(0xFFFF6D00),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _ReviewsList(providerId: p.id),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }

  void _showRateDialog(BuildContext context, ServiceProvider p) {
    double tempRating = 0;
    final commentCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20)),
          title: Text(
            'Noter ${p.name}',
            style: GoogleFonts.inter(fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Étoiles
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (i) => GestureDetector(
                  onTap: () => setS(() => tempRating = (i + 1).toDouble()),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.star_rounded,
                      size:  36,
                      color: i < tempRating
                          ? Colors.amber
                          : Colors.grey.shade300,
                    ),
                  ),
                )),
              ),
              const SizedBox(height: 16),
              TextField(
                controller:  commentCtrl,
                maxLines:    3,
                decoration:  InputDecoration(
                  hintText:   'Votre commentaire (optionnel)',
                  hintStyle:  GoogleFonts.inter(fontSize: 13),
                  border:     OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler'),
            ),
            ScaleButton(
              onPressed: tempRating == 0
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      widget.onRate(tempRating, commentCtrl.text.trim());
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: widget.color,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text('Envoyer',
                  style: GoogleFonts.inter(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// LISTE DES AVIS
// ═══════════════════════════════════════════════════════════════════════════

class _ReviewsList extends StatelessWidget {
  final String providerId;
  const _ReviewsList({required this.providerId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('service_reviews')
          .where('providerId', isEqualTo: providerId)
          .orderBy('createdAt', descending: true)
          .limit(10)
          .snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Center(
              child: CircularProgressIndicator(strokeWidth: 2));
        }
        final docs = snap.data!.docs;
        if (docs.isEmpty) {
          return Text(
            'Aucun avis pour l\'instant.',
            style: GoogleFonts.inter(
                color: Colors.grey, fontSize: 13),
          );
        }
        return Column(
          children: docs.map((d) {
            final data = d.data() as Map<String, dynamic>;
            final rating = (data['rating'] as num?)?.toDouble() ?? 0;
            final comment = data['comment'] as String? ?? '';
            final ts = (data['createdAt'] as Timestamp?)?.toDate();
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:        const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ...List.generate(5, (i) => Icon(
                        Icons.star_rounded,
                        size:  14,
                        color: i < rating
                            ? Colors.amber
                            : Colors.grey.shade300,
                      )),
                      const Spacer(),
                      if (ts != null)
                        Text(
                          '${ts.day}/${ts.month}/${ts.year}',
                          style: GoogleFonts.inter(
                              fontSize: 10, color: Colors.grey),
                        ),
                    ],
                  ),
                  if (comment.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      comment,
                      style: GoogleFonts.inter(
                          fontSize: 12.5,
                          color: Colors.black87,
                          height: 1.4),
                    ),
                  ],
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// FEUILLE DE FILTRES
// ═══════════════════════════════════════════════════════════════════════════

class _FilterSheet extends StatefulWidget {
  final Color color;
  final double minRating;
  final bool gpsOnly;
  final bool availableOnly;
  final void Function(double minR, bool gps, bool avail) onApply;
  const _FilterSheet({
    required this.color,
    required this.minRating,
    required this.gpsOnly,
    required this.availableOnly,
    required this.onApply,
  });

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late double _minRating;
  late bool   _gpsOnly;
  late bool   _availableOnly;

  @override
  void initState() {
    super.initState();
    _minRating    = widget.minRating;
    _gpsOnly      = widget.gpsOnly;
    _availableOnly = widget.availableOnly;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 20),
              decoration: BoxDecoration(
                color:        Colors.grey.shade300,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),

          Text('Filtres',
              style: GoogleFonts.inter(
                  fontSize: 18, fontWeight: FontWeight.bold)),

          const SizedBox(height: 20),

          // Note minimale
          Row(
            children: [
              const Icon(Icons.star_rounded, color: Colors.amber, size: 20),
              const SizedBox(width: 8),
              Text('Note minimale',
                  style: GoogleFonts.inter(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                _minRating == 0 ? 'Toutes' : '$_minRating ⭐',
                style: GoogleFonts.inter(
                    color: widget.color, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          Slider(
            value:      _minRating,
            min:        0,
            max:        5,
            divisions: 5,
            activeColor: widget.color,
            onChanged: (v) => setState(() => _minRating = v),
          ),

          // GPS seulement
          SwitchListTile(
            title: Text('Avec localisation GPS uniquement',
                style: GoogleFonts.inter(fontSize: 13)),
            value:       _gpsOnly,
            onChanged:   (v) => setState(() => _gpsOnly = v),
            activeThumbColor: widget.color,
            contentPadding: EdgeInsets.zero,
          ),

          // Disponibles uniquement
          SwitchListTile(
            title: Text('Disponibles uniquement',
                style: GoogleFonts.inter(fontSize: 13)),
            value:       _availableOnly,
            onChanged:   (v) => setState(() => _availableOnly = v),
            activeThumbColor: widget.color,
            contentPadding: EdgeInsets.zero,
          ),

          const SizedBox(height: 8),

          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  setState(() {
                    _minRating     = 0;
                    _gpsOnly       = false;
                    _availableOnly = true;
                  });
                },
                child: Text('Réinitialiser',
                    style: GoogleFonts.inter()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ScaleButton(
                onPressed: () {
                  widget.onApply(_minRating, _gpsOnly, _availableOnly);
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.color,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('Appliquer',
                    style: GoogleFonts.inter(color: Colors.white)),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// WIDGETS COMMUNS
// ═══════════════════════════════════════════════════════════════════════════

class _RatingBadge extends StatelessWidget {
  final double rating;
  final int count;
  const _RatingBadge({required this.rating, required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color:        Colors.amber.shade50,
        borderRadius: BorderRadius.circular(8),
        border:       Border.all(color: Colors.amber.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 13, color: Colors.amber),
          const SizedBox(width: 3),
          Text(
            rating.toStringAsFixed(1),
            style: GoogleFonts.inter(
              fontSize:   12,
              fontWeight: FontWeight.bold,
              color:      Colors.amber.shade800,
            ),
          ),
          Text(
            ' ($count)',
            style: GoogleFonts.inter(
                fontSize: 10, color: Colors.amber.shade600),
          ),
        ],
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _ActionBtn({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color:        color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border:       Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 15),
            const SizedBox(width: 5),
            Text(
              label,
              style: GoogleFonts.inter(
                color:      color,
                fontWeight: FontWeight.bold,
                fontSize:   12.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BigActionBtn extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _BigActionBtn({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 12),
        decoration: BoxDecoration(
          color:        color,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color:      color.withValues(alpha: 0.35),
              blurRadius: 10,
              offset:     const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: GoogleFonts.inter(
                color:      Colors.white,
                fontWeight: FontWeight.bold,
                fontSize:   13,
              ),
            ),
            Text(
              subtitle,
              style: GoogleFonts.inter(
                  color: Colors.white70, fontSize: 10.5),
              maxLines:  1,
              overflow:  TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String search;
  const _EmptyState({required this.icon, required this.search});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 72, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            search.isEmpty
                ? context.tr('no_provider')
                : '${context.tr('no_result_for')} "$search"',
            style: GoogleFonts.inter(
                fontSize: 16, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            context.tr('come_back'),
            style: GoogleFonts.inter(
                fontSize: 13, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }
}

class _GradientPlaceholder extends StatelessWidget {
  final List<Color> gradient;
  final IconData icon;
  const _GradientPlaceholder({required this.gradient, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: gradient,
          begin:  Alignment.topLeft,
          end:    Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(icon, size: 60, color: Colors.white24),
      ),
    );
  }
}

