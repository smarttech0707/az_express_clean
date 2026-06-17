import 'package:cloud_firestore/cloud_firestore.dart';

class EkAgent {
  final String id;       // Firebase Auth uid
  final String name;
  final String phone;
  final String? photoUrl;
  final String city;
  final List<String> operators; // supported operators
  final Map<String, String> operatorNumbers; // {operator_id: momo_phone}
  final bool isOnline;
  final bool isVerified;
  final bool isSuspended;
  final int walletBalance;
  final int totalCompleted;
  final double rating;
  final int ratingCount;
  final DateTime? createdAt;

  const EkAgent({
    required this.id,
    required this.name,
    required this.phone,
    this.photoUrl,
    this.city = 'Abengourou',
    this.operators = const [],
    this.operatorNumbers = const {},
    this.isOnline = false,
    this.isVerified = false,
    this.isSuspended = false,
    this.walletBalance = 0,
    this.totalCompleted = 0,
    this.rating = 0.0,
    this.ratingCount = 0,
    this.createdAt,
  });

  factory EkAgent.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return EkAgent(
      id:             doc.id,
      name:           d['name'] ?? '',
      phone:          d['phone'] ?? '',
      photoUrl:       d['photoUrl'] as String?,
      city:           d['city'] ?? 'Abengourou',
      operators:      List<String>.from(d['operators'] ?? []),
      operatorNumbers: Map<String, String>.from(d['operatorNumbers'] ?? {}),
      isOnline:       d['isOnline'] == true,
      isVerified:     d['isVerified'] == true,
      isSuspended:    d['isSuspended'] == true,
      walletBalance:  (d['walletBalance'] as num? ?? 0).toInt(),
      totalCompleted: (d['totalCompleted'] as num? ?? 0).toInt(),
      rating:         (d['rating'] as num? ?? 0).toDouble(),
      ratingCount:    (d['ratingCount'] as num? ?? 0).toInt(),
      createdAt:      (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
    'name':           name,
    'phone':          phone,
    'photoUrl':       photoUrl,
    'city':           city,
    'operators':        operators,
    'operatorNumbers':  operatorNumbers,
    'isOnline':         isOnline,
    'isVerified':     isVerified,
    'isSuspended':    isSuspended,
    'walletBalance':  walletBalance,
    'totalCompleted': totalCompleted,
    'rating':         rating,
    'ratingCount':    ratingCount,
    'createdAt':      FieldValue.serverTimestamp(),
  };

  String get displayRating =>
      ratingCount == 0 ? 'Nouveau' : rating.toStringAsFixed(1);
}
