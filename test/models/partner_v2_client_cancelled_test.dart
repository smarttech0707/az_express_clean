import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/models/partner_v2_info.dart';

void main() {
  Map<String, dynamic> v2({Map<String, dynamic>? refusal}) => {
        'amountsVersion': 2,
        'sellerType': 'restaurant',
        'totalAmount': 7500,
        if (refusal != null) 'partnerRefusal': refusal,
      };

  group('commandes annulées v2 visibles du client', () {
    test('v2 annulée : visible ; historique annulée : toujours masquée', () {
      final info = PartnerV2Info.tryParse(v2());
      expect(PartnerV2Info.visibleToClient('cancelled', info), isTrue);
      expect(PartnerV2Info.visibleToClient('cancelled', null), isFalse);
      expect(PartnerV2Info.visibleToClient('delivered', null), isTrue);
      expect(PartnerV2Info.visibleToClient('pending', null), isTrue);
    });

    test('refus avec motif : motif du restaurant, sans identifiant interne', () {
      final info = PartnerV2Info.tryParse(v2(refusal: {
        'reason': ' Rupture de stock ',
        'partnerId': 'secret-uid',
        'atMs': 1
      }))!;
      expect(info.cancelledTitle, 'Refusée par le restaurant');
      expect(info.cancelledMessage, 'Motif du restaurant : Rupture de stock');
      expect(info.cancelledMessage.contains('secret-uid'), isFalse);
      expect(info.totalAmount, 7500);
    });

    test('refus sans motif : aucun motif inventé', () {
      for (final refusal in [
        {'reason': '', 'partnerId': 'x'},
        {'partnerId': 'x'},
      ]) {
        final info = PartnerV2Info.tryParse(v2(refusal: refusal))!;
        expect(info.refusedByPartner, isTrue);
        expect(info.refusalReason, isNull);
        expect(info.cancelledMessage, 'Le restaurant a refusé votre commande.');
      }
    });

    test('annulation par le client : pas de refus affiché', () {
      final info = PartnerV2Info.tryParse(v2())!;
      expect(info.cancelledTitle, 'Annulée');
      expect(info.cancelledMessage, 'Cette commande a été annulée.');
    });

    test('l’écran filtre via visibleToClient et ne contacte plus de livreur annulé',
        () {
      final src = File('lib/screens/client/suivi_commande.dart').readAsStringSync();
      expect(src.contains('PartnerV2Info.visibleToClient'), isTrue);
      expect(src.contains('o.status != "cancelled"'), isFalse);
    });
  });

  group('annulation client refusée par le serveur', () {
    const inPrep =
        "Le restaurant a déjà commencé la préparation de votre commande. Vous ne pouvez plus l'annuler depuis l'application.";

    test('ORDER_IN_PREPARATION (message serveur réel) : message explicite', () {
      final e = FirebaseFunctionsException(
          code: 'failed-precondition',
          message:
              'Le partenaire a commencé la préparation : la commande ne peut plus être annulée automatiquement. Contactez le support AZ Express.');
      expect(PartnerV2Info.cancelFailureMessage(e), inPrep);
    });

    test('code ORDER_IN_PREPARATION dans le message ou les détails', () {
      expect(
          PartnerV2Info.cancelFailureMessage(FirebaseFunctionsException(
              code: 'failed-precondition',
              message: 'x',
              details: 'ORDER_IN_PREPARATION')),
          inPrep);
      expect(PartnerV2Info.cancelFailureMessage(Exception('ORDER_IN_PREPARATION')),
          inPrep);
    });

    test('commande non annulable et erreur inconnue', () {
      expect(
          PartnerV2Info.cancelFailureMessage(FirebaseFunctionsException(
              code: 'failed-precondition',
              message: 'Cette commande ne peut plus être annulée')),
          'Cette commande ne peut plus être annulée.');
      expect(
          PartnerV2Info.cancelFailureMessage(
              FirebaseFunctionsException(code: 'unavailable', message: 'offline')),
          "Échec de l'annulation. Réessayez dans quelques instants.");
    });

    test('aucune relance ni écriture wallet dans l’écran de suivi', () {
      final src = File('lib/screens/client/suivi_commande.dart').readAsStringSync();
      final i = src.indexOf('cancelOrder(order.id)');
      expect(i, greaterThan(0));
      expect(src.indexOf('cancelOrder(', i + 5), -1);
      // Les `.update(` de notation vendeur existent déjà ; on interdit seulement toute écriture de solde.
      expect(RegExp(r'''FieldValue\.increment|["']wallet["']\s*:''').hasMatch(src),
          isFalse);
    });
  });
}
