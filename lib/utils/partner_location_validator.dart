class PartnerLocationValidator {
  static const requiredMessage =
      'Un point précis est obligatoire : sans lui, le livreur ne peut pas être guidé et les commandes seront refusées.';

  static String? validate(double? latitude, double? longitude) {
    if (latitude == null || longitude == null) return requiredMessage;
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180 ||
        (latitude == 0 && longitude == 0)) {
      return 'Sélectionnez un point GPS valide : sans point précis, le livreur ne peut pas être guidé et les commandes seront refusées. Les coordonnées absentes, 0/0 ou hors limites sont refusées.';
    }
    return null;
  }

  static String? validateText(String latitude, String longitude) => validate(
        double.tryParse(latitude.trim()),
        double.tryParse(longitude.trim()),
      );
}
