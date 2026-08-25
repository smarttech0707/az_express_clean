import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../models/real_estate_listing.dart';
import '../../models/real_estate_property_field_policy.dart';
import '../../models/real_estate_property_type.dart';
import '../../theme/app_theme.dart';

/// Master Prompt "Immobilier V6" — Mission 3 : porte l'état des champs
/// additionnels (surface, pièces, équipements...) indépendamment du reste du
/// formulaire de création — le parent (`_ListingFormScreen`) le crée, le
/// passe à [PropertyDetailsFormSection], et lit ses valeurs au moment de la
/// sauvegarde via [toListingFieldsForCreate]/[toListingFieldsForUpdate].
/// Doit être disposé par l'appelant.
///
/// Master Prompt "Immobilier V6.2" — Mission 2 : gagne [loadFrom] pour
/// préremplir un formulaire d'ÉDITION à partir d'une annonce existante —
/// jamais de `0`/`false` inventé : un champ absent du document reste un
/// contrôleur texte vide (jamais "0"), un booléen absent reste `false` par
/// défaut du modèle lui-même (déjà le cas depuis V6, `RealEstateListing`
/// n'a jamais de booléen nullable).
class PropertyDetailsFormController {
  final surfaceCtrl = TextEditingController();
  final surfaceTerrainCtrl = TextEditingController();
  final roomsCtrl = TextEditingController();
  final bedroomsCtrl = TextEditingController();
  final bathroomsCtrl = TextEditingController();
  final floorCtrl = TextEditingController();
  final pricePerDayCtrl = TextEditingController();
  final pricePerWeekCtrl = TextEditingController();
  final pricePerMonthCtrl = TextEditingController();

  bool hasGarage = false;
  bool hasParking = false;
  bool hasTerrace = false;
  bool hasBalcony = false;
  bool hasKitchen = false;
  bool hasAirConditioning = false;
  bool hasInternet = false;
  bool hasGenerator = false;
  bool hasPool = false;
  bool hasBorehole = false;
  bool hasGuard = false;
  bool hasElevator = false;
  bool chargesIncluded = false;

  /// Master Prompt "Immobilier V6.2" — Mission 2 : "disponibilité" — le
  /// seul champ demandé par la mission qui n'avait jusqu'ici aucun contrôle
  /// dans le formulaire (ni création, ni édition), bien qu'il existe déjà
  /// dans le modèle et l'affichage (`PropertyDetailsDisplaySection`,
  /// bannière "indisponible"). Ajout minimal : un simple interrupteur,
  /// universel (jamais gated par [RealEstatePropertyFieldPolicy] — la
  /// disponibilité a un sens pour tout type de bien). Pas de sélecteur de
  /// date ajouté dans cette passe (`availabilityDate` reste en lecture
  /// seule tant qu'aucune UI de saisie de date n'est explicitement
  /// demandée) — décision documentée, pas un oubli.
  bool isAvailable = true;

  void dispose() {
    surfaceCtrl.dispose();
    surfaceTerrainCtrl.dispose();
    roomsCtrl.dispose();
    bedroomsCtrl.dispose();
    bathroomsCtrl.dispose();
    floorCtrl.dispose();
    pricePerDayCtrl.dispose();
    pricePerWeekCtrl.dispose();
    pricePerMonthCtrl.dispose();
  }

  double? _d(TextEditingController c) => double.tryParse(c.text.trim());
  int? _i(TextEditingController c) => int.tryParse(c.text.trim());

  static String _numText(num? v) => v == null ? '' : v.toString();

  /// Préremplit ce contrôleur à partir d'une annonce existante (Mission 2,
  /// V6.2) — appelé une seule fois à l'ouverture du formulaire en mode
  /// édition, jamais réappelé pendant la saisie (écraserait ce que l'agent
  /// tape). Un champ `null` dans le modèle reste un champ texte vide, pas
  /// "0" — cohérent avec la convention déjà actée pour l'affichage
  /// (`PropertyDetailsDisplaySection`, Mission 5 de V6).
  void loadFrom(RealEstateListing listing) {
    surfaceCtrl.text = _numText(listing.surface);
    surfaceTerrainCtrl.text = _numText(listing.surfaceTerrain);
    roomsCtrl.text = _numText(listing.rooms);
    bedroomsCtrl.text = _numText(listing.bedrooms);
    bathroomsCtrl.text = _numText(listing.bathrooms);
    floorCtrl.text = _numText(listing.floor);
    pricePerDayCtrl.text = _numText(listing.pricePerDay);
    pricePerWeekCtrl.text = _numText(listing.pricePerWeek);
    pricePerMonthCtrl.text = _numText(listing.pricePerMonth);
    hasGarage = listing.hasGarage;
    hasParking = listing.hasParking;
    hasTerrace = listing.hasTerrace;
    hasBalcony = listing.hasBalcony;
    hasKitchen = listing.hasKitchen;
    hasAirConditioning = listing.hasAirConditioning;
    hasInternet = listing.hasInternet;
    hasGenerator = listing.hasGenerator;
    hasPool = listing.hasPool;
    hasBorehole = listing.hasBorehole;
    hasGuard = listing.hasGuard;
    chargesIncluded = listing.chargesIncluded;
    hasElevator = listing.hasElevator;
    isAvailable = listing.isAvailable;
  }

  /// Master Prompt "Immobilier V6.2" — Mission 9 : "ne pas envoyer une mise
  /// à jour si aucune donnée n'a changé" — compare l'état courant des
  /// contrôleurs/interrupteurs à l'annonce d'origine, champ par champ.
  bool hasChangesFrom(RealEstateListing existing) {
    if (_d(surfaceCtrl) != existing.surface) return true;
    if (_d(surfaceTerrainCtrl) != existing.surfaceTerrain) return true;
    if (_i(roomsCtrl) != existing.rooms) return true;
    if (_i(bedroomsCtrl) != existing.bedrooms) return true;
    if (_i(bathroomsCtrl) != existing.bathrooms) return true;
    if (_i(floorCtrl) != existing.floor) return true;
    if (_i(pricePerDayCtrl) != existing.pricePerDay) return true;
    if (_i(pricePerWeekCtrl) != existing.pricePerWeek) return true;
    if (_i(pricePerMonthCtrl) != existing.pricePerMonth) return true;
    if (hasGarage != existing.hasGarage) return true;
    if (hasParking != existing.hasParking) return true;
    if (hasTerrace != existing.hasTerrace) return true;
    if (hasBalcony != existing.hasBalcony) return true;
    if (hasKitchen != existing.hasKitchen) return true;
    if (hasAirConditioning != existing.hasAirConditioning) return true;
    if (hasInternet != existing.hasInternet) return true;
    if (hasGenerator != existing.hasGenerator) return true;
    if (hasPool != existing.hasPool) return true;
    if (hasBorehole != existing.hasBorehole) return true;
    if (hasGuard != existing.hasGuard) return true;
    if (hasElevator != existing.hasElevator) return true;
    if (chargesIncluded != existing.chargesIncluded) return true;
    if (isAvailable != existing.isAvailable) return true;
    return false;
  }

  Map<String, num?> _numericValues() => {
        'surface': _d(surfaceCtrl),
        'surfaceTerrain': _d(surfaceTerrainCtrl),
        'rooms': _i(roomsCtrl),
        'bedrooms': _i(bedroomsCtrl),
        'bathrooms': _i(bathroomsCtrl),
        'floor': _i(floorCtrl),
        'pricePerDay': _i(pricePerDayCtrl),
        'pricePerWeek': _i(pricePerWeekCtrl),
        'pricePerMonth': _i(pricePerMonthCtrl),
      };

  Map<String, bool> _booleanValues() => {
        'hasGarage': hasGarage,
        'hasParking': hasParking,
        'hasTerrace': hasTerrace,
        'hasBalcony': hasBalcony,
        'hasKitchen': hasKitchen,
        'hasAirConditioning': hasAirConditioning,
        'hasInternet': hasInternet,
        'hasGenerator': hasGenerator,
        'hasPool': hasPool,
        'hasBorehole': hasBorehole,
        'hasGuard': hasGuard,
        'hasElevator': hasElevator,
        'chargesIncluded': chargesIncluded,
      };

  /// Valeurs prêtes à fusionner dans le payload de CRÉATION
  /// (`RealEstateListing.toMap()` + ceci, envoyés via `addListing`/`.add()`).
  /// Un champ incompatible avec [propertyType] (Mission 5/6, V6.2) n'est
  /// simplement jamais écrit — `FieldValue.delete()` n'est pas valide sur un
  /// `.add()` (document qui n'existe pas encore), contrairement à
  /// [toListingFieldsForUpdate].
  Map<String, dynamic> toListingFieldsForCreate(String propertyType) {
    final allowed = RealEstatePropertyFieldPolicy.allowedFields(propertyType);
    final map = <String, dynamic>{'isAvailable': isAvailable};
    _numericValues().forEach((key, value) {
      if (allowed.contains(key) && value != null) map[key] = value;
    });
    _booleanValues().forEach((key, value) {
      if (allowed.contains(key)) map[key] = value;
    });
    return map;
  }

  /// Master Prompt "Immobilier V6.2" — Mission 6 : équivalent pour une mise à
  /// jour (`update()`, qui supporte `FieldValue.delete()`) — un champ
  /// incompatible avec le NOUVEAU [propertyType] est explicitement supprimé
  /// du document plutôt que laissé tel quel ou écrit à `false`/`null` (ce qui
  /// affirmerait à tort qu'il a été activement désactivé). Utilisé par
  /// `RealEstateService` lors d'une édition — jamais par la création.
  Map<String, dynamic> toListingFieldsForUpdate(String propertyType) {
    final allowed = RealEstatePropertyFieldPolicy.allowedFields(propertyType);
    final map = <String, dynamic>{'isAvailable': isAvailable};
    _numericValues().forEach((key, value) {
      if (allowed.contains(key)) {
        if (value != null) {
          map[key] = value;
        } else {
          map[key] = FieldValue.delete();
        }
      } else {
        map[key] = FieldValue.delete();
      }
    });
    _booleanValues().forEach((key, value) {
      map[key] = allowed.contains(key) ? value : FieldValue.delete();
    });
    return map;
  }

  /// Terrain : superficie obligatoire — vérifié par l'appelant avant envoi.
  bool get hasSurfaceTerrain => _d(surfaceTerrainCtrl) != null;
}

/// Section de formulaire dynamique selon le type de bien (Mission 3) :
/// - Terrain → superficie terrain uniquement, jamais de pièces/chambres.
/// - Bureau/Magasin/Entrepôt/Local commercial → surface + parking + vitrine
///   (le "vitrine" demandé est représenté par `hasTerrace`, réutilisé
///   sémantiquement comme "façade/vitrine" pour ce type — pas de nouveau
///   champ dupliqué pour un concept déjà couvert par le même booléen).
/// - Résidence meublée → équipements (climatisation/internet/cuisine...)
///   affichés en premier et présentés comme la section principale.
/// - Villa/Maison/Appartement/Studio → pièces/chambres/salles de bain +
///   garage/piscine/etc.
///
/// Master Prompt "Immobilier V6.2" — Mission 5 : la liste des équipements
/// "généraux" (fin de la section) est désormais pilotée par
/// [RealEstatePropertyFieldPolicy.isFieldAllowed] plutôt que par des
/// conditions répétées `!isCommercial`/`!isLand` — source unique de vérité
/// partagée avec la logique de nettoyage Firestore (Mission 6) et
/// l'affichage (`PropertyDetailsDisplaySection`).
class PropertyDetailsFormSection extends StatefulWidget {
  final String propertyType;
  final PropertyDetailsFormController controller;

  const PropertyDetailsFormSection({
    super.key,
    required this.propertyType,
    required this.controller,
  });

  @override
  State<PropertyDetailsFormSection> createState() =>
      _PropertyDetailsFormSectionState();
}

class _PropertyDetailsFormSectionState
    extends State<PropertyDetailsFormSection> {
  Widget _numberField(TextEditingController ctrl, String label,
      {String? suffix}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: ctrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, suffixText: suffix),
      ),
    );
  }

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontSize: 14)),
      value: value,
      activeThumbColor: AppColors.primary,
      onChanged: (v) => setState(() => onChanged(v)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final isLand = RealEstatePropertyType.isLand(widget.propertyType);
    final isCommercial =
        RealEstatePropertyType.isCommercialType(widget.propertyType);
    final isFurnishedResidence =
        RealEstatePropertyType.isFurnishedResidenceType(widget.propertyType);
    final hasRooms = RealEstatePropertyType.hasRooms(widget.propertyType);
    bool allow(String field) => RealEstatePropertyFieldPolicy.isFieldAllowed(
        widget.propertyType, field);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text('Caractéristiques', style: AppTypography.titleLargeStyle(context)),
        const SizedBox(height: 8),

        // ── Terrain : superficie obligatoire, jamais de pièces/chambres.
        if (isLand) ...[
          _numberField(c.surfaceTerrainCtrl, 'Superficie du terrain *',
              suffix: 'm²'),
        ] else ...[
          _numberField(c.surfaceCtrl, 'Surface bâtie', suffix: 'm²'),
          if (!isCommercial)
            _numberField(c.surfaceTerrainCtrl, 'Surface du terrain (optionnel)',
                suffix: 'm²'),
        ],

        // ── Pièces/chambres/salles de bain — pas pour un terrain ni pour un
        // bien commercial (bureau/magasin/entrepôt/local commercial).
        // Bug réel trouvé sur appareil (Mission 2, V6.1) : le formulaire
        // affichait "Pièces"/"Chambres"/"Salles de bain"/"Étage" pour un
        // Local commercial, alors que le design de ce type ne prévoit que
        // surface + parking + vitrine ("aucune information résidentielle").
        if (hasRooms && !isLand && !isCommercial) ...[
          Row(children: [
            Expanded(child: _numberField(c.roomsCtrl, 'Pièces')),
            const SizedBox(width: 8),
            Expanded(child: _numberField(c.bedroomsCtrl, 'Chambres')),
          ]),
          Row(children: [
            Expanded(child: _numberField(c.bathroomsCtrl, 'Salles de bain')),
            const SizedBox(width: 8),
            Expanded(child: _numberField(c.floorCtrl, 'Étage')),
          ]),
        ],

        // ── Résidence meublée : équipements mis en avant en premier.
        if (isFurnishedResidence) ...[
          const Text('Équipements (résidence meublée)',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          _switch('Climatisation', c.hasAirConditioning,
              (v) => c.hasAirConditioning = v),
          _switch('Internet / Wi-Fi', c.hasInternet, (v) => c.hasInternet = v),
          _switch('Cuisine équipée', c.hasKitchen, (v) => c.hasKitchen = v),
        ],

        // ── Commercial (bureau/magasin/entrepôt/local) : surface déjà
        // affichée ci-dessus, parking + vitrine/façade.
        if (isCommercial) ...[
          _switch('Parking disponible', c.hasParking, (v) => c.hasParking = v),
          _switch('Vitrine / façade commerciale', c.hasTerrace,
              (v) => c.hasTerrace = v),
        ],

        // ── Équipements généraux — pertinents pour tout bien non-terrain.
        // Chaque interrupteur n'apparaît désormais que si
        // RealEstatePropertyFieldPolicy l'autorise pour ce type (Mission 5,
        // V6.2) — même source que le nettoyage Firestore (Mission 6).
        if (!isLand) ...[
          const SizedBox(height: 8),
          const Text('Autres équipements',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          if (!isFurnishedResidence) ...[
            if (allow('hasAirConditioning'))
              _switch('Climatisation', c.hasAirConditioning,
                  (v) => c.hasAirConditioning = v),
            if (allow('hasInternet'))
              _switch(
                  'Internet / Wi-Fi', c.hasInternet, (v) => c.hasInternet = v),
            if (allow('hasKitchen'))
              _switch('Cuisine équipée', c.hasKitchen, (v) => c.hasKitchen = v),
          ],
          if (!isCommercial) ...[
            if (allow('hasGarage'))
              _switch('Garage', c.hasGarage, (v) => c.hasGarage = v),
            if (allow('hasParking'))
              _switch('Parking', c.hasParking, (v) => c.hasParking = v),
            if (allow('hasTerrace'))
              _switch('Terrasse', c.hasTerrace, (v) => c.hasTerrace = v),
            if (allow('hasBalcony'))
              _switch('Balcon', c.hasBalcony, (v) => c.hasBalcony = v),
            if (allow('hasPool'))
              _switch('Piscine', c.hasPool, (v) => c.hasPool = v),
            if (allow('hasElevator'))
              _switch('Ascenseur', c.hasElevator, (v) => c.hasElevator = v),
          ],
          if (allow('hasGenerator'))
            _switch('Groupe électrogène', c.hasGenerator,
                (v) => c.hasGenerator = v),
          if (allow('hasBorehole'))
            _switch('Forage', c.hasBorehole, (v) => c.hasBorehole = v),
          if (allow('hasGuard'))
            _switch('Gardien', c.hasGuard, (v) => c.hasGuard = v),
          if (allow('chargesIncluded'))
            _switch('Charges incluses', c.chargesIncluded,
                (v) => c.chargesIncluded = v),
        ],

        // ── Tarifs alternatifs — surtout utiles pour résidences meublées /
        // locations courte durée, proposés pour tout bien en location.
        const SizedBox(height: 8),
        const Text('Tarifs alternatifs (optionnel)',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        Row(children: [
          Expanded(
              child:
                  _numberField(c.pricePerDayCtrl, 'Par jour', suffix: 'FCFA')),
          const SizedBox(width: 8),
          Expanded(
              child: _numberField(c.pricePerWeekCtrl, 'Par semaine',
                  suffix: 'FCFA')),
        ]),
        _numberField(c.pricePerMonthCtrl, 'Par mois', suffix: 'FCFA'),

        // ── Disponibilité — universel, jamais gated par le type (Mission 2,
        // V6.2) : seul champ demandé sans contrôle existant jusqu'ici.
        _switch('Disponible', c.isAvailable, (v) => c.isAvailable = v),
      ],
    );
  }
}
