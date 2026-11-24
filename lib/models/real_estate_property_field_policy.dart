import 'package:cloud_firestore/cloud_firestore.dart';

import 'real_estate_property_type.dart';

/// Master Prompt "Immobilier V6.2" — Mission 5 : source unique de vérité pour
/// "quel champ caractéristique a du sens pour quel type de bien". Avant
/// cette passe, cette logique était dispersée (dupliquée en esprit) entre
/// `PropertyDetailsFormSection` (quels champs afficher à la création) et
/// `PropertyDetailsDisplaySection` (quels champs afficher à la lecture) —
/// les deux widgets sont désormais réécrits pour consulter cette classe au
/// lieu de recalculer leurs propres conditions `isLand`/`isCommercial`/etc.
///
/// Le regroupement se fait par CATÉGORIE (terrain / commercial / résidentiel
/// — y compris résidence meublée, qui a exactement le même ensemble de
/// champs autorisés qu'un bien résidentiel classique dans le formulaire déjà
/// construit, seul le REGROUPEMENT visuel diffère) plutôt que par les 10
/// types canoniques individuels — reflet fidèle du comportement déjà
/// implémenté et testé, pas une nouvelle règle inventée.
///
/// Les exemples de champs donnés dans le Master Prompt V6.2 ("accèsRoute",
/// "documentsFonciers") ne correspondent à aucun champ réel de
/// `RealEstateListing` — plutôt que d'inventer de nouveaux champs hors du
/// modèle déjà construit et testé (V6/V6.1), cette politique reste strictement
/// alignée sur les champs qui existent réellement aujourd'hui.
class RealEstatePropertyFieldPolicy {
  const RealEstatePropertyFieldPolicy._();

  /// Champs "caractéristiques" propres à un bien bâti résidentiel classique
  /// (maison/villa/appartement/studio/résidence meublée).
  static const Set<String> _residentialFields = {
    'surface',
    'surfaceTerrain',
    'rooms',
    'bedrooms',
    'bathrooms',
    'floor',
    'hasGarage',
    'hasParking',
    'hasTerrace',
    'hasBalcony',
    'hasKitchen',
    'hasAirConditioning',
    'hasInternet',
    'hasGenerator',
    'hasPool',
    'hasBorehole',
    'hasGuard',
    'hasElevator',
    'chargesIncluded',
  };

  /// Champs propres à un bien commercial (bureau/magasin/entrepôt/local
  /// commercial) — jamais de pièces/chambres/salles de bain/étage/piscine/
  /// garage/balcon/terrasse résidentielle (`hasTerrace` y est réutilisé
  /// sémantiquement comme "vitrine/façade", pas comme une terrasse
  /// résidentielle — même convention déjà actée dans le formulaire).
  static const Set<String> _commercialFields = {
    'surface',
    'hasParking',
    'hasTerrace', // vitrine / façade commerciale
    'hasAirConditioning',
    'hasInternet',
    'hasKitchen',
    'hasGenerator',
    'hasBorehole',
    'hasGuard',
    'chargesIncluded',
  };

  /// Un terrain nu n'a qu'une seule caractéristique bâtie : sa superficie.
  static const Set<String> _landFields = {'surfaceTerrain'};

  /// Toujours autorisés, quel que soit le type — jamais gagné/perdu lors
  /// d'un changement de type (tarifs alternatifs, déjà proposés sans
  /// condition de type dans le formulaire existant).
  static const Set<String> universalFields = {
    'pricePerDay',
    'pricePerWeek',
    'pricePerMonth',
  };

  /// Union de tous les champs "caractéristiques" connus du modèle — sert de
  /// base pour calculer les champs incompatibles (tout ce qui n'est pas
  /// autorisé pour le type donné). Pas `const` : les 4 ensembles source se
  /// recouvrent partiellement (ex. "surface" appartient à la fois au
  /// résidentiel et au commercial), qu'un littéral `const Set` refuse.
  static final Set<String> allKnownCharacteristicFields = {
    ..._residentialFields,
    ..._commercialFields,
    ..._landFields,
    ...universalFields,
  };

  /// Champs autorisés (affichables/éditables) pour un type de bien donné —
  /// reconnaît aussi bien les valeurs canoniques que les anciens libellés
  /// français hérités (délègue à `RealEstatePropertyType`, jamais dupliqué).
  static Set<String> allowedFields(String propertyType) {
    if (RealEstatePropertyType.isLand(propertyType)) {
      return {..._landFields, ...universalFields};
    }
    if (RealEstatePropertyType.isCommercialType(propertyType)) {
      return {..._commercialFields, ...universalFields};
    }
    // Résidentiel classique ET résidence meublée : même ensemble de champs
    // autorisés dans le formulaire déjà construit — seul le regroupement
    // visuel diffère (équipements mis en avant en premier pour une
    // résidence meublée), jamais l'ensemble de champs lui-même.
    return {..._residentialFields, ...universalFields};
  }

  /// Champs qui n'ont plus de sens pour ce type — à nettoyer explicitement
  /// de Firestore lors d'un changement de type (Mission 6), jamais laissés
  /// tels quels ni simplement masqués côté UI.
  static Set<String> incompatibleFields(String propertyType) =>
      allKnownCharacteristicFields.difference(allowedFields(propertyType));

  /// Un champ caractéristique donné a-t-il du sens pour ce type ?
  static bool isFieldAllowed(String propertyType, String field) =>
      allowedFields(propertyType).contains(field);

  /// Construit les entrées `FieldValue.delete()` à fusionner dans un
  /// `update()` Firestore lors d'un changement de type — jamais un
  /// remplacement aveugle du document, jamais un champ mis à `null`/`false`
  /// (qui resterait un mensonge silencieux : "false" affirmerait que la
  /// piscine a été activement désactivée, alors qu'elle n'a simplement plus
  /// de sens pour ce type). Ne touche jamais aux champs système
  /// (agentId/createdAt/views/status/images/videos/GPS) — uniquement les
  /// champs caractéristiques connus de [allKnownCharacteristicFields].
  static Map<String, dynamic> cleanupFieldsForTypeChange(
      String newPropertyType) {
    final toClear = incompatibleFields(newPropertyType);
    return {for (final field in toClear) field: FieldValue.delete()};
  }
}
