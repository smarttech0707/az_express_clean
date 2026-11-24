import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

/// TEMPORAIRE (diagnostic du spinner Livreur, APK de test uniquement) : lectures chronométrées de chaque
/// service Firebase, à comparer avec les données des émulateurs. À retirer après résolution.
class EmulatorDiagnostics {
  const EmulatorDiagnostics._();

  static Future<void> _step(String name, Future<Object?> Function() run) async {
    final sw = Stopwatch()..start();
    try {
      final r = await run().timeout(const Duration(seconds: 25));
      debugPrint('[AZ_DIAG] $name OK ${sw.elapsedMilliseconds}ms $r');
    } on TimeoutException {
      debugPrint('[AZ_DIAG] $name TIMEOUT >25s');
    } catch (e) {
      debugPrint('[AZ_DIAG] $name ERREUR ${sw.elapsedMilliseconds}ms ${e.runtimeType} $e');
    }
  }

  static Future<void> run() async {
    final user = FirebaseAuth.instance.currentUser;
    debugPrint('[AZ_DIAG] debut uid=${user?.uid}');
    await _step('auth.getIdToken', () async => (await user?.getIdToken())?.length);
    if (user == null) return;
    final ref = FirebaseFirestore.instance.collection('livreurs').doc(user.uid);
    await _step('firestore.snapshots().first', () async {
      final d = await ref.snapshots().first;
      return 'exists=${d.exists} fromCache=${d.metadata.isFromCache} wallet=${d.data()?['wallet']}';
    });
    await _step('firestore.query.get(server)', () async {
      final q = await FirebaseFirestore.instance.collection('livreurs').limit(1).get(const GetOptions(source: Source.server));
      return 'docs=${q.docs.length}';
    });
    await _step('firestore.waitForPendingWrites', () async {
      await FirebaseFirestore.instance.waitForPendingWrites();
      return 'ok';
    });
    await _step('firestore.get(server)', () async {
      final d = await ref.get(const GetOptions(source: Source.server));
      return 'exists=${d.exists} wallet=${d.data()?['wallet']} fromCache=${d.metadata.isFromCache}';
    });
    await _step('firestore.get(default)', () async {
      final d = await ref.get();
      return 'exists=${d.exists} wallet=${d.data()?['wallet']} fromCache=${d.metadata.isFromCache}';
    });
    await _step('firestore.get(cache)', () async {
      final d = await ref.get(const GetOptions(source: Source.cache));
      return 'exists=${d.exists}';
    });
    await _step('firestore.orders.get(server)', () async {
      final d = await FirebaseFirestore.instance.collection('orders').doc('test-livraison-cash').get(const GetOptions(source: Source.server));
      return 'exists=${d.exists} status=${d.data()?['status']}';
    });
    await _step('functions.call(inexistante)', () async {
      try {
        await FirebaseFunctions.instanceFor(region: 'europe-west1').httpsCallable('azDiagPing').call();
        return 'reponse';
      } on FirebaseFunctionsException catch (e) {
        return 'code=${e.code} (aller-retour emulateur)';
      }
    });
    await _step('storage.getMetadata(inexistant)', () async {
      try {
        await FirebaseStorage.instance.ref('azdiag/none.jpg').getMetadata();
        return 'reponse';
      } on FirebaseException catch (e) {
        return 'code=${e.code} (aller-retour emulateur)';
      }
    });
  }
}
