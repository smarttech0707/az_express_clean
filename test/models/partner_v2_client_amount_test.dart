import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/models/partner_v2_info.dart';

void main() {
  // Le suivi client montrait `budget` : pour une v2 c'est le frais de livraison seul (500), pas les 7 500 FCFA payés.
  Map<String, dynamic> v2({String? seller}) => {
        'amountsVersion': 2,
        'sellerType': 'restaurant',
        'productAmount': 7000,
        'deliveryFee': 500,
        'totalAmount': 7500,
        if (seller != null) 'sellerStatus': seller,
      };

  test('v2 : le client voit le total payé, jamais le budget (frais de livraison)', () {
    final info = PartnerV2Info.tryParse(v2());
    expect(PartnerV2Info.clientAmount(500, info), 7500);
  });

  test('historique ou total absent : budget conservé', () {
    expect(PartnerV2Info.clientAmount(2500, null), 2500);
    final info = PartnerV2Info.tryParse(
        {'amountsVersion': 2, 'sellerType': 'restaurant'});
    expect(PartnerV2Info.clientAmount(500, info), 500);
  });

  test('libellés de préparation côté client suivent sellerStatus serveur', () {
    expect(PartnerV2Info.tryParse(v2())!.preparationLabel,
        'En attente de préparation');
    expect(PartnerV2Info.tryParse(v2(seller: 'preparing'))!.preparationLabel,
        'En préparation');
    expect(PartnerV2Info.tryParse(v2(seller: 'ready'))!.preparationLabel,
        'Prête à récupérer');
  });
}
