class EmailVerificationResendGuard {
  EmailVerificationResendGuard({this.cooldown = const Duration(minutes: 1)});

  final Duration cooldown;
  DateTime? _lastSentAt;

  Duration remaining([DateTime? now]) {
    final sentAt = _lastSentAt;
    if (sentAt == null) return Duration.zero;
    final elapsed = (now ?? DateTime.now()).difference(sentAt);
    if (elapsed >= cooldown) return Duration.zero;
    return cooldown - elapsed;
  }

  bool canSend([DateTime? now]) => remaining(now) == Duration.zero;

  void markSent([DateTime? now]) {
    _lastSentAt = now ?? DateTime.now();
  }
}
