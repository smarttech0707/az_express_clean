import 'package:az_express/auto_moto/models/vehicle_conversation.dart';
import 'package:az_express/auto_moto/models/vehicle_listing.dart';
import 'package:az_express/auto_moto/models/vehicle_seller_profile.dart';
import 'package:az_express/auto_moto/screens/my_vehicle_listings_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_chat_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_conversations_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_favorites_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_home_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_listing_detail_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_listing_form_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_listings_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_public_seller_profile_screen.dart';
import 'package:az_express/auto_moto/screens/vehicle_seller_profile_screen.dart';
import 'package:az_express/auto_moto/vehicle_conversation_repository.dart';
import 'package:az_express/auto_moto/vehicle_favorite_repository.dart';
import 'package:az_express/auto_moto/vehicle_listing_form_data.dart';
import 'package:az_express/auto_moto/vehicle_listing_repository.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _profile = VehicleSellerProfile(
  ownerId: 'seller-1',
  sellerType: VehicleSellerType.individual,
  displayName: 'Aya Kone',
  phone: '0700000000',
  cityId: 'abengourou',
);

const _conversation = VehicleConversation(
  id: 'conversation-1',
  listingId: 'listing-1',
  buyerId: 'buyer-1',
  sellerId: 'seller-1',
  participantIds: ['buyer-1', 'seller-1'],
  listingTitle: 'Toyota Corolla',
  listingPrice: 6500000,
  currency: 'XOF',
  sellerDisplayName: 'Aya Kone',
  sellerType: VehicleSellerType.individual,
  sellerVerificationStatus: VehicleSellerVerificationStatus.unverified,
);

VehicleListing _listing() => VehicleListingFormData(
      offerType: VehicleOfferType.sale,
      vehicleType: VehicleType.car,
      condition: VehicleCondition.used,
      brand: 'Toyota',
      model: 'Corolla',
      year: '2022',
      color: 'Gris',
      mileageKm: '25000',
      transmission: VehicleTransmission.automatic,
      fuelType: VehicleFuelType.petrol,
      seats: '5',
      salePrice: '6500000',
      title: 'Toyota Corolla',
      description: 'Vehicule disponible.',
    ).toListing(
      sellerId: 'seller-1',
      profile: _profile,
      cityId: 'abengourou',
      cityName: 'Abengourou',
    );

class _FakeConversations implements VehicleConversationDataSource {
  const _FakeConversations();

  @override
  Future<VehicleConversation?> getConversation(String id) async => _conversation;

  @override
  Future<VehicleConversationsPage> getConversations({
    required String uid,
    int pageSize = 20,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async =>
      const VehicleConversationsPage(
        conversations: [_conversation],
        nextCursor: null,
        hasMore: false,
      );

  @override
  Future<void> markRead(VehicleConversation conversation, String uid) async {}

  @override
  Future<void> sendMessage({
    required VehicleConversation conversation,
    required String senderId,
    required String text,
  }) async {}

  @override
  Stream<List<VehicleChatMessage>> watchMessages(String conversationId) =>
      Stream.value(const []);
}

Widget _app(Widget home) => MaterialApp(home: home);

class _RouteParent extends StatelessWidget {
  const _RouteParent({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: FilledButton(
            key: const Key('open_route'),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => child),
            ),
            child: const Text('Ouvrir'),
          ),
        ),
      );
}

Future<void> _expectMaybePop<T extends Widget>(
  WidgetTester tester,
  Widget child,
) async {
  await tester.pumpWidget(_app(_RouteParent(child: child)));
  await tester.tap(find.byKey(const Key('open_route')));
  await tester.pumpAndSettle();
  final destination = find.byType(T);
  expect(destination, findsOneWidget);

  final popped = await Navigator.of(tester.element(destination)).maybePop();
  expect(popped, isTrue);
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('open_route')), findsOneWidget);
  expect(find.byType(T), findsNothing);
}

void main() {
  group('retour Navigator des routes Auto & Moto', () {
    testWidgets('Marketplace vers Auto & Moto est dépilable', (tester) async {
      await _expectMaybePop<VehicleHomeScreen>(
        tester,
        VehicleHomeScreen(
          currentUserId: () => null,
          marketCitiesLoader: () async => const [],
        ),
      );
    });

    testWidgets('Auto & Moto vers liste est dépilable', (tester) async {
      await _expectMaybePop<VehicleListingsScreen>(
        tester,
        VehicleListingsScreen(
          offerType: VehicleOfferType.sale,
          vehicleType: VehicleType.car,
          cityId: null,
          pageLoader: ({
            required cityId,
            required offerType,
            required vehicleType,
            required pageSize,
            startAfter,
          }) async =>
              const VehicleListingsPage(
                listings: [],
                nextCursor: null,
                hasMore: false,
              ),
        ),
      );
    });

    testWidgets('liste et favoris vers détail sont dépilables', (tester) async {
      await _expectMaybePop<VehicleListingDetailScreen>(
        tester,
        VehicleListingDetailScreen(
          listing: _listing(),
          profileLoader: (_) async => _profile,
          currentUserId: () => 'buyer-1',
        ),
      );
    });

    testWidgets('mes annonces, profil et conversations sont dépilables',
        (tester) async {
      await _expectMaybePop<VehicleFavoritesScreen>(
        tester,
        VehicleFavoritesScreen(
          currentUserId: 'buyer-1',
          pageLoader: ({
            required uid,
            required pageSize,
            startAfter,
          }) async =>
              const VehicleFavoritesPage(
                favorites: [],
                nextCursor: null,
                hasMore: false,
              ),
        ),
      );
      await _expectMaybePop<MyVehicleListingsScreen>(
        tester,
        MyVehicleListingsScreen(
          profile: _profile,
          cityName: 'Abengourou',
          pageLoader: ({
            required sellerId,
            required pageSize,
            startAfter,
          }) async =>
              const VehicleListingsPage(
                listings: [],
                nextCursor: null,
                hasMore: false,
              ),
        ),
      );
      await _expectMaybePop<VehicleSellerProfileScreen>(
        tester,
        const VehicleSellerProfileScreen(
          ownerId: 'seller-1',
          initialProfile: _profile,
          cities: [],
        ),
      );
      await _expectMaybePop<VehicleConversationsScreen>(
        tester,
        const VehicleConversationsScreen(
          currentUserId: 'buyer-1',
          repository: _FakeConversations(),
        ),
      );
    });

    testWidgets('détail vers profil public et chat sont dépilables',
        (tester) async {
      await _expectMaybePop<VehiclePublicSellerProfileScreen>(
        tester,
        const VehiclePublicSellerProfileScreen(
          profile: _profile,
          cityName: 'Abengourou',
        ),
      );
      await _expectMaybePop<VehicleChatScreen>(
        tester,
        const VehicleChatScreen(
          conversation: _conversation,
          currentUserId: 'buyer-1',
          repository: _FakeConversations(),
        ),
      );
    });

    testWidgets('formulaire étape 0 : le retour AppBar dépile la route',
        (tester) async {
      await tester.pumpWidget(_app(_RouteParent(
        child: VehicleListingFormScreen(
          profile: _profile,
          cityId: 'abengourou',
          cityName: 'Abengourou',
          saveListing: (_) async {},
        ),
      )));
      await tester.tap(find.byKey(const Key('open_route')));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(VehicleListingFormScreen), findsNothing);
      expect(find.byKey(const Key('open_route')), findsOneWidget);
    });

    testWidgets('formulaire étape 1 : le retour AppBar revient à étape 0',
        (tester) async {
      await tester.pumpWidget(_app(VehicleListingFormScreen(
        profile: _profile,
        cityId: 'abengourou',
        cityName: 'Abengourou',
        saveListing: (_) async {},
      )));
      expect(find.text('1/9'), findsOneWidget);

      await tester.tap(find.text('Suivant'));
      await tester.pump();
      expect(find.text('2/9'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pump();
      expect(find.text('1/9'), findsOneWidget);
      expect(find.byType(VehicleListingFormScreen), findsOneWidget);
    });

    testWidgets('formulaire étape 1 : maybePop dépile toute la route',
        (tester) async {
      await tester.pumpWidget(_app(_RouteParent(
        child: VehicleListingFormScreen(
          profile: _profile,
          cityId: 'abengourou',
          cityName: 'Abengourou',
          saveListing: (_) async {},
        ),
      )));
      await tester.tap(find.byKey(const Key('open_route')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Suivant'));
      await tester.pump();
      expect(find.text('2/9'), findsOneWidget);

      final form = find.byType(VehicleListingFormScreen);
      final popped = await Navigator.of(tester.element(form)).maybePop();
      expect(popped, isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(VehicleListingFormScreen), findsNothing);
      expect(find.byKey(const Key('open_route')), findsOneWidget);
    });
  });
}
