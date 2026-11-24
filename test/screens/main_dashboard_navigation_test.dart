import 'package:az_express/screens/client/livraison_screen.dart';
import 'package:az_express/screens/main_dashboard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('refuse une session absente ou anonyme', () {
    expect(
      isAuthenticatedClientSession(hasUser: false, isAnonymous: true),
      isFalse,
    );
    expect(
      isAuthenticatedClientSession(hasUser: true, isAnonymous: true),
      isFalse,
    );
    expect(
      isAuthenticatedClientSession(hasUser: true, isAnonymous: false),
      isTrue,
    );
  });

  test('le bouton Commander cible LivraisonScreen', () {
    expect(buildClientOrderScreen(), isA<LivraisonScreen>());
  });
}
