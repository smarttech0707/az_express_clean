import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:provider/provider.dart';

import '../../models/pharmacy_guard.dart';
import '../../services/firestore_service.dart';
import '../../providers/active_city_provider.dart';
import '../../services/pharmacy_guard_repository.dart';
import '../../services/tarif_service.dart';

class PharmacieGardePage extends StatefulWidget {
  const PharmacieGardePage({super.key});

  @override
  State<PharmacieGardePage> createState() => _PharmacieGardePageState();
}

class _PharmacieGardePageState extends State<PharmacieGardePage>
    with SingleTickerProviderStateMixin {
  final _repository = PharmacyGuardRepository();
  late final TabController _tabs;
  Position? _position;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _loadPosition();
  }

  Future<void> _loadPosition() async {
    try {
      final permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final value = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.medium));
      if (mounted) setState(() => _position = value);
    } catch (_) {}
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFFF5F5F5),
        appBar: AppBar(
          title: const Text('Pharmacies de garde'),
          backgroundColor: Colors.red.shade700,
          foregroundColor: Colors.white,
          bottom: TabBar(
            controller: _tabs,
            isScrollable: true,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: const [
              Tab(text: 'Maintenant'),
              Tab(text: 'Cette semaine'),
              Tab(text: 'Ce mois'),
              Tab(text: 'Partenaires AZ'),
            ],
          ),
        ),
        body: StreamBuilder<List<PharmacyGuard>>(
          stream: _repository.watchPublicGuards(city: 'Abengourou'),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const _Message(
                  icon: Icons.cloud_off_rounded,
                  text:
                      'Les gardes sont momentanément indisponibles. Réessayez plus tard.');
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final periodLists = PharmacyGuardPeriod.values
                .map((period) => _GuardList(
                      guards: snapshot.data!,
                      period: period,
                      position: _position,
                    ))
                .toList(growable: false);
            return TabBarView(
              controller: _tabs,
              children: [
                ...periodLists,
                _PartnerPharmacies(position: _position)
              ],
            );
          },
        ),
      );
}

class _PartnerPharmacies extends StatelessWidget {
  const _PartnerPharmacies({required this.position});
  final Position? position;

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('pharmacies')
            .orderBy('name')
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.data!.docs.isEmpty) {
            return const _Message(
                icon: Icons.handshake_outlined,
                text: 'Aucune pharmacie partenaire enregistrée.');
          }
          final now = DateTime.now().toUtc();
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: snapshot.data!.docs.length,
            itemBuilder: (context, index) {
              final doc = snapshot.data!.docs[index];
              final data = doc.data();
              final guard = PharmacyGuard(
                id: 'partner-${doc.id}',
                pharmacyId: doc.id,
                name: data['name'] as String? ?? 'Pharmacie',
                city: data['city'] as String? ?? 'Abengourou',
                address: data['address'] as String?,
                phone: data['phone'] as String?,
                latitude: (data['lat'] as num?)?.toDouble(),
                longitude: (data['lng'] as num?)?.toDouble(),
                guardStartAt: now,
                guardEndAt: now.add(const Duration(days: 1)),
                sourceType: 'partner',
                isVerified: true,
                isActive: true,
                linkedPartner: true,
                partnerPharmacyId: doc.id,
              );
              return _GuardCard(
                  guard: guard,
                  now: now,
                  position: position,
                  partnerOnly: true);
            },
          );
        },
      );
}

class _GuardList extends StatelessWidget {
  const _GuardList(
      {required this.guards, required this.period, required this.position});

  final List<PharmacyGuard> guards;
  final PharmacyGuardPeriod period;
  final Position? position;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    final visible = guards
        .where((guard) => guard.matchesPeriod(period, now))
        .toList(growable: false)
      ..sort((a, b) => a.guardStartAt.compareTo(b.guardStartAt));
    if (visible.isEmpty) {
      return const _Message(
          icon: Icons.local_pharmacy_outlined,
          text: 'Aucune garde publiée pour cette période.');
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: visible.length,
      itemBuilder: (context, index) => _GuardCard(
        guard: visible[index],
        now: now,
        position: position,
      ),
    );
  }
}

class _GuardCard extends StatelessWidget {
  const _GuardCard(
      {required this.guard,
      required this.now,
      required this.position,
      this.partnerOnly = false});

  final PharmacyGuard guard;
  final DateTime now;
  final Position? position;
  final bool partnerOnly;

  String _date(DateTime value) {
    final local = value.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')} à '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _call() => launchUrl(Uri.parse('tel:${guard.phone}'));

  Future<void> _map() {
    final query = guard.latitude != null && guard.longitude != null
        ? '${guard.latitude},${guard.longitude}'
        : Uri.encodeComponent(
            '${guard.address ?? ''}, ${guard.city}, Côte d’Ivoire');
    return launchUrl(Uri.parse('https://maps.google.com/?q=$query'),
        mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final onDuty = guard.isOnDutyAt(now);
    final expired = guard.isExpiredAt(now);
    final hasMap = (guard.latitude != null && guard.longitude != null) ||
        guard.address?.trim().isNotEmpty == true;
    final distance =
        position != null && guard.latitude != null && guard.longitude != null
            ? Geolocator.distanceBetween(position!.latitude,
                    position!.longitude, guard.latitude!, guard.longitude!) /
                1000
            : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.local_pharmacy_rounded,
                  color: Colors.red.shade700, size: 34),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(guard.name,
                        style: GoogleFonts.urbanist(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    Text([
                      guard.city,
                      if (guard.district?.trim().isNotEmpty == true)
                        guard.district!,
                      if (guard.address?.trim().isNotEmpty == true)
                        guard.address!,
                    ].join(' — ')),
                    if (guard.phone?.trim().isNotEmpty == true)
                      Text(guard.phone!),
                    if (distance != null)
                      Text('${distance.toStringAsFixed(1)} km',
                          style: const TextStyle(color: Colors.blue)),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 12),
            if (!partnerOnly) ...[
              _GuardBadge(onDuty: onDuty, expired: expired, guard: guard),
              const SizedBox(height: 6),
              Text(onDuty
                  ? 'Jusqu’au ${_date(guard.guardEndAt)}'
                  : 'Du ${_date(guard.guardStartAt)} au ${_date(guard.guardEndAt)}'),
            ] else
              const Text('PARTENAIRE AZ EXPRESS',
                  style: TextStyle(
                      color: Colors.blue, fontWeight: FontWeight.bold)),
            if (guard.lastSyncedAt != null) ...[
              const SizedBox(height: 4),
              Text('Mise à jour : ${_date(guard.lastSyncedAt!)}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                    onPressed:
                        guard.phone?.trim().isNotEmpty == true ? _call : null,
                    icon: const Icon(Icons.call_rounded),
                    label: const Text('Appeler')),
                OutlinedButton.icon(
                    onPressed: hasMap ? _map : null,
                    icon: const Icon(Icons.directions_rounded),
                    label: const Text('Itinéraire')),
                FilledButton.icon(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _PharmacyOrderSheet(guard: guard),
                  ),
                  icon: const Icon(Icons.delivery_dining_rounded),
                  label: const Text('Commander avec AZ Express'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GuardBadge extends StatelessWidget {
  const _GuardBadge(
      {required this.onDuty, required this.expired, required this.guard});
  final bool onDuty;
  final bool expired;
  final PharmacyGuard guard;

  @override
  Widget build(BuildContext context) {
    final color = onDuty
        ? Colors.green
        : expired
            ? Colors.grey
            : Colors.orange;
    final label = onDuty
        ? 'DE GARDE MAINTENANT'
        : expired
            ? 'GARDE TERMINÉE'
            : 'GARDE À VENIR';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(20)),
      child: Text(label,
          style: TextStyle(
              color: color, fontWeight: FontWeight.w800, fontSize: 11)),
    );
  }
}

class _PharmacyOrderSheet extends StatefulWidget {
  const _PharmacyOrderSheet({required this.guard});
  final PharmacyGuard guard;

  @override
  State<_PharmacyOrderSheet> createState() => _PharmacyOrderSheetState();
}

class _PharmacyOrderSheetState extends State<_PharmacyOrderSheet> {
  final _products = TextEditingController();
  final _quantity = TextEditingController(text: '1');
  final _budget = TextEditingController();
  final _note = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _products.dispose();
    _quantity.dispose();
    _budget.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_products.text.trim().isEmpty) return;
    setState(() => _sending = true);
    try {
      var user = FirebaseAuth.instance.currentUser;
      user ??= (await FirebaseAuth.instance.signInAnonymously()).user;
      if (user == null) throw StateError('Utilisateur non connecté');
      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
            locationSettings:
                const LocationSettings(accuracy: LocationAccuracy.medium));
      } catch (_) {}
      final pickupLat = widget.guard.latitude;
      final pickupLng = widget.guard.longitude;
      if (pickupLat == null ||
          pickupLng == null ||
          (pickupLat == 0 && pickupLng == 0)) {
        throw StateError(
          'Les coordonnées de la pharmacie ne sont pas renseignées. '
          'La commande ne peut pas être envoyée.',
        );
      }
      if (position == null ||
          (position.latitude == 0 && position.longitude == 0)) {
        throw StateError(
          'Votre position de livraison est indisponible. '
          'Activez le GPS puis réessayez.',
        );
      }
      final lat = position.latitude;
      final lng = position.longitude;
      if (!mounted) return;
      final cityService = context.read<ActiveCityProvider>().service;
      final geography = await cityService.resolveDispatchGeography(
        pickupLatitude: pickupLat,
        pickupLongitude: pickupLng,
        deliveryLatitude: lat,
        deliveryLongitude: lng,
      );
      final tariff = TarifService.compute(clientLat: lat, clientLng: lng);
      if (!tariff.canOrder) {
        throw StateError(tariff.rejectionMessage ?? 'Livraison indisponible');
      }
      final id = const Uuid().v4();
      await FirebaseFirestore.instance.collection('orders').doc(id).set({
        ...buildPharmacyOrderPrefill(widget.guard),
        'id': id,
        'description':
            'Livraison pharmacie : ${_products.text.trim()} (quantité ${_quantity.text.trim()})',
        'customerNote': _note.text.trim(),
        'shoppingBudget': int.tryParse(_budget.text.trim()) ?? 0,
        'budget': tariff.standardPrice,
        'status': 'pending',
        'isPaid': false,
        'type': 'pharmacie',
        'latitude': pickupLat,
        'longitude': pickupLng,
        'destLat': lat,
        'destLng': lng,
        'pickupCityId': geography.pickupCityId,
        'pickupZoneId': geography.pickupZoneId,
        'deliveryCityId': geography.deliveryCityId,
        'deliveryZoneId': geography.deliveryZoneId,
        'pickupCoordinateSource': 'local_place',
        'deliveryCoordinateSource': 'gps',
        'gpsDetectedCityId': cityService.gpsDetectedCityId,
        'activeCityId': cityService.activeCityId,
        'citySelectionSource': cityService.citySelectionSource,
        'cityResolutionStatus': geography.cityResolutionStatus,
        'clientId': user.uid,
        'paymentMethod': 'cash',
        'createdAt': FieldValue.serverTimestamp(),
      });
      await FirestoreService().findNearestDriver(pickupLat, pickupLng, id,
          budget: tariff.standardPrice);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Demande confirmée et envoyée.'),
          backgroundColor: Colors.green));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur : $error')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 20, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Commander chez ${widget.guard.name}',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              TextField(
                  controller: _products,
                  decoration: const InputDecoration(
                      labelText: 'Médicament ou produit recherché *')),
              TextField(
                  controller: _quantity,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Quantité')),
              TextField(
                  controller: _budget,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Budget produits')),
              TextField(
                  controller: _note,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Note')),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _sending ? null : _submit,
                child: Text(_sending ? 'Envoi…' : 'Confirmer la demande'),
              ),
            ],
          ),
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ]),
        ),
      );
}
