import 'package:flutter/material.dart';

class AppText {
  final Locale locale;
  const AppText(this.locale);

  static const supportedLocales = [Locale('fr'), Locale('en')];

  static const Map<String, Map<String, String>> _v = {
    'fr': {
      // ── APP ────────────────────────────────────────────────
      'appTitle': 'AZ EXPRESS',
      'language': 'Langue',

      // ── HOME SCREEN ─────────────────────────────────────────
      'welcome': 'Bienvenue sur AZ Express',
      'abengourou': 'Abengourou & environs',
      'order': 'Commander',
      'fast_delivery': 'Livraison rapide à Abengourou',
      'driver': 'Livreur',
      'driver_space': 'Espace livreur AZ Express',
      'fleet_owner': 'Patron de flotte',
      'manage_fleet': 'Gérez vos livreurs et vos gains',

      // ── MAIN DASHBOARD ──────────────────────────────────────
      'order_btn': 'Commander',
      'home': 'Accueil',
      'tracking': 'Suivi',
      'messages': 'Messages',
      'profile': 'Profil',

      // ── CLIENT MAP ──────────────────────────────────────────
      'hello': 'Bonjour',
      'where_send': 'Où voulez-vous envoyer ?',
      'drivers_available': 'livreur(s) disponible(s)',
      'no_driver': 'Aucun livreur',
      'more_services': 'Plus de services',
      'boulangerie': 'Boulangerie & Café',
      'boulangerie_sub': 'Petit-déjeuner & viennoiseries livrés',
      'boutique': 'Boutique',
      'boutique_sub': 'Acheter en ligne, paiement wallet',
      'pharmacy': 'Pharmacie',
      'pharmacy_sub': 'Livraison de médicaments',
      'laundry': 'Blanchisserie',
      'laundry_sub': 'Dépôt et retrait de linge',
      'parcel': 'Colis & Cadeaux',
      'parcel_sub': 'Envoi de colis entre particuliers',
      'water': 'Eau & Boissons',
      'water_sub': 'Livraison de bouteilles',
      'houses': 'Maisons à louer',
      'houses_sub': 'Trouvez un logement à Abengourou',
      'real_estate': 'Immobilier',
      'real_estate_sub': 'Achat, vente et location avec agents vérifiés',
      'local_services': 'Services Locaux',
      'local_services_sub': 'Artisans, immobilier, téléphonie, construction',
      'tricycle': 'Location de tricycle',
      'tricycle_sub': 'Tricycles disponibles à Abengourou',
      'night_taxi': 'Taxi de nuit',
      'night_taxi_sub': 'Taxis disponibles la nuit',
      'furnished': 'Résidences Meublées',
      'furnished_sub': 'Studios, appartements & villas meublées',
      'seller': 'Espace Vendeur',
      'seller_space': 'Gérez vos commandes et livraisons',

      // ── AUTH CLIENT ─────────────────────────────────────────
      'client_space': 'Espace Client',
      'client_tagline': 'Ton wallet, tes commandes, ta boutique',
      'login': 'Connexion',
      'create_account': 'Créer un compte',
      'login_desc': 'Entre ton numéro et ton mot de passe',
      'register_desc': 'Crée ton compte pour accéder à ton wallet',
      'full_name': 'Nom complet',
      'phone_number': 'Numéro de téléphone',
      'phone_hint': 'Ex : 07 00 00 00 00',
      'password': 'Mot de passe',
      'password_hint': 'Minimum 6 caractères',
      'btn_login': 'Se connecter',
      'btn_register': 'Créer mon compte',
      'no_account': 'Pas encore de compte ? ',
      'have_account': 'Déjà un compte ? ',
      'sign_up': "S'inscrire",
      'wallet_hint': 'Ton wallet est lié à ton compte. Recharge et utilise tes crédits pour commander et acheter en boutique.',
      'fill_required': 'Remplis tous les champs obligatoires',
      'enter_name': 'Entre ton nom complet',
      'password_min': 'Le mot de passe doit avoir au moins 6 caractères',
      'account_created': 'Compte créé ! Bienvenue',
      'auth_invalid_cred': 'Numéro ou mot de passe incorrect',
      'auth_already_exists': 'Un compte existe déjà avec ce numéro',
      'auth_too_many': 'Trop de tentatives. Réessaie dans quelques minutes',
      'auth_no_network': 'Pas de connexion internet',

      // ── WALLET ──────────────────────────────────────────────
      'my_wallet': 'Mon Wallet',
      'top_up': 'Recharger',
      'top_up_title': 'Recharger mon wallet',
      'payment_method': 'Méthode de paiement',
      'amount': 'Montant',
      'other_amount': 'Autre',
      'custom_amount': 'Montant personnalisé (FCFA)',
      'instructions': 'Instructions',
      'send_amount': '1. Envoyez {amount} FCFA au numéro :',
      'instructions_steps': '2. Appuyez sur "J\'ai payé" ci-dessous\n3. L\'admin vérifie et crédite votre wallet',
      'paid_btn': "J'ai payé — Notifier l'admin",
      'min_amount': 'Montant minimum : 100 FCFA',
      'request_sent': "Demande envoyée ! L'admin créditera votre wallet après vérification.",
      'no_transactions': 'Aucune transaction',
      'tx_history': 'Historique des transactions',

      // ── BOUTIQUE ────────────────────────────────────────────
      'shop_title': 'Boutique AZ Express',
      'products_tab': 'Produits',
      'my_orders_tab': 'Mes commandes',
      'no_products': 'Aucun produit disponible',
      'out_of_stock': 'Épuisé',
      'in_stock': 'Stock :',
      'per_unit': 'FCFA / unité',
      'insufficient_balance': 'Solde insuffisant',
      'missing_amount': 'Il vous manque {amount} FCFA pour cet achat.',
      'current_balance': 'Solde actuel : {balance} FCFA',
      'order_confirmed': 'Commande confirmée ! Livraison dans les 48h ou remboursement automatique.',
      'auto_refund': 'Remboursement automatique si non livré dans 48h',
      'pay_btn': 'Payer {amount} FCFA',
      'qty_label': 'qté',
      'status_pending': 'En attente',
      'status_preparing': 'En préparation',
      'status_shipping': 'En livraison',
      'status_delivered': 'Livré',
      'status_refunded': 'Remboursé',
      'no_orders': 'Aucune commande',
      'delivery_before': 'Livraison avant : {date}',
      'deadline_exceeded': 'Délai dépassé — remboursement en cours...',
      'stock_label': 'En stock : {n} disponible(s)',
      'out_of_stock_label': 'Rupture de stock',

      // ── PROFIL ──────────────────────────────────────────────
      'my_profile': 'Mon profil',
      'personal_info': 'Informations personnelles',
      'not_provided': 'Non renseigné',
      'save': 'Enregistrer',
      'my_orders': 'Mes commandes',
      'total_orders': 'Total',
      'delivered_orders': 'Livrées',
      'pending_orders': 'En cours',
      'legal_info': 'Légal & Informations',
      'privacy': 'Politique de confidentialité',
      'terms': "Conditions d'utilisation",
      'delivery_policy': 'Politique de livraison',
      'payment_policy': 'Politique de paiement',
      'about': 'À propos de AZ Express',
      'logout': 'Se déconnecter',
      'delete_account': 'Supprimer mon compte',
      'logout_confirm': 'Ton wallet et tes commandes seront sauvegardés. Tu pourras te reconnecter avec ton numéro et ton mot de passe.',
      'delete_confirm': 'Cette action est irréversible. Toutes vos données seront supprimées.',
      'account_deleted': 'Compte supprimé',
      'profile_updated': 'Profil mis à jour',
      'close': 'Fermer',
      'about_app_text': 'AZ Express est une application de livraison rapide disponible à Abengourou et ses environs.\n\nLivraison de courses, repas, médicaments, colis et bien plus.',
      'copyright': '© 2024 AZ Express — Tous droits réservés',
      'insufficient_stock': 'Stock insuffisant',

      // ── SERVICES HUB ────────────────────────────────────────
      'services_title': 'Services Locaux',
      'services_sub': 'Artisans, Immobilier, Commerce — Abengourou',
      'ekbine_sub': 'Crédit, internet & Mobile Money',

      // catégories
      'cat_real_estate': 'Immobilier',
      'cat_artisans':    'Artisans',
      'cat_mecanique':   'Mécanique Auto & Moto',
      'cat_construction':'Eau & Construction',
      'cat_telephonie':  'Téléphonie',
      'cat_cave':        'Cave & Boissons',

      // sous-catégories artisans
      'sub_location':    'Location de maison',
      'sub_vente':       'Vente de maison',
      'sub_local':       'Local commercial',
      'sub_terrain':     'Terrain',
      'sub_macon':       'Maçon',
      'sub_plombier':    'Plombier',
      'sub_electricien': 'Électricien',
      'sub_ferronnier':  'Ferronnier',
      'sub_menuisier':   'Menuisier',
      'sub_carreleur':   'Carreleur',
      'sub_peintre':     'Peintre',
      'sub_vitrier':     'Vitrier',
      'sub_reparateur_tv': 'Réparateur TV / Électronique',
      'sub_camera':      'Installation caméra & alarme',
      'sub_decoration':  'Décoration intérieure',
      'sub_reparateur':       'Réparateur portable',
      'sub_salon_homme':      'Salon de coiffure homme',
      'sub_barber_shop':      'Barber Shop',
      'sub_salon_femme':      'Salon de coiffure femme',
      'sub_onglerie':         'Onglerie',

      // sous-catégories mécanique
      'sub_meca_voiture': 'Mécanicien voiture',
      'sub_meca_moto':    'Mécanicien moto',
      'sub_elec_auto':    'Électricien automobile',
      'sub_carrosserie':  'Carrossier & peinture auto',

      // construction
      'sub_eau':         'Eau en pack',
      'sub_ciment':      'Ciment & Briques',

      // téléphonie
      'sub_telephone':   'Téléphones portables',
      'sub_accessoires': 'Accessoires',

      // cave
      'sub_cave_vins':       'Vins & Spiritueux',
      'sub_cave_bieres':     'Bières',
      'sub_cave_sans_alcool':'Boissons sans alcool',
      'cave':     'Cave & Boissons',
      'cave_sub': 'Vins, bières, jus et sodas',

      // ── SERVICE PROVIDERS ───────────────────────────────────
      'providers_in': 'Prestataires disponibles à Abengourou',
      'search_provider': 'Rechercher un prestataire…',
      'no_provider': 'Aucun prestataire disponible',
      'come_back': 'Revenez bientôt !',
      'verified_provider': 'Prestataire vérifié',
      'call': 'Appeler',
      'get_directions': "S'y rendre",
      'gps_maps': 'GPS Google Maps',
      'gps_unavailable': 'Position GPS non disponible',
      'about_provider': 'À propos',

      // ── SIMPLE SERVICE ──────────────────────────────────────
      'available_in': 'Disponibles à Abengourou',

      // ── LOCATIONS ───────────────────────────────────────────
      'houses_title': 'Maisons à louer',
      'find_home': 'Trouvez votre logement à Abengourou',
      'search_house': 'Chercher un quartier, une maison…',
      'no_house': 'Aucune maison disponible',
      'see_details': 'Voir les détails',
      'contact_visit': 'Contactez AZ Express pour visiter',
      'contact_owner': 'Nous vous mettons en contact avec le propriétaire',
      'rooms_label': 'pièce',
      'per_month': '/mois',

      // ── RÉSIDENCES MEUBLÉES ──────────────────────────────────
      'furnished_title': 'Résidences Meublées',
      'find_residence': 'Studios, appartements & villas à Abengourou',
      'search_residence': 'Chercher une résidence, un quartier…',
      'no_residence': 'Aucune résidence disponible',
      'per_night': '/nuit',
      'amenities': 'Équipements',
      'all_types': 'Tous',
      'contact_residence': 'Appeler pour réserver',
      'contact_residence_sub': 'Contactez directement le gérant',

      // ── COMMUN ──────────────────────────────────────────────
      'cancel': 'Annuler',
      'delete': 'Supprimer',
      'error': 'Erreur',
      'sending': 'Envoi...',
      'conn_required': 'Connexion requise',
      'no_result_for': 'Aucun résultat pour',
      'newOrder': 'Nouvelle commande',
      'userProfile': 'Profil utilisateur',
      'name': 'Nom',
      'phone': 'Téléphone',
      'description': 'Description',
      'listenVoice': 'Écouter message vocal',
      'calcDistancePrice': 'Calculer distance et prix',
      'sendOrder': 'Envoyer la commande',
      'myOrders': 'Mes commandes',
      'map': 'Carte',
      'chooseDestination': 'Choisissez une destination sur la carte',
      'fillAllFields': 'Remplissez tous les champs',
      'calcDistanceFirst': 'Calculez la distance',
      'orderSent': 'Commande envoyée',
      'distance': 'Distance',
      'price': 'Prix',
      'serviceType': 'Type de service',
      'restaurant': 'Restaurant',
      'shopping': 'Courses',
    },

    'en': {
      // ── APP ────────────────────────────────────────────────
      'appTitle': 'AZ EXPRESS',
      'language': 'Language',

      // ── HOME SCREEN ─────────────────────────────────────────
      'welcome': 'Welcome to AZ Express',
      'abengourou': 'Abengourou & surroundings',
      'order': 'Order',
      'fast_delivery': 'Fast delivery in Abengourou',
      'driver': 'Driver',
      'driver_space': 'AZ Express Driver Space',
      'fleet_owner': 'Fleet Owner',
      'manage_fleet': 'Manage your drivers and earnings',

      // ── MAIN DASHBOARD ──────────────────────────────────────
      'order_btn': 'Order',
      'home': 'Home',
      'tracking': 'Tracking',
      'messages': 'Messages',
      'profile': 'Profile',

      // ── CLIENT MAP ──────────────────────────────────────────
      'hello': 'Hello',
      'where_send': 'Where do you want to send?',
      'drivers_available': 'driver(s) available',
      'no_driver': 'No driver',
      'more_services': 'More services',
      'boulangerie': 'Bakery & Café',
      'boulangerie_sub': 'Breakfast & pastries delivered',
      'boutique': 'Shop',
      'boutique_sub': 'Buy online, wallet payment',
      'pharmacy': 'Pharmacy',
      'pharmacy_sub': 'Medicine delivery',
      'laundry': 'Laundry',
      'laundry_sub': 'Drop-off and pick-up',
      'parcel': 'Parcels & Gifts',
      'parcel_sub': 'Send parcels between individuals',
      'water': 'Water & Drinks',
      'water_sub': 'Bottle delivery',
      'houses': 'Houses for rent',
      'houses_sub': 'Find accommodation in Abengourou',
      'real_estate': 'Real Estate',
      'real_estate_sub': 'Buy, sell and rent with verified agents',
      'local_services': 'Local Services',
      'local_services_sub': 'Craftsmen, real estate, telephony, construction',
      'tricycle': 'Tricycle rental',
      'tricycle_sub': 'Tricycles available in Abengourou',
      'night_taxi': 'Night taxi',
      'night_taxi_sub': 'Taxis available at night',
      'furnished': 'Furnished Residences',
      'furnished_sub': 'Studios, apartments & furnished villas',
      'seller': 'Seller Space',
      'seller_space': 'Manage your orders and deliveries',

      // ── AUTH CLIENT ─────────────────────────────────────────
      'client_space': 'Client Space',
      'client_tagline': 'Your wallet, your orders, your shop',
      'login': 'Login',
      'create_account': 'Create an account',
      'login_desc': 'Enter your phone number and password',
      'register_desc': 'Create your account to access your wallet',
      'full_name': 'Full name',
      'phone_number': 'Phone number',
      'phone_hint': 'Ex: 07 00 00 00 00',
      'password': 'Password',
      'password_hint': 'Minimum 6 characters',
      'btn_login': 'Log in',
      'btn_register': 'Create my account',
      'no_account': 'No account yet? ',
      'have_account': 'Already have an account? ',
      'sign_up': 'Sign up',
      'wallet_hint': 'Your wallet is linked to your account. Top up and use your credits to order and shop.',
      'fill_required': 'Please fill in all required fields',
      'enter_name': 'Enter your full name',
      'password_min': 'Password must be at least 6 characters',
      'account_created': 'Account created! Welcome',
      'auth_invalid_cred': 'Phone number or password incorrect',
      'auth_already_exists': 'An account already exists with this number',
      'auth_too_many': 'Too many attempts. Please try again in a few minutes',
      'auth_no_network': 'No internet connection',

      // ── WALLET ──────────────────────────────────────────────
      'my_wallet': 'My Wallet',
      'top_up': 'Top Up',
      'top_up_title': 'Top up my wallet',
      'payment_method': 'Payment method',
      'amount': 'Amount',
      'other_amount': 'Other',
      'custom_amount': 'Custom amount (FCFA)',
      'instructions': 'Instructions',
      'send_amount': '1. Send {amount} FCFA to:',
      'instructions_steps': '2. Tap "I paid" below\n3. Admin verifies and credits your wallet',
      'paid_btn': 'I paid — Notify admin',
      'min_amount': 'Minimum amount: 100 FCFA',
      'request_sent': 'Request sent! Admin will credit your wallet after verification.',
      'no_transactions': 'No transactions',
      'tx_history': 'Transaction history',

      // ── BOUTIQUE ────────────────────────────────────────────
      'shop_title': 'AZ Express Shop',
      'products_tab': 'Products',
      'my_orders_tab': 'My orders',
      'no_products': 'No products available',
      'out_of_stock': 'Out of stock',
      'in_stock': 'Stock:',
      'per_unit': 'FCFA / unit',
      'insufficient_balance': 'Insufficient balance',
      'missing_amount': 'You are missing {amount} FCFA for this purchase.',
      'current_balance': 'Current balance: {balance} FCFA',
      'order_confirmed': 'Order confirmed! Delivery within 48h or automatic refund.',
      'auto_refund': 'Automatic refund if not delivered within 48h',
      'pay_btn': 'Pay {amount} FCFA',
      'qty_label': 'qty',
      'status_pending': 'Pending',
      'status_preparing': 'Preparing',
      'status_shipping': 'Shipping',
      'status_delivered': 'Delivered',
      'status_refunded': 'Refunded',
      'no_orders': 'No orders',
      'delivery_before': 'Delivery by: {date}',
      'deadline_exceeded': 'Deadline exceeded — refund in progress...',
      'stock_label': 'In stock: {n} available',
      'out_of_stock_label': 'Out of stock',

      // ── PROFIL ──────────────────────────────────────────────
      'my_profile': 'My Profile',
      'personal_info': 'Personal information',
      'not_provided': 'Not provided',
      'save': 'Save',
      'my_orders': 'My orders',
      'total_orders': 'Total',
      'delivered_orders': 'Delivered',
      'pending_orders': 'In progress',
      'legal_info': 'Legal & Information',
      'privacy': 'Privacy Policy',
      'terms': 'Terms of Use',
      'delivery_policy': 'Delivery Policy',
      'payment_policy': 'Payment Policy',
      'about': 'About AZ Express',
      'logout': 'Log out',
      'delete_account': 'Delete my account',
      'logout_confirm': 'Your wallet and orders will be saved. You can log back in with your phone and password.',
      'delete_confirm': 'This action is irreversible. All your data will be deleted.',
      'account_deleted': 'Account deleted',
      'profile_updated': 'Profile updated',
      'close': 'Close',
      'about_app_text': 'AZ Express is a fast delivery app available in Abengourou and its surroundings.\n\nDelivery of groceries, meals, medicine, parcels and more.',
      'copyright': '© 2024 AZ Express — All rights reserved',
      'insufficient_stock': 'Insufficient stock',

      // ── SERVICES HUB ────────────────────────────────────────
      'services_title': 'Local Services',
      'services_sub': 'Craftsmen, Real Estate, Commerce — Abengourou',
      'ekbine_sub': 'Credit, internet & Mobile Money',

      'cat_real_estate': 'Real Estate',
      'cat_artisans':    'Craftsmen',
      'cat_mecanique':   'Auto & Moto Mechanics',
      'cat_construction':'Water & Construction',
      'cat_telephonie':  'Telephony',
      'cat_cave':        'Bar & Drinks',

      'sub_location':    'House rental',
      'sub_vente':       'House sale',
      'sub_local':       'Commercial space',
      'sub_terrain':     'Land',
      'sub_macon':       'Mason',
      'sub_plombier':    'Plumber',
      'sub_electricien': 'Electrician',
      'sub_ferronnier':  'Ironworker',
      'sub_menuisier':   'Carpenter',
      'sub_carreleur':   'Tiler',
      'sub_peintre':     'Painter',
      'sub_vitrier':     'Glazier',
      'sub_reparateur_tv': 'TV / Electronics repair',
      'sub_camera':      'Camera & alarm installation',
      'sub_decoration':  'Interior decoration',
      'sub_reparateur':       'Phone repair',
      'sub_salon_homme':      'Men\'s Hair Salon',
      'sub_barber_shop':      'Barber Shop',
      'sub_salon_femme':      'Women\'s Hair Salon',
      'sub_onglerie':         'Nail Salon',

      'sub_meca_voiture': 'Car mechanic',
      'sub_meca_moto':    'Motorbike mechanic',
      'sub_elec_auto':    'Auto electrician',
      'sub_carrosserie':  'Body shop & auto paint',

      'sub_eau':         'Bottled water',
      'sub_ciment':      'Cement & Bricks',
      'sub_telephone':   'Mobile phones',
      'sub_accessoires': 'Accessories',
      'sub_cave_vins':       'Wines & Spirits',
      'sub_cave_bieres':     'Beers',
      'sub_cave_sans_alcool':'Non-alcoholic drinks',
      'cave':     'Bar & Drinks',
      'cave_sub': 'Wines, beers, juices and sodas',

      // ── SERVICE PROVIDERS ───────────────────────────────────
      'providers_in': 'Service providers in Abengourou',
      'search_provider': 'Search a provider…',
      'no_provider': 'No provider available',
      'come_back': 'Come back soon!',
      'verified_provider': 'Verified provider',
      'call': 'Call',
      'get_directions': 'Get directions',
      'gps_maps': 'GPS Google Maps',
      'gps_unavailable': 'GPS position unavailable',
      'about_provider': 'About',

      // ── SIMPLE SERVICE ──────────────────────────────────────
      'available_in': 'Available in Abengourou',

      // ── LOCATIONS ───────────────────────────────────────────
      'houses_title': 'Houses for rent',
      'find_home': 'Find your home in Abengourou',
      'search_house': 'Search a neighborhood, a house…',
      'no_house': 'No house available',
      'see_details': 'View details',
      'contact_visit': 'Contact AZ Express to visit',
      'contact_owner': 'We will connect you with the owner',
      'rooms_label': 'room',
      'per_month': '/month',

      // ── FURNISHED RESIDENCES ─────────────────────────────────
      'furnished_title': 'Furnished Residences',
      'find_residence': 'Studios, apartments & villas in Abengourou',
      'search_residence': 'Search a residence, a neighborhood…',
      'no_residence': 'No residence available',
      'per_night': '/night',
      'amenities': 'Amenities',
      'all_types': 'All',
      'contact_residence': 'Call to book',
      'contact_residence_sub': 'Contact the manager directly',

      // ── COMMUN ──────────────────────────────────────────────
      'cancel': 'Cancel',
      'delete': 'Delete',
      'error': 'Error',
      'sending': 'Sending...',
      'conn_required': 'Login required',
      'no_result_for': 'No result for',
      'newOrder': 'New order',
      'userProfile': 'User profile',
      'name': 'Name',
      'phone': 'Phone',
      'description': 'Description',
      'listenVoice': 'Play voice message',
      'calcDistancePrice': 'Calculate distance and price',
      'sendOrder': 'Send order',
      'myOrders': 'My orders',
      'map': 'Map',
      'chooseDestination': 'Pick a destination on the map',
      'fillAllFields': 'Please fill all fields',
      'calcDistanceFirst': 'Please calculate distance first',
      'orderSent': 'Order sent',
      'distance': 'Distance',
      'price': 'Price',
      'serviceType': 'Service type',
      'restaurant': 'Restaurant',
      'shopping': 'Groceries',
    },
  };

  String t(String key) {
    final lang = _v[locale.languageCode] ?? _v['fr']!;
    return lang[key] ?? _v['fr']![key] ?? key;
  }
}

// ── Extension BuildContext pour accès rapide ───────────────────

extension AppTr on BuildContext {
  String tr(String key) {
    try {
      final lang = AppLanguage.of(this);
      return AppText(lang.locale).t(key);
    } catch (_) {
      return const AppText(Locale('fr')).t(key);
    }
  }
}

// ── InheritedWidget langue ─────────────────────────────────────

class AppLanguage extends InheritedWidget {
  final Locale locale;
  final ValueChanged<Locale> onLocaleChanged;

  const AppLanguage({
    super.key,
    required this.locale,
    required this.onLocaleChanged,
    required super.child,
  });

  static AppLanguage of(BuildContext context) {
    final result =
        context.dependOnInheritedWidgetOfExactType<AppLanguage>();
    assert(result != null, 'No AppLanguage found in context');
    return result!;
  }

  @override
  bool updateShouldNotify(AppLanguage old) => old.locale != locale;
}
