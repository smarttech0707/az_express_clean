import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:az_express/services/account_deletion_service.dart';
import 'package:az_express/widgets/account_deletion_dialog.dart';
void main() {
  Future<void> open(WidgetTester tester,AccountDeletionSubmit submit, {String role = 'livreur'}) async {
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:Builder(builder:(context)=>TextButton(
      onPressed:()=>showAccountDeletionRequestDialog(context,role:role,initialPhone:'0000000000',submit:submit),child:const Text('open'))))));
    await tester.tap(find.text('open'));await tester.pumpAndSettle();
  }
  testWidgets('partner warning describes conditional deletion without promising completion',(tester)async{
    await open(tester,({required role,required contactPhone,reason})async=>const AccountDeletionRequestResult('test'),role:'restaurant');
    expect(find.textContaining('Seule une confirmation definitive'),findsOneWidget);
    expect(find.textContaining('tous ses profils lies'),findsOneWidget);
    expect(find.textContaining('conservees separement'),findsNothing);
  });
  testWidgets('one pending request and truthful result after acknowledgement',(tester)async{
    final ack=Completer<AccountDeletionRequestResult>();int calls=0;
    await open(tester,({required role,required contactPhone,reason}){calls++;return ack.future;});
    final click=tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed!;click();click();await tester.pump();
    expect(calls,1);expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,isNull);
    expect(find.byType(SnackBar),findsNothing);
    ack.complete(const AccountDeletionRequestResult('test'));await tester.pumpAndSettle();
    expect(find.textContaining('non termin'),findsOneWidget);expect(find.text('Compte supprimé'),findsNothing);
  });
  testWidgets('server refusal displays error and permits retry',(tester)async{
    await open(tester,({required role,required contactPhone,reason})async=>throw FirebaseException(plugin:'cloud_firestore',code:'permission-denied'));
    await tester.tap(find.text('Envoyer la demande'));await tester.pumpAndSettle();
    expect(find.textContaining('Demande refusee'),findsOneWidget);expect(find.byType(SnackBar),findsNothing);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,isNotNull);
  });
  testWidgets('closed gateway: states that the request was NOT recorded, never a confirmation',(tester)async{
    await open(tester,({required role,required contactPhone,reason})async=>throw const AccountDeletionUnavailableException());
    await tester.tap(find.text('Envoyer la demande'));await tester.pumpAndSettle();
    expect(find.text('Le service de suppression de compte n’est pas disponible pour le moment. Votre demande n’a pas été enregistrée et votre compte reste inchangé. Réessayez plus tard ou contactez le support.'),findsOneWidget);
    expect(find.textContaining('Votre demande est conservee'),findsNothing);
    expect(find.byType(SnackBar),findsNothing);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,isNotNull);
  });
  testWidgets('network failure never claims the request was recorded',(tester)async{
    await open(tester,({required role,required contactPhone,reason})async=>throw FirebaseException(plugin:'cloud_functions',code:'unavailable'));
    await tester.tap(find.text('Envoyer la demande'));await tester.pumpAndSettle();
    expect(find.textContaining('Enregistrement non confirme'),findsOneWidget);
    expect(find.textContaining('Aucune suppression confirmee'),findsOneWidget);
    expect(find.textContaining('pas disponible'),findsNothing);
    expect(find.textContaining('Votre demande est conservee'),findsNothing);
  });
  testWidgets('reauthentication failures ask the user to sign in again',(tester)async{
    for(final code in ['requires-recent-login','unauthenticated']){
      await open(tester,({required role,required contactPhone,reason})async=>throw FirebaseException(plugin:'firebase_auth',code:code));
      await tester.tap(find.text('Envoyer la demande'));await tester.pumpAndSettle();
      expect(find.textContaining('Reauthentification requise'),findsOneWidget,reason:code);
      expect(find.textContaining('pas disponible'),findsNothing,reason:code);
      await tester.pumpWidget(const SizedBox());
    }
  });
  testWidgets('late failure after disposal is harmless',(tester)async{
    final ack=Completer<AccountDeletionRequestResult>();
    await open(tester,({required role,required contactPhone,reason})=>ack.future);
    await tester.tap(find.text('Envoyer la demande'));await tester.pump();await tester.pumpWidget(const SizedBox());
    ack.completeError(StateError('offline'));await tester.pump();expect(tester.takeException(),isNull);
  });
}
