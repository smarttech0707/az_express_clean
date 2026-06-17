import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/places_service.dart';

/// Résultat retourné par le search sheet
class PlaceSearchResult {
  final String  address;
  final double  latitude;
  final double  longitude;
  const PlaceSearchResult({
    required this.address,
    required this.latitude,
    required this.longitude,
  });
}

/// Search sheet style Uber/Yango.
///
/// Usage :
/// ```dart
/// final result = await PlaceSearchSheet.show(context, hint: 'Destination');
/// if (result != null) { ... }
/// ```
class PlaceSearchSheet extends StatefulWidget {
  final String hint;
  final String? initialValue;

  const PlaceSearchSheet({super.key, required this.hint, this.initialValue});

  static Future<PlaceSearchResult?> show(
    BuildContext context, {
    String hint = 'Rechercher un lieu…',
    String? initialValue,
  }) {
    return showModalBottomSheet<PlaceSearchResult?>(
      context:             context,
      isScrollControlled:  true,
      backgroundColor:     Colors.transparent,
      barrierColor:        Colors.black54,
      builder: (_) => PlaceSearchSheet(hint: hint, initialValue: initialValue),
    );
  }

  @override
  State<PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<PlaceSearchSheet> {

  final _ctrl  = TextEditingController();
  final _focus = FocusNode();

  List<PlaceSuggestion> _suggestions = [];
  bool  _loading  = false;
  bool  _searched = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (widget.initialValue != null) _ctrl.text = widget.initialValue!;
    _ctrl.addListener(_onChanged);
    // Auto-focus dès l'ouverture
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _onChanged() {
    _debounce?.cancel();
    final q = _ctrl.text.trim();
    if (q.length < 2) {
      setState(() { _suggestions = []; _searched = false; _loading = false; });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
  }

  Future<void> _search(String q) async {
    final results = await PlacesService.autocomplete(q);
    if (!mounted) return;
    setState(() {
      _suggestions = results;
      _loading     = false;
      _searched    = true;
    });
  }

  Future<void> _select(PlaceSuggestion s) async {
    setState(() => _loading = true);
    final coords = await PlacesService.getCoordinates(s.placeId, suggestion: s);
    if (!mounted) return;

    if (coords == null) {
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Impossible de localiser "${s.mainText}"'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    Navigator.pop(context, PlaceSearchResult(
      address:   s.description.isNotEmpty ? s.description : s.mainText,
      latitude:  coords.latitude,
      longitude: coords.longitude,
    ));
  }

  void _clear() {
    _ctrl.clear();
    setState(() { _suggestions = []; _searched = false; });
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final height    = MediaQuery.of(context).size.height * 0.92;
    final keyboardH = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height:     height,
      decoration: const BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(children: [

        // ── Header ────────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Column(children: [
            // Poignée
            Center(child: Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: Colors.grey.shade300, borderRadius: BorderRadius.circular(4)),
            )),

            // Barre de recherche
            Container(
              height: 50,
              decoration: BoxDecoration(
                color:        const Color(0xFFF2F2F2),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(children: [
                const SizedBox(width: 12),
                // Icône animée : chargement ou loupe
                _loading
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFFFF6D00)),
                      )
                    : const Icon(Icons.search_rounded,
                        color: Color(0xFFFF6D00), size: 22),
                const SizedBox(width: 10),

                // Champ de saisie
                Expanded(child: TextField(
                  controller:  _ctrl,
                  focusNode:   _focus,
                  autofocus:   true,
                  style:       GoogleFonts.inter(fontSize: 15, color: Colors.black87),
                  decoration:  InputDecoration(
                    hintText:       widget.hint,
                    hintStyle:      GoogleFonts.inter(
                        fontSize: 14, color: Colors.grey.shade500),
                    border:         InputBorder.none,
                    isDense:        true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  textInputAction:    TextInputAction.search,
                  onSubmitted: (q) { if (q.trim().length >= 2) _search(q.trim()); },
                )),

                // Bouton clear
                if (_ctrl.text.isNotEmpty) ...[
                  GestureDetector(
                    onTap: _clear,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      child: const Icon(Icons.close_rounded,
                          size: 18, color: Colors.grey),
                    ),
                  ),
                ],
                const SizedBox(width: 4),
              ]),
            ),

            const SizedBox(height: 10),
          ]),
        ),

        const Divider(height: 1),

        // ── Corps ─────────────────────────────────────────────────────────────
        Expanded(child: _buildBody(keyboardH)),
      ]),
    );
  }

  Widget _buildBody(double keyboardH) {
    // ── Aucune saisie : lieux rapides ────────────────────────────────────────
    if (_ctrl.text.trim().length < 2 && !_searched) {
      return _buildQuickPlaces();
    }

    // ── Résultats ────────────────────────────────────────────────────────────
    if (_suggestions.isNotEmpty) {
      return ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _suggestions.length,
        separatorBuilder: (_, __) =>
            Divider(height: 1, indent: 56, color: Colors.grey.shade100),
        itemBuilder: (_, i) => _SuggestionTile(
          suggestion: _suggestions[i],
          onTap:      () => _select(_suggestions[i]),
        ),
      );
    }

    // ── Aucun résultat ───────────────────────────────────────────────────────
    if (_searched && !_loading) {
      return Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off_rounded, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text('Aucun lieu trouvé',
              style: GoogleFonts.inter(fontSize: 15, color: Colors.grey.shade500)),
          const SizedBox(height: 6),
          Text('Essayez un autre nom ou quartier',
              style: GoogleFonts.inter(fontSize: 12, color: Colors.grey.shade400)),
        ],
      ));
    }

    // ── Chargement ───────────────────────────────────────────────────────────
    return const Center(
      child: CircularProgressIndicator(color: Color(0xFFFF6D00), strokeWidth: 2),
    );
  }

  // ── Lieux rapides (avant toute saisie) ────────────────────────────────────
  Widget _buildQuickPlaces() {
    final quickPlaces = [
      const _QuickPlace('CHU d\'Abengourou',    Icons.local_hospital_rounded,  Colors.red,    '6.7301,-3.4889'),
      const _QuickPlace('Marché Central',       Icons.storefront_rounded,      Colors.orange, '6.7265,-3.4952'),
      const _QuickPlace('Préfecture',           Icons.account_balance_rounded, Colors.blue,   '6.7253,-3.4961'),
      const _QuickPlace('Gare Routière',        Icons.directions_bus_rounded,  Colors.green,  '6.7242,-3.4978'),
      const _QuickPlace('Mairie d\'Abengourou', Icons.location_city_rounded,   Colors.indigo, '6.7260,-3.4975'),
      const _QuickPlace('Lycée Moderne',        Icons.school_rounded,          Colors.teal,   '6.7295,-3.4930'),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Text('Lieux populaires à Abengourou',
              style: GoogleFonts.inter(
                  fontSize: 12, fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500, letterSpacing: 0.3)),
        ),
        ...quickPlaces.map((p) => ListTile(
          leading: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: p.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(p.icon, color: p.color, size: 20),
          ),
          title: Text(p.name,
              style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: Text('Abengourou, Côte d\'Ivoire',
              style: GoogleFonts.inter(fontSize: 12, color: Colors.grey.shade500)),
          onTap: () {
            final coords = p.latLng.split(',');
            final lat = double.parse(coords[0]);
            final lng = double.parse(coords[1]);
            Navigator.pop(context, PlaceSearchResult(
              address:   '${p.name}, Abengourou',
              latitude:  lat,
              longitude: lng,
            ));
          },
        )),

        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text('Tapez pour rechercher n\'importe quel lieu…',
              style: GoogleFonts.inter(fontSize: 11, color: Colors.grey.shade400),
              textAlign: TextAlign.center),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }
}

// ── Tuile suggestion ───────────────────────────────────────────────────────────

class _SuggestionTile extends StatelessWidget {
  final PlaceSuggestion suggestion;
  final VoidCallback    onTap;
  const _SuggestionTile({required this.suggestion, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isOsm = suggestion.source == 'osm';
    return InkWell(
      onTap:   onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          // Icône source
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color:        const Color(0xFFFF6D00).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _iconFor(suggestion.mainText),
              color: const Color(0xFFFF6D00), size: 20,
            ),
          ),
          const SizedBox(width: 14),

          // Texte
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(suggestion.mainText,
                style: GoogleFonts.inter(
                    fontSize: 14, fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            if (suggestion.secondaryText.isNotEmpty)
              Text(suggestion.secondaryText,
                  style: GoogleFonts.inter(
                      fontSize: 12, color: Colors.grey.shade500),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),

          // Badge source
          if (isOsm)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('OSM',
                  style: GoogleFonts.inter(
                      fontSize: 9, color: Colors.green.shade600,
                      fontWeight: FontWeight.w600)),
            ),
        ]),
      ),
    );
  }

  IconData _iconFor(String name) {
    final n = name.toLowerCase();
    if (n.contains('pharmacie') || n.contains('hôpital') || n.contains('chu') || n.contains('clinique')) {
      return Icons.local_hospital_rounded;
    }
    if (n.contains('restaurant') || n.contains('maquis') || n.contains('cafét') || n.contains('café')) {
      return Icons.restaurant_rounded;
    }
    if (n.contains('marché') || n.contains('commerce') || n.contains('boutique') || n.contains('super')) {
      return Icons.storefront_rounded;
    }
    if (n.contains('école') || n.contains('lycée') || n.contains('université') || n.contains('collège')) {
      return Icons.school_rounded;
    }
    if (n.contains('gare') || n.contains('taxi') || n.contains('bus')) {
      return Icons.directions_bus_rounded;
    }
    if (n.contains('église') || n.contains('mosquée') || n.contains('temple')) {
      return Icons.place_rounded;
    }
    if (n.contains('banque') || n.contains('atm') || n.contains('wave') || n.contains('orange money')) {
      return Icons.account_balance_rounded;
    }
    if (n.contains('hôtel') || n.contains('auberge') || n.contains('résidence')) {
      return Icons.hotel_rounded;
    }
    return Icons.place_rounded;
  }
}

// ── Modèle lieu rapide ─────────────────────────────────────────────────────────
class _QuickPlace {
  final String   name;
  final IconData icon;
  final Color    color;
  final String   latLng;
  const _QuickPlace(this.name, this.icon, this.color, this.latLng);
}
