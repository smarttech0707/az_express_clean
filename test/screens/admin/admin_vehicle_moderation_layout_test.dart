import 'package:az_express/screens/admin/admin_vehicle_moderation_page.dart';
// ignore: depend_on_referenced_packages
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart'
    as platform;
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late platform.FirebaseFirestorePlatform original;
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    original = platform.FirebaseFirestorePlatform.instance;
    platform.FirebaseFirestorePlatform.instance = _EmptyStore();
    GoogleFonts.config.allowRuntimeFetching = false;
  });
  tearDownAll(() {
    platform.FirebaseFirestorePlatform.instance = original;
    GoogleFonts.config.allowRuntimeFetching = true;
  });

  for (final width in [320.0, 360.0, 412.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Android $width px, texte x$scale: titre, onglets et vide',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 640);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetPadding);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(MaterialApp(
          navigatorKey: navigator,
          theme: ThemeData(platform: TargetPlatform.android),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(),
        ));
        navigator.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const AdminVehicleModerationPage(),
        ));
        await tester.pumpAndSettle();
        expect(find.byType(BackButton), findsOneWidget);
        final title = find.text('Modération Auto & Moto');
        final titleRect = tester.getRect(title);
        expect(
            titleRect.left,
            greaterThanOrEqualTo(
                tester.getRect(find.byType(BackButton)).right));
        expect(titleRect.right, lessThanOrEqualTo(width));
        final titleParagraph = tester.renderObject<RenderParagraph>(title);
        expect(titleParagraph.maxLines, 1);
        expect(titleParagraph.overflow, TextOverflow.ellipsis);

        final tabs = tester.widget<TabBar>(find.byType(TabBar));
        for (final entry in [
          'Annonces',
          'Vendeurs',
          'Pros/Magasins',
          'Signalements',
        ].asMap().entries) {
          final label = find.text(entry.value);
          await tester.ensureVisible(label);
          await tester.pumpAndSettle();
          await tester.tap(label);
          await tester.pumpAndSettle();
          expect(tabs.controller!.index, entry.key);
          final paragraph = tester.renderObject<RenderParagraph>(label);
          expect(paragraph.didExceedMaxLines, isFalse);
          final labelRect = tester.getRect(label);
          final barRect = tester.getRect(find.byType(TabBar));
          expect(labelRect.left, greaterThanOrEqualTo(-0.1));
          expect(labelRect.right, lessThanOrEqualTo(width + 0.1));
          expect(labelRect.top, greaterThanOrEqualTo(barRect.top));
          expect(labelRect.bottom, lessThanOrEqualTo(barRect.bottom));
          final empty = find.text('Aucun élément.').hitTestable();
          expect(empty, findsOneWidget);
          final viewport = tester.getRect(find.byType(TabBarView));
          final emptyCenter = tester.getCenter(empty);
          expect(emptyCenter.dx, closeTo(viewport.center.dx, 1));
          expect(emptyCenter.dy, closeTo(viewport.center.dy, 1));
          expect(viewport.bottom, lessThanOrEqualTo(616));
          expect(viewport.height, greaterThan(400));
          expect(tester.takeException(), isNull);
        }
        await tester.drag(find.byType(TabBarView), Offset(width * 0.8, 0));
        await tester.pumpAndSettle();
        expect(tabs.controller!.index, 2);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

class _EmptyStore extends platform.FirebaseFirestorePlatform {
  @override
  platform.FirebaseFirestorePlatform delegateFor({
    required FirebaseApp app,
    required String databaseId,
  }) =>
      this;

  @override
  platform.CollectionReferencePlatform collection(String collectionPath) =>
      _EmptyCollection(this, collectionPath);
}

class _EmptyCollection extends platform.CollectionReferencePlatform {
  _EmptyCollection(super.firestore, super.path) {
    parameters.addAll({
      'where': <List<dynamic>>[],
      'orderBy': <List<dynamic>>[],
      'limit': null,
      'limitToLast': null,
      'startAt': null,
      'startAfter': null,
      'endAt': null,
      'endBefore': null,
    });
  }

  @override
  platform.QueryPlatform orderBy(Iterable<List<dynamic>> orders) => this;
  @override
  platform.QueryPlatform limit(int limit) => this;
  @override
  platform.QueryPlatform where(List<List<dynamic>> conditions) => this;
  @override
  Future<platform.QuerySnapshotPlatform> get(
          [platform.GetOptions options = const platform.GetOptions()]) async =>
      platform.QuerySnapshotPlatform(
          [], [], platform.SnapshotMetadataPlatform(false, false));
}
