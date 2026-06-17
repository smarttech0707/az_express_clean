import 'dart:math';
import '../../widgets/scale_button.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

class AdminPharmaciesPage extends StatelessWidget {
  const AdminPharmaciesPage({super.key});

  void _showAddPharmacy(BuildContext context, {DocumentSnapshot? existing}) {
    final data       = existing?.data() as Map<String, dynamic>?;
    final nameCtrl   = TextEditingController(text: data?['name']    ?? '');
    final addressCtrl= TextEditingController(text: data?['address'] ?? '');
    final phoneCtrl  = TextEditingController(text: data?['phone']   ?? '');
    final hoursCtrl  = TextEditingController(text: data?['hours']   ?? '08h–22h');
    final latCtrl    = TextEditingController(text: data?['lat']?.toString() ?? '');
    final lngCtrl    = TextEditingController(text: data?['lng']?.toString() ?? '');
    // For creation: pre-fill generated password. For edit: blank (leave unchanged).
    final passCtrl   = TextEditingController(
        text: existing == null ? _generatePassword() : '');
    bool isOnDuty   = data?['isOnDuty'] ?? false;
    bool gpsLoading = false;
    bool showPass   = existing == null; // visible by default for new pharmacies

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(existing == null ? 'Ajouter une pharmacie' : 'Modifier la pharmacie'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _field(nameCtrl, 'Nom de la pharmacie', Icons.local_pharmacy),
                const SizedBox(height: 10),
                _field(addressCtrl, 'Adresse (quartier / rue)', Icons.location_on),
                const SizedBox(height: 10),
                _field(phoneCtrl, 'Téléphone', Icons.phone,
                    type: TextInputType.phone),
                const SizedBox(height: 10),
                _field(hoursCtrl, 'Horaires (ex: 08h–22h)', Icons.access_time),
                const SizedBox(height: 10),

                // GPS fields
                Row(
                  children: [
                    Expanded(
                      child: _field(latCtrl, 'Latitude', Icons.gps_fixed,
                          type: const TextInputType.numberWithOptions(
                              decimal: true, signed: true)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _field(lngCtrl, 'Longitude', Icons.gps_not_fixed,
                          type: const TextInputType.numberWithOptions(
                              decimal: true, signed: true)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: gpsLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location, size: 18),
                    label: Text(gpsLoading ? 'Localisation...' : 'Ma position GPS'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      side: BorderSide(color: Colors.red.shade200),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: gpsLoading
                        ? null
                        : () async {
                            setS(() => gpsLoading = true);
                            try {
                              bool svc =
                                  await Geolocator.isLocationServiceEnabled();
                              if (!svc) {
                                setS(() => gpsLoading = false);
                                if (!ctx.mounted) return;
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                      content: Text('GPS désactivé sur cet appareil')));
                                return;
                              }
                              LocationPermission perm =
                                  await Geolocator.checkPermission();
                              if (perm == LocationPermission.denied) {
                                perm = await Geolocator.requestPermission();
                              }
                              if (perm == LocationPermission.denied ||
                                  perm == LocationPermission.deniedForever) {
                                setS(() => gpsLoading = false);
                                if (!ctx.mounted) return;
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Permission GPS refusée. Activez-la dans les paramètres.')));
                                return;
                              }
                              final pos = await Geolocator.getCurrentPosition();
                              setS(() {
                                latCtrl.text = pos.latitude.toStringAsFixed(6);
                                lngCtrl.text = pos.longitude.toStringAsFixed(6);
                                gpsLoading = false;
                              });
                            } catch (_) {
                              setS(() => gpsLoading = false);
                              if (!ctx.mounted) return;
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                    content: Text('Impossible d\'obtenir la position GPS')));
                            }
                          },
                  ),
                ),

                const SizedBox(height: 14),
                const Divider(),
                const SizedBox(height: 6),

                // Password section
                Text(
                  existing == null
                      ? 'Mot de passe temporaire'
                      : 'Réinitialiser le mot de passe',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: passCtrl,
                        obscureText: !showPass,
                        style: const TextStyle(
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          hintText: existing == null
                              ? 'Mot de passe temporaire'
                              : 'Laisser vide pour ne pas modifier',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            icon: Icon(showPass
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setS(() => showPass = !showPass),
                          ),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Copy button
                    Tooltip(
                      message: 'Copier',
                      child: IconButton(
                        icon: const Icon(Icons.copy_rounded,
                            color: Colors.grey),
                        onPressed: () {
                          final p = passCtrl.text.trim();
                          if (p.isEmpty) return;
                          Clipboard.setData(ClipboardData(text: p));
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content: Text('Mot de passe copié'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),

                // Regenerate button (only for creation)
                if (existing == null) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () =>
                          setS(() => passCtrl.text = _generatePassword()),
                      icon: const Icon(Icons.refresh, size: 15),
                      label: const Text('Régénérer',
                          style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 0),
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          color: Colors.orange.shade700, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          existing == null
                              ? 'Communiquez ce mot de passe à la pharmacie. Elle devra le changer à sa première connexion.'
                              : 'Si vous saisissez un mot de passe, la pharmacie devra le changer à sa prochaine connexion.',
                          style: TextStyle(
                              fontSize: 11, color: Colors.orange.shade800),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 10),
                SwitchListTile(
                  value: isOnDuty,
                  onChanged: (v) => setS(() => isOnDuty = v),
                  title: const Text('De garde maintenant'),
                  activeThumbColor: Colors.red,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Annuler')),
            ScaleButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white),
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty) return;
                final newPass = passCtrl.text.trim();
                final payload = <String, dynamic>{
                  'name':     nameCtrl.text.trim(),
                  'address':  addressCtrl.text.trim(),
                  'phone':    phoneCtrl.text.trim(),
                  'hours':    hoursCtrl.text.trim(),
                  'isOnDuty': isOnDuty,
                  'lat': double.tryParse(latCtrl.text.trim()) ?? 0.0,
                  'lng': double.tryParse(lngCtrl.text.trim()) ?? 0.0,
                };
                if (existing != null) {
                  // Edit: only update password fields if a new one is provided
                  if (newPass.isNotEmpty) {
                    payload['password']           = newPass;
                    payload['mustChangePassword'] = true;
                  }
                  await existing.reference.update(payload);
                } else {
                  // Create: always include password + force change on first login
                  payload['password']           = newPass.isNotEmpty
                      ? newPass
                      : _generatePassword();
                  payload['mustChangePassword'] = true;
                  payload['createdAt']          = FieldValue.serverTimestamp();
                  await FirebaseFirestore.instance
                      .collection('pharmacies')
                      .add(payload);
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Pharmacies'),
        backgroundColor: Colors.red.shade700,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.red.shade700,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
        onPressed: () => _showAddPharmacy(context),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('pharmacies')
            .orderBy('name')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];

          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.local_pharmacy_outlined,
                      size: 72, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  const Text('Aucune pharmacie enregistrée',
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                  const SizedBox(height: 8),
                  const Text('Appuyez sur + pour en ajouter',
                      style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          return ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final doc    = docs[i];
              final data   = doc.data() as Map<String, dynamic>;
              final onDuty = data['isOnDuty'] ?? false;
              final hasPass = ((data['password'] as String?) ?? '').isNotEmpty ||
                  ((data['accessCode'] as String?) ?? '').isNotEmpty;

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: onDuty
                      ? Border.all(color: Colors.red.shade200, width: 1.5)
                      : null,
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 8)
                  ],
                ),
                child: Column(
                  children: [
                    ListTile(
                      contentPadding:
                          const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      leading: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: (onDuty ? Colors.red : Colors.grey)
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(Icons.local_pharmacy,
                            color: onDuty
                                ? Colors.red.shade700
                                : Colors.grey,
                            size: 26),
                      ),
                      title: Text(data['name'] ?? '—',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(data['address'] ?? '',
                              style: const TextStyle(fontSize: 12)),
                          Text(data['phone'] ?? '',
                              style: TextStyle(
                                  color: Colors.blue.shade700,
                                  fontSize: 12)),
                          if ((data['hours'] ?? '').isNotEmpty)
                            Text('🕐 ${data['hours']}',
                                style: const TextStyle(fontSize: 11)),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(
                                hasPass
                                    ? Icons.lock_rounded
                                    : Icons.lock_open_rounded,
                                size: 12,
                                color:
                                    hasPass ? Colors.green : Colors.orange,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                hasPass
                                    ? 'Accès configuré'
                                    : 'Aucun mot de passe',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: hasPass
                                        ? Colors.green
                                        : Colors.orange),
                              ),
                            ],
                          ),
                        ],
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Switch(
                            value: onDuty,
                            activeThumbColor: Colors.red,
                            onChanged: (_) => doc.reference
                                .update({'isOnDuty': !onDuty}),
                          ),
                          Text(
                            onDuty ? 'De garde' : 'Fermée',
                            style: TextStyle(
                              fontSize: 10,
                              color: onDuty ? Colors.red : Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton.icon(
                            onPressed: () =>
                                _showAddPharmacy(context, existing: doc),
                            icon: const Icon(Icons.edit_outlined,
                                size: 16, color: Colors.blue),
                            label: const Text('Modifier',
                                style: TextStyle(
                                    color: Colors.blue, fontSize: 12)),
                          ),
                          TextButton.icon(
                            onPressed: () => _confirmDelete(context, doc),
                            icon: const Icon(Icons.delete_outline,
                                size: 16, color: Colors.red),
                            label: const Text('Supprimer',
                                style: TextStyle(
                                    color: Colors.red, fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _confirmDelete(BuildContext context, DocumentSnapshot doc) {
    final name = (doc.data() as Map<String, dynamic>)['name'] ?? 'cette pharmacie';
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer'),
        content: Text('Supprimer "$name" ? Cette action est irréversible.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          ScaleButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              doc.reference.delete();
              Navigator.pop(context);
            },
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

String _generatePassword() {
  const chars =
      'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  final rand = Random.secure();
  return List.generate(8, (_) => chars[rand.nextInt(chars.length)]).join();
}

Widget _field(TextEditingController ctrl, String label, IconData icon,
    {TextInputType? type}) {
  return TextField(
    controller: ctrl,
    keyboardType: type,
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
  );
}
