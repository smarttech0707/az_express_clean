import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// AdminSellersPage exige Firebase (flux Firestore) : on contrôle son code
// source. Les opérations sensibles doivent rester côté serveur, et la page ne
// doit jamais supprimer un document ni écrire un champ financier.
void main() {
  final src =
      File('lib/screens/admin/admin_sellers_page.dart').readAsStringSync();

  test('aucune suppression de document vendeur depuis la page', () {
    expect(src.contains('.delete()'), isFalse);
  });

  test('aucune écriture client de wallet, abonnement, VIP ou suspension', () {
    final writes = RegExp(
            r"""(\.update\(|\.set\(|SetOptions)[\s\S]{0,260}?"""
            r"""['"](wallet|subscription\w*|vip\w*|plan|paymentStatus|priorityLevel|isSuspended|status)['"]\s*:""")
        .allMatches(src);
    expect(writes, isEmpty);
  });

  test('plus aucune écriture Firestore directe : tout passe par une fonction serveur',
      () {
    expect(RegExp(r'\.(update|set|add)\(').hasMatch(src), isFalse);
    expect(src, contains('AdminPartnerAccountService.manageSeller'));
    final service = File('lib/screens/admin/admin_partner_account_service.dart')
        .readAsStringSync();
    expect(service, contains("httpsCallable('manageSellerAccountCF')"));
  });

  test('la création et l\'abonnement/VIP passent par les fonctions serveur', () {
    expect(src, contains('AdminPartnerAccountService.create'));
    expect(src, contains('SubscriptionService'));
    final sub = File('lib/services/subscription_service.dart');
    if (sub.existsSync()) {
      expect(sub.readAsStringSync(), contains('manageProfessionalSubscription'));
    }
  });

  test('l\'édition envoie uniquement les 6 champs de fiche autorisés par la règle',
      () {
    final i = src.indexOf('Map<String, dynamic> buildSellerProfileData');
    final body = src.substring(i, src.indexOf('class AdminSellersPage'));
    final keys = RegExp(r"'(\w+)':")
        .allMatches(body.replaceAll(RegExp(r"if \(isCreating\)[^,]*,"), ''))
        .map((m) => m.group(1))
        .toSet();
    expect(keys, {'name', 'phone', 'type', 'isActive', 'lat', 'lng'});
  });

  test('un échec d\'écriture (règle refusée) n\'est plus silencieux', () {
    expect(src, contains('Action refusée ou impossible'));
  });
}
