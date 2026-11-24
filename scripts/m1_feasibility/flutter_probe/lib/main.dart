// Sonde M1.2 : exerce le VRAI SDK Flutter (firebase_auth/cloud_functions/cloud_firestore, Flutter web) contre les
// émulateurs locaux. Reproduit les appels de lib/services/auth_service.dart sans importer le code de l'application.
// Pilotée par le script Node (/config -> étapes -> POST /report).
import 'dart:convert';
import 'dart:js_interop';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

final List<Map<String, Object?>> results = [];

String codeOf(Object e) {
  if (e is FirebaseAuthException) return 'auth/${e.code}';
  if (e is FirebaseFunctionsException) return 'functions/${e.code}';
  if (e is FirebaseException) return '${e.plugin}/${e.code}';
  return e.runtimeType.toString();
}

/// Exécute une étape ; [expectError] = l'échec est le comportement attendu (on enregistre le code observé).
Future<void> step(String id, Future<Object?> Function() fn, {bool expectError = false}) async {
  try {
    final detail = await fn();
    results.add({'id': id, 'ok': !expectError, 'detail': detail?.toString(), if (expectError) 'note': 'aucune erreur levée'});
  } catch (e) {
    results.add({'id': id, 'ok': expectError, 'error': codeOf(e), 'detail': expectError ? null : e.toString()});
  }
}

Future<String> storageDiag() async {
  final dbs = await web.window.indexedDB.databases().toDart;
  final names = [for (var i = 0; i < dbs.length; i++) dbs[i].name];
  return 'localStorage.length=${web.window.localStorage.length} indexedDB=$names';
}

Future<void> mark(String origin, String m) async {
  try { await http.get(Uri.parse('$origin/log?m=${Uri.encodeQueryComponent(m)}')); } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final origin = Uri.base.origin;
  final phase = Uri.base.queryParameters['phase'] ?? '0';
  final cfg = jsonDecode((await http.get(Uri.parse('$origin/config'))).body) as Map<String, dynamic>;

  await mark(origin, 'config ok');
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: 'fake-api-key', appId: '1:1:web:m1probe', messagingSenderId: '1', projectId: 'demo-m1-feasibility',
    ),
  );
  await mark(origin, 'core ok');
  final auth = FirebaseAuth.instance;
  try {
    await auth.useAuthEmulator('127.0.0.1', 29199);
  } catch (e) {
    await mark(origin, 'useAuthEmulator: ' + codeOf(e));
  }
  await mark(origin, 'auth emulator ok');
  final fns = FirebaseFunctions.instanceFor(region: 'europe-west1')..useFunctionsEmulator('127.0.0.1', 29501);
  final fs = FirebaseFirestore.instance..useFirestoreEmulator('127.0.0.1', 29080);

  await mark(origin, 'sdk prêt');
  Future<Map<String, dynamic>> login(String id, String pw) async {
    final r = await fns.httpsCallable('clientPhoneLoginM1').call<dynamic>({'identifier': id, 'password': pw});
    return Map<String, dynamic>.from(r.data as Map);
  }

  final c = cfg['client'] as Map<String, dynamic>;
  final s = cfg['seller'] as Map<String, dynamic>;

  if (phase == '1') {
    // PHASE 1 : connexion par jeton personnalisé + opérations de cycle de vie + tentatives d'élévation de rôle.
    Map<String, dynamic>? res;
    await step('1 callable renvoie ok/customToken/role seulement', () async {
      res = await login(c['phone'] as String, c['pw'] as String);
      final keys = (res!.keys.toList()..sort()).join(',');
      if (keys != 'customToken,ok,role' || res!['role'] != 'client') throw 'réponse inattendue: $keys';
      return 'role=${res!['role']}';
    });
    UserCredential? cred;
    await step('2 signInWithCustomToken', () async {
      cred = await auth.signInWithCustomToken(res!['customToken'] as String);
      return 'uid=${cred!.user?.uid}';
    });
    await step('3 uid attendu', () async {
      if (auth.currentUser?.uid != c['uid']) throw 'uid différent';
      return 'ok';
    });
    await step('4 currentUser.email', () async => auth.currentUser?.email == c['email'] ? 'email=${auth.currentUser?.email}' : throw 'email=${auth.currentUser?.email}');
    await step('5 providerData / isAnonymous / emailVerified', () async {
      final u = auth.currentUser!;
      final tok = await u.getIdTokenResult();
      return 'providerData=${u.providerData.map((p) => p.providerId).toList()} isAnonymous=${u.isAnonymous} '
          'emailVerified=${u.emailVerified} signInProvider=${tok.signInProvider} '
          'additionalProvider=${cred?.additionalUserInfo?.providerId} isNew=${cred?.additionalUserInfo?.isNewUser}';
    });
    await step('6 réauthentification (EmailAuthProvider, comme auth_service.reauthenticateEmail)', () async {
      await auth.currentUser!.reauthenticateWithCredential(EmailAuthProvider.credential(email: auth.currentUser!.email!, password: c['pw'] as String));
      return 'ok uid=${auth.currentUser?.uid}';
    });
    await step('7 verifyBeforeUpdateEmail (updateEmail n existe plus dans firebase_auth 6.5.2)', () async {
      await auth.currentUser!.verifyBeforeUpdateEmail(c['newEmail'] as String);
      await auth.currentUser!.reload();
      return 'demande envoyée ; email courant inchangé=${auth.currentUser?.email == c['email']}';
    });
    await step('8 updatePassword', () async {
      await auth.currentUser!.updatePassword(c['newPw'] as String);
      return 'ok';
    });
    // Rôle : tout ce que le client peut tenter depuis le SDK.
    await step('9a écriture admins/{uid} refusée', () => fs.doc('admins/${c['uid']}').set({'role': 'super', 'isActive': true, 'permissions': <String>[]}), expectError: true);
    await step('9b écriture sellers/{uid} refusée', () => fs.doc('sellers/${c['uid']}').set({'name': 'x', 'phone': 'y', 'wallet': 0}), expectError: true);
    await step('9c modification de son wallet refusée', () => fs.doc('clients/${c['uid']}').update({'wallet': 999999}), expectError: true);
    await step('9d lecture du profil d un autre client refusée', () => fs.doc('clients/${cfg['otherClientUid']}').get(), expectError: true);
    await step('9e champ role=admin sur son profil : sans effet sur le rôle serveur ni les revendications', () async {
      String write;
      try {
        await fs.doc('clients/${c['uid']}').update({'role': 'admin'});
        write = 'écriture tolérée par les règles';
      } catch (e) {
        write = 'écriture refusée (${codeOf(e)})';
      }
      final who = await fns.httpsCallable('m1WhoAmI').call<dynamic>({});
      final tok = await auth.currentUser!.getIdTokenResult(true);
      final hasPriv = tok.claims?.containsKey('admin') == true || tok.claims?.containsKey('role') == true;
      return '$write ; whoami=${Map<String, dynamic>.from(who.data as Map)['role']} claimsPrivilege=$hasPriv';
    });
    await step('9f jeton rafraîchi : aucune revendication admin/role', () async {
      final tok = await auth.currentUser!.getIdTokenResult(true);
      return 'claims=${(tok.claims?.keys.toList() ?? [])..sort()}';
    });
  } else if (phase == '2') {
    // PHASE 2 : NOUVEAU processus navigateur, même profil de stockage.
    await step('10 session restaurée au redémarrage (uid, email)', () async {
      final immediate = auth.currentUser?.uid;
      var u = await auth.authStateChanges().first;
      if (u == null) {
        await Future<void>.delayed(const Duration(seconds: 3));
        u = auth.currentUser;
        if (u == null) throw 'aucune session restaurée (currentUser immédiat=$immediate, après 3 s=null)';
      }
      if (u == null) throw 'aucune session restaurée';
      if (u.uid != c['uid']) throw 'uid différent';
      return 'uid ok email=${u.email} providerData=${u.providerData.map((p) => p.providerId).toList()}';
    });
    await step('11 renouvellement du jeton après redémarrage', () async {
      final t = await auth.currentUser!.getIdToken(true);
      return t != null && t.isNotEmpty ? 'ok' : throw 'jeton vide';
    });
    await step('12 déconnexion', () async {
      await auth.signOut();
      return 'currentUser=${auth.currentUser}';
    });
  } else if (phase == '4') {
    // TÉMOIN : session ouverte par e-mail + mot de passe (parcours actuel), pour comparer la persistance.
    final o = cfg['other'] as Map<String, dynamic>;
    await step('30 témoin : signInWithEmailAndPassword', () async {
      final cr = await auth.signInWithEmailAndPassword(email: o['email'] as String, password: o['pw'] as String);
      return 'uid=${cr.user?.uid}';
    });
  } else if (phase == '5') {
    final o = cfg['other'] as Map<String, dynamic>;
    await step('31 témoin : session mot de passe restaurée au redémarrage', () async {
      final immediate = auth.currentUser?.uid;
      final u = await auth.authStateChanges().first;
      if (u == null) throw 'aucune session restaurée (currentUser immédiat=$immediate)';
      return 'uidOk=${u.uid == o['uid']}';
    });
  } else if (phase == '3') {
    // PHASE 3 : nouveau processus : déconnexion persistée, vendeur, erreurs, mot de passe changé, suppression.
    await step('13 déconnexion persistée au redémarrage', () async {
      final u = await auth.authStateChanges().first;
      return u == null ? 'currentUser=null' : throw 'session encore présente';
    });
    await step('14 vendeur : signInWithCustomToken, email (alias), providerData', () async {
      final r = await login(s['phone'] as String, s['pw'] as String);
      final cr = await auth.signInWithCustomToken(r['customToken'] as String);
      final u = cr.user!;
      final out = 'role=${r['role']} uidOk=${u.uid == s['uid']} email=${u.email} providerData=${u.providerData.map((p) => p.providerId).toList()}';
      await auth.signOut();
      return out;
    });
    await step('15 erreur : jeton personnalisé invalide', () => auth.signInWithCustomToken('pas.un.jeton'), expectError: true);
    await step('16 erreur : ancien mot de passe refusé par la callable (uniforme, sans exception)', () async {
      final r = await login(c['phone'] as String, c['pw'] as String);
      return r['ok'] == false && r['code'] == 'invalid-credentials' ? 'uniforme ${r['code']}' : throw 'réponse inattendue';
    });
    await step('17 erreur : callable protégée sans session', () => fns.httpsCallable('m1WhoAmI').call<dynamic>({}), expectError: true);
    await step('18 erreur : callable avec charge utile invalide (null)', () => fns.httpsCallable('clientPhoneLoginM1').call<dynamic>(null), expectError: true);
    await step('19 connexion avec le NOUVEAU mot de passe (changé par le SDK)', () async {
      final r = await login(c['phone'] as String, c['newPw'] as String);
      if (r['ok'] != true) throw 'refus';
      await auth.signInWithCustomToken(r['customToken'] as String);
      return 'uidOk=${auth.currentUser?.uid == c['uid']}';
    });
    await step('20 erreur : réauthentification avec un mauvais mot de passe', () => auth.currentUser!.reauthenticateWithCredential(EmailAuthProvider.credential(email: auth.currentUser!.email!, password: 'Mauvais-mdp-123')), expectError: true);
    await step('21 réauthentification avec le bon mot de passe puis suppression du compte', () async {
      await auth.currentUser!.reauthenticateWithCredential(EmailAuthProvider.credential(email: auth.currentUser!.email!, password: c['newPw'] as String));
      await auth.currentUser!.delete();
      return 'currentUser=${auth.currentUser}';
    });
  }

  if (phase == '2' || phase == '4' || phase == '5') await step('99 diagnostic stockage', storageDiag);
  await http.post(Uri.parse('$origin/report?phase=$phase'), headers: {'content-type': 'application/json'}, body: jsonEncode(results));
}
