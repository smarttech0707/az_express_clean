import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:az_express/services/email_verification_resend_guard.dart';
import 'package:az_express/widgets/admin_email_verification_prompt.dart';

void main() {
  testWidgets('shows resend button only for the verification error',
      (tester) async {
    var resendCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AdminEmailVerificationPrompt(
          visible: false,
          onResend: () => resendCount++,
        ),
      ),
    );
    expect(find.text('Renvoyer l’email de vérification'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: AdminEmailVerificationPrompt(
          visible: true,
          remaining: const Duration(seconds: 10),
          onResend: () => resendCount++,
        ),
      ),
    );
    expect(find.text('Renvoyer dans 10s'), findsOneWidget);
    await tester.tap(find.byType(TextButton));
    expect(resendCount, 0);
  });

  test('allows one send and blocks for one minute', () {
    final guard = EmailVerificationResendGuard();
    final sentAt = DateTime(2026, 8, 20, 10);

    expect(guard.canSend(sentAt), isTrue);
    guard.markSent(sentAt);
    expect(guard.canSend(sentAt.add(const Duration(seconds: 59))), isFalse);
    expect(
      guard.remaining(sentAt.add(const Duration(seconds: 59))).inSeconds,
      1,
    );
    expect(guard.canSend(sentAt.add(const Duration(minutes: 1))), isTrue);
  });
}
