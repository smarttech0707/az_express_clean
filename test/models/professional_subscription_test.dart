import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/models/professional_subscription.dart';

void main() {
  group('Tarification professionnelle', () {
    test('applique les tarifs généraux pendant puis après trois mois', () {
      final subscription = ProfessionalSubscription(
        module: ProfessionalModule.event,
        plan: SubscriptionPlan.premium,
        status: ProfessionalPlanStatus.pending,
        trialStartedAt: DateTime(2026, 1, 15),
      );

      expect(subscription.priceAt(DateTime(2026, 4, 14)), 1000);
      expect(subscription.priceAt(DateTime(2026, 4, 15)), 3000);
    });

    test('applique la grille spécifique Artisans', () {
      final subscription = ProfessionalSubscription(
        module: ProfessionalModule.artisan,
        plan: SubscriptionPlan.vvip,
        status: ProfessionalPlanStatus.pending,
        trialStartedAt: DateTime(2026, 1, 1),
      );

      expect(subscription.priceAt(DateTime(2026, 3, 31)), 1500);
      expect(subscription.priceAt(DateTime(2026, 4, 1)), 3500);
    });

    test('détecte une expiration', () {
      final subscription = ProfessionalSubscription(
        module: ProfessionalModule.marketplace,
        plan: SubscriptionPlan.standard,
        status: ProfessionalPlanStatus.active,
        trialStartedAt: DateTime(2026, 1, 1),
        planEndsAt: DateTime(2026, 5, 1),
      );

      expect(subscription.isExpiredAt(DateTime(2026, 4, 30)), isFalse);
      expect(subscription.isExpiredAt(DateTime(2026, 5, 1)), isTrue);
    });
  });

  test('ordonne VVIP avant Premium avant Standard', () {
    final now = DateTime(2026, 6, 1);
    final plans = SubscriptionPlan.values.toList()
      ..sort((left, right) => compareProfessionalListings(
            leftPlan: left,
            leftActive: true,
            leftFeaturedUntil: null,
            leftPublishedAt: now,
            leftRelevance: 0,
            rightPlan: right,
            rightActive: true,
            rightFeaturedUntil: null,
            rightPublishedAt: now,
            rightRelevance: 0,
            now: now,
          ));

    expect(plans, [
      SubscriptionPlan.vvip,
      SubscriptionPlan.premium,
      SubscriptionPlan.standard,
    ]);
  });
}
