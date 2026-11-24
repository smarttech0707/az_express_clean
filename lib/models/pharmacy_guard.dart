import 'package:cloud_firestore/cloud_firestore.dart';

enum PharmacyGuardPeriod { now, week, month }

class PharmacyGuard {
  const PharmacyGuard({
    required this.id,
    required this.name,
    required this.city,
    required this.guardStartAt,
    required this.guardEndAt,
    required this.sourceType,
    required this.isVerified,
    required this.isActive,
    required this.linkedPartner,
    this.pharmacyId,
    this.externalId,
    this.district,
    this.address,
    this.phone,
    this.latitude,
    this.longitude,
    this.sourceName,
    this.sourceUrl,
    this.partnerPharmacyId,
    this.lastSyncedAt,
  });

  final String id;
  final String? pharmacyId;
  final String? externalId;
  final String name;
  final String city;
  final String? district;
  final String? address;
  final String? phone;
  final double? latitude;
  final double? longitude;
  final DateTime guardStartAt;
  final DateTime guardEndAt;
  final String sourceType;
  final String? sourceName;
  final String? sourceUrl;
  final bool isVerified;
  final bool isActive;
  final bool linkedPartner;
  final String? partnerPharmacyId;
  final DateTime? lastSyncedAt;

  bool isOnDutyAt(DateTime now) =>
      isActive && !guardStartAt.isAfter(now) && guardEndAt.isAfter(now);

  bool isExpiredAt(DateTime now) => !guardEndAt.isAfter(now);

  bool overlaps(DateTime from, DateTime to) =>
      guardStartAt.isBefore(to) && guardEndAt.isAfter(from);

  bool matchesPeriod(PharmacyGuardPeriod period, DateTime now) {
    switch (period) {
      case PharmacyGuardPeriod.now:
        return isOnDutyAt(now);
      case PharmacyGuardPeriod.week:
        final start = DateTime(now.year, now.month, now.day)
            .subtract(Duration(days: now.weekday - DateTime.monday));
        return overlaps(start, start.add(const Duration(days: 7)));
      case PharmacyGuardPeriod.month:
        final start = DateTime(now.year, now.month);
        return overlaps(start, DateTime(now.year, now.month + 1));
    }
  }

  factory PharmacyGuard.fromDocument(
      DocumentSnapshot<Map<String, dynamic>> document) {
    final data = document.data() ?? const <String, dynamic>{};
    return PharmacyGuard.fromMap(document.id, data);
  }

  factory PharmacyGuard.fromMap(String id, Map<String, dynamic> data) {
    DateTime readDate(String key) {
      final value = data[key];
      if (value is Timestamp) return value.toDate().toUtc();
      if (value is DateTime) return value.toUtc();
      throw FormatException('$key doit être un Timestamp');
    }

    DateTime? readOptionalDate(String key) {
      final value = data[key];
      if (value is Timestamp) return value.toDate().toUtc();
      if (value is DateTime) return value.toUtc();
      return null;
    }

    return PharmacyGuard(
      id: id,
      pharmacyId: data['pharmacyId'] as String?,
      externalId: data['externalId'] as String?,
      name: (data['name'] as String? ?? '').trim(),
      city: (data['city'] as String? ?? '').trim(),
      district: data['district'] as String?,
      address: data['address'] as String?,
      phone: data['phone'] as String?,
      latitude: (data['latitude'] as num?)?.toDouble(),
      longitude: (data['longitude'] as num?)?.toDouble(),
      guardStartAt: readDate('guardStartAt'),
      guardEndAt: readDate('guardEndAt'),
      sourceType: data['sourceType'] as String? ?? 'manual',
      sourceName: data['sourceName'] as String?,
      sourceUrl: data['sourceUrl'] as String?,
      isVerified: data['isVerified'] == true,
      isActive: data['isActive'] == true,
      linkedPartner: data['linkedPartner'] == true,
      partnerPharmacyId: data['partnerPharmacyId'] as String?,
      lastSyncedAt: readOptionalDate('lastSyncedAt'),
    );
  }

  Map<String, dynamic> toFirestore() => {
        if (pharmacyId != null) 'pharmacyId': pharmacyId,
        if (externalId != null) 'externalId': externalId,
        'name': name,
        'city': city,
        if (district?.trim().isNotEmpty == true) 'district': district!.trim(),
        if (address?.trim().isNotEmpty == true) 'address': address!.trim(),
        if (phone?.trim().isNotEmpty == true) 'phone': phone!.trim(),
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        'guardStartAt': Timestamp.fromDate(guardStartAt.toUtc()),
        'guardEndAt': Timestamp.fromDate(guardEndAt.toUtc()),
        'sourceType': sourceType,
        if (sourceName?.trim().isNotEmpty == true)
          'sourceName': sourceName!.trim(),
        if (sourceUrl?.trim().isNotEmpty == true)
          'sourceUrl': sourceUrl!.trim(),
        'isVerified': isVerified,
        'isActive': isActive,
        'linkedPartner': linkedPartner,
        if (partnerPharmacyId != null) 'partnerPharmacyId': partnerPharmacyId,
        if (lastSyncedAt != null)
          'lastSyncedAt': Timestamp.fromDate(lastSyncedAt!.toUtc()),
      };
}

Map<String, dynamic> buildPharmacyOrderPrefill(PharmacyGuard guard) => {
      if (guard.partnerPharmacyId != null)
        'pharmacieId': guard.partnerPharmacyId,
      'pharmacieName': guard.name,
      'pickupAddress': guard.address,
      'pickupLatitude': guard.latitude,
      'pickupLongitude': guard.longitude,
      'pickupPhone': guard.phone,
      'pharmacyGuardId': guard.id,
    };
