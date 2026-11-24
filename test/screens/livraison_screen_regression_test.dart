import 'package:az_express/models/order_model.dart';
import 'package:az_express/screens/client/livraison_screen.dart';
import 'package:flutter_test/flutter_test.dart';

OrderModel orderWithShoppingBudget(int shoppingBudget) => OrderModel(
      id: 'order-test',
      description: 'Test',
      budget: 1500,
      shoppingBudget: shoppingBudget,
      status: 'pending',
      type: 'livraison',
      latitude: 6.72,
      longitude: -3.49,
    );

void main() {
  group('cashOnDeliveryEnabled', () {
    test('désactive cash et quitte la sélection cash quand il vaut false', () {
      final enabled = livraisonCashOnDeliveryEnabled(false);

      expect(enabled, isFalse);
      expect(
        livraisonPaymentAfterCodUpdate(
          currentPayment: 'cash',
          cashOnDeliveryEnabled: enabled,
        ),
        'wallet',
      );
    });

    test('laisse cash disponible quand il vaut true', () {
      final enabled = livraisonCashOnDeliveryEnabled(true);

      expect(enabled, isTrue);
      expect(
        livraisonPaymentAfterCodUpdate(
          currentPayment: 'cash',
          cashOnDeliveryEnabled: enabled,
        ),
        'cash',
      );
    });

    test('un champ absent conserve le défaut historique true', () {
      expect(livraisonCashOnDeliveryEnabled(null), isTrue);
    });
  });

  group('budget achat', () {
    test('une commande avec budget positif le sérialise réellement', () {
      final order = orderWithShoppingBudget(
        parseLivraisonShoppingBudget('2500'),
      );

      expect(order.toMap()['shoppingBudget'], 2500);
      expect(order.totalAmount, 4000);
    });

    test('totalAmount reste égal aux frais sans budget achat', () {
      final order = orderWithShoppingBudget(
        parseLivraisonShoppingBudget(''),
      );

      expect(order.toMap()['shoppingBudget'], 0);
      expect(order.totalAmount, order.budget);
      expect(order.totalAmount, 1500);
    });

    test('reprend la borne de validation de CreateOrderScreen', () {
      expect(parseLivraisonShoppingBudget('-10'), 0);
      expect(parseLivraisonShoppingBudget('99999999'), 9999999);
      expect(parseLivraisonShoppingBudget('invalide'), 0);
    });
  });

  test('la commande sérialise tout le contexte géographique', () {
    final order = OrderModel(
      id: 'geo-order',
      description: 'Test géographique',
      budget: 1500,
      status: 'pending',
      latitude: 6.72,
      longitude: -3.49,
      type: 'livraison',
      pickupCityId: 'abengourou',
      deliveryCityId: 'abengourou',
      pickupZoneId: 'quartier-gabriel',
      deliveryZoneId: 'quartier-commerce',
      pickupCoordinateSource: 'gps',
      deliveryCoordinateSource: 'local_place',
      gpsDetectedCityId: 'abengourou',
      activeCityId: 'abengourou',
      citySelectionSource: 'manual_override',
      cityResolutionStatus: 'border',
    );

    final map = order.toMap();
    expect(map['pickupCityId'], 'abengourou');
    expect(map['deliveryCityId'], 'abengourou');
    expect(map['pickupZoneId'], 'quartier-gabriel');
    expect(map['deliveryZoneId'], 'quartier-commerce');
    expect(map['pickupCoordinateSource'], 'gps');
    expect(map['deliveryCoordinateSource'], 'local_place');
    expect(map['gpsDetectedCityId'], 'abengourou');
    expect(map['activeCityId'], 'abengourou');
    expect(map['citySelectionSource'], 'manual_override');
    expect(map['cityResolutionStatus'], 'border');

    final restored = OrderModel.fromMap('geo-order', map);
    expect(restored.pickupZoneId, 'quartier-gabriel');
    expect(restored.deliveryZoneId, 'quartier-commerce');
    expect(restored.pickupCoordinateSource, 'gps');
    expect(restored.deliveryCoordinateSource, 'local_place');
    expect(restored.citySelectionSource, 'manual_override');
    expect(restored.cityResolutionStatus, 'border');
  });

  test('les sources réelles de LivraisonScreen sont mappées sans deviner', () {
    expect(livraisonOrderCoordinateSource('gps'), 'gps');
    expect(livraisonOrderCoordinateSource('map'), 'map_pin');
    expect(livraisonOrderCoordinateSource('firestore'), 'local_place');
    expect(livraisonOrderCoordinateSource('osm'), 'nominatim');
    expect(livraisonOrderCoordinateSource('google'), 'google');
    expect(livraisonOrderCoordinateSource('inconnue'), isNull);
  });
}
