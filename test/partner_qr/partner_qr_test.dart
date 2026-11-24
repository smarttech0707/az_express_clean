import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/partner_qr/partner_qr_page.dart';
import 'package:az_express/partner_qr/partner_qr_link.dart';
void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('selection lists authorized establishments and disables unavailable ones',(tester)async{
    await tester.pumpWidget(MaterialApp(home:PartnerQrEstablishmentsPage(loader:()async=>[
      {'kind':'restaurant','establishmentId':'a','name':'A','available':true},
      {'kind':'pharmacie','establishmentId':'b','name':'B','available':false},
    ])));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile),findsNWidgets(2));
    expect(tester.widgetList<ListTile>(find.byType(ListTile)).map((w)=>w.enabled).toList(),[true,false]);
  });
  test('only canonical public identification URLs are recognized',(){
    const token='12345678-1234-1234-1234-123456789012';
    expect(partnerQrToken('https://az-express-b0469.web.app/partenaire/$token'),token);
    for(final bad in ['https://evil.example/partenaire/$token','http://az-express-b0469.web.app/partenaire/$token','https://az-express-b0469.web.app/partenaire/$token?secret=x','123456','qr_v1']){
      expect(partnerQrToken(bad),isNull);
    }
  });
  test('actual export produces a PNG with printing dimensions',()async{
    final bytes=await renderPartnerQrPng('https://az-express-b0469.web.app/partenaire/test-qr');
    expect(bytes.take(8).toList(),[137,80,78,71,13,10,26,10]);
    final codec=await ui.instantiateImageCodec(bytes);
    final frame=await codec.getNextFrame();
    expect(frame.image.width,1152);expect(frame.image.height,1152);
    frame.image.dispose();codec.dispose();
  });
  testWidgets('public page shows only public identification, never delivery confirmation',(tester)async{
    await tester.pumpWidget(MaterialApp(home:PublicPartnerPage(token:'test',load:(_)async=>{'available':true,'name':'Restaurant test','kind':'restaurant'})));
    await tester.pumpAndSettle();expect(find.text('Restaurant test'),findsOneWidget);
    expect(find.textContaining('pas une preuve'),findsOneWidget);
  });
  testWidgets('suspended page does not show former public name',(tester)async{
    await tester.pumpWidget(MaterialApp(home:PublicPartnerPage(token:'test',load:(_)async=>{'available':false,'name':'Old name'})));
    await tester.pumpAndSettle();expect(find.textContaining('suspendu'),findsOneWidget);expect(find.text('Old name'),findsNothing);
  });
  testWidgets('network failure never claims an establishment is verified',(tester)async{
    await tester.pumpWidget(MaterialApp(home:PublicPartnerPage(token:'test',load:(_)async=>throw StateError('offline'))));
    await tester.pumpAndSettle();expect(find.textContaining('Verification indisponible'),findsOneWidget);
  });
}
