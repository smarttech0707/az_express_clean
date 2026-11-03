import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/ek_order.dart';
import '../models/ek_agent.dart';
import '../services/ek_service.dart';

class EkProvider extends ChangeNotifier {
  List<EkOrder> _myOrders = [];
  EkAgent? _myAgent;
  bool _loading = false;
  bool _isAgent = false;
  StreamSubscription<List<EkOrder>>? _ordersSub;
  StreamSubscription<EkAgent?>? _agentSub;

  List<EkOrder> get myOrders => _myOrders;
  EkAgent? get myAgent => _myAgent;
  bool get loading => _loading;
  bool get isAgent => _isAgent;

  List<EkOrder> get activeOrders => _myOrders
      .where((o) =>
          o.status != 'completed' &&
          o.status != 'cancelled' &&
          o.status != 'disputed')
      .toList();

  Future<void> init() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _loading = true;
    notifyListeners();

    // Listen to client orders
    _ordersSub?.cancel();
    _ordersSub = EkService.streamClientOrders(uid).listen((list) {
      _myOrders = list;
      _loading = false;
      notifyListeners();
    });

    // Check if user is also an agent
    _agentSub?.cancel();
    _agentSub = EkService.streamAgent(uid).listen((agent) {
      _myAgent = agent;
      _isAgent = agent != null && agent.isVerified && !agent.isSuspended;
      notifyListeners();
    });
  }

  // Tentative en cours : la même clé d'idempotence est réutilisée tant que la commande est identique et que le
  // résultat est inconnu (coupure réseau, délai dépassé) → jamais deux débits pour une seule intention du client.
  String? _pendingKey;
  String? _pendingSignature;

  String _newKey() {
    final r = Random.secure();
    return List.generate(24, (_) => r.nextInt(36).toRadixString(36)).join();
  }

  /// Retourne l'identifiant de la commande, ou un message d'erreur (voir ek_order_form : détection par motif).
  Future<String?> placeOrder({
    required String clientId,
    required String clientName,
    required String clientPhone,
    required String operator,
    required String serviceId,
    required String serviceLabel,
    required String beneficiaryNumber,
    required int amount,
    required String paymentMethod,
  }) async {
    if (_loading) return 'Une commande est déjà en cours d\'envoi';
    _loading = true;
    notifyListeners();

    // Montants, frais et gain de l'agent sont calculés par le serveur : seul l'intention du client est envoyée.
    final signature = '$operator|$serviceId|$beneficiaryNumber|$amount|$paymentMethod';
    if (_pendingSignature != signature || _pendingKey == null) {
      _pendingKey = _newKey();
      _pendingSignature = signature;
    }
    try {
      final result = await EkService.createOrder(
        idempotencyKey: _pendingKey!,
        operator: operator,
        serviceId: serviceId,
        serviceLabel: serviceLabel,
        beneficiaryNumber: beneficiaryNumber,
        amount: amount,
        paymentMethod: paymentMethod,
      );
      // Réponse connue (succès ou refus métier) : la tentative est terminée.
      _pendingKey = null;
      _pendingSignature = null;
      _loading = false;
      notifyListeners();
      return result.success ? result.orderId : result.message;
    } on FirebaseFunctionsException catch (e) {
      _loading = false;
      notifyListeners();
      // Refus définitif du serveur → nouvelle clé au prochain essai ; réseau/délai → on garde la clé.
      if (e.code != 'unavailable' && e.code != 'deadline-exceeded' && e.code != 'internal' && e.code != 'unknown') {
        _pendingKey = null;
        _pendingSignature = null;
        return e.message ?? 'Commande refusée';
      }
      return 'Connexion instable : votre commande n\'a peut-être pas été envoyée. Appuyez à nouveau pour réessayer sans risque de double paiement.';
    } catch (e) {
      _loading = false;
      notifyListeners();
      return 'Connexion instable : appuyez à nouveau pour réessayer sans risque de double paiement.';
    }
  }

  Future<void> toggleAgentOnline() async {
    if (_myAgent == null) return;
    final newStatus = !_myAgent!.isOnline;
    await EkService.updateAgentOnlineStatus(_myAgent!.id, newStatus);
  }

  @override
  void dispose() {
    _ordersSub?.cancel();
    _agentSub?.cancel();
    super.dispose();
  }
}
