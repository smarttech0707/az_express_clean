import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:az_express/widgets/password_reset_email_guidance.dart';

void main() {
  testWidgets('sends the reset email then shows complete safety guidance',
      (tester) async {
    var sendCount = 0;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => sendResetEmailAndShowGuidance(
              context: context,
              sendEmail: () async {
                sendCount++;
              },
            ),
            child: const Text('Réinitialiser'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Réinitialiser'));
    await tester.pumpAndSettle();

    expect(sendCount, 1);
    expect(find.text('Vérifiez votre e-mail'), findsOneWidget);
    expect(kPasswordResetEmailGuidance, contains('boîte de réception'));
    expect(kPasswordResetEmailGuidance, contains('Spam/Indésirables'));
    expect(kPasswordResetEmailGuidance, contains('copiez-le'));
    expect(kPasswordResetEmailGuidance, contains('Chrome ou un navigateur'));
    expect(kPasswordResetEmailGuidance, contains('Ne partagez jamais ce lien'));
    expect(find.text(kPasswordResetEmailGuidance), findsOneWidget);
    expect(find.textContaining('https://'), findsNothing);
  });

  testWidgets('does not show success guidance when email sending fails',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              try {
                await sendResetEmailAndShowGuidance(
                  context: context,
                  sendEmail: () async => throw StateError('send failed'),
                );
              } on StateError {
                // The screen reports the send failure; this test only verifies
                // that success guidance is not shown.
              }
            },
            child: const Text('Réinitialiser'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Réinitialiser'));
    await tester.pump();

    expect(find.text('Vérifiez votre e-mail'), findsNothing);
  });
}
