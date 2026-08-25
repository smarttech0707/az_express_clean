import 'package:cloud_firestore/cloud_firestore.dart';

class EkDepositAccount {
  final String id;
  final String operator;
  final String phoneNumber;
  final String? label;
  final bool isPrimary;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const EkDepositAccount({
    required this.id,
    required this.operator,
    required this.phoneNumber,
    this.label,
    this.isPrimary = false,
    this.isActive = true,
    this.createdAt,
    this.updatedAt,
  });

  static String normalizePhone(String value) =>
      value.replaceAll(RegExp(r'[^0-9+]'), '').replaceFirst('+225', '');

  bool get isValid =>
      const {'orange', 'mtn', 'moov', 'wave'}.contains(operator) &&
      normalizePhone(phoneNumber).replaceAll('+', '').length >= 8;

  factory EkDepositAccount.fromMap(Map<String, dynamic> map) => EkDepositAccount(
        id: map['id'] as String? ?? '',
        operator: map['operator'] as String? ?? '',
        phoneNumber: normalizePhone(map['phoneNumber'] as String? ?? ''),
        label: map['label'] as String?,
        isPrimary: map['isPrimary'] == true,
        isActive: map['isActive'] != false,
        createdAt: (map['createdAt'] as Timestamp?)?.toDate(),
        updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'operator': operator,
        'phoneNumber': normalizePhone(phoneNumber),
        'label': label,
        'isPrimary': isPrimary,
        'isActive': isActive,
        'createdAt': createdAt == null ? FieldValue.serverTimestamp() : Timestamp.fromDate(createdAt!),
        'updatedAt': FieldValue.serverTimestamp(),
      };

  EkDepositAccount copyWith({String? phoneNumber, String? label, bool? isPrimary, bool? isActive}) =>
      EkDepositAccount(
        id: id, operator: operator, phoneNumber: phoneNumber ?? this.phoneNumber,
        label: label ?? this.label, isPrimary: isPrimary ?? this.isPrimary,
        isActive: isActive ?? this.isActive, createdAt: createdAt,
      );
}
