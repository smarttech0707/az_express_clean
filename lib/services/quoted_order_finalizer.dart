import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/order_model.dart';
import 'firestore_service.dart';

/// Après `createOrderFromQuoteCF` : relit la commande créée par le serveur et
/// lance la recherche de livreur (comme `DeliveryOrderService.submit`, chemin
/// wallet : la commande existe déjà, seul le dispatch reste).
///
/// Le dispatch n'est lancé que si la commande est encore `pending` sans
/// livreur : sur un rejeu (réponse perdue), la première tentative a pu déjà
/// attribuer un livreur ; on ne relance rien dans ce cas.
class QuotedOrderFinalizer {
  QuotedOrderFinalizer({
    Future<OrderModel?> Function(String orderId)? loader,
    Future<void> Function(OrderModel order)? dispatcher,
  })  : _loader = loader ?? _defaultLoader,
        _dispatcher = dispatcher ??
            ((o) => FirestoreService().createOrder(o, alreadyCreated: true));

  final Future<OrderModel?> Function(String) _loader;
  final Future<void> Function(OrderModel) _dispatcher;

  static Future<OrderModel?> _defaultLoader(String orderId) async {
    final snap =
        await FirebaseFirestore.instance.collection('orders').doc(orderId).get();
    final data = snap.data();
    return data == null ? null : OrderModel.fromMap(snap.id, data);
  }

  Future<OrderModel?> finalize(String orderId) async {
    final order = await _loader(orderId);
    if (order == null) return null;
    if (order.status == 'pending' && (order.driverId ?? '').isEmpty) {
      await _dispatcher(order);
    }
    return order;
  }
}
