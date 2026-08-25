import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/models/pharmacy_guard.dart';

PharmacyGuard guard({
  required DateTime start,
  required DateTime end,
  String? partnerId,
}) =>
    PharmacyGuard(
      id: 'g1',
      name: 'Pharmacie Centre',
      city: 'Abengourou',
      address: 'Centre-ville',
      phone: '0700000000',
      latitude: 6.73,
      longitude: -3.49,
      guardStartAt: start,
      guardEndAt: end,
      sourceType: partnerId == null ? 'external' : 'partner',
      isVerified: true,
      isActive: true,
      linkedPartner: partnerId != null,
      partnerPharmacyId: partnerId,
    );

void main() {
  final now = DateTime.utc(2026, 8, 11, 22);

  test('garde active maintenant', () {
    expect(
        guard(
                start: now.subtract(const Duration(hours: 2)),
                end: now.add(const Duration(hours: 4)))
            .isOnDutyAt(now),
        isTrue);
  });

  test('garde future', () {
    final value = guard(
        start: now.add(const Duration(hours: 2)),
        end: now.add(const Duration(hours: 8)));
    expect(value.isOnDutyAt(now), isFalse);
    expect(value.isExpiredAt(now), isFalse);
  });

  test('garde expirée', () {
    expect(
        guard(
                start: now.subtract(const Duration(days: 2)),
                end: now.subtract(const Duration(hours: 1)))
            .isExpiredAt(now),
        isTrue);
  });

  test('garde traversant minuit', () {
    final value = guard(
        start: DateTime.utc(2026, 8, 11, 20),
        end: DateTime.utc(2026, 8, 12, 8));
    expect(value.isOnDutyAt(DateTime.utc(2026, 8, 12, 1)), isTrue);
  });

  test('filtre semaine inclut une garde chevauchant la semaine', () {
    final value = guard(
        start: DateTime.utc(2026, 8, 9, 20), end: DateTime.utc(2026, 8, 10, 8));
    expect(value.matchesPeriod(PharmacyGuardPeriod.week, now), isTrue);
  });

  test('filtre mois exclut une garde du mois suivant', () {
    final value =
        guard(start: DateTime.utc(2026, 9, 1), end: DateTime.utc(2026, 9, 2));
    expect(value.matchesPeriod(PharmacyGuardPeriod.month, now), isFalse);
  });

  test('pharmacie partenaire liée préremplit son identifiant', () {
    final value = guard(
        start: now, end: now.add(const Duration(hours: 2)), partnerId: 'p1');
    expect(buildPharmacyOrderPrefill(value)['pharmacieId'], 'p1');
  });

  test('pharmacie externe reste sans identifiant partenaire', () {
    final value = guard(start: now, end: now.add(const Duration(hours: 2)));
    expect(
        buildPharmacyOrderPrefill(value).containsKey('pharmacieId'), isFalse);
  });

  test('commande préremplit retrait, téléphone et coordonnées', () {
    final draft = buildPharmacyOrderPrefill(
        guard(start: now, end: now.add(const Duration(hours: 2))));
    expect(draft['pharmacieName'], 'Pharmacie Centre');
    expect(draft['pickupAddress'], 'Centre-ville');
    expect(draft['pickupPhone'], '0700000000');
    expect(draft['pickupLatitude'], 6.73);
  });
}
