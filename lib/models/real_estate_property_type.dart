/// Master Prompt "Immobilier V6" — Mission 2 : catégorisation des types de
/// bien, SANS jamais renommer ni invalider les valeurs déjà écrites dans
/// `real_estate_listings.propertyType` (des libellés français en dur créés
/// par le formulaire existant : 'Maison', 'Villa', 'Terrain', etc.).
///
/// Ce fichier ajoute des constantes CANONIQUES (nouvelles valeurs, en
/// anglais, pour toute future annonce créée via le formulaire mis à jour)
/// et une fonction de catégorisation qui reconnaît À LA FOIS les anciennes
/// valeurs françaises ET les nouvelles valeurs canoniques — jamais de
/// migration de données, jamais d'ancienne annonce cassée.
class RealEstatePropertyType {
  const RealEstatePropertyType._();

  static const house = 'house';
  static const apartment = 'apartment';
  static const studio = 'studio';
  static const villa = 'villa';
  static const land = 'land';
  static const office = 'office';
  static const shop = 'shop';
  static const warehouse = 'warehouse';
  static const furnishedResidence = 'furnishedResidence';
  static const commercial = 'commercial';

  static const all = [
    house,
    apartment,
    studio,
    villa,
    land,
    office,
    shop,
    warehouse,
    furnishedResidence,
    commercial,
  ];

  /// Libellé français affiché — couvre les valeurs canoniques ET les
  /// anciennes valeurs françaises (retournées telles quelles, déjà lisibles).
  static String label(String propertyType) {
    switch (propertyType) {
      case house:
        return 'Maison';
      case apartment:
        return 'Appartement';
      case studio:
        return 'Studio';
      case villa:
        return 'Villa';
      case land:
        return 'Terrain';
      case office:
        return 'Bureau';
      case shop:
        return 'Magasin';
      case warehouse:
        return 'Entrepôt';
      case furnishedResidence:
        return 'Résidence meublée';
      case commercial:
        return 'Local commercial';
      default:
        // Anciennes valeurs françaises ('Maison', 'Villa', 'Terrain', ...)
        // déjà directement lisibles — retournées sans modification.
        return propertyType;
    }
  }

  /// Reconnaît un "terrain" qu'il soit codé en canonique ou en ancien
  /// libellé français — sert à masquer les champs pièces/chambres/etc.
  static bool isLand(String propertyType) =>
      propertyType == land || propertyType.toLowerCase().contains('terrain');

  /// Un bien qui a normalement des pièces/chambres/salles de bain (tout sauf
  /// terrain — même un bureau/magasin peut avoir des pièces, donc large).
  static bool hasRooms(String propertyType) => !isLand(propertyType);

  /// Un bien commercial/professionnel (bureau/magasin/entrepôt/local
  /// commercial) — affiche vitrine/surface plutôt que chambres.
  static bool isCommercialType(String propertyType) {
    const canonical = {office, shop, warehouse, commercial};
    if (canonical.contains(propertyType)) return true;
    final lower = propertyType.toLowerCase();
    return lower.contains('bureau') ||
        lower.contains('magasin') ||
        lower.contains('entrepôt') ||
        lower.contains('entrepot') ||
        lower.contains('local commercial');
  }

  /// Une résidence meublée — équipements obligatoires dans le formulaire.
  static bool isFurnishedResidenceType(String propertyType) {
    if (propertyType == furnishedResidence) return true;
    return propertyType.toLowerCase().contains('résidence meublée') ||
        propertyType.toLowerCase().contains('residence meublee');
  }
}
