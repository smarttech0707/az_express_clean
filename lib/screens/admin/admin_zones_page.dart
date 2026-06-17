import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

class AdminZonesPage extends StatefulWidget {
  const AdminZonesPage({super.key});
  @override
  State<AdminZonesPage> createState() => _AdminZonesPageState();
}

class _AdminZonesPageState extends State<AdminZonesPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  bool _seeding = false;

  static const _tabs  = ['Tout', 'Villes', 'Quartiers', 'Villages', 'Secteurs'];
  static const _types = ['', 'ville', 'quartier', 'village', 'secteur'];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  // ── Firestore ref ───────────────────────────────────────────────────────────
  CollectionReference get _col =>
      FirebaseFirestore.instance.collection('zones_livraison');

  // ── Seed initial ─────────────────────────────────────────────────────────────
  static const _initialZones = [
    // Ville
    {'name': 'Abengourou', 'type': 'ville', 'lat': 6.7273, 'lng': -3.4961,
     'parentName': '', 'order': 0},
    // Quartiers d'Abengourou
    {'name': 'Commerce',      'type': 'quartier', 'parentName': 'Abengourou', 'order': 1},
    {'name': 'Château',       'type': 'quartier', 'parentName': 'Abengourou', 'order': 2},
    {'name': 'Baoulékro',     'type': 'quartier', 'parentName': 'Abengourou', 'order': 3},
    {'name': 'Cafétou',       'type': 'quartier', 'parentName': 'Abengourou', 'order': 4},
    {'name': 'Plateau',       'type': 'quartier', 'parentName': 'Abengourou', 'order': 5},
    {'name': 'Pokoukro',      'type': 'quartier', 'parentName': 'Abengourou', 'order': 6},
    {'name': 'Résidentiel',   'type': 'quartier', 'parentName': 'Abengourou', 'order': 7},
    {'name': 'Administratif', 'type': 'quartier', 'parentName': 'Abengourou', 'order': 8},
    // Villages desservis
    {'name': 'Niablé',           'type': 'village', 'parentName': 'Abengourou', 'order': 10},
    {'name': 'Amélékia',         'type': 'village', 'parentName': 'Abengourou', 'order': 11},
    {'name': 'Sankadiokro',      'type': 'village', 'parentName': 'Abengourou', 'order': 12},
    {'name': 'Zinzenou',         'type': 'village', 'parentName': 'Abengourou', 'order': 13},
    {'name': 'Yakassé-Feyassé',  'type': 'village', 'parentName': 'Abengourou', 'order': 14},
    {'name': 'Aniassué',         'type': 'village', 'parentName': 'Abengourou', 'order': 15},
    {'name': 'Kodjinan',         'type': 'village', 'parentName': 'Abengourou', 'order': 16},
    {'name': 'Zamaka',           'type': 'village', 'parentName': 'Abengourou', 'order': 17},
    {'name': 'Assakra',          'type': 'village', 'parentName': 'Abengourou', 'order': 18},
    {'name': 'Apprompronou',     'type': 'village', 'parentName': 'Abengourou', 'order': 19},
  ];

  Future<void> _seedZones() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Initialiser les zones ?'),
        content: const Text(
          'Ceci ajoutera les 19 zones initiales (1 ville, 8 quartiers, 10 villages). '
          'Les zones déjà existantes ne seront pas dupliquées.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Initialiser')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _seeding = true);
    try {
      final existing = await _col.get();
      final existingNames = existing.docs
          .map((d) => (d['name'] as String).toLowerCase())
          .toSet();

      final batch = FirebaseFirestore.instance.batch();
      int added = 0;
      for (final z in _initialZones) {
        final name = z['name'] as String;
        if (existingNames.contains(name.toLowerCase())) continue;
        final ref = _col.doc();
        batch.set(ref, {
          'name':       name,
          'type':       z['type'],
          'parentName': z['parentName'] ?? '',
          'lat':        z['lat'],
          'lng':        z['lng'],
          'isActive':   true,
          'order':      z['order'],
          'createdAt':  FieldValue.serverTimestamp(),
        });
        added++;
      }
      await batch.commit();
      if (mounted) {
        _snack('$added zone(s) ajoutée(s)', Colors.green);
      }
    } catch (e) {
      if (mounted) _snack('Erreur : $e', Colors.red);
    } finally {
      if (mounted) setState(() => _seeding = false);
    }
  }

  // ── GPS terrain ─────────────────────────────────────────────────────────────
  Future<Position?> _captureGps() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      if (mounted) _snack('Permission GPS refusée', Colors.red);
      return null;
    }
    return Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high));
  }

  // ── Ajouter / Modifier zone ─────────────────────────────────────────────────
  Future<void> _openForm([DocumentSnapshot? doc]) async {
    final data = doc?.data() as Map<String, dynamic>?;

    final nameCtrl   = TextEditingController(text: data?['name'] ?? '');
    final parentCtrl = TextEditingController(text: data?['parentName'] ?? '');
    String type      = data?['type'] ?? 'quartier';
    double? lat      = (data?['lat'] as num?)?.toDouble();
    double? lng      = (data?['lng'] as num?)?.toDouble();
    bool gpsLoading  = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(doc == null ? 'Nouvelle zone' : 'Modifier la zone'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Nom
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Nom de la zone *',
                      border: OutlineInputBorder()),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 12),

                // Type
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: const InputDecoration(
                      labelText: 'Type', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'ville',    child: Text('Ville')),
                    DropdownMenuItem(value: 'quartier', child: Text('Quartier')),
                    DropdownMenuItem(value: 'village',  child: Text('Village')),
                    DropdownMenuItem(value: 'secteur',  child: Text('Secteur')),
                  ],
                  onChanged: (v) => setS(() => type = v ?? type),
                ),
                const SizedBox(height: 12),

                // Parent
                TextField(
                  controller: parentCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Ville parente (ex: Abengourou)',
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),

                // GPS
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Coordonnées GPS',
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade700)),
                      const SizedBox(height: 4),
                      if (lat != null && lng != null)
                        Text(
                          'Lat: ${lat!.toStringAsFixed(5)}\n'
                          'Lng: ${lng!.toStringAsFixed(5)}',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF1565C0)),
                        )
                      else
                        const Text('Aucune coordonnée enregistrée',
                            style:
                                TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: gpsLoading
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.my_location,
                                  color: Color(0xFF1565C0)),
                          label: Text(
                            gpsLoading
                                ? 'Localisation…'
                                : 'Capturer ma position GPS',
                            style:
                                const TextStyle(color: Color(0xFF1565C0)),
                          ),
                          onPressed: gpsLoading
                              ? null
                              : () async {
                                  setS(() => gpsLoading = true);
                                  final pos = await _captureGps();
                                  setS(() {
                                    gpsLoading = false;
                                    if (pos != null) {
                                      lat = pos.latitude;
                                      lng = pos.longitude;
                                    }
                                  });
                                },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Annuler')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6D00)),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final payload = <String, dynamic>{
                  'name':       name,
                  'type':       type,
                  'parentName': parentCtrl.text.trim(),
                  'isActive':   data?['isActive'] ?? true,
                  'order':      data?['order'] ?? 99,
                  'updatedAt':  FieldValue.serverTimestamp(),
                  if (lat != null) 'lat': lat,
                  if (lng != null) 'lng': lng,
                };
                if (doc == null) {
                  payload['createdAt'] = FieldValue.serverTimestamp();
                  await _col.add(payload);
                } else {
                  await doc.reference.update(payload);
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: Text(doc == null ? 'Ajouter' : 'Enregistrer',
                  style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Toggle actif ────────────────────────────────────────────────────────────
  Future<void> _toggleActive(DocumentSnapshot doc) async {
    final current = doc['isActive'] as bool? ?? true;
    await doc.reference.update({'isActive': !current});
  }

  // ── Supprimer ────────────────────────────────────────────────────────────────
  Future<void> _delete(DocumentSnapshot doc) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer la zone ?'),
        content: Text('Supprimer "${doc['name']}" ? Cette action est irréversible.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Supprimer', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true) await doc.reference.delete();
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: color,
            duration: const Duration(seconds: 3)));
  }

  // ── BUILD ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: const Text('Gestion Géographique',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (_seeding)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2)),
            )
          else
            IconButton(
              icon: const Icon(Icons.download_rounded),
              tooltip: 'Initialiser les zones de départ',
              onPressed: _seedZones,
            ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          isScrollable: true,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          indicatorColor: Colors.white,
          tabs: _tabs.map((t) => Tab(text: t)).toList(),
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: List.generate(_tabs.length, (i) => _ZonesList(
          typeFilter: _types[i],
          onEdit: _openForm,
          onToggle: _toggleActive,
          onDelete: _delete,
        )),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_location_alt_rounded),
        label: const Text('Ajouter une zone'),
        onPressed: () => _openForm(),
      ),
    );
  }
}

// ── Liste des zones (par type) ───────────────────────────────────────────────

class _ZonesList extends StatelessWidget {
  final String typeFilter;
  final Future<void> Function(DocumentSnapshot) onEdit;
  final Future<void> Function(DocumentSnapshot) onToggle;
  final Future<void> Function(DocumentSnapshot) onDelete;

  const _ZonesList({
    required this.typeFilter,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    Query query = FirebaseFirestore.instance
        .collection('zones_livraison')
        .orderBy('order')
        .orderBy('name');

    if (typeFilter.isNotEmpty) {
      query = query.where('type', isEqualTo: typeFilter);
    }

    return StreamBuilder<QuerySnapshot>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.location_off_rounded,
                    size: 56, color: Colors.grey.shade400),
                const SizedBox(height: 12),
                Text(
                  typeFilter.isEmpty
                      ? 'Aucune zone définie\nAppuyez sur ↓ pour initialiser'
                      : 'Aucune zone de type "$typeFilter"',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 15),
                ),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
          itemCount: docs.length,
          itemBuilder: (_, i) => _ZoneCard(
            doc: docs[i],
            onEdit: onEdit,
            onToggle: onToggle,
            onDelete: onDelete,
          ),
        );
      },
    );
  }
}

// ── Carte zone ───────────────────────────────────────────────────────────────

class _ZoneCard extends StatelessWidget {
  final DocumentSnapshot doc;
  final Future<void> Function(DocumentSnapshot) onEdit;
  final Future<void> Function(DocumentSnapshot) onToggle;
  final Future<void> Function(DocumentSnapshot) onDelete;

  const _ZoneCard({
    required this.doc,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  static const _typeColors = {
    'ville':    Color(0xFF1565C0),
    'quartier': Color(0xFF2E7D32),
    'village':  Color(0xFF6A1B9A),
    'secteur':  Color(0xFFBF360C),
  };

  static const _typeIcons = {
    'ville':    Icons.location_city_rounded,
    'quartier': Icons.holiday_village_rounded,
    'village':  Icons.cabin_rounded,
    'secteur':  Icons.grid_view_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final data     = doc.data() as Map<String, dynamic>;
    final name     = data['name'] as String? ?? '';
    final type     = data['type'] as String? ?? '';
    final parent   = data['parentName'] as String? ?? '';
    final isActive = data['isActive'] as bool? ?? true;
    final lat      = (data['lat'] as num?)?.toDouble();
    final lng      = (data['lng'] as num?)?.toDouble();
    final color    = _typeColors[type] ?? Colors.grey;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(_typeIcons[type] ?? Icons.place_rounded,
              color: color, size: 22),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(name,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: isActive ? Colors.black87 : Colors.grey)),
            ),
            if (!isActive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.red.shade200)),
                child: const Text('Inactif',
                    style: TextStyle(fontSize: 11, color: Colors.red)),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(type,
                    style: TextStyle(
                        fontSize: 11,
                        color: color,
                        fontWeight: FontWeight.w600)),
              ),
              if (parent.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text('· $parent',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ]),
            if (lat != null && lng != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '📍 ${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Colors.grey),
          onSelected: (v) {
            if (v == 'edit')   onEdit(doc);
            if (v == 'toggle') onToggle(doc);
            if (v == 'delete') onDelete(doc);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit',
                child: ListTile(
                    dense: true,
                    leading: Icon(Icons.edit_rounded, color: Colors.blue),
                    title: Text('Modifier'))),
            PopupMenuItem(value: 'toggle',
                child: ListTile(
                    dense: true,
                    leading: Icon(
                        isActive
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: isActive ? Colors.orange : Colors.green),
                    title: Text(isActive ? 'Désactiver' : 'Réactiver'))),
            const PopupMenuItem(value: 'delete',
                child: ListTile(
                    dense: true,
                    leading: Icon(Icons.delete_rounded, color: Colors.red),
                    title: Text('Supprimer',
                        style: TextStyle(color: Colors.red)))),
          ],
        ),
      ),
    );
  }
}
