import 'package:az_express/screens/admin/admin_reviews_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AdminReviewRecord _record(int index) => AdminReviewRecord(
      id: 'review-$index',
      sellerId: '',
      sellerType: 'restaurant',
      rating: 4,
      comment: 'Avis $index',
      createdAt: DateTime(2026, 8, 23),
    );

void main() {
  testWidgets('charge les avis par pages strictement bornées à 25',
      (tester) async {
    final requests = <AdminReviewPageRequest>[];
    Future<AdminReviewPageResult> loader(AdminReviewPageRequest request) async {
      requests.add(request);
      return AdminReviewPageResult(
        records: List.generate(25, _record),
        cursor: 'page-${requests.length}',
      );
    }

    await tester.pumpWidget(
      MaterialApp(home: AdminReviewsPage(pageLoader: loader)),
    );
    await tester.pumpAndSettle();

    expect(requests.single.limit, 25);
    await tester.scrollUntilVisible(
      find.byKey(const Key('reviews-load-more')),
      500,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.byKey(const Key('reviews-load-more')), findsOneWidget);
    await tester.tap(find.byKey(const Key('reviews-load-more')));
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    expect(requests.last.limit, 25);
    expect(requests.last.cursor, 'page-1');
  });

  testWidgets('applique le filtre des notes 1 et 2', (tester) async {
    final requests = <AdminReviewPageRequest>[];
    Future<AdminReviewPageResult> loader(AdminReviewPageRequest request) async {
      requests.add(request);
      return const AdminReviewPageResult(records: []);
    }

    await tester.pumpWidget(
      MaterialApp(home: AdminReviewsPage(pageLoader: loader)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reviews-low-rating-filter')));
    await tester.pumpAndSettle();

    expect(requests.last.ratingFilter, AdminReviewRatingFilter.low);
    expect(requests.last.limit, 25);
  });

  testWidgets('applique le filtre par type de partenaire', (tester) async {
    final requests = <AdminReviewPageRequest>[];
    Future<AdminReviewPageResult> loader(AdminReviewPageRequest request) async {
      requests.add(request);
      return const AdminReviewPageResult(records: []);
    }

    await tester.pumpWidget(
      MaterialApp(home: AdminReviewsPage(pageLoader: loader)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reviews-partner-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Boulangeries').last);
    await tester.pumpAndSettle();

    expect(requests.last.partnerFilter, AdminReviewPartnerFilter.boulangerie);
    expect(requests.last.limit, 25);
  });
}
