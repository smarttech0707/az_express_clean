import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/screens/admin/admin_seller_requests_page.dart';

/// Approbation vendeur — régression du 2026-10-06.
///
/// `_approve` utilisait `batch.set(sellers/{uid}, …)` **sans merge** et sans
/// jamais vérifier si le document existait déjà. Le payload d'approbation ne
/// contient aucun champ financier : un `set` sur un document existant les
/// effaçait donc tous (`wallet`, `subscriptionStatus`, `vipStatus`, `plan`…).
/// La sous-collection `wallet_transactions` survivant à l'écrasement du parent,
/// le solde et son propre historique divergeaient de façon irréparable.
///
/// Corrigé par une transaction qui REFUSE si `sellers/{uid}` existe déjà
/// (plutôt qu'un merge, qui masquerait une double approbation).
///
/// Aucun Firestore, aucun réseau, aucun Firebase Auth : seules les décisions
/// pures et le corps transactionnel sont exercés, contre un faux store.
class _FakeSellerApprovalStore implements SellerApprovalStore {
  _FakeSellerApprovalStore({this.existing});

  /// Document `sellers/{uid}` déjà en base, ou `null` s'il n'existe pas.
  Map<String, dynamic>? existing;

  final List<String> operations = <String>[];
  Map<String, dynamic>? written;
  bool requestApproved = false;

  @override
  Future<bool> sellerExists() async {
    operations.add('read');
    return existing != null;
  }

  @override
  void createSeller(Map<String, dynamic> data) {
    operations.add('createSeller');
    written = data;
    existing = data;
  }

  @override
  void markRequestApproved() {
    operations.add('markRequestApproved');
    requestApproved = true;
  }
}

void main() {
  const request = <String, dynamic>{
    'uid': 'seller-uid-1',
    'ownerName': 'Kone Awa',
    'shopName': 'Boutique Gabriel',
    'phone': '0700000000',
    'address': 'Quartier Commerce, Abengourou',
    'category': 'Téléphones',
    'lat': 6.7273,
    'lng': -3.4961,
    'status': 'pending',
  };

  /// Un vendeur déjà actif, avec solde et abonnement payé — exactement les
  /// champs que `firestore.rules` interdit au vendeur de modifier lui-même.
  Map<String, dynamic> activeSeller() => <String, dynamic>{
        'uid': 'seller-uid-1',
        'ownerName': 'Kone Awa',
        'shopName': 'Boutique Gabriel',
        'phone': '0700000000',
        'isActive': true,
        'wallet': 125000,
        'subscriptionStatus': 'active',
        'subscriptionExpiresAt': '2027-01-01',
        'vipStatus': 'active',
        'vipExpiresAt': '2027-01-01',
        'vipStartedAt': '2026-01-01',
        'plan': 'pro',
        'priorityLevel': 3,
        'paymentStatus': 'paid',
      };

  Future<void> approve(_FakeSellerApprovalStore store) => runSellerApproval(
        store,
        'seller-uid-1',
        request,
        latitude: 6.7273,
        longitude: -3.4961,
        createdAt: 'SERVER_TIMESTAMP',
      );

  group('Approbation normale', () {
    test('aucun vendeur existant : création + demande approuvée', () async {
      final store = _FakeSellerApprovalStore();
      await approve(store);
      expect(store.written, isNotNull);
      expect(store.requestApproved, isTrue);
      expect(store.operations, ['read', 'createSeller', 'markRequestApproved'],
          reason: 'la lecture doit précéder toute écriture');
    });

    test('les données légitimes de la demande sont conservées', () async {
      final store = _FakeSellerApprovalStore();
      await approve(store);
      final doc = store.written!;
      expect(doc['uid'], 'seller-uid-1');
      expect(doc['ownerName'], 'Kone Awa');
      expect(doc['shopName'], 'Boutique Gabriel');
      expect(doc['phone'], '0700000000');
      expect(doc['address'], 'Quartier Commerce, Abengourou');
      expect(doc['category'], 'Téléphones');
      expect(doc['lat'], 6.7273);
      expect(doc['lng'], -3.4961);
      expect(doc['isActive'], isTrue);
      expect(doc['createdAt'], 'SERVER_TIMESTAMP');
    });

    test('le payload ne porte AUCUN champ financier', () async {
      final store = _FakeSellerApprovalStore();
      await approve(store);
      for (final field in [
        'wallet',
        'subscriptionStatus',
        'subscriptionExpiresAt',
        'vipStatus',
        'vipExpiresAt',
        'vipStartedAt',
        'plan',
        'priorityLevel',
        'paymentStatus',
      ]) {
        expect(store.written!.containsKey(field), isFalse,
            reason: 'champ financier $field écrit par une approbation');
      }
      // Verrou plus fort : l'ensemble exact des clés autorisées.
      expect(store.written!.keys.toSet(), {
        'uid', 'ownerName', 'shopName', 'phone', 'address',
        'category', 'lat', 'lng', 'isActive', 'createdAt',
      });
    });

    test('coordonnées validées, jamais celles brutes de la demande', () {
      final doc = buildApprovedSellerDoc(
        'seller-uid-1',
        {...request, 'lat': 0, 'lng': 0},
        latitude: 7.1,
        longitude: -3.2,
        createdAt: 'SERVER_TIMESTAMP',
      );
      expect(doc['lat'], 7.1);
      expect(doc['lng'], -3.2);
    });

    test('demande incomplète : champs vides plutôt que null', () {
      final doc = buildApprovedSellerDoc(
        'seller-uid-1',
        const {},
        latitude: 7.1,
        longitude: -3.2,
        createdAt: 'SERVER_TIMESTAMP',
      );
      expect(doc['ownerName'], '');
      expect(doc['shopName'], '');
      expect(doc['phone'], '');
      expect(doc['address'], '');
      expect(doc['category'], '');
      expect(doc.containsKey('wallet'), isFalse);
    });
  });

  group('Vendeur déjà existant — aucun écrasement', () {
    test('approbation refusée si sellers/{uid} existe', () async {
      final store = _FakeSellerApprovalStore(existing: activeSeller());
      await expectLater(
        approve(store),
        throwsA(isA<SellerAlreadyApprovedException>()),
      );
    });

    test('le wallet positif est intégralement conservé', () async {
      final store = _FakeSellerApprovalStore(existing: activeSeller());
      await approve(store).catchError((_) {});
      expect(store.existing!['wallet'], 125000,
          reason: 'le solde ne doit jamais être remis à 0');
    });

    test('les autres champs financiers sont conservés', () async {
      final store = _FakeSellerApprovalStore(existing: activeSeller());
      await approve(store).catchError((_) {});
      final seller = store.existing!;
      expect(seller['subscriptionStatus'], 'active');
      expect(seller['subscriptionExpiresAt'], '2027-01-01');
      expect(seller['vipStatus'], 'active');
      expect(seller['vipExpiresAt'], '2027-01-01');
      expect(seller['vipStartedAt'], '2026-01-01');
      expect(seller['plan'], 'pro');
      expect(seller['priorityLevel'], 3);
      expect(seller['paymentStatus'], 'paid');
    });

    test('aucune écriture partielle : ni création, ni demande approuvée',
        () async {
      final store = _FakeSellerApprovalStore(existing: activeSeller());
      await approve(store).catchError((_) {});
      expect(store.written, isNull);
      expect(store.requestApproved, isFalse,
          reason: 'la demande doit rester dans son état d\'origine');
      expect(store.operations, ['read'],
          reason: 'le refus doit intervenir avant toute écriture');
    });

    test('double approbation : le second passage ne remet pas le wallet à 0',
        () async {
      // Premier passage sur un vendeur déjà actif (retry d\'un admin qui n\'a
      // pas vu le résultat du premier clic — le bouton n\'a pas d\'état de
      // chargement), puis second passage immédiat.
      final store = _FakeSellerApprovalStore(existing: activeSeller());
      for (var attempt = 0; attempt < 2; attempt++) {
        await approve(store).catchError((_) {});
      }
      expect(store.existing!['wallet'], 125000);
      expect(store.written, isNull);
      expect(store.requestApproved, isFalse);
    });

    test('approbation puis retry immédiat : la création n\'a lieu qu\'une fois',
        () async {
      // Cas réel du double-tap sur une demande réellement en attente : le
      // premier passage crée, le second est refusé par la transaction.
      final store = _FakeSellerApprovalStore();
      await approve(store);
      final firstWrite = store.written;
      await expectLater(
        approve(store),
        throwsA(isA<SellerAlreadyApprovedException>()),
      );
      expect(store.written, same(firstWrite),
          reason: 'le document ne doit pas être réécrit');
      expect(
        store.operations.where((op) => op == 'createSeller').length,
        1,
      );
    });
  });

  group('Message rendu à l\'admin', () {
    test('succès → message de succès', () {
      final feedback = sellerApprovalFeedback(
        error: null,
        shopName: 'Boutique Gabriel',
      );
      expect(feedback.isSuccess, isTrue);
      expect(feedback.message, 'Boutique Gabriel approuvé !');
    });

    test('vendeur déjà existant → message explicite et compréhensible', () {
      final feedback = sellerApprovalFeedback(
        error: const SellerAlreadyApprovedException(),
        shopName: 'Boutique Gabriel',
      );
      expect(feedback.isSuccess, isFalse);
      expect(feedback.message, contains('déjà un compte'));
      expect(feedback.message, contains('Aucune donnée'));
      expect(feedback.message, isNot(contains('approuvé !')));
    });

    test('échec Firestore → JAMAIS un message de succès', () {
      for (final error in <Object>[
        Exception('permission-denied'),
        StateError('offline'),
        'erreur brute',
      ]) {
        final feedback = sellerApprovalFeedback(
          error: error,
          shopName: 'Boutique Gabriel',
        );
        expect(feedback.isSuccess, isFalse, reason: 'échec $error');
        expect(feedback.message, contains('impossible'));
      }
    });

    test('le message d\'échec ne divulgue aucun détail technique', () {
      final feedback = sellerApprovalFeedback(
        error: Exception('PERMISSION_DENIED: sellers/abc123 hasAdminPermission'),
        shopName: 'Boutique Gabriel',
      );
      expect(feedback.message, isNot(contains('PERMISSION_DENIED')));
      expect(feedback.message, isNot(contains('sellers/')));
    });
  });
}
