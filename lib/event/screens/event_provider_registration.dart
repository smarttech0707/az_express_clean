import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../theme/app_theme.dart';
import '../../models/professional_subscription.dart';
import '../services/event_service.dart';

const eventRegistrationCategories = <String, List<String>>{
  'Location': [
    'Chaises',
    'Tables',
    'Bâches',
    'Tentes',
    'Vaisselle',
    'Verrerie',
    'Chambres froides',
    'Glacières',
    'Barbecue',
    'Marmites',
    'Groupes électrogènes',
    'Sonorisation',
    'Éclairage',
    'Écrans LED',
    'Podiums',
  ],
  'Décoration': [
    'Mariage',
    'Anniversaire',
    'Baptême',
    'Funérailles',
    'Soutenance',
    'Conférence',
    'Séminaire',
    "Évènement d'entreprise",
    'Fête traditionnelle',
    'Cérémonie religieuse',
  ],
  'Traiteur': [
    'Cuisine africaine',
    'Cuisine européenne',
    'Buffets',
    'Grillades',
    'Cocktail',
    'Boissons',
    'Pâtisserie',
    'Gâteaux',
    'Desserts',
  ],
  'Animation': [
    'Maître de cérémonie (MC)',
    'DJ',
    'Orchestre',
    'Animateur',
    'Chanteur',
    'Groupe traditionnel',
    'Danseurs',
    'Humoriste',
  ],
  'Photo & Vidéo': ['Photographe', 'Vidéaste', 'Drone', 'Photobooth'],
  'Personnel': [
    'Serveurs',
    'Cuisiniers',
    'Hôtesses',
    'Agents de sécurité',
    'Nettoyage',
  ],
};

Color eventRegistrationChoiceForeground(ColorScheme colors, bool selected) =>
    selected ? colors.onSecondary : colors.onSurface;

Color eventRegistrationChoiceBackground(ColorScheme colors, bool selected) =>
    selected ? colors.secondary : colors.surface;

class EventProviderRegistration extends StatefulWidget {
  const EventProviderRegistration({super.key, required this.service});
  final EventService service;

  @override
  State<EventProviderRegistration> createState() =>
      _EventProviderRegistrationState();
}

class _EventProviderRegistrationState extends State<EventProviderRegistration> {
  final picker = ImagePicker();
  final formKey = GlobalKey<FormState>();
  final fields = <String, TextEditingController>{
    for (final key in [
      'shopName',
      'managerName',
      'phone',
      'whatsapp',
      'email',
      'city',
      'commune',
      'district',
      'address',
      'interventionZone',
      'description',
    ])
      key: TextEditingController(),
  };
  int step = 0;
  String category = eventRegistrationCategories.keys.first;
  final subcategories = <String>{};
  final offers = <_OfferDraft>[];
  XFile? logo, cover, identity, rccm;
  final gallery = <XFile>[];
  final videos = <XFile>[];
  bool sending = false;
  SubscriptionPlan requestedPlan = SubscriptionPlan.standard;

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Devenir prestataire')),
      body: SafeArea(
        child: Stepper(
          physics: const ClampingScrollPhysics(),
          currentStep: step,
          onStepTapped: (value) => setState(() => step = value),
          controlsBuilder: (context, details) => Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Row(children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: step == 7
                      ? 'Envoyer la demande prestataire'
                      : 'Continuer vers l’étape suivante',
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.blueDark,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor:
                          AppColors.blueDark.withValues(alpha: 0.55),
                      disabledForegroundColor:
                          Colors.white.withValues(alpha: 0.85),
                      minimumSize: const Size(48, 52),
                    ),
                    onPressed: sending ? null : _continue,
                    child: sending
                        ? SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.onSecondary,
                            ),
                          )
                        : Text(step == 7 ? 'Envoyer la demande' : 'Continuer'),
                  ),
                ),
              ),
              if (step > 0)
                TextButton(
                  onPressed: sending ? null : () => setState(() => step--),
                  child: const Text('Retour'),
                ),
            ]),
          ),
          steps: [
            Step(
              title: const Text('Catégorie principale'),
              content: Column(
                children: eventRegistrationCategories.keys
                    .map((value) => ListTile(
                          textColor: eventRegistrationChoiceForeground(
                              colors, category == value),
                          iconColor: eventRegistrationChoiceForeground(
                              colors, category == value),
                          tileColor: eventRegistrationChoiceBackground(
                              colors, category == value),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: category == value
                                  ? colors.primary
                                  : colors.outline,
                            ),
                          ),
                          leading: Icon(
                            category == value
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                          ),
                          title: Text(value),
                          onTap: () => setState(() {
                            category = value;
                            subcategories.clear();
                          }),
                        ))
                    .toList(),
              ),
            ),
            Step(
              title: const Text('Sous-catégories'),
              content: Wrap(
                spacing: 8,
                children: eventRegistrationCategories[category]!
                    .map((value) => FilterChip(
                          label: Text(value),
                          selected: subcategories.contains(value),
                          showCheckmark: true,
                          selectedColor:
                              eventRegistrationChoiceBackground(colors, true),
                          checkmarkColor: colors.onSecondary,
                          backgroundColor: colors.surface,
                          side: BorderSide(
                            color: subcategories.contains(value)
                                ? colors.primary
                                : colors.outline,
                          ),
                          labelStyle: TextStyle(
                            color: eventRegistrationChoiceForeground(
                                colors, subcategories.contains(value)),
                            fontWeight: FontWeight.w600,
                          ),
                          onSelected: (selected) => setState(() => selected
                              ? subcategories.add(value)
                              : subcategories.remove(value)),
                        ))
                    .toList(),
              ),
            ),
            Step(
              title: const Text('Informations de la boutique'),
              content: Form(
                key: formKey,
                child: Column(children: [
                  _field('shopName', "Nom de l'entreprise"),
                  _field('managerName', 'Nom du responsable'),
                  _field('phone', 'Téléphone', phone: true),
                  _field('whatsapp', 'WhatsApp', phone: true),
                  _field('email', 'Email (optionnel)', optional: true),
                  _field('city', 'Ville'),
                  _field('commune', 'Commune'),
                  _field('district', 'Quartier'),
                  _field('address', 'Adresse'),
                  _field('interventionZone', "Zone d'intervention"),
                  _field('description', 'Description', lines: 3),
                ]),
              ),
            ),
            Step(
              title: const Text('Médias'),
              content: Column(children: [
                _mediaTile('Logo', logo, () => _pickSingle('logo')),
                _mediaTile(
                    'Photo de couverture', cover, () => _pickSingle('cover')),
                ListTile(
                  title: Text('Galerie photos (${gallery.length})'),
                  trailing: const Icon(Icons.add_a_photo_outlined),
                  onTap: _pickGallery,
                ),
                ListTile(
                  title: Text('Vidéos optionnelles (${videos.length})'),
                  trailing: const Icon(Icons.video_library_outlined),
                  onTap: _pickVideo,
                ),
              ]),
            ),
            Step(
              title: const Text('Prestations'),
              content: Column(children: [
                ...offers.indexed.map((entry) => ListTile(
                      title: Text(entry.$2.name),
                      subtitle: Text('${entry.$2.price} FCFA'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            setState(() => offers.removeAt(entry.$1)),
                      ),
                    )),
                OutlinedButton.icon(
                  onPressed: _addOffer,
                  icon: const Icon(Icons.add),
                  label: const Text('Ajouter une prestation'),
                ),
              ]),
            ),
            Step(
              title: const Text('Documents'),
              content: Column(children: [
                _mediaTile("Pièce d'identité", identity,
                    () => _pickSingle('identity')),
                _mediaTile('RCCM (optionnel)', rccm, () => _pickSingle('rccm')),
                Text(
                  'Formats JPG, PNG ou WebP. Taille maximale : 10 Mo.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
              ]),
            ),
            Step(
              title: const Text('Choix du plan'),
              content: _planSelection(),
            ),
            Step(
              title: const Text('Résumé'),
              content: _summary(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(String key, String label,
          {bool optional = false, bool phone = false, int lines = 1}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextFormField(
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          controller: fields[key],
          keyboardType: phone ? TextInputType.phone : TextInputType.text,
          minLines: lines,
          maxLines: lines,
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            hintStyle: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            errorStyle: TextStyle(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          validator: optional
              ? null
              : (value) => value == null || value.trim().isEmpty
                  ? 'Champ obligatoire'
                  : null,
        ),
      );

  Widget _mediaTile(String title, XFile? file, VoidCallback onTap) => ListTile(
        title: Text(title),
        subtitle: Text(
          file?.name ?? 'Non ajouté',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        trailing: Icon(
            file == null ? Icons.upload_outlined : Icons.check_circle,
            color: file == null ? null : AppColors.green),
        onTap: onTap,
      );

  Widget _planSelection() {
    final colors = Theme.of(context).colorScheme;
    const pricing = ModulePricing.general;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Choisissez le niveau de visibilité souhaité. Aucun paiement ne sera déclenché.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 12),
        for (final plan in SubscriptionPlan.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _PlanCard(
              plan: plan,
              selected: requestedPlan == plan,
              launchPrice: pricing.launchPrice(plan),
              normalPrice: pricing.normalPrice(plan),
              onSelected: () => setState(() => requestedPlan = plan),
            ),
          ),
        Text(
          'Offre de lancement valable pendant les 3 premiers mois suivant la création du compte professionnel.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }

  Widget _summary() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(fields['shopName']!.text,
                style: Theme.of(context).textTheme.titleLarge),
            Text('$category • ${subcategories.join(', ')}'),
            const Divider(),
            Text('${fields['managerName']!.text} • ${fields['phone']!.text}'),
            Text('${fields['city']!.text}, ${fields['commune']!.text}'),
            Text('${offers.length} prestation(s)'),
            Text('${gallery.length} photo(s) • ${videos.length} vidéo(s)'),
            Text('Plan demandé : ${requestedPlan.name.toUpperCase()}'),
            const SizedBox(height: 12),
            const Text(
              "Après envoi, votre demande sera en attente de validation.",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ]),
        ),
      );

  Future<void> _pickSingle(String target) async {
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 75,
      maxWidth: 1600,
    );
    if (file == null) return;
    if (!await _validImage(file, maxMb: 10)) return;
    setState(() {
      if (target == 'logo') logo = file;
      if (target == 'cover') cover = file;
      if (target == 'identity') identity = file;
      if (target == 'rccm') rccm = file;
    });
  }

  Future<void> _pickGallery() async {
    final files = await picker.pickMultiImage(imageQuality: 75, maxWidth: 1600);
    final valid = <XFile>[];
    for (final file in files.take(10)) {
      if (await _validImage(file, maxMb: 10)) valid.add(file);
    }
    if (valid.isNotEmpty) setState(() => gallery.addAll(valid));
  }

  Future<void> _pickVideo() async {
    final file = await picker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(minutes: 3),
    );
    if (file != null &&
        videos.length < 3 &&
        await _validVideo(file, maxMb: 50)) {
      setState(() => videos.add(file));
    }
  }

  Future<bool> _validImage(XFile file, {required int maxMb}) =>
      _validFile(file, const ['jpg', 'jpeg', 'png', 'webp'], maxMb);

  Future<bool> _validVideo(XFile file, {required int maxMb}) =>
      _validFile(file, const ['mp4', 'mov', 'm4v', 'webm'], maxMb);

  Future<bool> _validFile(
      XFile file, List<String> extensions, int maxMb) async {
    final extension = file.name.split('.').last.toLowerCase();
    final size = await file.length();
    if (!extensions.contains(extension) ||
        size <= 0 ||
        size > maxMb * 1048576) {
      _error('Fichier invalide. Formats: ${extensions.join(', ')}, '
          'maximum $maxMb Mo.');
      return false;
    }
    return true;
  }

  Future<void> _addOffer() async {
    final draft = await showDialog<_OfferDraft>(
      context: context,
      builder: (_) => const _OfferDraftDialog(),
    );
    if (draft != null) setState(() => offers.add(draft));
  }

  void _continue() {
    if (step == 1 && subcategories.isEmpty) {
      return _error('Sélectionnez une sous-catégorie.');
    }
    if (step == 2 && !(formKey.currentState?.validate() ?? false)) {
      return;
    }
    if (step == 3 && (logo == null || cover == null)) {
      return _error('Le logo et la couverture sont obligatoires.');
    }
    if (step == 4 && offers.isEmpty) {
      return _error('Ajoutez au moins une prestation.');
    }
    if (step == 5 && identity == null) {
      return _error("La pièce d'identité est obligatoire.");
    }
    if (step < 7) {
      setState(() => step++);
    } else {
      _submit();
    }
  }

  void _error(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _submit() async {
    setState(() => sending = true);
    try {
      final id = widget.service.newProviderId();
      Future<String> upload(XFile file, String kind) => widget.service
          .uploadProviderFile(providerId: id, path: file.path, kind: kind);
      final logoUrl = await upload(logo!, 'logo');
      final coverUrl = await upload(cover!, 'cover');
      final identityUrl = await upload(identity!, 'documents');
      final rccmUrl = rccm == null ? null : await upload(rccm!, 'documents');
      final galleryUrls = <String>[];
      for (final file in gallery) {
        galleryUrls.add(await upload(file, 'gallery'));
      }
      final videoUrls = <String>[];
      for (final file in videos) {
        videoUrls.add(await upload(file, 'videos'));
      }
      await widget.service.submitProviderApplication(
        providerId: id,
        profile: {
          for (final entry in fields.entries)
            entry.key: entry.value.text.trim(),
          'categories': [category],
          'subcategories': subcategories.toList(),
          'logoUrl': logoUrl,
          'coverUrl': coverUrl,
          'galleryUrls': galleryUrls,
          'videoUrls': videoUrls,
          'documents': {
            'identityUrl': identityUrl,
            if (rccmUrl != null) 'rccmUrl': rccmUrl,
          },
        },
        offers: offers
            .map((offer) => offer.toMap(category, subcategories.first))
            .toList(),
        requestedPlan: requestedPlan.name,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      _error('Envoi impossible : $error');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }
}

class _OfferDraft {
  const _OfferDraft({
    required this.name,
    required this.description,
    required this.price,
    required this.quantity,
    required this.available,
    required this.delivery,
    required this.installation,
    required this.dismantling,
  });
  final String name, description;
  final int price, quantity;
  final bool available, delivery, installation, dismantling;

  Map<String, dynamic> toMap(String category, String subcategory) => {
        'title': name,
        'description': description,
        'category': switch (category) {
          'Location' => 'rental',
          'Décoration' => 'decoration',
          'Traiteur' => 'catering',
          _ => 'staff',
        },
        'subcategory': subcategory,
        'unitPrice': price,
        'availableQuantity': quantity,
        'available': available,
        'deliveryAvailable': delivery,
        'installationAvailable': installation,
        'dismantlingAvailable': dismantling,
      };
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.selected,
    required this.launchPrice,
    required this.normalPrice,
    required this.onSelected,
  });

  final SubscriptionPlan plan;
  final bool selected;
  final int launchPrice;
  final int normalPrice;
  final VoidCallback onSelected;

  String get title => plan.name.toUpperCase();

  String get benefit => switch (plan) {
        SubscriptionPlan.standard =>
          'Visibilité normale, après Premium et VVIP',
        SubscriptionPlan.premium =>
          'Badge Premium, priorité sur Standard et meilleure visibilité',
        SubscriptionPlan.vvip =>
          'Badge VVIP, priorité maximale et mise en avant principale',
      };

  String _price(int value) => value == 0 ? 'Gratuit' : '$value FCFA / mois';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = selected ? colors.onSecondary : colors.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Plan $title, ${_price(launchPrice)} pendant trois mois',
      child: InkWell(
        onTap: onSelected,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected ? colors.secondary : colors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? colors.secondary : colors.outline,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: foreground,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: foreground,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${_price(launchPrice)} pendant 3 mois',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              Text(
                'Puis ${_price(normalPrice)}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: foreground,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                benefit,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: foreground,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfferDraftDialog extends StatefulWidget {
  const _OfferDraftDialog();
  @override
  State<_OfferDraftDialog> createState() => _OfferDraftDialogState();
}

class _OfferDraftDialogState extends State<_OfferDraftDialog> {
  final name = TextEditingController(), description = TextEditingController();
  final price = TextEditingController(), quantity = TextEditingController();
  bool available = true,
      delivery = false,
      installation = false,
      dismantling = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Nouvelle prestation'),
        content: SingleChildScrollView(
            child: Column(children: [
          TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Nom')),
          TextField(
              controller: description,
              decoration: const InputDecoration(labelText: 'Description')),
          TextField(
              controller: price,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Prix')),
          TextField(
              controller: quantity,
              keyboardType: TextInputType.number,
              decoration:
                  const InputDecoration(labelText: 'Quantité disponible')),
          SwitchListTile(
              value: available,
              onChanged: (v) => setState(() => available = v),
              title: const Text('Disponible')),
          SwitchListTile(
              value: delivery,
              onChanged: (v) => setState(() => delivery = v),
              title: const Text('Livraison possible')),
          SwitchListTile(
              value: installation,
              onChanged: (v) => setState(() => installation = v),
              title: const Text('Installation possible')),
          SwitchListTile(
              value: dismantling,
              onChanged: (v) => setState(() => dismantling = v),
              title: const Text('Démontage possible')),
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty ||
                  int.tryParse(price.text) == null) {
                return;
              }
              Navigator.pop(
                  context,
                  _OfferDraft(
                    name: name.text.trim(),
                    description: description.text.trim(),
                    price: int.parse(price.text),
                    quantity: int.tryParse(quantity.text) ?? 1,
                    available: available,
                    delivery: delivery,
                    installation: installation,
                    dismantling: dismantling,
                  ));
            },
            child: const Text('Ajouter'),
          ),
        ],
      );
}
