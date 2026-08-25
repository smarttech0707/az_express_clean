import 'package:az_express/constants/support_categories.dart';
import 'package:az_express/screens/admin/admin_support_page.dart';
import 'package:az_express/screens/support/support_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('la nouvelle catégorie précède Autre', () {
    final feedbackIndex =
        SupportCategories.all.indexOf(SupportCategories.applicationFeedback);
    expect(feedbackIndex, SupportCategories.all.indexOf('Autre') - 1);
  });

  test('le ticket conserve la catégorie retour application', () {
    final data = buildSupportTicketData(
      userId: 'client-1',
      subject: 'Une suggestion',
      message: 'Ajouter le mode sombre',
      category: SupportCategories.applicationFeedback,
      createdAt: 'timestamp-test',
    );
    expect(data['category'], SupportCategories.applicationFeedback);
    expect(data['status'], 'open');
    expect(data['subject'], 'Une suggestion');
    expect(data['message'], 'Ajouter le mode sombre');
  });

  testWidgets('la catégorie est identifiable clairement côté admin',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AdminTicketCategoryBadge(
            category: SupportCategories.applicationFeedback,
            isApplicationFeedback: true,
          ),
        ),
      ),
    );

    expect(find.text(SupportCategories.applicationFeedback), findsOneWidget);
    expect(find.byKey(const Key('admin-application-feedback-category')),
        findsOneWidget);
  });
}
