enum ProfessionalModule { realEstate, marketplace, event, artisan }

enum SubscriptionPlan { standard, premium, vvip }

enum ProfessionalPlanStatus { pending, trial, active, expired, suspended }

class ModulePricing {
  const ModulePricing({
    required this.standard,
    required this.premium,
    required this.vvip,
    required this.launchStandard,
    required this.launchPremium,
    required this.launchVvip,
  });

  final int standard;
  final int premium;
  final int vvip;
  final int launchStandard;
  final int launchPremium;
  final int launchVvip;

  static const general = ModulePricing(
    standard: 1000,
    premium: 3000,
    vvip: 5000,
    launchStandard: 0,
    launchPremium: 1000,
    launchVvip: 2000,
  );

  static const artisan = ModulePricing(
    standard: 500,
    premium: 2000,
    vvip: 3500,
    launchStandard: 0,
    launchPremium: 500,
    launchVvip: 1500,
  );

  static ModulePricing forModule(ProfessionalModule module) =>
      module == ProfessionalModule.artisan ? artisan : general;

  int normalPrice(SubscriptionPlan plan) => switch (plan) {
        SubscriptionPlan.standard => standard,
        SubscriptionPlan.premium => premium,
        SubscriptionPlan.vvip => vvip,
      };

  int launchPrice(SubscriptionPlan plan) => switch (plan) {
        SubscriptionPlan.standard => launchStandard,
        SubscriptionPlan.premium => launchPremium,
        SubscriptionPlan.vvip => launchVvip,
      };
}

class ProfessionalSubscription {
  const ProfessionalSubscription({
    required this.module,
    required this.plan,
    required this.status,
    required this.trialStartedAt,
    this.planStartedAt,
    this.planEndsAt,
  });

  static const launchMonths = 3;

  final ProfessionalModule module;
  final SubscriptionPlan plan;
  final ProfessionalPlanStatus status;
  final DateTime trialStartedAt;
  final DateTime? planStartedAt;
  final DateTime? planEndsAt;

  DateTime get trialEndsAt => DateTime(trialStartedAt.year,
      trialStartedAt.month + launchMonths, trialStartedAt.day);

  bool isLaunchPriceAt(DateTime date) =>
      !date.isBefore(trialStartedAt) && date.isBefore(trialEndsAt);

  int priceAt(DateTime date) {
    final pricing = ModulePricing.forModule(module);
    return isLaunchPriceAt(date)
        ? pricing.launchPrice(plan)
        : pricing.normalPrice(plan);
  }

  bool isExpiredAt(DateTime date) =>
      planEndsAt != null && !date.isBefore(planEndsAt!);

  static int priorityFor(SubscriptionPlan plan) => switch (plan) {
        SubscriptionPlan.standard => 1,
        SubscriptionPlan.premium => 2,
        SubscriptionPlan.vvip => 3,
      };
}

int compareProfessionalListings({
  required SubscriptionPlan leftPlan,
  required bool leftActive,
  required DateTime? leftFeaturedUntil,
  required DateTime leftPublishedAt,
  required double leftRelevance,
  required SubscriptionPlan rightPlan,
  required bool rightActive,
  required DateTime? rightFeaturedUntil,
  required DateTime rightPublishedAt,
  required double rightRelevance,
  DateTime? now,
}) {
  final reference = now ?? DateTime.now();
  int descendingInt(int left, int right) => right.compareTo(left);

  final byPlan = descendingInt(
    ProfessionalSubscription.priorityFor(leftPlan),
    ProfessionalSubscription.priorityFor(rightPlan),
  );
  if (byPlan != 0) return byPlan;

  final byActive = descendingInt(leftActive ? 1 : 0, rightActive ? 1 : 0);
  if (byActive != 0) return byActive;

  final leftFeatured =
      leftFeaturedUntil != null && leftFeaturedUntil.isAfter(reference);
  final rightFeatured =
      rightFeaturedUntil != null && rightFeaturedUntil.isAfter(reference);
  final byFeatured = descendingInt(leftFeatured ? 1 : 0, rightFeatured ? 1 : 0);
  if (byFeatured != 0) return byFeatured;

  final byDate = rightPublishedAt.compareTo(leftPublishedAt);
  if (byDate != 0) return byDate;
  return rightRelevance.compareTo(leftRelevance);
}
