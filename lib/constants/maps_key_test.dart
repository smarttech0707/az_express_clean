// Clé Google Maps des builds de TEST sur émulateurs : vide (cartes désactivées) sauf clé de test explicitement
// fournie par --dart-define=TEST_MAPS_API_KEY=... Jamais la clé de production.
const String kMapsApiKey = String.fromEnvironment('TEST_MAPS_API_KEY');
