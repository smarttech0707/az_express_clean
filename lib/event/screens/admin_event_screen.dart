import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';

Future<void> _openDocument(dynamic url) async {
  if (url is String && url.isNotEmpty) {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}

Future<void> _changeStatus(
  QueryDocumentSnapshot<Map<String, dynamic>> doc, {
  required String status,
  required bool suspended,
  String reason = '',
}) async {
  final offers = status == 'approved'
      ? await FirebaseFirestore.instance
          .collection('event_offers')
          .where('providerId', isEqualTo: doc.id)
          .get()
      : null;
  final batch = FirebaseFirestore.instance.batch();
  batch.update(doc.reference, {
    'status': status,
    'isSuspended': suspended,
    'rejectionReason': reason,
    'suspensionReason': suspended ? reason : '',
    'validatedAt': FieldValue.serverTimestamp(),
    'updatedAt': FieldValue.serverTimestamp(),
  });
  batch.set(doc.reference.collection('history').doc(), {
    'status': status,
    'isSuspended': suspended,
    'reason': reason,
    'createdAt': FieldValue.serverTimestamp(),
  });
  if (offers != null) {
    for (final offer in offers.docs) {
      batch.update(offer.reference, {
        'isActive': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }
  await batch.commit();
}

Future<void> _reject(
  BuildContext context,
  QueryDocumentSnapshot<Map<String, dynamic>> doc,
) async {
  final controller = TextEditingController();
  final reason = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Motif du refus'),
      content: TextField(
        controller: controller,
        minLines: 2,
        maxLines: 4,
        decoration:
            const InputDecoration(hintText: 'Éléments à corriger obligatoires'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
          child: const Text('Confirmer'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (reason == null || reason.isEmpty) return;
  await _changeStatus(
    doc,
    status: 'rejected',
    suspended: false,
    reason: reason,
  );
}

Future<void> _suspend(
  BuildContext context,
  QueryDocumentSnapshot<Map<String, dynamic>> doc,
  String status,
) async {
  final controller = TextEditingController();
  final reason = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Motif de suspension'),
      content: TextField(
        controller: controller,
        minLines: 2,
        maxLines: 4,
        decoration: const InputDecoration(hintText: 'Motif obligatoire'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
          child: const Text('Suspendre'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (reason == null || reason.isEmpty) return;
  await _changeStatus(
    doc,
    status: status,
    suspended: true,
    reason: reason,
  );
}

class AdminEventScreen extends StatelessWidget {
  const AdminEventScreen({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Événementiel'),
            bottom: const TabBar(
              isScrollable: true,
              tabs: [
                Tab(text: 'Prestataires'),
                Tab(text: 'Réservations'),
                Tab(text: 'Annonces'),
                Tab(text: 'Signalements'),
              ],
            ),
          ),
          body: const TabBarView(children: [
            _ProvidersAdmin(),
            _ReservationsAdmin(),
            _OffersAdmin(),
            _ReportsAdmin(),
          ]),
        ),
      );
}

class _ProvidersAdmin extends StatelessWidget {
  const _ProvidersAdmin();

  @override
  Widget build(BuildContext context) => _CollectionList(
        query: FirebaseFirestore.instance
            .collection('event_providers')
            .orderBy('createdAt', descending: true),
        empty: 'Aucun prestataire.',
        builder: (doc) {
          final d = doc.data();
          final status = d['status'] as String? ?? 'pending';
          final suspended = d['isSuspended'] as bool? ?? false;
          return Card(
            child: ExpansionTile(
              title: Text(d['shopName'] as String? ?? 'Prestataire'),
              subtitle: Text('${d['zone'] ?? ''} • $status'
                  '\nPlan demandé : ${(d['requestedPlan'] ?? 'standard').toString().toUpperCase()}'
                  '${suspended ? ' • suspendu' : ''}'),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(d['description'] as String? ?? ''),
                ),
                _ProviderDocuments(providerId: doc.id),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () => _changeStatus(doc,
                          status: 'approved', suspended: false),
                      icon: const Icon(Icons.verified_rounded),
                      label: const Text('Valider'),
                    ),
                    TextButton.icon(
                      onPressed: () => suspended
                          ? _changeStatus(doc, status: status, suspended: false)
                          : _suspend(context, doc, status),
                      icon: Icon(suspended
                          ? Icons.play_circle_outline
                          : Icons.pause_circle_outline),
                      label: Text(suspended ? 'Réactiver' : 'Suspendre'),
                    ),
                    TextButton.icon(
                      onPressed: () => _reject(context, doc),
                      icon: const Icon(Icons.block_outlined),
                      label: const Text('Refuser'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
}

class _ProviderDocuments extends StatelessWidget {
  const _ProviderDocuments({required this.providerId});
  final String providerId;

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: FirebaseFirestore.instance
            .collection('event_provider_documents')
            .doc(providerId)
            .get(),
        builder: (_, snapshot) {
          final data = snapshot.data?.data();
          if (data == null) return const SizedBox.shrink();
          return Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: () => _openDocument(data['identityUrl']),
                icon: const Icon(Icons.badge_outlined),
                label: const Text("Pièce d'identité"),
              ),
              if (data['rccmUrl'] != null)
                TextButton.icon(
                  onPressed: () => _openDocument(data['rccmUrl']),
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('RCCM'),
                ),
            ],
          );
        },
      );
}

class _ReservationsAdmin extends StatelessWidget {
  const _ReservationsAdmin();

  @override
  Widget build(BuildContext context) => _CollectionList(
        query: FirebaseFirestore.instance
            .collection('event_reservations')
            .orderBy('createdAt', descending: true)
            .limit(200),
        empty: 'Aucune réservation.',
        builder: (doc) {
          final d = doc.data();
          return Card(
            child: ListTile(
              leading: const Icon(Icons.event_available_rounded,
                  color: AppColors.primary),
              title: Text('${d['totalAmount'] ?? 0} FCFA'),
              subtitle: Text(
                  '${d['address'] ?? ''}\n${d['paymentMethod'] ?? ''} • ${d['status'] ?? ''}'),
              isThreeLine: true,
              trailing: PopupMenuButton<String>(
                onSelected: (status) => doc.reference.update({
                  'status': status,
                  'updatedAt': FieldValue.serverTimestamp(),
                }),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'confirmed', child: Text('Confirmer')),
                  PopupMenuItem(value: 'completed', child: Text('Terminer')),
                  PopupMenuItem(value: 'cancelled', child: Text('Annuler')),
                ],
              ),
            ),
          );
        },
      );
}

class _OffersAdmin extends StatelessWidget {
  const _OffersAdmin();

  @override
  Widget build(BuildContext context) => _CollectionList(
        query: FirebaseFirestore.instance
            .collection('event_offers')
            .orderBy('createdAt', descending: true)
            .limit(200),
        empty: 'Aucune annonce.',
        builder: (doc) {
          final d = doc.data();
          final active = d['isActive'] as bool? ?? true;
          return Card(
            child: ListTile(
              title: Text(d['title'] as String? ?? 'Prestation'),
              subtitle:
                  Text('${d['providerName'] ?? ''} • ${d['category'] ?? ''}'),
              trailing: IconButton(
                tooltip: active ? 'Masquer' : 'Republier',
                onPressed: () => doc.reference.update({'isActive': !active}),
                icon: Icon(active
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
              ),
            ),
          );
        },
      );
}

class _ReportsAdmin extends StatelessWidget {
  const _ReportsAdmin();

  @override
  Widget build(BuildContext context) => _CollectionList(
        query: FirebaseFirestore.instance
            .collection('event_reports')
            .orderBy('createdAt', descending: true)
            .limit(200),
        empty: 'Aucun signalement.',
        builder: (doc) {
          final d = doc.data();
          return Card(
            child: ListTile(
              leading: const Icon(Icons.flag_outlined, color: Colors.red),
              title: Text(d['reason'] as String? ?? 'Signalement'),
              subtitle:
                  Text('${d['targetType'] ?? ''} • ${d['status'] ?? 'open'}'),
              trailing: TextButton(
                onPressed: () => doc.reference.update({'status': 'resolved'}),
                child: const Text('Traité'),
              ),
            ),
          );
        },
      );
}

class _CollectionList extends StatelessWidget {
  const _CollectionList({
    required this.query,
    required this.empty,
    required this.builder,
  });
  final Query<Map<String, dynamic>> query;
  final String empty;
  final Widget Function(QueryDocumentSnapshot<Map<String, dynamic>>) builder;

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: query.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Erreur : ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.data!.docs.isEmpty) return Center(child: Text(empty));
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: snapshot.data!.docs.length,
            itemBuilder: (_, i) => builder(snapshot.data!.docs[i]),
          );
        },
      );
}
