import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:az_express/models/order_model.dart';
import 'package:az_express/models/decline_order_result.dart';
import 'package:az_express/services/firestore_service.dart';
import 'package:az_express/screens/driver/driver_dashboard.dart';
class FakeService implements FirestoreService {
  int calls=0;
  final result=Completer<DeclineOrderResult>();
  @override Future<DeclineOrderResult> declineOrder(String orderId,String driverId) {calls++; return result.future;}
  @override int calculateDriverGain(int budget)=>400;
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
void main() {
  Future<void> open(WidgetTester t, FakeService service, Stream<Map<String,dynamic>?> updates, VoidCallback done) async {
    await t.binding.setSurfaceSize(const Size(1000,1400));
    await t.pumpWidget(MaterialApp(home:Scaffold(body:Builder(builder:(context)=>TextButton(onPressed:(){
      showDialog<void>(context:context,builder:(_)=>OrderRequestDialog(
        order:OrderModel(id:'o',description:'Course',budget:500,status:'assigned',latitude:6,longitude:-3,type:'delivery',driverId:'d'),
        driverId:'d',driverLat:6,driverLng:-3,firestore:service,onDone:done,orderUpdates:updates));
    },child:const Text('open'))))));
    await t.tap(find.text('open'));await t.pump();await t.pump(const Duration(milliseconds:400));
  }
  testWidgets('double click blocked, recovery message and one close',(t) async {
    final s=FakeService();final events=StreamController<Map<String,dynamic>?>();int closed=0;
    await open(t,s,events.stream,()=>closed++);
    final click=t.widget<OutlinedButton>(find.byType(OutlinedButton).last).onPressed!;
    click();click();await t.pump();
    expect(t.widget<ElevatedButton>(find.byType(ElevatedButton).last).onPressed,isNull);
    expect(find.text('Refus en cours...'),findsOneWidget);
    expect(t.widget<OutlinedButton>(find.byType(OutlinedButton).last).onPressed,isNull);
    events.add({'status':'pending'});await t.pump();expect(closed,0);
    s.result.complete(const DeclineOrderResult(recoveryPending:true));await t.pumpAndSettle();
    expect(s.calls,1);expect(closed,1);expect(find.textContaining('Reprise de la recherche'),findsOneWidget);
    unawaited(events.close());await t.pumpWidget(const SizedBox());
  });
  testWidgets('callable error allows retry without closing',(t) async {
    final s=FakeService();final events=StreamController<Map<String,dynamic>?>();int closed=0;
    await open(t,s,events.stream,()=>closed++);await t.tap(find.text('Refuser'));await t.pump();
    s.result.completeError(FirebaseFunctionsException(code:'unavailable',message:'offline'));
    await t.pump();expect(find.textContaining('Refus non confirme'),findsOneWidget);expect(closed,0);
    expect(t.widget<OutlinedButton>(find.byType(OutlinedButton).last).onPressed,isNotNull);
    await t.pumpWidget(const SizedBox());unawaited(events.close());
  });
  for(final update in [null,{'status':'cancelled'},{'status':'assigned','driverId':'other'},{'status':'accepted','driverId':'d'}]) {
    testWidgets('invalid assignment closes once: $update',(t) async {
      final s=FakeService();final events=StreamController<Map<String,dynamic>?>();int closed=0;
      await open(t,s,events.stream,()=>closed++);events.add(update);events.add(update);
      await t.pumpAndSettle();expect(closed,1);expect(s.calls,0);unawaited(events.close());await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets('listener error is not a refusal',(t) async {
    final s=FakeService();final events=StreamController<Map<String,dynamic>?>();int closed=0;
    await open(t,s,events.stream,()=>closed++);events.addError(StateError('offline'));await t.pump();
    expect(closed,0);expect(s.calls,0);expect(find.textContaining('Synchronisation indisponible'),findsOneWidget);
    await t.pumpWidget(const SizedBox());unawaited(events.close());
  });
  testWidgets('timer refuses once and a late response after disposal is safe',(t) async {
    final s=FakeService();final events=StreamController<Map<String,dynamic>?>();int closed=0;
    await open(t,s,events.stream,()=>closed++);
    await t.pump(const Duration(seconds:30));expect(s.calls,1);
    await t.pump(const Duration(seconds:30));expect(s.calls,1);
    await t.pumpWidget(const SizedBox());
    s.result.complete(const DeclineOrderResult());await t.pump();
    expect(closed,0);expect(t.takeException(),isNull);unawaited(events.close());
  });

}
