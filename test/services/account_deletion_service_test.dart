import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
// ignore_for_file: depend_on_referenced_packages, implementation_imports
import 'package:flutter/services.dart' show PlatformException;
import 'package:cloud_functions_platform_interface/src/method_channel/utils/exception.dart' show platformExceptionToFirebaseFunctionsException;
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
  test('closed gateway refusal is not a success and never reads as a recorded request', () {
    const e = AccountDeletionUnavailableException();
    expect(e, isA<Exception>());
    expect(e.message, 'Le service de suppression de compte n’est pas disponible pour le moment. Votre demande n’a pas été enregistrée et votre compte reste inchangé. Réessayez plus tard ou contactez le support.');
    expect(e.message, isNot(contains('conserv')));
    expect(e.toString(), e.message);
  });
  test('gate refusal is recognised by machine reason, by message fallback, and only for failed-precondition', () {
    expect(AccountDeletionService.isGateClosedRefusal(FirebaseFunctionsException(message:'x',code:'failed-precondition',details:const {'reason':'ACCOUNT_DELETION_NOT_ENABLED'})),isTrue);
    expect(AccountDeletionService.isGateClosedRefusal(FirebaseFunctionsException(message:'ACCOUNT_DELETION_NOT_ENABLED',code:'failed-precondition')),isTrue);
    expect(AccountDeletionService.isGateClosedRefusal(FirebaseFunctionsException(message:'RATE_LIMITER_REQUIRED',code:'failed-precondition')),isFalse);
    expect(AccountDeletionService.isGateClosedRefusal(FirebaseFunctionsException(message:'ACCOUNT_DELETION_NOT_ENABLED',code:'unavailable')),isFalse);
    expect(AccountDeletionService.isGateClosedRefusal(FirebaseFunctionsException(message:'x',code:'failed-precondition',details:const {'reason':'OTHER'})),isFalse);
  });
  // Contrat avec la fonction callable. Le corps d'erreur ci-dessous est celui RECU de l'emulateur Functions (mission 7E-76) :
  // HTTP 400 {"error":{"details":{"reason":"ACCOUNT_DELETION_NOT_ENABLED"},"message":"ACCOUNT_DELETION_NOT_ENABLED","status":"FAILED_PRECONDITION"}}.
  // Le SDK natif (Android/iOS) remet `details` dans PlatformException.details['additionalData'] ; on utilise ici le VRAI
  // convertisseur du plugin pour obtenir l'exception que verra l'application.
  FirebaseFunctionsException fromNative(String code, String message, [Object? details]) =>
      platformExceptionToFirebaseFunctionsException(
        PlatformException(code: code, message: message, details: {'code': code, 'message': message, if (details != null) 'additionalData': details}),
        StackTrace.empty) as FirebaseFunctionsException;
  test('callable contract: details.reason survives the plugin conversion and is read first', () {
    final e = fromNative('failed-precondition', 'texte reformule sans le code', {'reason': 'ACCOUNT_DELETION_NOT_ENABLED'});
    expect(e.code, 'failed-precondition');
    expect(e.details, isA<Map>());
    expect(AccountDeletionService.isGateClosedRefusal(e), isTrue);
  });
  test('callable contract: web details (Map<Object?, Object?>) are read the same way', () {
    final e = FirebaseFunctionsException(message: 'x', code: 'failed-precondition', details: const <Object?, Object?>{'reason': 'ACCOUNT_DELETION_NOT_ENABLED'});
    expect(AccountDeletionService.isGateClosedRefusal(e), isTrue);
  });
  test('callable contract: other failed-precondition and other errors are never taken for a closed gateway', () {
    for (final e in [
      fromNative('failed-precondition', 'RATE_LIMITER_REQUIRED'),
      fromNative('failed-precondition', 'autre', {'reason': 'AUTRE_RAISON'}),
      fromNative('failed-precondition', 'autre', 'details en texte'),
      fromNative('unavailable', 'ACCOUNT_DELETION_NOT_ENABLED', {'reason': 'ACCOUNT_DELETION_NOT_ENABLED'}),
      fromNative('unauthenticated', 'Connexion requise'),
      fromNative('invalid-argument', 'Demande invalide'),
      fromNative('resource-exhausted', 'Trop de tentatives'),
      fromNative('unknown', 'inconnu'),
    ]) {
      expect(AccountDeletionService.isGateClosedRefusal(e), isFalse, reason: '${e.code} ${e.message}');
    }
  });
  // 7E-83 : discrimination entre la reconnaissance STRUCTUREE (details.reason) et le REPLI TEXTUEL (message).
  // Ces cas sont des tests unitaires : seul le premier a un equivalent observe sur appareil (7E-83, journal natif).
  test('structured reason alone is sufficient: unrelated message, no trace of the code in the text', () async {
    final e = fromNative('failed-precondition', 'Message totalement different, sans aucun code machine', {'reason': 'ACCOUNT_DELETION_NOT_ENABLED'});
    expect(e.message, isNot(contains('ACCOUNT_DELETION_NOT_ENABLED')));
    expect(AccountDeletionService.isGateClosedRefusal(e), isTrue);
    var asked = 0;
    await expectLater(
      AccountDeletionService.resolveCallableFailure(e, () async { asked++; throw StateError('recu ne doit pas etre lu'); }),
      throwsA(isA<AccountDeletionUnavailableException>()));
    expect(asked, 0);
  });
  test('text fallback only (no details at all): still a refusal, but through the textual fallback path', () async {
    for (final e in [
      FirebaseFunctionsException(message: 'ACCOUNT_DELETION_NOT_ENABLED', code: 'failed-precondition'),
      fromNative('failed-precondition', 'ACCOUNT_DELETION_NOT_ENABLED'),
      FirebaseFunctionsException(message: 'ACCOUNT_DELETION_NOT_ENABLED', code: 'failed-precondition', details: 'details en texte'),
    ]) {
      expect(e.details is Map, isFalse, reason: 'cas sans details structures');
      expect(AccountDeletionService.isGateClosedRefusal(e), isTrue, reason: 'repli textuel (version de fonction anterieure)');
    }
  });
  test('neither structured reason nor the code in the text: never a refusal', () {
    expect(AccountDeletionService.isGateClosedRefusal(fromNative('failed-precondition', 'Message sans code', {'reason': 'AUTRE'})), isFalse);
    expect(AccountDeletionService.isGateClosedRefusal(fromNative('failed-precondition', 'Message sans code')), isFalse);
  });
  test('closed gateway never reads an older receipt; other failures still ask the server receipt', () async {
    var asked = 0;
    const older = AccountDeletionRequestResult('ancien-dossier', status: 'quarantined');
    Future<AccountDeletionRequestResult> last() async { asked++; return older; }
    await expectLater(
      AccountDeletionService.resolveCallableFailure(fromNative('failed-precondition', 'ACCOUNT_DELETION_NOT_ENABLED', {'reason': 'ACCOUNT_DELETION_NOT_ENABLED'}), last),
      throwsA(isA<AccountDeletionUnavailableException>().having((x) => x.message, 'message', 'Le service de suppression de compte n’est pas disponible pour le moment. Votre demande n’a pas été enregistrée et votre compte reste inchangé. Réessayez plus tard ou contactez le support.')));
    expect(asked, 0);
    final r = await AccountDeletionService.resolveCallableFailure(fromNative('unavailable', 'reseau'), last);
    expect(asked, 1);
    expect(r.requestId, 'ancien-dossier');
    // Les autres erreurs ne sont jamais transformees en refus de suppression : elles suivent le chemin du recu serveur.
    for (final code in ['unauthenticated', 'invalid-argument', 'resource-exhausted', 'unknown', 'internal']) {
      final before = asked;
      await AccountDeletionService.resolveCallableFailure(fromNative(code, 'x'), last);
      expect(asked, before + 1, reason: code);
    }
  });
  test('really recorded request keeps its confirmation (body received from the emulator, gateway open)', () {
    final r = AccountDeletionRequestResult.fromData({'status': 'quarantined', 'reason': 'waiting_for_inflight_operations',
      'requestId': 'BjoTJqAk4qZWapB62sd38JsZfbPu', 'authDeleted': false, 'profileAnonymized': false, 'reviewRequired': false});
    expect(r.accessClosed, isTrue);
    expect(r.message, contains('enregistr'));
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
