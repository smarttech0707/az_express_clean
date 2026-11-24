import 'package:cloud_firestore/cloud_firestore.dart';

enum TxStatus { pending, completed, failed, cancelled, error }

class FeexPayTransaction {
  final String id;
  final String userId;
  final String userType;
  final int amount;
  final TxStatus status;
  final String paymentMethod;
  final String provider;
  final String? phone;
  final DateTime createdAt;
  final DateTime? validatedAt;
  final bool credited;
  final String? feexpayToken;
  final String? feexpayUrl;

  const FeexPayTransaction({
    required this.id,
    required this.userId,
    required this.userType,
    required this.amount,
    required this.status,
    required this.paymentMethod,
    required this.provider,
    this.phone,
    required this.createdAt,
    this.validatedAt,
    required this.credited,
    this.feexpayToken,
    this.feexpayUrl,
  });

  factory FeexPayTransaction.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return FeexPayTransaction(
      id: doc.id,
      userId: d['userId'] ?? '',
      userType: d['userType'] ?? 'client',
      amount: (d['amount'] as num?)?.toInt() ?? 0,
      status: _parseStatus(d['status']),
      paymentMethod: d['paymentMethod'] ?? '',
      provider: d['provider'] ?? 'FeexPay',
      phone: d['phone'],
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      validatedAt: (d['validatedAt'] as Timestamp?)?.toDate(),
      credited: d['credited'] ?? false,
      feexpayToken: d['feexpayToken'],
      feexpayUrl: d['feexpayUrl'],
    );
  }

  static TxStatus _parseStatus(String? s) {
    switch (s) {
      case 'completed':
        return TxStatus.completed;
      case 'failed':
        return TxStatus.failed;
      case 'cancelled':
        return TxStatus.cancelled;
      case 'error':
        return TxStatus.error;
      default:
        return TxStatus.pending;
    }
  }

  bool get isCompleted => status == TxStatus.completed;
  bool get isPending => status == TxStatus.pending;
  bool get isFailed => status == TxStatus.failed || status == TxStatus.error;
  bool get isCancelled => status == TxStatus.cancelled;
}
