import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';
import '../event_constants.dart';
import '../models/event_models.dart';
import '../providers/event_provider.dart';
import '../services/event_service.dart';
import 'event_chat_screen.dart';
import 'event_provider_portal.dart';

class EventHomeScreen extends StatefulWidget {
  const EventHomeScreen({super.key});

  @override
  State<EventHomeScreen> createState() => _EventHomeScreenState();
}

class _EventHomeScreenState extends State<EventHomeScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<EventProvider>().load(refresh: true);
    });
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 500) {
        context.read<EventProvider>().load();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<EventProvider>();
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Événementiel'),
        actions: [
          if (state.comparison.length >= 2)
            IconButton(
              tooltip: 'Comparer',
              icon: Badge(
                label: Text('${state.comparison.length}'),
                child: const Icon(Icons.compare_arrows_rounded),
              ),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      EventComparisonScreen(offers: state.comparison),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Mes réservations',
            icon: const Icon(Icons.history_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    EventReservationHistoryScreen(service: state.service),
              ),
            ),
          ),
          Badge(
            isLabelVisible: state.cartCount > 0,
            label: Text('${state.cartCount}'),
            child: IconButton(
              tooltip: 'Ma réservation',
              icon: const Icon(Icons.shopping_bag_outlined),
              onPressed: () => _openCart(context),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => state.load(refresh: true),
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(child: _Header(state: state)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              sliver: state.error != null && state.offers.isEmpty
                  ? SliverFillRemaining(
                      child: _Message(
                        icon: Icons.cloud_off_rounded,
                        text: 'Impossible de charger les prestations.',
                        action: () => state.load(refresh: true),
                      ),
                    )
                  : state.offers.isEmpty && !state.loading
                      ? const SliverFillRemaining(
                          child: _Message(
                            icon: Icons.event_busy_rounded,
                            text:
                                'Aucune prestation disponible pour ce filtre.',
                          ),
                        )
                      : SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 360,
                            mainAxisExtent: 285,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              if (index == state.offers.length) {
                                return const Center(
                                  child: CircularProgressIndicator(),
                                );
                              }
                              final offer = state.offers[index];
                              return _OfferCard(
                                offer: offer,
                                onTap: () => _showOffer(context, offer),
                                onAdd: () => state.addToCart(offer),
                                compared: state.isCompared(offer.id),
                                onCompare: () => state.toggleComparison(offer),
                              );
                            },
                            childCount:
                                state.offers.length + (state.loading ? 1 : 0),
                          ),
                        ),
            ),
          ],
        ),
      ),
      floatingActionButton: state.cartCount == 0
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openCart(context),
              icon: const Icon(Icons.event_available_rounded),
              label: Text('${state.cartTotal} FCFA'),
            ),
    );
  }

  void _showOffer(BuildContext context, EventOffer offer) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .78,
        maxChildSize: .95,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          children: [
            if (offer.photoUrls.isNotEmpty)
              ClipRRect(
                borderRadius: AppRadius.lgR,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: PageView(
                    children: offer.photoUrls
                        .map(
                          (url) => CachedNetworkImage(
                            imageUrl: url,
                            fit: BoxFit.cover,
                            memCacheWidth: 900,
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            const SizedBox(height: 18),
            Text(offer.title, style: Theme.of(context).textTheme.headlineSmall),
            Text(
              '${offer.providerName} • ${offer.zone}',
              style: const TextStyle(color: AppColors.textLight),
            ),
            const SizedBox(height: 12),
            Text(offer.description),
            const SizedBox(height: 16),
            _Info(
              icon: Icons.payments_outlined,
              text: '${offer.unitPrice} FCFA / unité',
            ),
            _Info(
              icon: Icons.inventory_2_outlined,
              text: '${offer.availableQuantity} disponibles',
            ),
            if (offer.availableDays.isNotEmpty)
              _Info(
                icon: Icons.calendar_month_outlined,
                text: offer.availableDays.join(', '),
              ),
            if (offer.openingTime.isNotEmpty)
              _Info(
                icon: Icons.schedule_rounded,
                text: '${offer.openingTime} – ${offer.closingTime}',
              ),
            if (offer.deliveryAvailable)
              const _Info(
                icon: Icons.local_shipping_outlined,
                text: 'Livraison disponible',
              ),
            if (offer.installationAvailable)
              const _Info(
                icon: Icons.construction_outlined,
                text: 'Installation disponible',
              ),
            if (offer.dismantlingAvailable)
              const _Info(
                icon: Icons.handyman_outlined,
                text: 'Démontage disponible',
              ),
            if (offer.conditions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Conditions',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(offer.conditions),
            ],
            if (offer.videoUrls.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Vidéos', style: Theme.of(context).textTheme.titleMedium),
              ...offer.videoUrls.indexed.map(
                (entry) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.play_circle_outline_rounded),
                  title: Text('Voir la vidéo ${entry.$1 + 1}'),
                  onTap: () => launchUrl(
                    Uri.parse(entry.$2),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                context.read<EventProvider>().addToCart(offer);
                Navigator.pop(sheetContext);
              },
              icon: const Icon(Icons.add_shopping_cart_rounded),
              label: const Text('Ajouter à la réservation'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: offer.ownerId.isEmpty
                  ? null
                  : () async {
                      final service = context.read<EventProvider>().service;
                      final chatId = await service.openChat(
                        providerId: offer.providerId,
                        providerOwnerId: offer.ownerId,
                        providerName: offer.providerName,
                      );
                      if (!context.mounted) return;
                      Navigator.pop(sheetContext);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => EventChatScreen(
                            chatId: chatId,
                            title: offer.providerName,
                            service: service,
                          ),
                        ),
                      );
                    },
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              label: const Text('Contacter le prestataire'),
            ),
          ],
        ),
      ),
    );
  }

  void _openCart(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const EventCartScreen()),
    );
  }
}

class EventReservationHistoryScreen extends StatelessWidget {
  const EventReservationHistoryScreen({super.key, required this.service});
  final EventService service;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Mes réservations')),
        body: StreamBuilder<List<EventReservation>>(
          stream: service.watchClientReservations(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const _Message(
                icon: Icons.cloud_off_rounded,
                text: 'Impossible de charger l’historique.',
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final reservations = snapshot.data!;
            if (reservations.isEmpty) {
              return const _Message(
                icon: Icons.event_note_outlined,
                text: 'Aucune réservation pour le moment.',
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: reservations.length,
              itemBuilder: (_, index) {
                final reservation = reservations[index];
                return Card(
                  child: ExpansionTile(
                    title: Text(
                      '${DateFormat('dd/MM/yyyy').format(reservation.eventDate)} • ${reservation.totalAmount} FCFA',
                    ),
                    subtitle: Text(
                      '${reservation.address} • ${reservation.status}',
                    ),
                    children: [
                      ...reservation.items.map(
                        (item) => ListTile(
                          title: Text('${item['title']}'),
                          subtitle: Text('${item['providerName']}'),
                          trailing: Text('x${item['quantity']}'),
                        ),
                      ),
                      if (reservation.status == 'pending' ||
                          reservation.status == 'confirmed')
                        TextButton.icon(
                          onPressed: () =>
                              service.cancelReservation(reservation.id),
                          icon: const Icon(Icons.cancel_outlined),
                          label: const Text('Annuler la réservation'),
                        ),
                      if (reservation.status == 'completed')
                        TextButton.icon(
                          onPressed: () =>
                              _reviewReservation(context, reservation),
                          icon: const Icon(Icons.star_outline_rounded),
                          label: const Text('Donner un avis'),
                        ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      );

  Future<void> _reviewReservation(
    BuildContext context,
    EventReservation reservation,
  ) async {
    final providers = {
      for (final item in reservation.items)
        '${item['providerId']}': '${item['providerName']}',
    };
    if (providers.isEmpty) return;
    var providerId = providers.keys.first;
    var rating = 5;
    final comment = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, setDialogState) => AlertDialog(
          title: const Text('Votre avis'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: providerId,
                items: providers.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    )
                    .toList(),
                onChanged: (v) => providerId = v!,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  5,
                  (i) => IconButton(
                    onPressed: () => setDialogState(() => rating = i + 1),
                    icon: Icon(
                      i < rating
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                    ),
                    color: Colors.amber.shade700,
                  ),
                ),
              ),
              TextField(
                controller: comment,
                decoration: const InputDecoration(labelText: 'Commentaire'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Publier'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      await service.submitReview(
        reservationId: reservation.id,
        providerId: providerId,
        rating: rating,
        comment: comment.text,
      );
    }
    comment.dispose();
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state});
  final EventProvider state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF6A1B9A), Color(0xFFE65100)],
              ),
              borderRadius: AppRadius.xlR,
            ),
            child: const Row(
              children: [
                Icon(Icons.celebration_rounded, color: Colors.white, size: 42),
                SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Tout votre événement dans une seule réservation',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            onChanged: state.setSearch,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'Chaise, traiteur, DJ, photographe…',
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const EventProviderPortal(),
                ),
              ),
              icon: const Icon(Icons.storefront_outlined),
              label: const Text('Devenir prestataire'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                ChoiceChip(
                  label: Text(
                    'Tout',
                    style: TextStyle(
                      color: state.category == null
                          ? Colors.white
                          : const Color(0xFF212121),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  selected: state.category == null,
                  selectedColor: AppColors.blue,
                  backgroundColor: Colors.white,
                  checkmarkColor: Colors.white,
                  onSelected: (_) => state.setCategory(null),
                ),
                const SizedBox(width: 8),
                ...EventCategory.values.map(
                  (category) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      avatar: Icon(
                        category.icon,
                        size: 18,
                        color: state.category == category
                            ? Colors.white
                            : const Color(0xFF212121),
                      ),
                      label: Text(
                        category.label,
                        style: TextStyle(
                          color: state.category == category
                              ? Colors.white
                              : const Color(0xFF212121),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      selected: state.category == category,
                      selectedColor: AppColors.blue,
                      backgroundColor: Colors.white,
                      checkmarkColor: Colors.white,
                      onSelected: (_) => state.setCategory(category),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (state.category != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: eventSubcategories[state.category]!
                    .map(
                      (value) => Padding(
                        padding: const EdgeInsets.only(right: 7),
                        child: FilterChip(
                          label: Text(
                            value,
                            style: TextStyle(
                              color: state.subcategory == value
                                  ? Colors.white
                                  : const Color(0xFF212121),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          selected: state.subcategory == value,
                          selectedColor: AppColors.blue,
                          backgroundColor: Colors.white,
                          checkmarkColor: Colors.white,
                          onSelected: (selected) =>
                              state.setSubcategory(selected ? value : null),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.offer,
    required this.onTap,
    required this.onAdd,
    required this.compared,
    required this.onCompare,
  });
  final EventOffer offer;
  final VoidCallback onTap;
  final VoidCallback onAdd;
  final bool compared;
  final VoidCallback onCompare;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                SizedBox(
                  height: 145,
                  width: double.infinity,
                  child: offer.photoUrls.isEmpty
                      ? ColoredBox(
                          color: AppColors.primary10,
                          child: Icon(
                            offer.category.icon,
                            size: 54,
                            color: AppColors.primary,
                          ),
                        )
                      : CachedNetworkImage(
                          imageUrl: offer.photoUrls.first,
                          fit: BoxFit.cover,
                          memCacheWidth: 600,
                          placeholder: (_, __) =>
                              const Center(child: CircularProgressIndicator()),
                        ),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: IconButton.filledTonal(
                    tooltip: 'Comparer',
                    onPressed: onCompare,
                    icon: Icon(
                      compared
                          ? Icons.compare_arrows_rounded
                          : Icons.add_chart_outlined,
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    offer.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    '${offer.providerName} • ${offer.zone}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textLight,
                      fontSize: 12,
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${offer.unitPrice} FCFA',
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Ajouter',
                        onPressed: onAdd,
                        icon: const Icon(Icons.add_rounded),
                      ),
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

class EventComparisonScreen extends StatelessWidget {
  const EventComparisonScreen({super.key, required this.offers});
  final List<EventOffer> offers;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Comparer les prestataires')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: [
              const DataColumn(label: Text('Critère')),
              ...offers.map(
                (offer) => DataColumn(
                  label: SizedBox(
                    width: 160,
                    child: Text(
                      offer.providerName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ],
            rows: [
              _comparisonRow('Prestation', offers.map((e) => e.title)),
              _comparisonRow('Tarif', offers.map((e) => '${e.unitPrice} FCFA')),
              _comparisonRow(
                'Disponibilité',
                offers.map((e) => '${e.availableQuantity} unités'),
              ),
              _comparisonRow('Zone', offers.map((e) => e.zone)),
              _comparisonRow(
                'Livraison',
                offers.map((e) => e.deliveryAvailable ? 'Oui' : 'Non'),
              ),
              _comparisonRow(
                'Installation',
                offers.map((e) => e.installationAvailable ? 'Oui' : 'Non'),
              ),
              _comparisonRow(
                'Conditions',
                offers.map((e) => e.conditions.isEmpty ? '—' : e.conditions),
              ),
            ],
          ),
        ),
      );

  DataRow _comparisonRow(String label, Iterable<String> values) => DataRow(
        cells: [
          DataCell(
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          ...values.map(
            (value) => DataCell(
              SizedBox(
                width: 160,
                child:
                    Text(value, maxLines: 3, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        ],
      );
}

class EventCartScreen extends StatelessWidget {
  const EventCartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<EventProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Ma réservation')),
      body: state.cart.isEmpty
          ? const _Message(
              icon: Icons.shopping_bag_outlined,
              text: 'Ajoutez des prestations pour préparer votre événement.',
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ...state.cart.map(
                  (item) => Card(
                    child: ListTile(
                      title: Text(item.offer.title),
                      subtitle: Text(
                        '${item.offer.unitPrice} FCFA • ${item.offer.providerName}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: () => state.setQuantity(
                              item.offer.id,
                              item.quantity - 1,
                            ),
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                          Text(
                            '${item.quantity}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          IconButton(
                            onPressed: () => state.setQuantity(
                              item.offer.id,
                              item.quantity + 1,
                            ),
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  title: const Text(
                    'Total estimé',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  trailing: Text(
                    '${state.cartTotal} FCFA',
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: state.cart.isEmpty
          ? null
          : SafeArea(
              minimum: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const EventCheckoutScreen(),
                  ),
                ),
                child: const Text('Choisir date, lieu et paiement'),
              ),
            ),
    );
  }
}

class EventCheckoutScreen extends StatefulWidget {
  const EventCheckoutScreen({super.key});

  @override
  State<EventCheckoutScreen> createState() => _EventCheckoutScreenState();
}

class _EventCheckoutScreenState extends State<EventCheckoutScreen> {
  final _form = GlobalKey<FormState>();
  final _address = TextEditingController();
  final _description = TextEditingController();
  DateTime _date = DateTime.now().add(const Duration(days: 1));
  TimeOfDay _time = const TimeOfDay(hour: 10, minute: 0);
  LatLng _point = const LatLng(6.7297, -3.4964);
  EventPaymentMethod _payment = EventPaymentMethod.cash;
  bool _delivery = false;
  bool _installation = false;
  bool _dismantling = false;
  bool _saving = false;

  @override
  void dispose() {
    _address.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<EventProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Finaliser la réservation')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              leading: const Icon(Icons.calendar_month_rounded),
              title: const Text("Date de l'événement"),
              subtitle: Text(DateFormat('dd/MM/yyyy').format(_date)),
              onTap: _pickDate,
            ),
            ListTile(
              leading: const Icon(Icons.schedule_rounded),
              title: const Text('Heure'),
              subtitle: Text(_time.format(context)),
              onTap: _pickTime,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _address,
              decoration: const InputDecoration(
                labelText: 'Lieu / adresse',
                prefixIcon: Icon(Icons.location_on_outlined),
              ),
              validator: (v) =>
                  v == null || v.trim().length < 3 ? 'Adresse requise' : null,
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: AppRadius.lgR,
              child: SizedBox(
                height: 210,
                child: GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _point,
                    zoom: 13,
                  ),
                  markers: {
                    Marker(markerId: const MarkerId('event'), position: _point),
                  },
                  onTap: (value) => setState(() => _point = value),
                  myLocationButtonEnabled: false,
                  zoomControlsEnabled: false,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 5),
              child: Text(
                'Touchez la carte pour préciser le lieu.',
                style: TextStyle(color: AppColors.textLight, fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _description,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Description et consignes',
              ),
            ),
            SwitchListTile(
              value: _delivery,
              onChanged: (v) => setState(() => _delivery = v),
              title: const Text('Livraison'),
            ),
            SwitchListTile(
              value: _installation,
              onChanged: (v) => setState(() => _installation = v),
              title: const Text('Installation'),
            ),
            SwitchListTile(
              value: _dismantling,
              onChanged: (v) => setState(() => _dismantling = v),
              title: const Text('Démontage'),
            ),
            const SizedBox(height: 8),
            Text('Paiement', style: Theme.of(context).textTheme.titleMedium),
            RadioGroup<EventPaymentMethod>(
              groupValue: _payment,
              onChanged: (value) => setState(() => _payment = value!),
              child: Column(
                children: EventPaymentMethod.values
                    .map(
                      (method) => RadioListTile(
                        value: method,
                        title: Text(method.label),
                      ),
                    )
                    .toList(),
              ),
            ),
            const Divider(),
            ListTile(
              title: const Text('Total'),
              trailing: Text(
                '${state.cartTotal} FCFA',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_circle_outline),
          label: const Text('Confirmer la réservation'),
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final value = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (value != null) setState(() => _date = value);
  }

  Future<void> _pickTime() async {
    final value = await showTimePicker(context: context, initialTime: _time);
    if (value != null) setState(() => _time = value);
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final state = context.read<EventProvider>();
    try {
      await state.service.createReservation(
        items: state.cart,
        eventDate: _date,
        eventTime:
            '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
        address: _address.text,
        description: _description.text,
        paymentMethod: _payment,
        delivery: _delivery,
        installation: _installation,
        dismantling: _dismantling,
        latitude: _point.latitude,
        longitude: _point.longitude,
      );
      state.clearCart();
      if (!mounted) return;
      Navigator.popUntil(context, (route) => route.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Réservation envoyée avec succès.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Échec : $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 58, color: AppColors.textLight),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center),
              if (action != null)
                TextButton(onPressed: action, child: const Text('Réessayer')),
            ],
          ),
        ),
      );
}
