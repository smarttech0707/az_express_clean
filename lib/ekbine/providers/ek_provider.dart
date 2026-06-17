import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/ek_order.dart';
import '../models/ek_agent.dart';
import '../services/ek_service.dart';
import '../ek_constants.dart';

class EkProvider extends ChangeNotifier {
  List<EkOrder> _myOrders  = [];
  EkAgent?      _myAgent;
  bool          _loading   = false;
  bool          _isAgent   = false;
  StreamSubscription<List<EkOrder>>? _ordersSub;
  StreamSubscription<EkAgent?>?      _agentSub;

  List<EkOrder> get myOrders => _myOrders;
  EkAgent?      get myAgent  => _myAgent;
  bool get loading           => _loading;
  bool get isAgent           => _isAgent;

  List<EkOrder> get activeOrders =>
      _myOrders.where((o) =>
          o.status != 'completed' &&
          o.status != 'cancelled' &&
          o.status != 'disputed').toList();

  Future<void> init() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _loading = true;
    notifyListeners();

    // Listen to client orders
    _ordersSub?.cancel();
    _ordersSub = EkService.streamClientOrders(uid).listen((list) {
      _myOrders = list;
      _loading  = false;
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
    _loading = true;
    notifyListeners();

    try {
      final fee         = ekCalculateFee(serviceId, amount);
      final totalPaid   = amount + fee;
      final commAZ      = ekAzCommission(fee);
      final agentEarn   = ekAgentEarning(fee);

      // If paying by wallet, debit first
      if (paymentMethod == 'wallet') {
        final ok = await EkService.debitClientWallet(clientId, totalPaid);
        if (!ok) {
          _loading = false;
          notifyListeners();
          return 'Solde insuffisant dans votre wallet';
        }
      }

      final orderId = await EkService.createOrder({
        'clientId':          clientId,
        'clientName':        clientName,
        'clientPhone':       clientPhone,
        'operator':          operator,
        'serviceId':         serviceId,
        'serviceLabel':      serviceLabel,
        'beneficiaryNumber': beneficiaryNumber,
        'amount':            amount,
        'fee':               fee,
        'totalPaid':         totalPaid,
        'commissionAZ':      commAZ,
        'agentEarning':      agentEarn,
        'paymentMethod':     paymentMethod,
        'status':            'pending',
        'createdAt':         FieldValue.serverTimestamp(),
      });

      _loading = false;
      notifyListeners();
      return orderId;
    } catch (e) {
      _loading = false;
      notifyListeners();
      return 'Erreur : $e';
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
