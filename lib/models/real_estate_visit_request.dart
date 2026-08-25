import 'package:cloud_firestore/cloud_firestore.dart';

class RealEstateVisitRequest {
  final String id;
  final String listingId;
  final String? listingTitle;
  final String clientId;
  final String agentId;
  final String? preferredDate;
  final String? proposedDate;
  final String? message;
  final String status; // pending | proposed | confirmed | declined | cancelled
  final DateTime? createdAt;

  const RealEstateVisitRequest({
    required this.id,
    required this.listingId,
    this.listingTitle,
    required this.clientId,
    required this.agentId,
    this.preferredDate,
    this.proposedDate,
    this.message,
    this.status = 'pending',
    this.createdAt,
  });

  factory RealEstateVisitRequest.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return RealEstateVisitRequest(
      id: doc.id,
      listingId: d['listingId'] as String? ?? '',
      listingTitle: d['listingTitle'] as String?,
      clientId: d['clientId'] as String? ?? '',
      agentId: d['agentId'] as String? ?? '',
      preferredDate: d['preferredDate'] as String?,
      proposedDate: d['proposedDate'] as String?,
      message: d['message'] as String?,
      status: d['status'] as String? ?? 'pending',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
