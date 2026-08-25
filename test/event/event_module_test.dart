import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/event/event_constants.dart';
import 'package:az_express/event/models/event_models.dart';

void main() {
  group('Catalogue événementiel', () {
    test('contient les quatre familles demandées', () {
      expect(EventCategory.values, hasLength(4));
      expect(eventSubcategories.keys.toSet(), EventCategory.values.toSet());
    });

    test('contient toutes les sous-catégories sans doublon', () {
      final all = eventSubcategories.values.expand((e) => e).toList();
      expect(all, hasLength(48));
      expect(all.toSet(), hasLength(all.length));
      expect(all, containsAll(['Chaises', 'Mariage', 'Buffets', 'DJ']));
      expect(all, contains('Soutenance'));
    });
  });

  group('Réservation multi-prestations', () {
    const chairs = EventOffer(
      id: 'chairs',
      providerId: 'p1',
      ownerId: 'owner1',
      providerName: 'Loc Express',
      title: 'Chaise blanche',
      description: '',
      category: EventCategory.rental,
      subcategory: 'Chaises',
      unitPrice: 250,
      availableQuantity: 500,
      zone: 'Abengourou',
    );
    const dj = EventOffer(
      id: 'dj',
      providerId: 'p2',
      ownerId: 'owner2',
      providerName: 'DJ Events',
      title: 'Pack DJ',
      description: '',
      category: EventCategory.staff,
      subcategory: 'DJ',
      unitPrice: 75000,
      availableQuantity: 1,
      zone: 'Abengourou',
    );

    test('calcule les lignes et conserve un instantané complet', () {
      const item = EventCartItem(offer: chairs, quantity: 200);
      expect(item.total, 50000);
      expect(item.toMap(), containsPair('quantity', 200));
      expect(item.toMap(), containsPair('providerId', 'p1'));
      expect(item.toMap(), containsPair('subcategory', 'Chaises'));
    });

    test('agrège plusieurs prestataires dans une commande', () {
      const items = [
        EventCartItem(offer: chairs, quantity: 200),
        EventCartItem(offer: dj, quantity: 1),
      ];
      final total = items.fold<int>(0, (value, item) => value + item.total);
      expect(total, 125000);
      expect(items.map((e) => e.offer.providerId).toSet(), {'p1', 'p2'});
    });
  });
}
