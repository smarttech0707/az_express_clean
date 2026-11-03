import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'delivery_quote_service.dart';

/// Tentative de création dont le résultat est INCONNU (réponse réseau perdue,
/// application fermée en plein appel). Conservée par compte pour qu'une
/// réouverture de l'écran ou de l'application vérifie d'abord le même devis
/// (rejeu idempotent côté serveur) au lieu d'en créer un second.
class PendingQuote {
  const PendingQuote({
    required this.uid,
    required this.quote,
    required this.paymentMethod,
    this.shoppingBudget = 0,
    this.orderFields = const {},
  });

  final String uid;
  final DeliveryQuote quote;
  final String paymentMethod;
  final int shoppingBudget;
  final Map<String, dynamic> orderFields;

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'quoteId': quote.quoteId,
        'amount': quote.amount,
        'expiresAtMs': quote.expiresAt.millisecondsSinceEpoch,
        'tariffVersion': quote.tariffVersion,
        'isNight': quote.isNight,
        'request': quote.request.toStorage(),
        'paymentMethod': paymentMethod,
        'shoppingBudget': shoppingBudget,
        'orderFields': orderFields,
      };

  static PendingQuote? fromJson(Map<String, dynamic> j) {
    try {
      return PendingQuote(
        uid: j['uid'] as String,
        quote: DeliveryQuote(
          quoteId: j['quoteId'] as String,
          amount: (j['amount'] as num).toInt(),
          expiresAt: DateTime.fromMillisecondsSinceEpoch(
              (j['expiresAtMs'] as num).toInt(),
              isUtc: true),
          request: QuoteRequest.fromStorage(
              (j['request'] as Map).cast<String, dynamic>()),
          tariffVersion: (j['tariffVersion'] as num?)?.toInt(),
          isNight: j['isNight'] == true,
        ),
        paymentMethod: j['paymentMethod'] as String,
        shoppingBudget: (j['shoppingBudget'] as num?)?.toInt() ?? 0,
        orderFields:
            (j['orderFields'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
    } catch (_) {
      return null; // enregistrement illisible : traité comme absent
    }
  }
}

abstract class PendingQuoteStore {
  Future<PendingQuote?> load(String uid);
  Future<void> save(PendingQuote pending);
  Future<void> clear(String uid);
}

/// Une entrée par compte (clé `pending_quote_<uid>`) : un changement de compte
/// ne mélange jamais les tentatives, et ne peut pas les rejouer (le serveur
/// refuse de toute façon le devis d'un autre client).
class SharedPrefsPendingQuoteStore implements PendingQuoteStore {
  static String _key(String uid) => 'pending_quote_$uid';

  @override
  Future<PendingQuote?> load(String uid) async {
    final raw = (await SharedPreferences.getInstance()).getString(_key(uid));
    if (raw == null) return null;
    try {
      final p = PendingQuote.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>());
      return p != null && p.uid == uid ? p : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(PendingQuote pending) async => (await SharedPreferences
          .getInstance())
      .setString(_key(pending.uid), jsonEncode(pending.toJson()));

  @override
  Future<void> clear(String uid) async =>
      (await SharedPreferences.getInstance()).remove(_key(uid));
}

class MemoryPendingQuoteStore implements PendingQuoteStore {
  final Map<String, PendingQuote> data = {};
  @override
  Future<PendingQuote?> load(String uid) async => data[uid];
  @override
  Future<void> save(PendingQuote pending) async => data[pending.uid] = pending;
  @override
  Future<void> clear(String uid) async => data.remove(uid);
}
