import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:az_express/services/account_deletion_service.dart';
void main() {
  for (final role in AccountDeletionService.roleCollections.keys) {
    test('$role records pending only after acknowledgement', () async {
      final ack=Completer<String>(); Map<String,dynamic>? stored; bool returned=false;
      final future=AccountDeletionService.submitRequestUsing(role:role,contactPhone:'0000000000',authenticatedUid:'test-uid',
        write:(data){stored=data;return ack.future;}).then((r){returned=true;return r;});
      await Future<void>.delayed(Duration.zero);expect(returned,false);expect(stored!['status'],'pending');
      expect(stored!['uid'],'test-uid');expect(stored!['docId'],isNull);
      ack.complete('request-test');final result=await future;expect(result.status,'pending');expect(result.requestId,'request-test');
      expect(result.completed,false);expect(result.message,contains('non termin')); 
    });
  }
  for (final role in AccountDeletionService.manualOnlyRoles) {
    test('$role (sans moteur automatique) : demande manuelle en attente, jamais annoncée comme supprimée', () async {
      Map<String,dynamic>? stored;
      final result=await AccountDeletionService.submitRequestUsing(role:role,contactPhone:'0000000000',
        write:(data){stored=data;return Future.value('request-manual');});
      expect(stored!['role'],role);expect(stored!['status'],'pending');
      expect(result.completed,false);
      expect(AccountDeletionService.roleLabels.containsKey(role),true);
      expect(AccountDeletionService.roleCollections.containsKey(role),false); // pas d'appel au moteur serveur
    });
  }
  test('permission failure cannot return success', () async {
    await expectLater(AccountDeletionService.submitRequestUsing(role:'client',contactPhone:'0000000000',
      write:(_)=>Future.error(FirebaseException(plugin:'cloud_firestore',code:'permission-denied'))),throwsA(isA<FirebaseException>()));
  });
  test('missing acknowledgement is not success', () async {
    await expectLater(AccountDeletionService.submitRequestUsing(role:'livreur',contactPhone:'0000000000',write:(_)async=>''),throwsStateError);
  });
  test('invalid role or phone causes no write', () async {
    int writes=0;Future<String> write(Map<String,dynamic> _)async{writes++;return 'id';}
    await expectLater(AccountDeletionService.submitRequestUsing(role:'admin',contactPhone:'000',write:write),throwsArgumentError);
    await expectLater(AccountDeletionService.submitRequestUsing(role:'client',contactPhone:' ',write:write),throwsArgumentError);expect(writes,0);
  });
  test('legacy destructive method fails before accessing Firebase', () async {
    // ignore: deprecated_member_use_from_same_package
    await expectLater(AccountDeletionService.deleteClientAccountNow(password:'test-password'),throwsStateError);
  });
  test('completed requires both Auth and cleanup confirmations', () {
    for(final data in [
      {'requestId':'u','status':'completed','authDeleted':false,'profileAnonymized':true},
      {'requestId':'u','status':'completed','authDeleted':true,'profileAnonymized':false},
      {'requestId':'u','status':'deleted'}]) {
      expect(()=>AccountDeletionRequestResult.fromData(data),throwsFormatException);
    }
    final result=AccountDeletionRequestResult.fromData({'requestId':'u','status':'completed','authDeleted':true,'profileAnonymized':true});
    expect(result.completed,true);expect(result.message,'Compte supprimé');
  });
  test('quarantine and blocked states never announce deletion', () {
    for(final state in ['pending','blocked','quarantined','cleanup_pending']) {
      final result=AccountDeletionRequestResult.fromData({'requestId':'u','status':state,'authDeleted':true});
      expect(result.completed,false);expect(result.message,contains('non termin'));
    }
  });

}
