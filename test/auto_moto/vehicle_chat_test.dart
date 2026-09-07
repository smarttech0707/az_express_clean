import 'package:az_express/auto_moto/models/vehicle_conversation.dart';
import 'package:az_express/auto_moto/models/vehicle_listing.dart';
import 'package:az_express/auto_moto/models/vehicle_seller_profile.dart';
import 'package:az_express/auto_moto/screens/vehicle_chat_screen.dart';
import 'package:az_express/auto_moto/vehicle_conversation_repository.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const conversation = VehicleConversation(
  id: 'vc_listing-1_buyer-1',
  listingId: 'listing-1',
  buyerId: 'buyer-1',
  sellerId: 'seller-1',
  participantIds: ['buyer-1', 'seller-1'],
  listingTitle: 'Toyota Corolla 2018',
  listingPrice: 6500000,
  currency: 'XOF',
  sellerDisplayName: 'AZ Motors',
  sellerType: VehicleSellerType.professional,
  sellerVerificationStatus: VehicleSellerVerificationStatus.unverified,
  sellerUnreadCount: 2,
);

class FakeChatRepository implements VehicleConversationDataSource {
  final sent = <String>[];
  final readBy = <String>[];
  bool sending = false;

  @override
  Stream<List<VehicleChatMessage>> watchMessages(String conversationId) =>
      Stream.value(const []);

  @override
  Future<void> sendMessage({
    required VehicleConversation conversation,
    required String senderId,
    required String text,
  }) async {
    sending = true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    sent.add(text.trim());
    sending = false;
  }

  @override
  Future<void> markRead(VehicleConversation conversation, String uid) async {
    readBy.add(uid);
  }

  @override
  Future<VehicleConversation?> getConversation(String id) async => conversation;

  @override
  Future<VehicleConversationsPage> getConversations({
    required String uid,
    int pageSize = 20,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async =>
      const VehicleConversationsPage(
        conversations: [conversation],
        nextCursor: null,
        hasMore: false,
      );
}

Widget app(Widget home, {ThemeMode mode = ThemeMode.light}) => MaterialApp(
      theme: ThemeData.light(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: mode,
      home: home,
    );

void main() {
  test('identifiant conversation déterministe et validation message', () {
    expect(
      VehicleConversationRepository.conversationIdFor('listing-1', 'buyer-1'),
      'vc_listing-1_buyer-1',
    );
    expect(VehicleChatValidator.validateMessage('   '), isNotNull);
    expect(
      VehicleChatValidator.validateMessage(List.filled(1001, 'x').join()),
      isNotNull,
    );
    expect(VehicleChatValidator.validateMessage(' Bonjour '), isNull);
    expect(conversation.unreadFor('seller-1'), 2);
    expect(conversation.unreadFor('other'), 0);
  });

  testWidgets('chat affiche annonce, sécurité et aucun faux badge vérifié',
      (tester) async {
    final repository = FakeChatRepository();
    await tester.pumpWidget(app(VehicleChatScreen(
      conversation: conversation,
      currentUserId: 'buyer-1',
      repository: repository,
    )));
    await tester.pump();
    expect(find.text('Toyota Corolla 2018'), findsOneWidget);
    expect(find.text('Professionnel'), findsOneWidget);
    expect(find.text('Vérifié'), findsNothing);
    expect(find.textContaining('n’est pas partie à la transaction'),
        findsOneWidget);
    expect(repository.readBy, ['buyer-1']);
  });

  testWidgets('trim, anti-double-envoi et clavier sur petit écran sombre',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = FakeChatRepository();
    await tester.pumpWidget(app(
      VehicleChatScreen(
        conversation: conversation,
        currentUserId: 'buyer-1',
        repository: repository,
      ),
      mode: ThemeMode.dark,
    ));
    await tester.enterText(
      find.byKey(const Key('vehicle_chat_input')),
      ' Bonjour ',
    );
    await tester.showKeyboard(find.byKey(const Key('vehicle_chat_input')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('vehicle_chat_send')));
    await tester.tap(find.byKey(const Key('vehicle_chat_send')));
    await tester.pumpAndSettle();
    expect(repository.sent, ['Bonjour']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blocage conserve historique et masque le compositeur sur 320 px',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(
      VehicleChatScreen(
        conversation: conversation,
        currentUserId: 'buyer-1',
        repository: FakeChatRepository(),
        blockedLoader: () async => true,
      ),
      mode: ThemeMode.dark,
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Conversation bloquée'), findsOneWidget);
    expect(find.byKey(const Key('vehicle_chat_input')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
