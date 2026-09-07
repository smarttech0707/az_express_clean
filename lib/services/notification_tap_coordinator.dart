import 'package:flutter/foundation.dart';

typedef NotificationTapHandler = void Function(
  String type,
  String? orderId,
  String? status,
);

@immutable
class NotificationTap {
  const NotificationTap({
    required this.type,
    this.orderId,
    this.status,
    this.dedupeKey,
  });

  final String type;
  final String? orderId;
  final String? status;
  final String? dedupeKey;
}

/// Conserve un tap FCM jusqu'à ce que le dashboard du bon rôle soit prêt.
///
/// Cette classe ne connaît ni Firebase ni Navigator : elle reste donc
/// testable sans plugin natif. Les contrôles d'authentification et de rôle
/// demeurent assurés par le flux qui construit le dashboard concerné.
class NotificationTapCoordinator {
  NotificationTapCoordinator({required Set<String> supportedTypes})
      : _supportedTypes = Set.unmodifiable(supportedTypes);

  static const _maxHandledKeys = 50;

  final Set<String> _supportedTypes;
  final Set<String> _handledKeys = <String>{};

  NotificationTapHandler? _handler;
  Set<String> _acceptedTypes = const <String>{};
  NotificationTap? _pendingTap;

  @visibleForTesting
  NotificationTap? get pendingTap => _pendingTap;

  void registerHandler(
    NotificationTapHandler handler, {
    required Set<String> acceptedTypes,
  }) {
    _handler = handler;
    _acceptedTypes = Set.unmodifiable(acceptedTypes);
    _deliverPendingIfPossible();
  }

  void unregisterHandler() {
    _handler = null;
    _acceptedTypes = const <String>{};
  }

  void receive(NotificationTap tap) {
    if (!_supportedTypes.contains(tap.type) || _wasHandled(tap.dedupeKey)) {
      return;
    }
    if (_pendingTap?.dedupeKey != null &&
        _pendingTap!.dedupeKey == tap.dedupeKey) {
      return;
    }
    if (_canDeliver(tap)) {
      _deliver(tap);
      return;
    }
    _pendingTap = tap;
  }

  bool _canDeliver(NotificationTap tap) =>
      _handler != null && _acceptedTypes.contains(tap.type);

  void _deliverPendingIfPossible() {
    final pending = _pendingTap;
    if (pending == null || !_canDeliver(pending)) return;
    _pendingTap = null;
    _deliver(pending);
  }

  void _deliver(NotificationTap tap) {
    final key = tap.dedupeKey;
    if (key != null) {
      _handledKeys.add(key);
      if (_handledKeys.length > _maxHandledKeys) {
        _handledKeys.remove(_handledKeys.first);
      }
    }
    _handler?.call(tap.type, tap.orderId, tap.status);
  }

  bool _wasHandled(String? key) => key != null && _handledKeys.contains(key);
}
