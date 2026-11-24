import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/screens/admin/admin_purge_page.dart';

void main() {
  testWidgets('Order purge is disabled and unselected', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AdminPurgePage()));
    expect(find.text('Commandes'), findsOneWidget);
    final checkbox = tester.widget<Checkbox>(find.byType(Checkbox).first);
    expect(checkbox.value, false);
    expect(checkbox.onChanged, isNull);
  });
}
