// AppColors est défini dans lib/theme/app_theme.dart — source unique
// import '../theme/app_theme.dart' pour accéder à AppColors

// ═══════════════════════════════════════════════════════════════════════════
// COLLECTIONS FIRESTORE
// ═══════════════════════════════════════════════════════════════════════════
class Collections {
  Collections._();

  static const clients = 'clients';
  static const livreurs = 'livreurs';
  static const sellers = 'sellers';
  static const restaurants = 'restaurants';
  static const restaurantOwners = 'restaurant_owners';
  static const boulangeries = 'boulangeries';
  static const pharmacies = 'pharmacies';
  static const fleetOwners = 'fleet_owners';
  static const admins = 'admins';

  static const orders = 'orders';
  static const walletTransactions = 'wallet_transactions';
  static const withdrawalRequests = 'withdrawal_requests';
  static const rechargeRequests = 'recharge_requests';
  static const paymentSessions = 'payment_sessions';

  static const driverRequests = 'driver_requests';
  static const sellerRequests = 'seller_requests';
  static const restaurantRequests = 'restaurant_requests';
  static const boulangerieRequests = 'boulangerie_requests';
  static const pharmacieRequests = 'pharmacie_requests';

  static const marketplaceProducts = 'marketplace_products';
  static const marketplaceFavorites = 'marketplace_favorites';
  static const marketplaceChats = 'marketplace_chats';
  static const marketplaceReports = 'marketplace_reports';

  static const ekbineOrders = 'ekbine_orders';
  static const ekbineAgents = 'ekbine_agents';
  static const ekbineChats = 'ekbine_chats';

  static const sosAlerts = 'sos_alerts';
  static const chats = 'chats';
  static const notifications = 'notifications';
  static const supportTickets = 'support_tickets';
  static const config = 'config';
  static const appConfig = 'app_config';
  static const driverRankings = 'driver_rankings';
  static const boutiqueOrders = 'boutique_orders';
  static const boutiqueProducts = 'boutique_products';
  static const locations = 'locations';
  static const residences = 'residences';
  static const services = 'services';
  static const serviceProviders = 'service_providers';
  static const blanchisserieOrders = 'blanchisserie_orders';
  static const eauBoissonsOrders = 'eau_boissons_orders';
}

// ═══════════════════════════════════════════════════════════════════════════
// STATUTS COMMANDES
// ═══════════════════════════════════════════════════════════════════════════
class OrderStatus {
  OrderStatus._();

  static const pending = 'pending';
  static const assigned = 'assigned';
  static const accepted = 'accepted';
  static const pickedUp = 'picked_up';
  static const delivered = 'delivered';
  static const cancelled = 'cancelled';
}

// ═══════════════════════════════════════════════════════════════════════════
// STATUTS TRANSACTIONS — utiliser l'enum TxStatus de feexpay_transaction.dart
// ═══════════════════════════════════════════════════════════════════════════
// TxStatus supprimé ici pour éviter la duplication avec
// lib/models/feexpay_transaction.dart qui définit l'enum TxStatus.
// Importer depuis : import '../models/feexpay_transaction.dart';

// ═══════════════════════════════════════════════════════════════════════════
// RÔLES UTILISATEURS
// ═══════════════════════════════════════════════════════════════════════════
class UserRole {
  UserRole._();

  static const client = 'client';
  static const driver = 'driver';
  static const seller = 'seller';
  static const restaurant = 'restaurant';
  static const boulangerie = 'boulangerie';
  static const pharmacie = 'pharmacie';
  static const fleet = 'fleet';
  static const artisan = 'artisan';
  static const admin = 'admin';
}

// ═══════════════════════════════════════════════════════════════════════════
// OPÉRATEURS MOBILE MONEY
// ═══════════════════════════════════════════════════════════════════════════
class MobileOperator {
  MobileOperator._();

  static const mtn = 'mtn';
  static const orange = 'orange';
  static const moov = 'moov';
  static const wave = 'wave';

  static String label(String op) {
    switch (op) {
      case mtn:
        return 'MTN MoMo';
      case orange:
        return 'Orange Money';
      case moov:
        return 'Moov Money';
      case wave:
        return 'Wave';
      default:
        return op.toUpperCase();
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TARIFICATION LIVRAISON — Abengourou
// ═══════════════════════════════════════════════════════════════════════════
class DeliveryPricing {
  DeliveryPricing._();

  static const baseFare = 500; // FCFA
  static const pricePerKm = 200; // FCFA/km
  static const minFare = 500; // FCFA
  static const maxFare = 5000; // FCFA
  static const commissionRate = 0.15; // 15% AZ Express

  static int calculate(double distanceKm) {
    final fare = baseFare + (distanceKm * pricePerKm).round();
    return fare.clamp(minFare, maxFare);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CONFIGURATION APP
// ═══════════════════════════════════════════════════════════════════════════
class AppConfig {
  AppConfig._();

  static const appName = 'AZ Express';
  static const city = 'Abengourou';
  static const country = 'Côte d\'Ivoire';
  static const currency = 'FCFA';
  static const supportPhone = '+2250798051397';
  static const supportWhatsApp = '+2250798051397';
  static const supportEmail = 'support@azexpress.ci';
  static const whatsAppUrl = 'https://wa.me/2250798051397';
  static const minOrderAmount = 500;
  static const minWalletRecharge = 100;
  static const minWalletWithdraw = 500;

  // Coordonnées centre d'Abengourou
  static const abengourouLat = 6.7273;
  static const abengourouLng = -3.4961;
  static const defaultZoom = 14.0;
}

// ═══════════════════════════════════════════════════════════════════════════
// GOOGLE MAPS — clé partagée
// Centralisée ici pour éviter la duplication (était recopiée telle quelle
// dans 3 fichiers de services Maps) — ne change pas la posture de sécurité
// (la clé reste embarquée côté client, comme l'exige le SDK Maps) : la
// restreindre par domaine/app/API se fait côté Google Cloud Console, hors
// du code (voir mémoire projet `project_maps_cost_audit`).
// ═══════════════════════════════════════════════════════════════════════════
class MapsConfig {
  MapsConfig._();

  static const apiKey = 'AIzaSyCjWt989YSIBblhRE9WNVOWXvOsXHIQ1DE';
}

// ═══════════════════════════════════════════════════════════════════════════
// CHEMINS FIREBASE STORAGE
// ═══════════════════════════════════════════════════════════════════════════
class StoragePaths {
  StoragePaths._();

  static String clientPhoto(String uid) => 'client_photos/$uid/profile.jpg';
  static String driverSelfie(String uid) => 'driver_selfies/$uid/selfie.jpg';
  static String driverIdPhoto(String uid) => 'driver_id_photos/$uid/id.jpg';
  static String fleetSelfie(String uid) => 'fleet_selfies/$uid/selfie.jpg';
  static String fleetIdPhoto(String uid) => 'fleet_id_photos/$uid/id.jpg';
  static String deliveryPhoto(String driverId, String orderId) =>
      'delivery_photos/$driverId/$orderId.jpg';
  static String voiceMessage(String id) => 'voice_messages/$id/voice.aac';
  static String chatAudio(String id) => 'chat_audio/$id/audio.aac';
  static String marketplaceImage(String pid, int idx) =>
      'marketplace/$pid/img_$idx.jpg';
  static String ekbineProof(String orderId) =>
      'ekbine_proofs/$orderId/proof.jpg';
}
