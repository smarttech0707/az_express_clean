import 'package:az_express/screens/restaurant/restaurant_list.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('coverImageUrl a priorité sur les champs historiques', () {
    expect(
      restaurantCoverUrl({
        'coverImageUrl': 'https://example.com/cover.jpg',
        'coverUrl': 'https://example.com/legacy.jpg',
      }),
      'https://example.com/cover.jpg',
    );
  });

  test('aucune couverture retourne null et laisse le fallback premium', () {
    expect(restaurantCoverUrl({'logoUrl': 'https://example.com/logo.jpg'}),
        isNull);
  });
}
