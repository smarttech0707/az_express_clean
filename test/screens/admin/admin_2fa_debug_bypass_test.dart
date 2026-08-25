import 'package:az_express/screens/admin/admin_dashboard.dart';
import 'package:az_express/screens/admin/admin_login.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

bool bypass({
  bool isDebug = true,
  bool flag = true,
  bool credentials = true,
  bool document = true,
  bool role = true,
  bool email = true,
  bool phone = true,
}) =>
    adminDevelopmentBypassAllowed(
      isDebug: isDebug,
      buildFlagEnabled: flag,
      credentialsAccepted: credentials,
      adminDocumentExists: document,
      roleActive: role,
      emailVerified: email,
      phoneConfigured: phone,
    );

void main() {
  test('2FA reste obligatoire sans le flag explicite', () {
    expect(bypass(flag: false), isFalse);
  });

  test('2FA reste obligatoire en release même avec le flag', () {
    expect(bypass(isDebug: false, flag: true), isFalse);
  });

  test('le contournement exige toutes les cinq autres conditions', () {
    expect(bypass(), isTrue);
    expect(bypass(credentials: false), isFalse);
    expect(bypass(document: false), isFalse);
    expect(bypass(role: false), isFalse);
    expect(bypass(email: false), isFalse);
    expect(bypass(phone: false), isFalse);
  });

  test('le flag accepte uniquement super ou sub explicitement actif', () {
    expect(adminDevelopmentRoleAllowed({'role': 'super'}), isTrue);
    expect(
      adminDevelopmentRoleAllowed({'role': 'sub', 'isActive': true}),
      isTrue,
    );
    expect(
      adminDevelopmentRoleAllowed({'role': 'sub', 'isActive': false}),
      isFalse,
    );
    expect(adminDevelopmentRoleAllowed({'role': 'sub'}), isFalse);
    expect(adminDevelopmentRoleAllowed({'role': 'client'}), isFalse);
    expect(adminDevelopmentRoleAllowed({}), isFalse);
  });

  testWidgets('le bandeau de contournement est visible et explicite',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AdminDashboard(
          adminData: {
            'uid': 'admin-test',
            'role': 'sub',
            'isActive': true,
            'permissions': <String>[],
          },
          twoFactorBypassed: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('admin-2fa-debug-bypass-banner')), findsOne);
    expect(find.text('2FA DÉSACTIVÉE — MODE DEV'), findsOne);
  });
}
