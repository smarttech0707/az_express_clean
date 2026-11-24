import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/delivery_zone.dart';
import '../../../models/order_model.dart';
import '../../../services/active_city_service.dart';
import '../../../services/delivery_order_service.dart';
import '../../../services/places_search_service.dart';
import '../../../services/tarif_service.dart';
import '../../web_theme.dart';

/// Livraison Express — page Web cliente.
///
/// Réutilise intégralement la logique métier existante : [TarifService] pour
/// le prix (via [DeliveryOrderService.quote]), [DeliveryOrderService] pour la
/// construction et l'écriture de la commande, [PlacesSearchService] pour les
/// adresses, [ActiveCityService] pour la ville et les zones.
///
/// COÛTS GOOGLE : `expandSearch` n'est JAMAIS passé à vrai, donc l'API Google
/// Places n'est jamais appelée depuis le navigateur — seules la collection
/// Firestore `places` puis Nominatim (gratuit, avec son cache 5 min déjà
/// intégré au service) sont interrogées. Aucun appel Directions n'est fait :
/// il serait de toute façon bloqué par le CORS depuis un navigateur, et
/// [TarifService] retombe proprement sur la distance à vol d'oiseau depuis le
/// centre-ville. Aucune carte interactive n'est chargée.
class WebDeliveryPage extends StatefulWidget {
  /// Injectables pour les tests — en production, valeurs réelles par défaut.
  final DeliveryOrderService? orderService;
  final ActiveCityService? cityService;
  final String? Function()? currentUid;
  final Future<List<PlaceSuggestion>> Function(String, ActiveCityService)?
      suggest;

  const WebDeliveryPage({
    super.key,
    this.orderService,
    this.cityService,
    this.currentUid,
    this.suggest,
  });

  @override
  State<WebDeliveryPage> createState() => WebDeliveryPageState();
}

@visibleForTesting
class WebDeliveryPageState extends State<WebDeliveryPage> {
  static const _debounce = Duration(milliseconds: 400);

  late final DeliveryOrderService _orders;
  late final ActiveCityService _cities;

  final _pickupCtrl = TextEditingController();
  final _destCtrl = TextEditingController();
  final _senderNameCtrl = TextEditingController();
  final _senderPhoneCtrl = TextEditingController();
  final _recipientNameCtrl = TextEditingController();
  final _recipientPhoneCtrl = TextEditingController();
  final _parcelCtrl = TextEditingController();

  PlaceSuggestion? _pickup;
  PlaceSuggestion? _destination;
  String _mode = 'standard';
  String _payment = 'cash';

  bool _initializing = true;
  bool _submitting = false;
  String? _error;
  String? _cityId;
  List<DeliveryZone> _availableCities = const [];
  int _wallet = 0;

  Timer? _pickupTimer;
  Timer? _destTimer;
  List<PlaceSuggestion> _pickupResults = const [];
  List<PlaceSuggestion> _destResults = const [];
  bool _pickupSearching = false;
  bool _destSearching = false;

  @override
  void initState() {
    super.initState();
    _orders = widget.orderService ?? DeliveryOrderService();
    _cities = widget.cityService ?? ActiveCityService();
    _bootstrap();
  }

  @override
  void dispose() {
    _pickupTimer?.cancel();
    _destTimer?.cancel();
    for (final c in [
      _pickupCtrl,
      _destCtrl,
      _senderNameCtrl,
      _senderPhoneCtrl,
      _recipientNameCtrl,
      _recipientPhoneCtrl,
      _parcelCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// UID du client authentifié — pris de Firebase Auth, JAMAIS de l'interface.
  ///
  /// Quand une source est injectée (tests), son résultat est utilisé tel quel,
  /// `null` compris : un `??` ferait retomber un « pas de session » sur
  /// `FirebaseAuth.instance`, ce qui masquerait précisément le cas à traiter.
  String? get _uid {
    final injected = widget.currentUid;
    if (injected != null) return injected();
    return FirebaseAuth.instance.currentUser?.uid;
  }

  Future<void> _bootstrap() async {
    try {
      await _cities.initialize();
      final cities = _cities.activeCities
          .where((c) => c.cityId != null && c.hasUsableGeometry)
          .toList(growable: false);
      var active = _cities.activeCityId;
      // Sur le web, aucune résolution GPS n'a lieu : si une seule ville est
      // exploitable, on la sélectionne — sinon l'utilisateur choisit.
      if (active == null && cities.length == 1) {
        await _cities.setManualOverride(cities.first.cityId!);
        active = _cities.activeCityId;
      }
      final uid = _uid;
      final profile =
          uid == null ? (name: null, phone: null) : await _orders.clientProfile(uid);
      final balance = uid == null ? 0 : await _orders.walletBalance(uid);
      if (!mounted) return;
      setState(() {
        _availableCities = cities;
        _cityId = active;
        _wallet = balance;
        if (profile.name != null) _senderNameCtrl.text = profile.name!;
        if (profile.phone != null) _senderPhoneCtrl.text = profile.phone!;
        _initializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = 'Impossible de charger les villes desservies.';
      });
    }
  }

  Future<void> _selectCity(String cityId) async {
    await _cities.setManualOverride(cityId);
    if (!mounted) return;
    setState(() {
      _cityId = _cities.activeCityId;
      _pickup = null;
      _destination = null;
      _pickupResults = const [];
      _destResults = const [];
      _pickupCtrl.clear();
      _destCtrl.clear();
    });
  }

  // ── Adresses : recherche débouncée, jamais un appel par caractère ─────────
  void _onAddressChanged(String value, {required bool isPickup}) {
    (isPickup ? _pickupTimer : _destTimer)?.cancel();
    final timer = Timer(_debounce, () => _runSearch(value, isPickup: isPickup));
    setState(() {
      if (isPickup) {
        _pickupTimer = timer;
        _pickup = null;
      } else {
        _destTimer = timer;
        _destination = null;
      }
    });
  }

  Future<void> _runSearch(String value, {required bool isPickup}) async {
    final query = value.trim();
    if (query.length < PlacesSearchService.minQueryLength || _cityId == null) {
      if (!mounted) return;
      setState(() {
        if (isPickup) {
          _pickupResults = const [];
        } else {
          _destResults = const [];
        }
      });
      return;
    }
    setState(() {
      if (isPickup) {
        _pickupSearching = true;
      } else {
        _destSearching = true;
      }
    });
    List<PlaceSuggestion> results;
    try {
      results = widget.suggest != null
          ? await widget.suggest!(query, _cities)
          // `expandSearch` volontairement absent : pas d'appel Google.
          : await PlacesSearchService.autocomplete(query, cityService: _cities);
    } catch (_) {
      results = const [];
    }
    if (!mounted) return;
    setState(() {
      if (isPickup) {
        _pickupResults = results;
        _pickupSearching = false;
      } else {
        _destResults = results;
        _destSearching = false;
      }
    });
  }

  void _pick(PlaceSuggestion s, {required bool isPickup}) {
    setState(() {
      if (isPickup) {
        _pickup = s;
        _pickupCtrl.text = s.description;
        _pickupResults = const [];
      } else {
        _destination = s;
        _destCtrl.text = s.description;
        _destResults = const [];
      }
    });
  }

  // ── Tarif : logique existante, aucune règle recopiée ─────────────────────
  TarifResult? get tarif {
    final d = _destination;
    if (d?.latitude == null || d?.longitude == null) return null;
    return DeliveryOrderService.quote(
      destLat: d!.latitude!,
      destLng: d.longitude!,
    );
  }

  int get price {
    final t = tarif;
    return t == null ? 0 : DeliveryOrderService.priceFor(t, _mode);
  }

  /// Distance à vol d'oiseau départ → destination, affichée à titre indicatif.
  /// Elle n'entre pas dans le calcul du prix (c'est [TarifService] qui décide,
  /// à partir de la distance au centre-ville).
  double? get straightLineKm {
    final p = _pickup, d = _destination;
    if (p?.latitude == null || d?.latitude == null) return null;
    return TarifService.haversineKm(
        p!.latitude!, p.longitude!, d!.latitude!, d.longitude!);
  }

  // ── Points d'injection pour les tests ────────────────────────────────────
  // Permettent d'exercer la validation et la soumission sans dépendre du
  // rendu de la liste de suggestions ni de la saisie clavier.
  @visibleForTesting
  void debugSetPickup(PlaceSuggestion s) => setState(() {
        _pickup = s;
        _pickupCtrl.text = s.description;
      });

  @visibleForTesting
  void debugSetDestination(PlaceSuggestion s) => setState(() {
        _destination = s;
        _destCtrl.text = s.description;
      });

  @visibleForTesting
  void debugSetPhones({required String sender, required String recipient}) {
    _senderPhoneCtrl.text = sender;
    _recipientPhoneCtrl.text = recipient;
  }

  @visibleForTesting
  void debugSetPayment(String method) => setState(() => _payment = method);

  /// Première erreur de validation, ou `null` si le formulaire est complet.
  @visibleForTesting
  String? validate() {
    if (_cityId == null) return 'Choisis ta ville';
    if (_pickup?.latitude == null) {
      return 'Choisis un point de départ dans la liste des suggestions';
    }
    if (_destination?.latitude == null) {
      return 'Choisis une destination dans la liste des suggestions';
    }
    if (_senderPhoneCtrl.text.trim().isEmpty) {
      return 'Entre le téléphone de l\'expéditeur';
    }
    if (!isValidIvorianPhone(_senderPhoneCtrl.text)) {
      return 'Téléphone expéditeur invalide';
    }
    if (_recipientPhoneCtrl.text.trim().isEmpty) {
      return 'Entre le téléphone du destinataire';
    }
    if (!isValidIvorianPhone(_recipientPhoneCtrl.text)) {
      return 'Téléphone destinataire invalide';
    }
    final t = tarif;
    if (t == null) return 'Prix indisponible pour cette destination';
    if (!t.canOrder) {
      return t.rejectionMessage ?? 'Livraison non disponible pour ce trajet';
    }
    if (_payment == 'wallet' && _wallet < price) {
      return 'Solde insuffisant ($_wallet FCFA) — recharge ton wallet';
    }
    return null;
  }

  @visibleForTesting
  Future<void> submit() async {
    // Anti double-commande : un envoi déjà en cours bloque tout nouvel appel,
    // en plus du bouton désactivé côté UI.
    if (_submitting) return;
    final problem = validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final uid = _uid;
    if (uid == null) {
      setState(() => _error = 'Session expirée, reconnecte-toi');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final parcel = _parcelCtrl.text.trim();
      final modeLabel = _mode == 'express' ? 'EXPRESS' : 'STANDARD';
      final zones = await Future.wait([
        _orders.resolveZoneId(_cities,
            latitude: _pickup!.latitude!, longitude: _pickup!.longitude!),
        _orders.resolveZoneId(_cities,
            latitude: _destination!.latitude!,
            longitude: _destination!.longitude!),
      ]);

      final order = _orders.buildOrder(
        clientId: uid,
        price: price,
        description: parcel.isNotEmpty
            ? '[$modeLabel][COLIS] $parcel'
            : '[$modeLabel][COLIS] Livraison — ${_destination!.mainText}',
        pickupLat: _pickup!.latitude!,
        pickupLng: _pickup!.longitude!,
        destLat: _destination!.latitude!,
        destLng: _destination!.longitude!,
        deliveryAddress: _destination!.description,
        pickupAddress: _pickup!.description,
        deliveryMode: _mode,
        paymentMethod: _payment,
        clientName: _senderNameCtrl.text.trim().isEmpty
            ? null
            : _senderNameCtrl.text.trim(),
        clientPhone: _senderPhoneCtrl.text.trim(),
        pickupContactName: _senderNameCtrl.text.trim().isEmpty
            ? null
            : _senderNameCtrl.text.trim(),
        pickupContactPhone: _senderPhoneCtrl.text.trim(),
        recipientName: _recipientNameCtrl.text.trim().isEmpty
            ? null
            : _recipientNameCtrl.text.trim(),
        recipientPhone: _recipientPhoneCtrl.text.trim(),
        pickupCityId: _cityId,
        deliveryCityId: _cityId,
        pickupZoneId: zones[0],
        deliveryZoneId: zones[1],
        activeCityId: _cityId,
        gpsDetectedCityId: _cities.gpsDetectedCityId,
        citySelectionSource: _cities.citySelectionSource,
        cityResolutionStatus: _cities.cityResolutionStatus,
      );

      await _orders.submit(order);
      if (!mounted) return;
      _showSuccess(order);
      context.go('/app/commandes');
    } on InsufficientWalletException {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Solde insuffisant — recharge ton wallet';
      });
    } on DeliveryOrderException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'La commande n\'a pas pu être créée. Réessaie.';
      });
    }
  }

  void _showSuccess(OrderModel order) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: kSuccess,
      content: Text(
        'Commande créée — ${order.budget} FCFA. '
        'Recherche d\'un livreur en cours.',
        style: GoogleFonts.inter(color: Colors.white),
      ),
    ));
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Center(child: CircularProgressIndicator(color: kOrange));
    }
    return SingleChildScrollView(
      padding: EdgeInsets.all(hPad(context)),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const SizedBox(height: 20),
              if (_availableCities.length > 1) ...[
                _card('Ville', [_cityPicker()]),
                const SizedBox(height: 16),
              ],
              _card('Trajet', [
                _addressField(
                  controller: _pickupCtrl,
                  label: 'Point de départ',
                  icon: Icons.my_location_rounded,
                  selected: _pickup,
                  results: _pickupResults,
                  searching: _pickupSearching,
                  isPickup: true,
                ),
                const SizedBox(height: 16),
                _addressField(
                  controller: _destCtrl,
                  label: 'Destination',
                  icon: Icons.place_rounded,
                  selected: _destination,
                  results: _destResults,
                  searching: _destSearching,
                  isPickup: false,
                ),
              ]),
              const SizedBox(height: 16),
              _card('Expéditeur', [
                _field(_senderNameCtrl, 'Nom de l\'expéditeur',
                    Icons.person_rounded),
                const SizedBox(height: 16),
                _field(_senderPhoneCtrl, 'Téléphone expéditeur',
                    Icons.phone_rounded,
                    type: TextInputType.phone, hint: 'Ex: 07 00 00 00 00'),
              ]),
              const SizedBox(height: 16),
              _card('Destinataire', [
                _field(_recipientNameCtrl, 'Nom du destinataire',
                    Icons.person_outline_rounded),
                const SizedBox(height: 16),
                _field(_recipientPhoneCtrl, 'Téléphone destinataire',
                    Icons.phone_rounded,
                    type: TextInputType.phone, hint: 'Ex: 07 00 00 00 00'),
              ]),
              const SizedBox(height: 16),
              _card('Colis', [
                _field(_parcelCtrl, 'Contenu du colis (optionnel)',
                    Icons.inventory_2_rounded,
                    hint: 'Ex: documents, pièce détachée…'),
              ]),
              const SizedBox(height: 16),
              _card('Type de livraison', [_modePicker()]),
              const SizedBox(height: 16),
              _card('Paiement', [_paymentPicker()]),
              const SizedBox(height: 16),
              _estimate(),
              if (_error != null) ...[
                const SizedBox(height: 16),
                _errorBox(_error!),
              ],
              const SizedBox(height: 20),
              _submitButton(),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Livraison Express',
              style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Envoie un colis d\'un point A à un point B',
              style: GoogleFonts.inter(color: kTextMuted, fontSize: 14)),
        ],
      );

  Widget _card(String title, List<Widget> children) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0x1AFFFFFF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title,
                style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      );

  Widget _cityPicker() => Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final c in _availableCities)
            ChoiceChip(
              label: Text(c.name ?? c.cityId!),
              selected: _cityId == c.cityId,
              onSelected: (_) => _selectCity(c.cityId!),
              backgroundColor: const Color(0xFF0D1117),
              selectedColor: kOrange,
              labelStyle: GoogleFonts.inter(
                  color: _cityId == c.cityId ? Colors.white : kTextMuted,
                  fontSize: 13),
              side: const BorderSide(color: Color(0x33FFFFFF)),
            ),
        ],
      );

  /// Option sélectionnable. `RadioListTile` est déprécié dans cette version de
  /// Flutter (au profit de `RadioGroup`) : on utilise une ligne cliquable
  /// explicite plutôt que d'ajouter des avertissements de dépréciation.
  Widget _option({
    required bool selected,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: _submitting ? null : onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? kOrange.withValues(alpha: 0.12) : _fill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? kOrange : _borderColor),
        ),
        child: Row(children: [
          Icon(
            selected
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            color: selected ? kOrange : kTextMuted,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style:
                          GoogleFonts.inter(color: kTextMuted, fontSize: 12)),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _modePicker() {
    final t = tarif;
    return Column(
      children: [
        for (final e in const [
          ('standard', 'Standard', 'Livraison classique'),
          ('express', 'Express', 'Prioritaire, plus rapide'),
        ]) ...[
          _option(
            selected: _mode == e.$1,
            title: e.$2,
            subtitle: t == null
                ? e.$3
                : '${e.$3} · '
                    '${e.$1 == 'express' ? t.expressPrice : t.standardPrice} FCFA',
            onTap: () => setState(() => _mode = e.$1),
          ),
          if (e.$1 == 'standard') const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _paymentPicker() => Column(
        children: [
          _option(
            selected: _payment == 'cash',
            title: 'Espèces à la livraison',
            subtitle: 'Le livreur encaisse à l\'arrivée',
            onTap: () => setState(() => _payment = 'cash'),
          ),
          const SizedBox(height: 10),
          _option(
            selected: _payment == 'wallet',
            title: 'Wallet AZ Express',
            subtitle: 'Solde : $_wallet FCFA',
            onTap: () => setState(() => _payment = 'wallet'),
          ),
        ],
      );

  Widget _estimate() {
    final t = tarif;
    final km = straightLineKm;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: kHeroGradient,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Estimation',
              style: GoogleFonts.inter(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(t == null ? '— FCFA' : '$price FCFA',
              style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text(
            [
              if (km != null) 'Distance ≈ ${km.toStringAsFixed(1)} km',
              if (t != null) t.isNight ? 'Tarif nuit' : 'Tarif jour',
              if (t != null && t.isOutside) 'Hors zone centrale',
            ].join(' · '),
            style: GoogleFonts.inter(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _errorBox(String message) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          const Icon(Icons.error_outline_rounded, color: Colors.red, size: 18),
          const SizedBox(width: 10),
          Expanded(
              child: Text(message,
                  style:
                      GoogleFonts.inter(color: Colors.red, fontSize: 13))),
        ]),
      );

  Widget _submitButton() => SizedBox(
        height: 54,
        child: ElevatedButton(
          // Désactivé pendant la soumission : premier rempart contre le
          // double clic, doublé par le garde `_submitting` dans submit().
          onPressed: _submitting ? null : submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: kOrange,
            foregroundColor: Colors.white,
            disabledBackgroundColor: kOrange.withValues(alpha: 0.4),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            elevation: 0,
          ),
          child: _submitting
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5))
              : Text('Commander',
                  style: GoogleFonts.inter(
                      fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      );

  // Champs : styles explicites, jamais dépendants d'un InputDecorationTheme
  // global (qui est clair côté web — voir web_client_login.dart).
  static const _fill = Color(0xFF0D1117);
  static const _borderColor = Color(0x33FFFFFF);

  InputDecoration _decoration(String label, IconData icon, {String? hint}) {
    OutlineInputBorder b(Color c, double w) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: c, width: w),
        );
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: GoogleFonts.inter(color: const Color(0xB3FFFFFF), fontSize: 14),
      floatingLabelStyle: GoogleFonts.inter(color: kOrange, fontSize: 14),
      hintStyle: GoogleFonts.inter(color: const Color(0x80FFFFFF), fontSize: 14),
      prefixIcon: Icon(icon, color: const Color(0xCCFFFFFF), size: 20),
      filled: true,
      fillColor: _fill,
      border: b(_borderColor, 1),
      enabledBorder: b(_borderColor, 1),
      focusedBorder: b(kOrange, 1.6),
      disabledBorder: b(_borderColor, 1),
    );
  }

  Widget _field(TextEditingController ctrl, String label, IconData icon,
          {TextInputType? type, String? hint}) =>
      TextField(
        controller: ctrl,
        keyboardType: type,
        enabled: !_submitting,
        style: GoogleFonts.inter(color: Colors.white, fontSize: 15),
        cursorColor: kOrange,
        decoration: _decoration(label, icon, hint: hint),
      );

  Widget _addressField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required PlaceSuggestion? selected,
    required List<PlaceSuggestion> results,
    required bool searching,
    required bool isPickup,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          enabled: !_submitting,
          style: GoogleFonts.inter(color: Colors.white, fontSize: 15),
          cursorColor: kOrange,
          onChanged: (v) => _onAddressChanged(v, isPickup: isPickup),
          decoration: _decoration(label, icon,
                  hint: 'Tape au moins '
                      '${PlacesSearchService.minQueryLength} caractères')
              .copyWith(
            suffixIcon: searching
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: kOrange)),
                  )
                : (selected != null
                    ? const Icon(Icons.check_circle_rounded,
                        color: kSuccess, size: 20)
                    : null),
          ),
        ),
        if (results.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: _fill,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _borderColor),
            ),
            child: Column(
              children: [
                for (final s in results.take(6))
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.location_on_outlined,
                        color: kTextMuted, size: 18),
                    title: Text(s.mainText,
                        style: GoogleFonts.inter(
                            color: Colors.white, fontSize: 14)),
                    subtitle: s.secondaryText.isEmpty
                        ? null
                        : Text(s.secondaryText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                                color: kTextMuted, fontSize: 12)),
                    onTap: () => _pick(s, isPickup: isPickup),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
