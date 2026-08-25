import 'package:cloud_firestore/cloud_firestore.dart';

class EkOrder {
  final String id;
  final String clientId;
  final String clientName;
  final String clientPhone;
  final String? agentId;
  final String? agentName;
  final String? agentPhone;
  final String?
      agentMomoNumber; // agent's MoMo number for this order's operator
  final String? agentDepositNumber;
  final String? agentDepositOperator;
  final String? agentDepositAccountId;
  final String operator; // orange / mtn / moov / wave
  final String
      serviceId; // credit / mix / internet / transfer / momo_deposit / momo_withdrawal
  final String serviceLabel;
  final String beneficiaryNumber;
  final int amount; // montant du service (FCFA)
  final int fee; // frais de service
  final int totalPaid; // amount + fee
  final int commissionAZ; // 25% des frais
  final int agentEarning; // 75% des frais
  final String paymentMethod; // wallet / orange_money / mtn_momo / wave
  final String
      status; // pending / assigned / awaiting_deposit / in_progress / proof_sent / completed / cancelled / disputed
  final String? proofUrl; // URL preuve de service (agent)
  final String? depositProofUrl; // URL preuve de dépôt (client)
  final String? transactionReference;
  final String? depositRejectionReason;
  final String? message;
  final String? cancellationReason;
  final DateTime? createdAt;
  final DateTime? assignedAt;
  final DateTime? completedAt;

  const EkOrder({
    required this.id,
    required this.clientId,
    required this.clientName,
    required this.clientPhone,
    this.agentId,
    this.agentName,
    this.agentPhone,
    this.agentMomoNumber,
    this.agentDepositNumber,
    this.agentDepositOperator,
    this.agentDepositAccountId,
    required this.operator,
    required this.serviceId,
    required this.serviceLabel,
    required this.beneficiaryNumber,
    required this.amount,
    required this.fee,
    required this.totalPaid,
    required this.commissionAZ,
    required this.agentEarning,
    required this.paymentMethod,
    this.status = 'pending',
    this.proofUrl,
    this.depositProofUrl,
    this.transactionReference,
    this.depositRejectionReason,
    this.message,
    this.cancellationReason,
    this.createdAt,
    this.assignedAt,
    this.completedAt,
  });

  factory EkOrder.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return EkOrder(
      id: doc.id,
      clientId: d['clientId'] ?? '',
      clientName: d['clientName'] ?? '',
      clientPhone: d['clientPhone'] ?? '',
      agentId: d['agentId'] as String?,
      agentName: d['agentName'] as String?,
      agentPhone: d['agentPhone'] as String?,
      agentMomoNumber: d['agentMomoNumber'] as String?,
      agentDepositNumber: d['agentDepositNumber'] as String?,
      agentDepositOperator: d['agentDepositOperator'] as String?,
      agentDepositAccountId: d['agentDepositAccountId'] as String?,
      operator: d['operator'] ?? '',
      serviceId: d['serviceId'] ?? '',
      serviceLabel: d['serviceLabel'] ?? '',
      beneficiaryNumber: d['beneficiaryNumber'] ?? '',
      amount: (d['amount'] as num? ?? 0).toInt(),
      fee: (d['fee'] as num? ?? 0).toInt(),
      totalPaid: (d['totalPaid'] as num? ?? 0).toInt(),
      commissionAZ: (d['commissionAZ'] as num? ?? 0).toInt(),
      agentEarning: (d['agentEarning'] as num? ?? 0).toInt(),
      paymentMethod: d['paymentMethod'] ?? 'wallet',
      status: d['status'] ?? 'pending',
      proofUrl: d['proofUrl'] as String?,
      depositProofUrl: d['depositProofUrl'] as String?,
      transactionReference: d['transactionReference'] as String?,
      depositRejectionReason: d['depositRejectionReason'] as String?,
      message: d['message'] as String?,
      cancellationReason: d['cancellationReason'] as String?,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      assignedAt: (d['assignedAt'] as Timestamp?)?.toDate(),
      completedAt: (d['completedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
        'clientId': clientId,
        'clientName': clientName,
        'clientPhone': clientPhone,
        'agentId': agentId,
        'agentName': agentName,
        'agentPhone': agentPhone,
        'agentMomoNumber': agentMomoNumber,
        'agentDepositNumber': agentDepositNumber,
        'agentDepositOperator': agentDepositOperator,
        'agentDepositAccountId': agentDepositAccountId,
        'operator': operator,
        'serviceId': serviceId,
        'serviceLabel': serviceLabel,
        'beneficiaryNumber': beneficiaryNumber,
        'amount': amount,
        'fee': fee,
        'totalPaid': totalPaid,
        'commissionAZ': commissionAZ,
        'agentEarning': agentEarning,
        'paymentMethod': paymentMethod,
        'status': status,
        'proofUrl': proofUrl,
        'depositProofUrl': depositProofUrl,
        'transactionReference': transactionReference,
        'depositRejectionReason': depositRejectionReason,
        'message': message,
        'cancellationReason': cancellationReason,
        'createdAt': FieldValue.serverTimestamp(),
        'assignedAt':
            assignedAt != null ? Timestamp.fromDate(assignedAt!) : null,
        'completedAt':
            completedAt != null ? Timestamp.fromDate(completedAt!) : null,
      };
}
