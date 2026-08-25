import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../theme/app_theme.dart';
import '../event_constants.dart';
import '../models/event_models.dart';
import '../services/event_service.dart';
import 'event_chat_screen.dart';
import 'event_provider_registration.dart';
import '../../widgets/stream_error_state.dart';

class EventProviderPortal extends StatefulWidget {
  const EventProviderPortal({super.key});

  @override
  State<EventProviderPortal> createState() => _EventProviderPortalState();
}

class _EventProviderPortalState extends State<EventProviderPortal> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && !user.isAnonymous) {
      return const EventProviderDashboard();
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Espace prestataire événementiel')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              const Icon(Icons.celebration_rounded,
                  size: 72, color: AppColors.primary),
              const SizedBox(height: 16),
              const Text(
                'Gérez votre boutique, vos prestations et vos réservations.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'E-mail'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Mot de passe'),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _loading ? null : _signIn,
                child: Text(_loading ? 'Connexion…' : 'Se connecter'),
              ),
              TextButton(
                onPressed: _loading ? null : _register,
                child: const Text('Devenir prestataire'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _auth(Future<UserCredential> Function() action) async {
    setState(() => _loading = true);
    try {
      final current = FirebaseAuth.instance.currentUser;
      if (current?.isAnonymous == true) await FirebaseAuth.instance.signOut();
      await action();
      if (mounted) setState(() {});
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message ?? e.code)));
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signIn() =>
      _auth(() => FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _email.text.trim(), password: _password.text));

  Future<void> _register() =>
      _auth(() => FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _email.text.trim(), password: _password.text));
}

class EventProviderDashboard extends StatefulWidget {
  const EventProviderDashboard({super.key});

  @override
  State<EventProviderDashboard> createState() => _EventProviderDashboardState();
}

class _EventProviderDashboardState extends State<EventProviderDashboard> {
  final service = EventService();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<EventProviderProfile?>(
      stream: service.watchMyProfile(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        // Stabilisation V1.0 : une erreur de flux (réseau, permission) ne
        // doit jamais être confondue avec "aucun profil" — sinon un
        // prestataire déjà approuvé se retrouverait devant le formulaire
        // d'inscription à chaque coupure réseau transitoire.
        if (snapshot.hasError) {
          return const Scaffold(body: StreamErrorState());
        }
        final profile = snapshot.data;
        if (profile == null) {
          return EventProviderRegistration(service: service);
        }
        if (profile.status != 'approved' || profile.isSuspended) {
          return _ProviderApprovalStatus(profile: profile, service: service);
        }
        return DefaultTabController(
          length: 4,
          child: Scaffold(
            appBar: AppBar(
              title: Text(profile.shopName),
              bottom: const TabBar(tabs: [
                Tab(text: 'Prestations'),
                Tab(text: 'Réservations'),
                Tab(text: 'Messages'),
                Tab(text: 'Profil'),
              ]),
            ),
            body: TabBarView(children: [
              _OffersTab(service: service, profile: profile),
              _ReservationsTab(service: service, profile: profile),
              EventConversationListScreen(service: service),
              _ProfileTab(
                profile: profile,
                service: service,
                onEdit: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _ProviderProfileForm(
                        service: service, profile: profile),
                  ),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _ProviderApprovalStatus extends StatelessWidget {
  const _ProviderApprovalStatus({
    required this.profile,
    required this.service,
  });
  final EventProviderProfile profile;
  final EventService service;

  @override
  Widget build(BuildContext context) {
    final rejected = profile.status == 'rejected';
    final title = profile.isSuspended
        ? 'Compte suspendu'
        : rejected
            ? 'Demande refusée'
            : 'En attente de validation';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Suivi de ma demande'),
        actions: [
          IconButton(
            tooltip: 'Déconnexion',
            onPressed: FirebaseAuth.instance.signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    profile.isSuspended
                        ? Icons.pause_circle_outline
                        : rejected
                            ? Icons.cancel_outlined
                            : Icons.hourglass_top_rounded,
                    size: 72,
                    color: AppColors.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 10),
                  Text(
                    rejected && profile.rejectionReason.isNotEmpty
                        ? 'Motif : ${profile.rejectionReason}'
                        : profile.isSuspended
                            ? profile.suspensionReason.isNotEmpty
                                ? 'Motif : ${profile.suspensionReason}'
                                : "Contactez l'administration pour connaître le motif."
                            : "Votre boutique sera activée après contrôle des informations et documents.",
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _ProviderProfileForm(
                          service: service,
                          profile: profile,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Modifier mes informations'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProviderProfileForm extends StatefulWidget {
  const _ProviderProfileForm({required this.service, this.profile});
  final EventService service;
  final EventProviderProfile? profile;

  @override
  State<_ProviderProfileForm> createState() => _ProviderProfileFormState();
}

class _ProviderProfileFormState extends State<_ProviderProfileForm> {
  late final _name = TextEditingController(text: widget.profile?.shopName);
  late final _description =
      TextEditingController(text: widget.profile?.description);
  late final _zone = TextEditingController(text: widget.profile?.zone);
  late final _phone = TextEditingController(text: widget.profile?.phone);
  bool saving = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(widget.profile == null
                ? 'Créer ma boutique'
                : 'Modifier ma boutique')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
                controller: _name,
                decoration:
                    const InputDecoration(labelText: 'Nom de boutique')),
            const SizedBox(height: 12),
            TextField(
                controller: _description,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Description')),
            const SizedBox(height: 12),
            TextField(
                controller: _zone,
                decoration:
                    const InputDecoration(labelText: "Zone d'intervention")),
            const SizedBox(height: 12),
            TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Téléphone')),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: saving ? null : _save,
              child: Text(saving ? 'Enregistrement…' : 'Enregistrer'),
            ),
            if (widget.profile == null)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  "La boutique sera visible après validation par l'administration.",
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      );

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _zone.text.trim().isEmpty) return;
    setState(() => saving = true);
    try {
      await widget.service.saveProvider(
        id: widget.profile?.id,
        shopName: _name.text,
        description: _description.text,
        zone: _zone.text,
        phone: _phone.text,
      );
      if (mounted && widget.profile != null) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}

class _OffersTab extends StatelessWidget {
  const _OffersTab({required this.service, required this.profile});
  final EventService service;
  final EventProviderProfile profile;

  @override
  Widget build(BuildContext context) => StreamBuilder<List<EventOffer>>(
        stream: service.watchProviderOffers(profile.id),
        builder: (context, snapshot) {
          final offers = snapshot.data ?? const [];
          return Scaffold(
            body: offers.isEmpty
                ? const Center(
                    child: Text('Publiez votre première prestation.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: offers.length,
                    itemBuilder: (_, i) {
                      final offer = offers[i];
                      return Card(
                        child: ListTile(
                          leading: Icon(offer.category.icon),
                          title: Text(offer.title),
                          subtitle: Text(
                              '${offer.unitPrice} FCFA • Stock ${offer.availableQuantity}'),
                          trailing: Icon(
                            offer.isActive
                                ? Icons.visibility_rounded
                                : Icons.visibility_off_rounded,
                          ),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => _OfferForm(
                                service: service,
                                profile: profile,
                                offer: offer,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: profile.status != 'approved' || profile.isSuspended
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              _OfferForm(service: service, profile: profile),
                        ),
                      ),
              icon: const Icon(Icons.add),
              label: Text(profile.status == 'approved'
                  ? 'Publier'
                  : 'Validation en attente'),
            ),
          );
        },
      );
}

class _OfferForm extends StatefulWidget {
  const _OfferForm({required this.service, required this.profile, this.offer});
  final EventService service;
  final EventProviderProfile profile;
  final EventOffer? offer;

  @override
  State<_OfferForm> createState() => _OfferFormState();
}

class _OfferFormState extends State<_OfferForm> {
  late final title = TextEditingController(text: widget.offer?.title);
  late final description =
      TextEditingController(text: widget.offer?.description);
  late final price =
      TextEditingController(text: widget.offer?.unitPrice.toString());
  late final quantity =
      TextEditingController(text: widget.offer?.availableQuantity.toString());
  late final zone =
      TextEditingController(text: widget.offer?.zone ?? widget.profile.zone);
  late final conditions = TextEditingController(text: widget.offer?.conditions);
  late final opening = TextEditingController(text: widget.offer?.openingTime);
  late final closing = TextEditingController(text: widget.offer?.closingTime);
  late EventCategory category = widget.offer?.category ?? EventCategory.rental;
  late String subcategory =
      widget.offer?.subcategory ?? eventSubcategories[category]!.first;
  late bool delivery = widget.offer?.deliveryAvailable ?? false;
  late bool installation = widget.offer?.installationAvailable ?? false;
  late bool dismantling = widget.offer?.dismantlingAvailable ?? false;
  late bool active = widget.offer?.isActive ?? true;
  late final Set<String> days =
      Set<String>.from(widget.offer?.availableDays ?? const []);
  bool saving = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Prestation')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField(
              initialValue: category,
              items: EventCategory.values
                  .map((v) => DropdownMenuItem(value: v, child: Text(v.label)))
                  .toList(),
              onChanged: (v) => setState(() {
                category = v!;
                subcategory = eventSubcategories[v]!.first;
              }),
              decoration: const InputDecoration(labelText: 'Catégorie'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField(
              key: ValueKey(category),
              initialValue: subcategory,
              items: eventSubcategories[category]!
                  .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                  .toList(),
              onChanged: (v) => setState(() => subcategory = v!),
              decoration: const InputDecoration(labelText: 'Sous-catégorie'),
            ),
            const SizedBox(height: 12),
            TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Titre')),
            const SizedBox(height: 12),
            TextField(
                controller: description,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Description')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: price,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Tarif unitaire FCFA'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: quantity,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Quantité disponible'),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            TextField(
                controller: zone,
                decoration:
                    const InputDecoration(labelText: "Zone d'intervention")),
            const SizedBox(height: 12),
            TextField(
                controller: conditions,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Conditions')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: opening,
                  decoration:
                      const InputDecoration(labelText: 'Ouverture (ex. 08:00)'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: closing,
                  decoration:
                      const InputDecoration(labelText: 'Fermeture (ex. 18:00)'),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            const Text('Jours disponibles'),
            Wrap(
              spacing: 6,
              children: const ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim']
                  .map((day) => FilterChip(
                        label: Text(day),
                        selected: days.contains(day),
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            days.add(day);
                          } else {
                            days.remove(day);
                          }
                        }),
                      ))
                  .toList(),
            ),
            SwitchListTile(
                value: delivery,
                onChanged: (v) => setState(() => delivery = v),
                title: const Text('Livraison')),
            SwitchListTile(
                value: installation,
                onChanged: (v) => setState(() => installation = v),
                title: const Text('Installation')),
            SwitchListTile(
                value: dismantling,
                onChanged: (v) => setState(() => dismantling = v),
                title: const Text('Démontage')),
            SwitchListTile(
                value: active,
                onChanged: (v) => setState(() => active = v),
                title: const Text('Annonce active')),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: saving ? null : () => _save(media: 'image'),
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(saving
                  ? 'Enregistrement…'
                  : 'Enregistrer et ajouter une photo'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: saving ? null : () => _save(media: 'video'),
              icon: const Icon(Icons.video_library_outlined),
              label: const Text('Enregistrer et ajouter une vidéo'),
            ),
          ],
        ),
      );

  Future<void> _save({required String media}) async {
    final amount = int.tryParse(price.text);
    final stock = int.tryParse(quantity.text);
    if (title.text.trim().isEmpty ||
        amount == null ||
        amount < 0 ||
        stock == null ||
        stock < 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Vérifiez le titre, le tarif et le stock.')));
      return;
    }
    setState(() => saving = true);
    try {
      final values = <String, dynamic>{
        'title': title.text.trim(),
        'description': description.text.trim(),
        'category': category.name,
        'subcategory': subcategory,
        'unitPrice': amount,
        'availableQuantity': stock,
        'zone': zone.text.trim(),
        'conditions': conditions.text.trim(),
        'deliveryAvailable': delivery,
        'installationAvailable': installation,
        'dismantlingAvailable': dismantling,
        'isActive': active,
        'photoUrls': widget.offer?.photoUrls ?? <String>[],
        'videoUrls': widget.offer?.videoUrls ?? <String>[],
        'availableDays': days.toList(),
        'openingTime': opening.text.trim(),
        'closingTime': closing.text.trim(),
      };
      final id = await widget.service.saveOffer(
        id: widget.offer?.id,
        providerId: widget.profile.id,
        providerName: widget.profile.shopName,
        values: values,
      );
      final picked = media == 'video'
          ? await ImagePicker().pickVideo(
              source: ImageSource.gallery,
              maxDuration: const Duration(minutes: 3),
            )
          : await ImagePicker().pickImage(
              source: ImageSource.gallery,
              imageQuality: 82,
              maxWidth: 1600,
            );
      if (picked != null) {
        final url = await widget.service.uploadMedia(
            offerId: id, path: picked.path, video: media == 'video');
        await widget.service.saveOffer(
          id: id,
          providerId: widget.profile.id,
          providerName: widget.profile.shopName,
          values: {
            if (media == 'video')
              'videoUrls': [...(widget.offer?.videoUrls ?? const []), url]
            else
              'photoUrls': [...(widget.offer?.photoUrls ?? const []), url]
          },
        );
      }
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}

class _ReservationsTab extends StatelessWidget {
  const _ReservationsTab({required this.service, required this.profile});
  final EventService service;
  final EventProviderProfile profile;

  @override
  Widget build(BuildContext context) => StreamBuilder<List<EventReservation>>(
        stream: service.watchProviderReservations(profile.id),
        builder: (context, snapshot) {
          final reservations = snapshot.data ?? const [];
          if (reservations.isEmpty) {
            return const Center(child: Text('Aucune réservation reçue.'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: reservations.length,
            itemBuilder: (_, i) {
              final r = reservations[i];
              return Card(
                child: ExpansionTile(
                  title: Text('${r.totalAmount} FCFA • ${r.status}'),
                  subtitle: Text('${r.address} • ${r.eventTime}'),
                  children: [
                    ...r.items
                        .where((e) => e['providerId'] == profile.id)
                        .map((e) => ListTile(
                              title: Text('${e['title']}'),
                              trailing: Text('x${e['quantity']}'),
                            )),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () => service.updateReservationStatus(
                              r.id, 'confirmed'),
                          child: const Text('Confirmer'),
                        ),
                        TextButton(
                          onPressed: () => service.updateReservationStatus(
                              r.id, 'completed'),
                          child: const Text('Terminer'),
                        ),
                        TextButton(
                          onPressed: () => service.updateReservationStatus(
                              r.id, 'cancelled'),
                          child: const Text('Annuler'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
}

class _ProfileTab extends StatelessWidget {
  const _ProfileTab({
    required this.profile,
    required this.service,
    required this.onEdit,
  });
  final EventProviderProfile profile;
  final EventService service;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const CircleAvatar(
            radius: 42,
            child: Icon(Icons.storefront_rounded, size: 42),
          ),
          const SizedBox(height: 14),
          Text(profile.shopName,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall),
          Text(profile.zone, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Chip(
            label: Text(profile.isSuspended
                ? 'Suspendu'
                : profile.status == 'approved'
                    ? 'Validé'
                    : 'Validation en attente'),
          ),
          const SizedBox(height: 12),
          Text(profile.description),
          const SizedBox(height: 20),
          StreamBuilder<List<EventReservation>>(
            stream: service.watchProviderReservations(profile.id),
            builder: (_, snapshot) {
              final reservations = snapshot.data ?? const [];
              final completed =
                  reservations.where((r) => r.status == 'completed').toList();
              final revenue = completed.fold<int>(
                  0,
                  (total, reservation) =>
                      total +
                      reservation.items
                          .where((item) => item['providerId'] == profile.id)
                          .fold<int>(
                              0,
                              (subtotal, item) =>
                                  subtotal +
                                  ((item['lineTotal'] as num?)?.toInt() ?? 0)));
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  _StatCard(
                      label: 'Réservations', value: '${reservations.length}'),
                  _StatCard(label: 'Terminées', value: '${completed.length}'),
                  _StatCard(label: 'Chiffre', value: '$revenue F'),
                  _StatCard(
                      label: 'Note',
                      value: profile.reviewCount == 0
                          ? '—'
                          : profile.rating.toStringAsFixed(1)),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          Text('Avis récents', style: Theme.of(context).textTheme.titleMedium),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: service.watchProviderReviews(profile.id),
            builder: (_, snapshot) {
              final reviews = snapshot.data?.docs ?? const [];
              if (reviews.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Aucun avis reçu pour le moment.'),
                );
              }
              return Column(
                children: reviews.map((review) {
                  final data = review.data();
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading:
                        const Icon(Icons.star_rounded, color: Colors.amber),
                    title: Text('${data['rating'] ?? 0}/5'),
                    subtitle: Text('${data['comment'] ?? ''}'),
                  );
                }).toList(),
              );
            },
          ),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Modifier le profil'),
          ),
        ],
      );
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        width: 135,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: AppRadius.lgR,
        ),
        child: Column(
          children: [
            Text(value,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            Text(label,
                style:
                    const TextStyle(fontSize: 12, color: AppColors.textLight)),
          ],
        ),
      );
}
