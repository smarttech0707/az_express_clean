import 'package:flutter/material.dart';

enum EventCategory {
  rental('Location', Icons.chair_alt_rounded),
  decoration('Décoration', Icons.celebration_rounded),
  catering('Traiteur', Icons.restaurant_menu_rounded),
  staff('Personnel', Icons.groups_rounded);

  const EventCategory(this.label, this.icon);
  final String label;
  final IconData icon;
}

const eventSubcategories = <EventCategory, List<String>>{
  EventCategory.rental: [
    'Chaises',
    'Tables',
    'Bâches',
    'Tentes',
    'Vaisselle',
    'Verrerie',
    'Chambres froides',
    'Glacières',
    'Barbecue',
    'Marmites',
    'Cuisinières',
    'Groupes électrogènes',
    'Sonorisation',
    'Éclairage',
    'Écrans LED',
    'Podiums',
    'Décorations lumineuses',
  ],
  EventCategory.decoration: [
    'Mariage',
    'Anniversaire',
    'Baptême',
    'Funérailles',
    'Soutenance',
    'Conférence',
    'Séminaire',
    "Évènement d'entreprise",
    'Fête traditionnelle',
    'Cérémonie religieuse',
  ],
  EventCategory.catering: [
    'Cuisine africaine',
    'Cuisine européenne',
    'Buffets',
    'Grillades',
    'Cocktail',
    'Boissons',
    'Pâtisserie',
    'Gâteaux',
    'Desserts',
  ],
  EventCategory.staff: [
    'Serveurs',
    'Cuisiniers',
    'Hôtesses',
    'Agents de sécurité',
    'Nettoyage',
    'Maître de cérémonie',
    'DJ',
    'Orchestre',
    'Photographe',
    'Vidéaste',
    'Drone',
    'Animateur',
  ],
};

enum EventPaymentMethod { wallet, cash, future }

extension EventPaymentLabel on EventPaymentMethod {
  String get label => switch (this) {
        EventPaymentMethod.wallet => 'Wallet',
        EventPaymentMethod.cash => 'Cash',
        EventPaymentMethod.future => 'Paiement futur',
      };
}
