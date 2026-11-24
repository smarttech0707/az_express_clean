class DeclineOrderResult {
  final bool replay;
  final bool recoveryPending;
  const DeclineOrderResult({this.replay = false, this.recoveryPending = false});

  factory DeclineOrderResult.fromData(dynamic data) {
    if (data is! Map || data['success'] != true || data['replay'] is! bool ||
        (data.containsKey('recoveryPending') && data['recoveryPending'] is! bool)) {
      throw const FormatException('R?ponse de refus invalide');
    }
    return DeclineOrderResult(replay: data['replay'] as bool,
      recoveryPending: data['recoveryPending'] == true);
  }
}
