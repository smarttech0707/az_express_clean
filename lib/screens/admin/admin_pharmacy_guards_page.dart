import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../models/pharmacy_guard.dart';
import '../../services/pharmacy_guard_repository.dart';

enum _GuardFilter { current, upcoming, expired, week, month, unverified }

class AdminPharmacyGuardsPage extends StatefulWidget {
  const AdminPharmacyGuardsPage({super.key});
  @override
  State<AdminPharmacyGuardsPage> createState() =>
      _AdminPharmacyGuardsPageState();
}

class _AdminPharmacyGuardsPageState extends State<AdminPharmacyGuardsPage> {
  final _repository = PharmacyGuardRepository();
  _GuardFilter _filter = _GuardFilter.current;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Gardes pharmacies')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _showForm(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Ajouter une garde'),
        ),
        body: Column(children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<_GuardFilter>(
              segments: const [
                ButtonSegment(
                    value: _GuardFilter.current, label: Text('En cours')),
                ButtonSegment(
                    value: _GuardFilter.upcoming, label: Text('À venir')),
                ButtonSegment(
                    value: _GuardFilter.expired, label: Text('Expirées')),
                ButtonSegment(value: _GuardFilter.week, label: Text('Semaine')),
                ButtonSegment(value: _GuardFilter.month, label: Text('Mois')),
                ButtonSegment(
                    value: _GuardFilter.unverified,
                    label: Text('Non vérifiées')),
              ],
              selected: {_filter},
              onSelectionChanged: (value) =>
                  setState(() => _filter = value.first),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<PharmacyGuard>>(
              stream: _repository.watchAllForAdmin(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Erreur : ${snapshot.error}'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final guards = snapshot.data!.where(_matches).toList();
                if (guards.isEmpty) {
                  return const Center(child: Text('Aucune garde.'));
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
                  itemCount: guards.length,
                  itemBuilder: (context, index) {
                    final guard = guards[index];
                    return _GuardCard(
                      guard: guard,
                      onEdit: () => _showForm(existing: guard),
                      onToggle: () =>
                          _repository.setActive(guard.id, !guard.isActive),
                      onDelete: () => _delete(guard),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      );

  bool _matches(PharmacyGuard guard) {
    final now = DateTime.now().toUtc();
    return switch (_filter) {
      _GuardFilter.current => guard.isOnDutyAt(now),
      _GuardFilter.upcoming => guard.guardStartAt.isAfter(now),
      _GuardFilter.expired => guard.isExpiredAt(now),
      _GuardFilter.week => guard.matchesPeriod(PharmacyGuardPeriod.week, now),
      _GuardFilter.month => guard.matchesPeriod(PharmacyGuardPeriod.month, now),
      _GuardFilter.unverified => !guard.isVerified,
    };
  }

  Future<void> _delete(PharmacyGuard guard) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Supprimer la garde ?'),
            content: Text(guard.name),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Annuler')),
              TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Supprimer')),
            ],
          ),
        ) ??
        false;
    if (confirmed) await _repository.delete(guard.id);
  }

  Future<void> _showForm({PharmacyGuard? existing}) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final city = TextEditingController(text: existing?.city ?? 'Abengourou');
    final district = TextEditingController(text: existing?.district ?? '');
    final address = TextEditingController(text: existing?.address ?? '');
    final phone = TextEditingController(text: existing?.phone ?? '');
    final source =
        TextEditingController(text: existing?.sourceName ?? 'Admin AZ Express');
    var start = existing?.guardStartAt.toLocal() ?? DateTime.now();
    var end = existing?.guardEndAt.toLocal() ??
        DateTime.now().add(const Duration(hours: 12));
    var verified = existing?.isVerified ?? true;
    var active = existing?.isActive ?? true;
    var partnerId = existing?.partnerPharmacyId;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(
              existing == null ? 'Ajouter une garde' : 'Modifier la garde'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Nom *')),
                TextField(
                    controller: city,
                    decoration: const InputDecoration(labelText: 'Ville *')),
                TextField(
                    controller: district,
                    decoration: const InputDecoration(labelText: 'Quartier')),
                TextField(
                    controller: address,
                    decoration: const InputDecoration(labelText: 'Adresse')),
                TextField(
                    controller: phone,
                    decoration: const InputDecoration(labelText: 'Téléphone')),
                TextField(
                    controller: source,
                    decoration: const InputDecoration(labelText: 'Source')),
                const SizedBox(height: 8),
                _PartnerPicker(
                    value: partnerId,
                    onChanged: (value) => setState(() => partnerId = value)),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Début'),
                  subtitle: Text(start.toString()),
                  trailing: const Icon(Icons.edit_calendar_rounded),
                  onTap: () async {
                    final value = await _pickDateTime(start);
                    if (value != null) setState(() => start = value);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Fin'),
                  subtitle: Text(end.toString()),
                  trailing: const Icon(Icons.edit_calendar_rounded),
                  onTap: () async {
                    final value = await _pickDateTime(end);
                    if (value != null) setState(() => end = value);
                  },
                ),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Vérifiée'),
                    value: verified,
                    onChanged: (v) => setState(() => verified = v)),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    value: active,
                    onChanged: (v) => setState(() => active = v)),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Annuler')),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty ||
                    city.text.trim().isEmpty ||
                    !end.isAfter(start)) {
                  return;
                }
                await _repository.saveManual(PharmacyGuard(
                  id: existing?.id ?? '',
                  name: name.text.trim(),
                  city: city.text.trim(),
                  district: district.text.trim(),
                  address: address.text.trim(),
                  phone: phone.text.trim(),
                  guardStartAt: start.toUtc(),
                  guardEndAt: end.toUtc(),
                  sourceType: partnerId == null ? 'manual' : 'partner',
                  sourceName: source.text.trim(),
                  isVerified: verified,
                  isActive: active,
                  linkedPartner: partnerId != null,
                  partnerPharmacyId: partnerId,
                  pharmacyId: partnerId,
                ));
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }

  Future<DateTime?> _pickDateTime(DateTime initial) async {
    final date = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime.now().subtract(const Duration(days: 365)),
        lastDate: DateTime.now().add(const Duration(days: 730)));
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }
}

class _PartnerPicker extends StatelessWidget {
  const _PartnerPicker({required this.value, required this.onChanged});
  final String? value;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) =>
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('pharmacies')
            .orderBy('name')
            .snapshots(),
        builder: (context, snapshot) => DropdownButtonFormField<String?>(
          initialValue: value,
          decoration:
              const InputDecoration(labelText: 'Pharmacie partenaire liée'),
          items: [
            const DropdownMenuItem<String?>(
                value: null, child: Text('Aucune — pharmacie externe')),
            ...(snapshot.data?.docs ?? []).map((doc) => DropdownMenuItem(
                value: doc.id,
                child: Text(doc.data()['name'] as String? ?? doc.id))),
          ],
          onChanged: onChanged,
        ),
      );
}

class _GuardCard extends StatelessWidget {
  const _GuardCard(
      {required this.guard,
      required this.onEdit,
      required this.onToggle,
      required this.onDelete});
  final PharmacyGuard guard;
  final VoidCallback onEdit, onToggle, onDelete;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.local_pharmacy_rounded),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(guard.name,
                          style: const TextStyle(fontWeight: FontWeight.bold))),
                  Switch(value: guard.isActive, onChanged: (_) => onToggle()),
                ]),
                Text(
                    '${guard.city} — ${guard.address ?? guard.district ?? ''}'),
                Text(
                    '${guard.guardStartAt.toLocal()} → ${guard.guardEndAt.toLocal()}'),
                Text(
                    '${guard.linkedPartner ? 'Partenaire lié' : 'Source ${guard.sourceName ?? guard.sourceType}'} • ${guard.isVerified ? 'vérifiée' : 'non vérifiée'}'),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Modifier')),
                  OutlinedButton.icon(
                      onPressed: onToggle,
                      icon: Icon(guard.isActive
                          ? Icons.pause_circle_outline
                          : Icons.play_circle_outline),
                      label: Text(guard.isActive ? 'Désactiver' : 'Réactiver')),
                  TextButton.icon(
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Supprimer')),
                ]),
              ]),
        ),
      );
}
