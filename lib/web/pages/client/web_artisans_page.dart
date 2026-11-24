import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../models/service_provider_model.dart';
import '../../../l10n/app_text.dart';
import '../../../widgets/stream_error_state.dart';
import '../../web_theme.dart';

/// Artisans — équivalent web de `lib/screens/client/service_providers_page.dart`,
/// limité à la catégorie `artisans` (16 métiers, voir `services_hub_page.dart`
/// côté mobile : `_catFor()` fixe `category: 'artisans'` pour ces 16
/// sous-catégories précisément — confirmé en lisant
/// `service_provider_register_page.dart`).
///
/// Même collection (`service_providers`), mêmes champs, mêmes règles
/// Firestore (`firestore.rules:1289` et s., `service_reviews:1400`) — aucune
/// nouvelle Cloud Function, aucune règle modifiée. Seule différence
/// structurelle avec le mobile : une requête unique filtrée sur
/// `category == 'artisans'` (plutôt que 16 requêtes par sous-catégorie),
/// avec le filtre de métier appliqué côté client — mêmes documents, mêmes
/// permissions, juste un regroupement plus adapté à une page web unique.
const kArtisansCategory = 'artisans';

/// (id, clé de libellé i18n réutilisée telle quelle depuis `app_text.dart`,
/// icône) — recopié à l'identique de la liste privée de
/// `services_hub_page.dart` (classe `_Category` non importable, étant
/// privée) : mêmes 16 identifiants, aucun métier inventé.
const kArtisanSubcategories = <(String, String, IconData)>[
  ('macon', 'sub_macon', Icons.domain_rounded),
  ('plombier', 'sub_plombier', Icons.plumbing_rounded),
  ('electricien', 'sub_electricien', Icons.electrical_services_rounded),
  ('ferronnier', 'sub_ferronnier', Icons.hardware_rounded),
  ('menuisier', 'sub_menuisier', Icons.carpenter_rounded),
  ('carreleur', 'sub_carreleur', Icons.grid_on_rounded),
  ('peintre', 'sub_peintre', Icons.format_paint_rounded),
  ('vitrier', 'sub_vitrier', Icons.window_rounded),
  ('reparateur_tv', 'sub_reparateur_tv', Icons.tv_rounded),
  ('installation_camera', 'sub_camera', Icons.videocam_rounded),
  ('decoration', 'sub_decoration', Icons.home_rounded),
  ('reparateur_portable', 'sub_reparateur', Icons.phone_android_rounded),
  ('salon_coiffure_homme', 'sub_salon_homme', Icons.content_cut_rounded),
  ('barber_shop', 'sub_barber_shop', Icons.face_rounded),
  ('salon_coiffure_femme', 'sub_salon_femme',
      Icons.face_retouching_natural_rounded),
  ('onglerie', 'sub_onglerie', Icons.spa_rounded),
];

enum ArtisanSortBy { distance, rating, name }

double haversineKm(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLng = (lng2 - lng1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLng / 2) * sin(dLng / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

/// Filtrage + tri — fonction pure, testable sans Firebase.
List<ServiceProvider> filterAndSortArtisans(
  List<ServiceProvider> all, {
  String? subcategory,
  String search = '',
  ArtisanSortBy sortBy = ArtisanSortBy.rating,
}) {
  var list = all.where((p) {
    if (subcategory != null && p.subcategory != subcategory) return false;
    if (search.isNotEmpty) {
      final q = search.toLowerCase();
      if (!p.name.toLowerCase().contains(q) &&
          !p.address.toLowerCase().contains(q) &&
          !p.description.toLowerCase().contains(q)) {
        return false;
      }
    }
    return true;
  }).toList();

  list.sort((a, b) {
    switch (sortBy) {
      case ArtisanSortBy.distance:
        final da = a.distanceKm ?? 999999;
        final db = b.distanceKm ?? 999999;
        return da.compareTo(db);
      case ArtisanSortBy.rating:
        return b.rating.compareTo(a.rating);
      case ArtisanSortBy.name:
        return a.name.compareTo(b.name);
    }
  });
  return list;
}

class WebArtisansPage extends StatefulWidget {
  const WebArtisansPage({super.key});

  @override
  State<WebArtisansPage> createState() => _WebArtisansPageState();
}

class _WebArtisansPageState extends State<WebArtisansPage> {
  final _searchCtrl = TextEditingController();
  String _search = '';
  String? _subcategory;
  ArtisanSortBy _sortBy = ArtisanSortBy.rating;
  double? _userLat;
  double? _userLng;
  Set<String> _favorites = {};
  String? _openProviderId;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

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

  Future<void> _loadUserPosition() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 8)),
      );
      if (mounted) {
        setState(() {
          _userLat = pos.latitude;
          _userLng = pos.longitude;
        });
      }
    } catch (_) {
      // Géolocalisation navigateur refusée/indisponible : le tri par
      // distance reste simplement désactivé, comme sur mobile.
    }
  }

  Future<void> _loadFavorites() async {
    final uid = _uid;
    if (uid == null) return;
    final snap = await FirebaseFirestore.instance
        .collection('clients')
        .doc(uid)
        .collection('favorite_providers')
        .get();
    if (mounted) setState(() => _favorites = snap.docs.map((d) => d.id).toSet());
  }

  Future<void> _toggleFavorite(String providerId) async {
    final uid = _uid;
    if (uid == null) return;
    final ref = FirebaseFirestore.instance
        .collection('clients')
        .doc(uid)
        .collection('favorite_providers')
        .doc(providerId);
    if (_favorites.contains(providerId)) {
      await ref.delete();
      if (mounted) setState(() => _favorites.remove(providerId));
    } else {
      await ref.set({'addedAt': FieldValue.serverTimestamp()});
      if (mounted) setState(() => _favorites.add(providerId));
    }
  }

  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:${phone.replaceAll(RegExp(r'[\s\-()]'), '')}');
    await launchUrl(uri);
  }

  Future<void> _whatsapp(String phone, String name) async {
    var p = phone.replaceAll(RegExp(r'[\s\-()]'), '');
    if (p.startsWith('0')) p = p.substring(1);
    if (!p.startsWith('225')) p = '225$p';
    final msg = Uri.encodeComponent('Bonjour $name, je vous contacte via AZ Express.');
    await launchUrl(Uri.parse('https://wa.me/$p?text=$msg'),
        mode: LaunchMode.externalApplication);
  }

  Future<void> _openMaps(double lat, double lng) async {
    await launchUrl(
        Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng'),
        mode: LaunchMode.externalApplication);
  }

  List<ServiceProvider> _process(List<QueryDocumentSnapshot> docs) {
    final list = docs.where((d) {
      final data = d.data() as Map<String, dynamic>?;
      final status = data?['status'] as String?;
      return status == null || status == 'approved';
    }).map((d) {
      final p = ServiceProvider.fromFirestore(d);
      if (_userLat != null && _userLng != null && p.hasGps) {
        p.distanceKm = haversineKm(_userLat!, _userLng!, p.lat, p.lng);
      }
      return p;
    }).toList();
    return filterAndSortArtisans(list,
        subcategory: _subcategory, search: _search, sortBy: _sortBy);
  }

  @override
  Widget build(BuildContext context) {
    if (_openProviderId != null) {
      return _ArtisanDetail(
        providerId: _openProviderId!,
        isFavorite: _favorites.contains(_openProviderId),
        onFavorite: () => _toggleFavorite(_openProviderId!),
        onCall: _call,
        onWhatsApp: _whatsapp,
        onGps: _openMaps,
        onBack: () => setState(() => _openProviderId = null),
      );
    }
    return Column(children: [
      Padding(
        padding: EdgeInsets.fromLTRB(hPad(context), hPad(context), hPad(context), 0),
        child: Column(children: [
          TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _search = v),
            style: GoogleFonts.inter(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFF161B22),
              hintText: 'Rechercher un artisan (nom, quartier...)',
              hintStyle: GoogleFonts.inter(color: kTextMuted, fontSize: 13),
              prefixIcon: const Icon(Icons.search_rounded, color: kOrange),
              suffixIcon: _search.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded, color: kTextMuted),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _search = '');
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _chip('Tous les métiers', null, Icons.handyman_rounded),
                for (final sub in kArtisanSubcategories)
                  _chip(context.tr(sub.$2), sub.$1, sub.$3),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Text('Trier par :', style: GoogleFonts.inter(color: kTextMuted, fontSize: 12)),
            const SizedBox(width: 8),
            _sortChip('Note', ArtisanSortBy.rating),
            const SizedBox(width: 6),
            _sortChip('Distance', ArtisanSortBy.distance),
            const SizedBox(width: 6),
            _sortChip('Nom A-Z', ArtisanSortBy.name),
          ]),
        ]),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('service_providers')
              .where('category', isEqualTo: kArtisansCategory)
              .snapshots(),
          builder: (ctx, snap) {
            if (snap.hasError) {
              return StreamErrorState(
                message: 'Impossible de charger les artisans pour le moment.',
                onRetry: () => setState(() {}),
              );
            }
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator(color: kOrange));
            }
            final providers = _process(snap.data?.docs ?? []);
            if (providers.isEmpty) {
              return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.handyman_rounded, color: kTextMuted, size: 64),
                  const SizedBox(height: 16),
                  Text(
                      _search.isEmpty && _subcategory == null
                          ? 'Aucun artisan pour le moment'
                          : 'Aucun résultat',
                      style: GoogleFonts.inter(
                          color: kTextMuted,
                          fontSize: 18,
                          fontWeight: FontWeight.w600)),
                ]),
              );
            }
            final cols = isDesktop(context) ? 3 : (isTablet(context) ? 2 : 1);
            return GridView.builder(
              padding: EdgeInsets.all(hPad(context)),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 0.82,
              ),
              itemCount: providers.length,
              itemBuilder: (_, i) {
                final p = providers[i];
                return _ArtisanCard(
                  provider: p,
                  isFavorite: _favorites.contains(p.id),
                  onFavorite: () => _toggleFavorite(p.id),
                  onCall: () => _call(p.phone),
                  onWhatsApp: () => _whatsapp(p.phone, p.name),
                  onGps: p.hasGps ? () => _openMaps(p.lat, p.lng) : null,
                  onTap: () => setState(() => _openProviderId = p.id),
                );
              },
            );
          },
        ),
      ),
    ]);
  }

  Widget _chip(String label, String? value, IconData icon) {
    final selected = _subcategory == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => setState(() => _subcategory = value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? kOrange : const Color(0xFF161B22),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: selected ? kOrange : const Color(0xFF30363D)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: selected ? Colors.white : kTextMuted),
            const SizedBox(width: 6),
            Text(label,
                style: GoogleFonts.inter(
                    fontSize: 12,
                    color: selected ? Colors.white : kTextMuted,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
          ]),
        ),
      ),
    );
  }

  Widget _sortChip(String label, ArtisanSortBy value) {
    final selected = _sortBy == value;
    return GestureDetector(
      onTap: () => setState(() => _sortBy = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? kOrange.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected ? kOrange : const Color(0xFF30363D)),
        ),
        child: Text(label,
            style: GoogleFonts.inter(
                fontSize: 11,
                color: selected ? kOrange : kTextMuted,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
      ),
    );
  }
}

class _ArtisanCard extends StatelessWidget {
  final ServiceProvider provider;
  final bool isFavorite;
  final VoidCallback onFavorite;
  final VoidCallback onCall;
  final VoidCallback onWhatsApp;
  final VoidCallback? onGps;
  final VoidCallback onTap;

  const _ArtisanCard({
    required this.provider,
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
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            SizedBox(
              height: 120,
              width: double.infinity,
              child: p.photos.isNotEmpty
                  ? Image.network(p.photos.first,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _placeholder())
                  : _placeholder(),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: GestureDetector(
                onTap: onFavorite,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: isFavorite ? Colors.red : Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                      isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                      color: Colors.white,
                      size: 15),
                ),
              ),
            ),
            if (p.isVerified)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                      color: kSuccess, borderRadius: BorderRadius.circular(6)),
                  child: Text('Vérifié',
                      style: GoogleFonts.inter(
                          color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text(p.name,
                        style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)),
                if (p.ratingCount > 0) ...[
                  const Icon(Icons.star_rounded, color: Colors.amber, size: 14),
                  Text(p.ratingStr,
                      style: GoogleFonts.inter(color: Colors.amber, fontSize: 11)),
                ],
              ]),
              if (p.address.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(p.address,
                    style: GoogleFonts.inter(color: kTextMuted, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
              if (p.distanceStr.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text('À ${p.distanceStr}',
                    style: GoogleFonts.inter(color: kOrange, fontSize: 10)),
              ],
              const SizedBox(height: 10),
              Row(children: [
                if (p.phone.isNotEmpty) ...[
                  Expanded(
                      child: _miniBtn(Icons.call_rounded, kSuccess, onCall)),
                  const SizedBox(width: 6),
                  Expanded(
                      child: _miniBtn(
                          Icons.chat_rounded, const Color(0xFF25D366), onWhatsApp)),
                ],
                if (onGps != null) ...[
                  const SizedBox(width: 6),
                  Expanded(child: _miniBtn(Icons.navigation_rounded, kBlue, onGps!)),
                ],
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _placeholder() => Container(
        color: const Color(0xFF0F1923),
        child: const Center(
            child: Icon(Icons.handyman_rounded, color: kTextMuted, size: 36)),
      );

  Widget _miniBtn(IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: color, size: 16),
      ),
    );
  }
}

class _ArtisanDetail extends StatefulWidget {
  final String providerId;
  final bool isFavorite;
  final VoidCallback onFavorite;
  final Future<void> Function(String phone) onCall;
  final Future<void> Function(String phone, String name) onWhatsApp;
  final Future<void> Function(double lat, double lng) onGps;
  final VoidCallback onBack;

  const _ArtisanDetail({
    required this.providerId,
    required this.isFavorite,
    required this.onFavorite,
    required this.onCall,
    required this.onWhatsApp,
    required this.onGps,
    required this.onBack,
  });

  @override
  State<_ArtisanDetail> createState() => _ArtisanDetailState();
}

class _ArtisanDetailState extends State<_ArtisanDetail> {
  late bool _isFav = widget.isFavorite;

  Future<void> _submitReview(ServiceProvider p, double rating, String comment) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final db = FirebaseFirestore.instance;
    final existing = await db
        .collection('service_reviews')
        .where('providerId', isEqualTo: p.id)
        .where('clientId', isEqualTo: uid)
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Vous avez déjà noté ce prestataire.'),
            backgroundColor: Colors.orange));
      }
      return;
    }
    await db.collection('service_reviews').add({
      'providerId': p.id,
      'clientId': uid,
      'rating': rating,
      'comment': comment,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await db.runTransaction((tx) async {
      final ref = db.collection('service_providers').doc(p.id);
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final d = snap.data()!;
      final cnt = ((d['ratingCount'] as num?)?.toInt() ?? 0) + 1;
      final avg = ((d['rating'] as num?)?.toDouble() ?? 0) * (cnt - 1) / cnt + rating / cnt;
      tx.update(ref, {'rating': double.parse(avg.toStringAsFixed(1)), 'ratingCount': cnt});
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Merci pour votre avis !'), backgroundColor: kSuccess));
    }
  }

  void _showRateDialog(ServiceProvider p) {
    double tempRating = 0;
    final commentCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Noter ${p.name}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                  5,
                  (i) => GestureDetector(
                        onTap: () => setS(() => tempRating = (i + 1).toDouble()),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(Icons.star_rounded,
                              size: 32,
                              color: i < tempRating ? Colors.amber : Colors.grey.shade300),
                        ),
                      )),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: commentCtrl,
              maxLines: 3,
              decoration: const InputDecoration(hintText: 'Votre commentaire (optionnel)'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            ElevatedButton(
              onPressed: tempRating == 0
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      _submitReview(p, tempRating, commentCtrl.text.trim());
                    },
              style: ElevatedButton.styleFrom(backgroundColor: kOrange),
              child: const Text('Envoyer', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('service_providers')
          .doc(widget.providerId)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return StreamErrorState(
            message: 'Impossible de charger cet artisan.',
            onRetry: () => setState(() {}),
          );
        }
        if (!snap.hasData || !snap.data!.exists) {
          return const Center(child: CircularProgressIndicator(color: kOrange));
        }
        final p = ServiceProvider.fromFirestore(snap.data!);
        return SingleChildScrollView(
          padding: EdgeInsets.all(hPad(context)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconButton(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white)),
              Expanded(
                  child: Text(p.name,
                      style: GoogleFonts.inter(
                          color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700))),
              IconButton(
                onPressed: () {
                  setState(() => _isFav = !_isFav);
                  widget.onFavorite();
                },
                icon: Icon(_isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    color: _isFav ? Colors.red : kTextMuted),
              ),
            ]),
            const SizedBox(height: 12),
            if (p.photos.isNotEmpty)
              SizedBox(
                height: 220,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: p.photos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.network(p.photos[i], width: 300, fit: BoxFit.cover),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            if (p.address.isNotEmpty)
              Row(children: [
                const Icon(Icons.location_on_rounded, color: kTextMuted, size: 16),
                const SizedBox(width: 6),
                Text(p.address, style: GoogleFonts.inter(color: kTextMuted, fontSize: 13)),
              ]),
            if (p.description.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(p.description,
                  style: GoogleFonts.inter(color: Colors.white70, fontSize: 14, height: 1.6)),
            ],
            const SizedBox(height: 20),
            Wrap(spacing: 12, runSpacing: 12, children: [
              if (p.phone.isNotEmpty)
                _bigBtn('Appeler', p.phone, Icons.call_rounded, kSuccess,
                    () => widget.onCall(p.phone)),
              if (p.phone.isNotEmpty)
                _bigBtn('WhatsApp', p.phone, Icons.chat_rounded, const Color(0xFF25D366),
                    () => widget.onWhatsApp(p.phone, p.name)),
              if (p.hasGps)
                _bigBtn('Itinéraire', 'Voir sur la carte', Icons.navigation_rounded, kBlue,
                    () => widget.onGps(p.lat, p.lng)),
            ]),
            const SizedBox(height: 28),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Avis clients',
                  style: GoogleFonts.inter(
                      color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
              TextButton.icon(
                onPressed: () => _showRateDialog(p),
                icon: const Icon(Icons.star_rounded, color: kOrange, size: 16),
                label: const Text('Laisser un avis', style: TextStyle(color: kOrange)),
              ),
            ]),
            const SizedBox(height: 8),
            _ReviewsList(providerId: p.id),
            const SizedBox(height: 40),
          ]),
        );
      },
    );
  }

  Widget _bigBtn(
      String label, String subtitle, IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 160,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
        child: Column(children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(height: 4),
          Text(label,
              style: GoogleFonts.inter(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
          Text(subtitle,
              style: GoogleFonts.inter(color: Colors.white70, fontSize: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}

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
        if (snap.hasError) {
          return Text('Impossible de charger les avis.',
              style: GoogleFonts.inter(color: kTextMuted, fontSize: 13));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: kOrange));
        }
        final docs = snap.data!.docs;
        if (docs.isEmpty) {
          return Text('Aucun avis pour l\'instant.',
              style: GoogleFonts.inter(color: kTextMuted, fontSize: 13));
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
                  color: const Color(0xFF161B22), borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  ...List.generate(
                      5,
                      (i) => Icon(Icons.star_rounded,
                          size: 13,
                          color: i < rating ? Colors.amber : Colors.grey.shade700)),
                  const Spacer(),
                  if (ts != null)
                    Text('${ts.day}/${ts.month}/${ts.year}',
                        style: GoogleFonts.inter(fontSize: 10, color: kTextMuted)),
                ]),
                if (comment.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(comment,
                      style: GoogleFonts.inter(color: Colors.white70, fontSize: 12)),
                ],
              ]),
            );
          }).toList(),
        );
      },
    );
  }
}
