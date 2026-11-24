import 'package:cloud_firestore/cloud_firestore.dart';

class RealEstateAgent {
  final String uid;
  final String name;
  final String phone;
  final String? agencyName;
  final String? city;
  final String? photoUrl;
  final bool isVerified;
  final bool isActive;
  final DateTime? createdAt;

  const RealEstateAgent({
    required this.uid,
    required this.name,
    required this.phone,
    this.agencyName,
    this.city,
    this.photoUrl,
    this.isVerified = false,
    this.isActive = false,
    this.createdAt,
  });

  factory RealEstateAgent.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return RealEstateAgent(
      uid: doc.id,
      name: d['name'] as String? ?? '',
      phone: d['phone'] as String? ?? '',
      agencyName: d['agencyName'] as String?,
      city: d['city'] as String?,
      photoUrl: d['photoUrl'] as String?,
      isVerified: d['isVerified'] == true,
      isActive: d['isActive'] == true,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
