import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/constants/app_constants.dart';

// Tant que `deliveryTransferCF` n'est pas déployée, aucun point d'entrée du remplacement de livreur ne doit
// être proposé dans la version publiée.
void main() {
  test('le remplacement de livreur est désactivé par défaut', () {
    expect(AppConfig.deliveryTransferEnabled, isFalse);
  });

  test('les deux accès du tableau de bord livreur sont protégés par le drapeau', () {
    final source =
        File('lib/screens/driver/driver_dashboard.dart').readAsStringSync();
    expect(
        RegExp(r'if \(AppConfig\.deliveryTransferEnabled\)\s+IconButton\(')
            .hasMatch(source),
        isTrue);
    expect(
        RegExp(r"if \(picked && !AppConfig\.deliveryTransferEnabled\) \{")
            .hasMatch(source),
        isTrue);
  });
}
