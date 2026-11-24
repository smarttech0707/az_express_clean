import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Keeps an unacknowledged attempt across timeouts and checkout recreation.
/// Only a successful server response retires its key. No prices are stored.
class EventReservationAttempts {
  static final Map<String, Future<String>> _inFlight = {};

  Future<String> submit({
    required String uid,
    required Map<String, dynamic> payload,
    required Future<String> Function(Map<String, dynamic>) send,
  }) {
    // Snapshot before the first await: later cart edits cannot alter this request.
    final encoded = jsonEncode(payload);
    final snapshot = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
    final digest = sha256.convert(utf8.encode(jsonEncode([uid, encoded])));
    final storageKey = 'event_reservation_attempt_v1_$digest';
    final pending = _inFlight[storageKey];
    if (pending != null) return pending;

    final operation = _send(storageKey, snapshot, send);
    _inFlight[storageKey] = operation;
    return operation;
  }

  Future<String> _send(
    String storageKey,
    Map<String, dynamic> payload,
    Future<String> Function(Map<String, dynamic>) send,
  ) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      var attemptId = preferences.getString(storageKey);
      if (attemptId == null) {
        attemptId = const Uuid().v4();
        if (!await preferences.setString(storageKey, attemptId)) {
          throw StateError(
              'Impossible de sauvegarder la tentative de réservation');
        }
      }
      final result = await send({...payload, 'attemptId': attemptId});
      // A local cleanup failure must not turn a committed reservation into an
      // apparent payment failure. Keeping the receipt key is conservative.
      try {
        await preferences.remove(storageKey);
      } catch (_) {
        // The next identical request will recover the existing server result.
      }
      return result;
    } finally {
      _inFlight.remove(storageKey);
    }
  }
}
